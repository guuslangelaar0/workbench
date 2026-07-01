use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use anyhow::{Context, Result};
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::extract::{Query, State};
use axum::http::{header, HeaderMap, HeaderName, StatusCode};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use futures_util::{SinkExt, StreamExt};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::net::TcpListener;
use tokio::sync::broadcast;

use crate::auth;
use crate::net::detect_bind;
use crate::protocol::EventEnvelope;
use crate::store::MeshStore;

const INDEX_HTML: &str = include_str!("../assets/index.html");
const APP_JS: &str = include_str!("../assets/app.js");
const STYLE_CSS: &str = include_str!("../assets/style.css");

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
    daemon_token: String,
    local_role: String,
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
struct StaticQuery {
    token: Option<String>,
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
struct WsEventRequest {
    v: u16,
    #[serde(flatten)]
    event: EventRequest,
}

#[derive(Debug, Deserialize)]
struct InviteRequest {
    role: String,
    ttl_seconds: Option<u64>,
    max_uses: Option<u32>,
}

pub async fn serve(opts: ServeOptions) -> Result<()> {
    auth::require_local_project_credential(&opts.project_root, opts.home.clone())?;
    let credential_token = auth::local_project_token(&opts.project_root, opts.home.clone())?;
    let local_role =
        auth::project_token_role(&opts.project_root, opts.home.clone(), &credential_token)?;
    let daemon_token = random_bearer_token();
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
        daemon_token: daemon_token.clone(),
        local_role,
    };

    let metadata = ServerMetadata {
        mode: bind_info.mode.clone(),
        host: metadata_host(&bind_info.mode, &bind_info.lan_ips),
        port: local_addr.port(),
        hostname: bind_info.hostname,
        mdns: bind_info.mdns_name,
        lan_ips: bind_info.lan_ips,
        local_token: daemon_token,
    };
    write_server_metadata(&opts.project_root, &metadata)?;
    if let Some(pid_file) = opts.pid_file {
        fs::write(&pid_file, std::process::id().to_string())
            .with_context(|| format!("write pid file {}", pid_file.display()))?;
    }

    let app = Router::new()
        .route("/", get(command_center))
        .route("/assets/app.js", get(command_center_js))
        .route("/assets/style.css", get(command_center_css))
        .route("/health", get(health))
        .route("/api/state", get(api_state))
        .route("/api/events", get(api_events).post(post_event))
        .route("/api/invites", post(post_invite))
        .route("/ws", get(ws_handler))
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

async fn command_center(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<StaticQuery>,
) -> Result<impl IntoResponse, ApiError> {
    let html = match static_auth(&state, &headers, &query)? {
        StaticAuth::Bearer => INDEX_HTML.to_string(),
        StaticAuth::QueryToken(token) => tokenized_command_center_html(&token),
    };
    Ok((static_headers("text/html; charset=utf-8"), html))
}

async fn command_center_js(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<StaticQuery>,
) -> Result<impl IntoResponse, ApiError> {
    static_auth(&state, &headers, &query)?;
    Ok((
        static_headers("application/javascript; charset=utf-8"),
        APP_JS,
    ))
}

async fn command_center_css(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<StaticQuery>,
) -> Result<impl IntoResponse, ApiError> {
    static_auth(&state, &headers, &query)?;
    Ok((static_headers("text/css; charset=utf-8"), STYLE_CSS))
}

async fn health(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    require_bearer(&state, &headers)?;
    Ok(Json(json!({ "ok": true })))
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
    require_token(&state, &query.token)?;
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
                    let Ok(request) = serde_json::from_str::<WsEventRequest>(&text) else {
                        continue;
                    };
                    if request.v != 1 {
                        continue;
                    };
                    let Ok(event) = append_event(&state, request.event) else {
                        continue;
                    };
                    let ack = json!({ "v": 1, "type": "ack", "id": event.id, "seq": event.seq });
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
    require_token(state, token)?;
    Ok(state.local_role.clone())
}

enum StaticAuth {
    Bearer,
    QueryToken(String),
}

fn static_auth(
    state: &AppState,
    headers: &HeaderMap,
    query: &StaticQuery,
) -> Result<StaticAuth, ApiError> {
    if let Some(token) = query.token.as_deref() {
        if require_token(state, token).is_ok() {
            return Ok(StaticAuth::QueryToken(token.to_string()));
        }
    }
    require_bearer(state, headers)?;
    Ok(StaticAuth::Bearer)
}

fn tokenized_command_center_html(token: &str) -> String {
    INDEX_HTML
        .replace(
            "/assets/style.css",
            &format!("/assets/style.css?token={token}"),
        )
        .replace("/assets/app.js", &format!("/assets/app.js?token={token}"))
}

fn static_headers(content_type: &'static str) -> [(HeaderName, &'static str); 3] {
    [
        (header::CONTENT_TYPE, content_type),
        (header::CACHE_CONTROL, "no-store"),
        (HeaderName::from_static("referrer-policy"), "no-referrer"),
    ]
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
        "events": events,
        "last_seq": events.last().map(|event| event.seq).unwrap_or(0),
    }))
}

fn require_token(state: &AppState, token: &str) -> Result<(), ApiError> {
    if token == state.daemon_token {
        Ok(())
    } else {
        Err(ApiError::unauthorized())
    }
}

fn metadata_host(mode: &str, lan_ips: &[String]) -> String {
    match mode {
        "local" => "127.0.0.1".to_string(),
        "lan" => lan_ips
            .first()
            .cloned()
            .unwrap_or_else(|| "127.0.0.1".to_string()),
        _ => "127.0.0.1".to_string(),
    }
}

fn random_bearer_token() -> String {
    let mut bytes = [0_u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
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

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::Path;
    use std::time::Duration;

    use futures_util::{SinkExt, StreamExt};
    use serde_json::{json, Value};
    use tempfile::TempDir;
    use tokio::time::sleep;
    use tokio_tungstenite::connect_async;
    use tokio_tungstenite::tungstenite::Message as ClientMessage;

    use super::{read_server_metadata, serve, server_metadata_path, ServeOptions};
    use crate::auth;
    use crate::store::MeshStore;

    #[tokio::test]
    async fn websocket_auth_replay_versioned_append_ack_and_broadcast() {
        let project = TempDir::new().unwrap();
        let home = TempDir::new().unwrap();
        write_project_config(project.path(), "Mesh Service");
        auth::bootstrap(project.path(), Some(home.path().to_path_buf())).unwrap();

        MeshStore::open(project.path())
            .unwrap()
            .append_event(
                "presence.join",
                "repo:mesh-service",
                "session:existing",
                None,
                json!({ "role": "lead" }),
            )
            .unwrap();

        let server = tokio::spawn(serve(ServeOptions {
            project_root: project.path().to_path_buf(),
            home: Some(home.path().to_path_buf()),
            bind: "local".to_string(),
            port: 0,
            pid_file: None,
        }));

        let metadata = wait_for_metadata(project.path()).await;
        let durable_token =
            auth::local_project_token(project.path(), Some(home.path().to_path_buf())).unwrap();
        assert_ne!(metadata.local_token, durable_token);

        let ws_url = format!(
            "ws://{}:{}/ws?token={}&last_seq=0",
            metadata.host, metadata.port, metadata.local_token
        );
        let (mut first, _) = connect_async(&ws_url).await.unwrap();
        let replay = read_ws_json(&mut first).await;
        assert_eq!(replay["v"], 1);
        assert_eq!(replay["seq"], 1);
        assert_eq!(replay["type"], "presence.join");
        assert_eq!(replay["from"], "session:existing");

        let (mut second, _) = connect_async(format!(
            "ws://{}:{}/ws?token={}&last_seq=1",
            metadata.host, metadata.port, metadata.local_token
        ))
        .await
        .unwrap();

        first
            .send(ClientMessage::Text(
                json!({
                    "v": 1,
                    "type": "message.sent",
                    "room": "repo:mesh-service",
                    "from": "session:first",
                    "payload": { "text": "hello" }
                })
                .to_string(),
            ))
            .await
            .unwrap();

        let ack = read_ws_json(&mut first).await;
        assert_eq!(ack["v"], 1);
        assert_eq!(ack["type"], "ack");
        assert_eq!(ack["seq"], 2);
        assert!(ack["id"].as_str().is_some());

        let broadcast = read_ws_json(&mut second).await;
        assert_eq!(broadcast["v"], 1);
        assert_eq!(broadcast["seq"], 2);
        assert_eq!(broadcast["type"], "message.sent");
        assert_eq!(broadcast["from"], "session:first");

        let events = MeshStore::open(project.path())
            .unwrap()
            .list_events_since(1)
            .unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0].event_type, "message.sent");

        server.abort();
    }

    async fn wait_for_metadata(project: &Path) -> super::ServerMetadata {
        for _ in 0..50 {
            if server_metadata_path(project).is_file() {
                return read_server_metadata(project).unwrap();
            }
            sleep(Duration::from_millis(20)).await;
        }
        panic!("server metadata was not written");
    }

    async fn read_ws_json<S>(socket: &mut S) -> Value
    where
        S: StreamExt<Item = Result<ClientMessage, tokio_tungstenite::tungstenite::Error>> + Unpin,
    {
        let message = tokio::time::timeout(Duration::from_secs(2), socket.next())
            .await
            .unwrap()
            .unwrap()
            .unwrap();
        match message {
            ClientMessage::Text(text) => serde_json::from_str(&text).unwrap(),
            other => panic!("expected websocket text frame, got {other:?}"),
        }
    }

    fn write_project_config(project: &Path, name: &str) {
        fs::create_dir_all(project.join(".workbench")).unwrap();
        fs::write(
            project.join(".workbench/config.json"),
            format!(r#"{{"project":{{"name":"{name}"}}}}"#),
        )
        .unwrap();
    }
}
