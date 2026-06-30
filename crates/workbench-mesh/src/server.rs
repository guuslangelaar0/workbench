use std::collections::BTreeSet;
use std::fs;
use std::net::SocketAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result};
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use futures_util::{SinkExt, StreamExt};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::net::TcpListener;
use tokio::sync::broadcast;
use tower_http::cors::CorsLayer;

use crate::auth;
use crate::net::detect_bind;
use crate::protocol::EventEnvelope;
use crate::store::MeshStore;

#[derive(Debug, Clone)]
pub struct ServeOptions {
    pub project_root: PathBuf,
    pub home: Option<PathBuf>,
    pub bind: String,
    pub port: u16,
    pub pid_file: Option<PathBuf>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ServerMetadata {
    pub mode: String,
    pub host: String,
    pub port: u16,
    pub hostname: String,
    pub mdns: String,
    pub lan_ips: Vec<String>,
    pub local_token: String,
}

#[derive(Clone)]
struct AppState {
    project_root: PathBuf,
    home: Option<PathBuf>,
    store: Arc<MeshStore>,
    events_tx: broadcast::Sender<EventEnvelope>,
}

#[derive(Debug, Deserialize)]
struct EventsQuery {
    since: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct WsQuery {
    token: String,
    last_seq: Option<u64>,
}

#[derive(Debug, Deserialize)]
struct EventRequest {
    #[serde(rename = "type")]
    event_type: String,
    room: String,
    from: String,
    to: Option<String>,
    payload: Value,
}

#[derive(Debug, Deserialize)]
struct InviteRequest {
    role: String,
    ttl_seconds: Option<u64>,
    max_uses: Option<u32>,
}

pub async fn serve(opts: ServeOptions) -> Result<()> {
    auth::require_local_project_credential(&opts.project_root, opts.home.clone())?;
    let local_token = auth::local_project_token(&opts.project_root, opts.home.clone())?;
    let bind_info = detect_bind(&opts.bind, opts.port)?;
    let listener = TcpListener::bind(bind_info.bind_addr)
        .await
        .with_context(|| format!("bind {}", bind_info.bind_addr))?;
    let local_addr = listener.local_addr().context("read bound address")?;
    let store = Arc::new(MeshStore::open(&opts.project_root)?);
    let (events_tx, _) = broadcast::channel(256);
    let state = AppState {
        project_root: opts.project_root.clone(),
        home: opts.home.clone(),
        store,
        events_tx,
    };

    let metadata = ServerMetadata {
        mode: bind_info.mode,
        host: metadata_host(local_addr, &opts.bind),
        port: local_addr.port(),
        hostname: bind_info.hostname,
        mdns: bind_info.mdns_name,
        lan_ips: bind_info.lan_ips,
        local_token,
    };
    write_server_metadata(&opts.project_root, &metadata)?;
    if let Some(pid_file) = opts.pid_file {
        fs::write(&pid_file, std::process::id().to_string())
            .with_context(|| format!("write pid file {}", pid_file.display()))?;
    }

    let app = Router::new()
        .route("/health", get(health))
        .route("/api/state", get(api_state))
        .route("/api/events", get(api_events).post(post_event))
        .route("/api/invites", post(post_invite))
        .route("/ws", get(ws_handler))
        .layer(CorsLayer::permissive())
        .with_state(state);

    axum::serve(listener, app)
        .await
        .context("serve mesh http api")?;
    Ok(())
}

pub fn server_metadata_path(project_root: &Path) -> PathBuf {
    project_root.join(".workbench/mesh/server.json")
}

pub fn read_server_metadata(project_root: &Path) -> Result<ServerMetadata> {
    let path = server_metadata_path(project_root);
    let content = fs::read_to_string(&path).with_context(|| format!("read {}", path.display()))?;
    serde_json::from_str(&content).with_context(|| format!("parse {}", path.display()))
}

async fn health() -> Json<Value> {
    Json(json!({ "ok": true }))
}

async fn api_state(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    require_bearer(&state, &headers)?;
    Ok(Json(state_json(&state)?))
}

async fn api_events(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<EventsQuery>,
) -> Result<Json<Value>, ApiError> {
    require_bearer(&state, &headers)?;
    let events = state.store.list_events_since(query.since.unwrap_or(0))?;
    Ok(Json(json!({ "events": events })))
}

async fn post_event(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<EventRequest>,
) -> Result<Json<EventEnvelope>, ApiError> {
    require_bearer(&state, &headers)?;
    let event = append_event(&state, request)?;
    Ok(Json(event))
}

async fn post_invite(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(request): Json<InviteRequest>,
) -> Result<Json<Value>, ApiError> {
    let role = bearer_role(&state, &headers)?;
    if !matches!(role.as_str(), "owner" | "operator") {
        return Err(ApiError::forbidden("owner/operator bearer required"));
    }
    let invite = auth::create_invite(
        &state.project_root,
        state.home.clone(),
        &request.role,
        request.ttl_seconds.unwrap_or(3600),
        request.max_uses.unwrap_or(1),
    )?;
    Ok(Json(json!({
        "token": invite.token,
        "role": invite.role,
        "expires_at": invite.expires_at,
        "max_uses": invite.max_uses,
    })))
}

async fn ws_handler(
    State(state): State<AppState>,
    Query(query): Query<WsQuery>,
    ws: WebSocketUpgrade,
) -> Result<impl IntoResponse, ApiError> {
    auth::check(&state.project_root, state.home.clone(), &query.token)
        .map_err(|_| ApiError::unauthorized())?;
    Ok(ws.on_upgrade(move |socket| websocket_session(socket, state, query.last_seq.unwrap_or(0))))
}

async fn websocket_session(socket: WebSocket, state: AppState, last_seq: u64) {
    let (mut sender, mut receiver) = socket.split();
    let mut events_rx = state.events_tx.subscribe();

    if let Ok(events) = state.store.list_events_since(last_seq) {
        for event in events {
            let Ok(text) = serde_json::to_string(&event) else {
                continue;
            };
            if sender.send(Message::Text(text)).await.is_err() {
                return;
            }
        }
    }

    loop {
        tokio::select! {
            received = events_rx.recv() => {
                let Ok(event) = received else {
                    continue;
                };
                let Ok(text) = serde_json::to_string(&event) else {
                    continue;
                };
                if sender.send(Message::Text(text)).await.is_err() {
                    return;
                }
            }
            incoming = receiver.next() => {
                let Some(Ok(message)) = incoming else {
                    return;
                };
                if let Message::Text(text) = message {
                    let Ok(request) = serde_json::from_str::<EventRequest>(&text) else {
                        continue;
                    };
                    let Ok(event) = append_event(&state, request) else {
                        continue;
                    };
                    let ack = json!({ "type": "ack", "id": event.id, "seq": event.seq });
                    if sender.send(Message::Text(ack.to_string())).await.is_err() {
                        return;
                    }
                }
            }
        }
    }
}

fn append_event(state: &AppState, request: EventRequest) -> Result<EventEnvelope> {
    let event = state.store.append_event(
        &request.event_type,
        &request.room,
        &request.from,
        request.to.as_deref(),
        request.payload,
    )?;
    let _ = state.events_tx.send(event.clone());
    Ok(event)
}

fn require_bearer(state: &AppState, headers: &HeaderMap) -> Result<(), ApiError> {
    bearer_role(state, headers).map(|_| ())
}

fn bearer_role(state: &AppState, headers: &HeaderMap) -> Result<String, ApiError> {
    let Some(value) = headers.get(axum::http::header::AUTHORIZATION) else {
        return Err(ApiError::unauthorized());
    };
    let Ok(value) = value.to_str() else {
        return Err(ApiError::unauthorized());
    };
    let Some(token) = value.strip_prefix("Bearer ") else {
        return Err(ApiError::unauthorized());
    };
    auth::project_token_role(&state.project_root, state.home.clone(), token)
        .map_err(|_| ApiError::unauthorized())
}

fn state_json(state: &AppState) -> Result<Value> {
    let events = state.store.list_events_since(0)?;
    let mut actors = BTreeSet::new();
    for event in &events {
        actors.insert(event.from.clone());
        if let Some(to) = &event.to {
            actors.insert(to.clone());
        }
    }
    Ok(json!({
        "event_count": events.len(),
        "connected_actor_count": actors.len(),
        "actors": actors.into_iter().collect::<Vec<_>>(),
        "last_seq": events.last().map(|event| event.seq).unwrap_or(0),
    }))
}

fn metadata_host(local_addr: SocketAddr, bind: &str) -> String {
    if bind == "local" {
        "127.0.0.1".to_string()
    } else {
        local_addr.ip().to_string()
    }
}

fn write_server_metadata(project_root: &Path, metadata: &ServerMetadata) -> Result<()> {
    let path = server_metadata_path(project_root);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).with_context(|| format!("create {}", parent.display()))?;
    }
    let content = serde_json::to_string(metadata).context("serialize server metadata")?;

    #[cfg(unix)]
    {
        use std::io::Write;
        use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};

        let mut file = fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .mode(0o600)
            .open(&path)
            .with_context(|| format!("open {}", path.display()))?;
        file.write_all(content.as_bytes())
            .with_context(|| format!("write {}", path.display()))?;
        file.flush()
            .with_context(|| format!("flush {}", path.display()))?;
        file.set_permissions(fs::Permissions::from_mode(0o600))
            .with_context(|| format!("chmod {}", path.display()))?;
    }

    #[cfg(not(unix))]
    fs::write(&path, content).with_context(|| format!("write {}", path.display()))?;

    Ok(())
}

#[derive(Debug)]
struct ApiError {
    status: StatusCode,
    message: String,
}

impl ApiError {
    fn unauthorized() -> Self {
        Self {
            status: StatusCode::UNAUTHORIZED,
            message: "unauthorized".to_string(),
        }
    }

    fn forbidden(message: &str) -> Self {
        Self {
            status: StatusCode::FORBIDDEN,
            message: message.to_string(),
        }
    }
}

impl From<anyhow::Error> for ApiError {
    fn from(error: anyhow::Error) -> Self {
        Self {
            status: StatusCode::BAD_REQUEST,
            message: error.to_string(),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> axum::response::Response {
        (self.status, Json(json!({ "error": self.message }))).into_response()
    }
}
