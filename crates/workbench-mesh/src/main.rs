use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::{Args, Parser, Subcommand};

use workbench_mesh::auth;
use workbench_mesh::client;
use workbench_mesh::server::{self, ServeOptions};
use workbench_mesh::store::MeshStore;

#[derive(Debug, Parser)]
#[command(name = "workbench-mesh")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Debug, Subcommand)]
enum Command {
    Event(EventCommand),
    Auth(AuthCommand),
    Invite(InviteCommand),
    Device(DeviceCommand),
    Serve(ServeArgs),
    Status(ClientArgs),
    Who(ClientArgs),
    Bench(BenchArgs),
    Room(RoomCommand),
    Message(MessageArgs),
    Ask(AskArgs),
    Handoff(HandoffArgs),
    Jobs(JobsArgs),
    Availability(AvailabilityArgs),
    Doing(DoingArgs),
    Watch(WatchArgs),
    Actor(ActorCommand),
    Snapshot(SnapshotCommand),
}

#[derive(Debug, Args)]
struct EventCommand {
    #[command(subcommand)]
    command: EventSubcommand,
}

#[derive(Debug, Subcommand)]
enum EventSubcommand {
    Append(AppendArgs),
    List(ListArgs),
}

#[derive(Debug, Args)]
struct AuthCommand {
    #[command(subcommand)]
    command: AuthSubcommand,
}

#[derive(Debug, Subcommand)]
enum AuthSubcommand {
    Bootstrap(AuthBootstrapArgs),
    Check(AuthCheckArgs),
}

#[derive(Debug, Args)]
struct InviteCommand {
    #[command(subcommand)]
    command: InviteSubcommand,
}

#[derive(Debug, Subcommand)]
enum InviteSubcommand {
    Create(InviteCreateArgs),
    Accept(InviteAcceptArgs),
}

#[derive(Debug, Args)]
struct RoomCommand {
    #[command(subcommand)]
    command: RoomSubcommand,
}

#[derive(Debug, Subcommand)]
enum RoomSubcommand {
    Create(RoomCreateArgs),
}

#[derive(Debug, Args)]
struct ActorCommand {
    #[command(subcommand)]
    command: ActorSubcommand,
}

#[derive(Debug, Subcommand)]
enum ActorSubcommand {
    Spawn(ActorSpawnArgs),
}

#[derive(Debug, Args)]
struct SnapshotCommand {
    #[command(subcommand)]
    command: SnapshotSubcommand,
}

#[derive(Debug, Subcommand)]
enum SnapshotSubcommand {
    Statusline(ClientArgs),
}

#[derive(Debug, Args)]
struct AppendArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
    #[arg(long = "type")]
    event_type: String,
    #[arg(long)]
    room: String,
    #[arg(long = "from")]
    from_actor: String,
    #[arg(long = "to")]
    to_actor: Option<String>,
    #[arg(long)]
    payload_json: String,
}

#[derive(Debug, Args)]
struct ListArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
    #[arg(long, default_value_t = 0)]
    since: u64,
}

#[derive(Debug, Args)]
struct AuthBootstrapArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
}

#[derive(Debug, Args)]
struct AuthCheckArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
    #[arg(long)]
    token: String,
}

#[derive(Debug, Args)]
struct InviteCreateArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
    #[arg(long)]
    role: String,
    #[arg(long, default_value_t = 3600)]
    ttl_seconds: u64,
    #[arg(long, default_value_t = 1)]
    max_uses: u32,
}

#[derive(Debug, Args)]
struct InviteAcceptArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
    #[arg(long)]
    url: Option<String>,
    #[arg(long)]
    token: String,
    #[arg(long)]
    device: String,
}

#[derive(Debug, Args)]
struct DeviceCommand {
    #[command(subcommand)]
    command: DeviceSubcommand,
}

#[derive(Debug, Subcommand)]
enum DeviceSubcommand {
    List(DeviceListArgs),
    Revoke(DeviceRevokeArgs),
}

#[derive(Debug, Args)]
struct DeviceListArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
}

#[derive(Debug, Args)]
struct DeviceRevokeArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
    #[arg(long)]
    device: String,
}

#[derive(Debug, Args)]
struct ServeArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
    #[arg(long, default_value = "local")]
    bind: String,
    #[arg(long, default_value_t = 0)]
    port: u16,
    #[arg(long)]
    pid_file: Option<PathBuf>,
}

#[derive(Debug, Args)]
struct ClientArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
}

#[derive(Debug, Args)]
struct BenchArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
    #[arg(long, default_value_t = 100)]
    messages: u64,
}

#[derive(Debug, Args)]
struct RoomCreateArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
    #[arg(long)]
    name: String,
}

#[derive(Debug, Args)]
struct MessageArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
    #[arg(long = "to")]
    to_actor: String,
    #[arg(long)]
    text: String,
}

#[derive(Debug, Args)]
struct AskArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
    #[arg(long = "to")]
    to_actor: String,
    #[arg(long)]
    question: String,
}

#[derive(Debug, Args)]
struct HandoffArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
    #[arg(long)]
    task_id: String,
    #[arg(long = "to")]
    to_actor: String,
}

#[derive(Debug, Args)]
struct JobsArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
    #[arg(long, default_value_t = 0)]
    since: u64,
}

#[derive(Debug, Args)]
struct AvailabilityArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
    state: String,
    #[arg(long)]
    reason: Option<String>,
}

#[derive(Debug, Args)]
struct DoingArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
    text: String,
}

#[derive(Debug, Args)]
struct WatchArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
    actor: String,
}

#[derive(Debug, Args)]
struct ActorSpawnArgs {
    #[arg(long)]
    target: PathBuf,
    #[arg(long)]
    home: Option<PathBuf>,
    #[arg(long)]
    kind: String,
    #[arg(long)]
    parent: String,
    #[arg(long)]
    purpose: String,
    #[arg(long)]
    task_id: Option<String>,
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Event(event) => run_event(event),
        Command::Auth(auth) => run_auth(auth),
        Command::Invite(invite) => run_invite(invite).await,
        Command::Device(device) => run_device(device).await,
        Command::Serve(args) => {
            server::serve(ServeOptions {
                project_root: args.target,
                home: args.home,
                bind: args.bind,
                port: args.port,
                pid_file: args.pid_file,
            })
            .await
        }
        Command::Status(args) => client::status(args.target, args.home).await,
        Command::Who(args) => client::who(args.target, args.home).await,
        Command::Bench(args) => client::bench(args.target, args.home, args.messages).await,
        Command::Room(room) => run_room(room).await,
        Command::Message(args) => {
            client::send_message(args.target, args.home, args.to_actor, args.text).await
        }
        Command::Ask(args) => {
            client::ask_status(args.target, args.home, args.to_actor, args.question).await
        }
        Command::Handoff(args) => {
            client::handoff_task(args.target, args.home, args.task_id, args.to_actor).await
        }
        Command::Jobs(args) => client::print_jobs(args.target, args.home, args.since),
        Command::Availability(args) => {
            client::set_availability(args.target, args.home, args.state, args.reason).await
        }
        Command::Doing(args) => client::set_doing(args.target, args.home, args.text).await,
        Command::Watch(args) => client::watch_actor(args.target, args.home, args.actor).await,
        Command::Actor(actor) => run_actor(actor).await,
        Command::Snapshot(snapshot) => run_snapshot(snapshot),
    }
}

fn run_event(event: EventCommand) -> Result<()> {
    match event.command {
        EventSubcommand::Append(args) => append_event(args),
        EventSubcommand::List(args) => list_events(args),
    }
}

fn run_auth(auth_command: AuthCommand) -> Result<()> {
    match auth_command.command {
        AuthSubcommand::Bootstrap(args) => auth_bootstrap(args),
        AuthSubcommand::Check(args) => auth_check(args),
    }
}

async fn run_invite(invite_command: InviteCommand) -> Result<()> {
    match invite_command.command {
        InviteSubcommand::Create(args) => invite_create(args),
        InviteSubcommand::Accept(args) => invite_accept(args).await,
    }
}

async fn run_device(device_command: DeviceCommand) -> Result<()> {
    match device_command.command {
        DeviceSubcommand::List(args) => client::list_devices(args.target, args.home).await,
        DeviceSubcommand::Revoke(args) => {
            client::revoke_device(args.target, args.home, args.device).await
        }
    }
}

async fn run_room(room_command: RoomCommand) -> Result<()> {
    match room_command.command {
        RoomSubcommand::Create(args) => {
            client::create_room(args.target, args.home, args.name).await
        }
    }
}

async fn run_actor(actor_command: ActorCommand) -> Result<()> {
    match actor_command.command {
        ActorSubcommand::Spawn(args) => {
            client::spawn_actor(
                args.target,
                args.home,
                args.kind,
                args.parent,
                args.purpose,
                args.task_id,
            )
            .await
        }
    }
}

fn run_snapshot(snapshot_command: SnapshotCommand) -> Result<()> {
    match snapshot_command.command {
        SnapshotSubcommand::Statusline(args) => client::snapshot_statusline(args.target, args.home),
    }
}

fn append_event(args: AppendArgs) -> Result<()> {
    auth::require_local_mutating_project_credential(&args.target, args.home)?;
    let store = MeshStore::open(args.target)?;
    let payload = serde_json::from_str(&args.payload_json).context("parse --payload-json")?;
    let event = store.append_event(
        &args.event_type,
        &args.room,
        &args.from_actor,
        args.to_actor.as_deref(),
        payload,
    )?;
    println!(
        "event: appended seq={} id={} type={}",
        event.seq, event.id, event.event_type
    );
    Ok(())
}

fn list_events(args: ListArgs) -> Result<()> {
    auth::require_local_project_credential(&args.target, args.home)?;
    let store = MeshStore::open(args.target)?;
    for event in store.list_events_since(args.since)? {
        println!("{}", serde_json::to_string(&event)?);
    }
    Ok(())
}

fn auth_bootstrap(args: AuthBootstrapArgs) -> Result<()> {
    println!("{}", auth::bootstrap(&args.target, args.home)?);
    Ok(())
}

fn auth_check(args: AuthCheckArgs) -> Result<()> {
    println!("{}", auth::check(&args.target, args.home, &args.token)?);
    Ok(())
}

fn invite_create(args: InviteCreateArgs) -> Result<()> {
    let invite = auth::create_invite(
        &args.target,
        args.home,
        &args.role,
        args.ttl_seconds,
        args.max_uses,
    )?;
    println!(
        "token: {}\nrole: {}\nexpires: {}\nmax_uses: {}",
        invite.token, invite.role, invite.expires_at, invite.max_uses
    );
    Ok(())
}

async fn invite_accept(args: InviteAcceptArgs) -> Result<()> {
    if let Some(url) = args.url {
        client::accept_remote_invite(args.target, args.home, url, args.token, args.device).await
    } else {
        println!(
            "{}",
            auth::accept_invite(&args.target, args.home, &args.token, &args.device)?
        );
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;

    use clap::Parser;

    use super::{Cli, Command, DeviceSubcommand, InviteSubcommand};

    #[test]
    fn parses_jobs_as_top_level_project_command() {
        let cli = Cli::try_parse_from([
            "workbench-mesh",
            "jobs",
            "--target",
            "/tmp/project",
            "--home",
            "/tmp/home",
            "--since",
            "7",
        ])
        .unwrap();

        match cli.command {
            Command::Jobs(args) => {
                assert_eq!(args.target, PathBuf::from("/tmp/project"));
                assert_eq!(args.home, Some(PathBuf::from("/tmp/home")));
                assert_eq!(args.since, 7);
            }
            other => panic!("expected jobs command, got {other:?}"),
        }
    }

    #[test]
    fn parses_remote_invite_accept_url() {
        let cli = Cli::try_parse_from([
            "workbench-mesh",
            "invite",
            "accept",
            "--target",
            "/tmp/project",
            "--home",
            "/tmp/home",
            "--url",
            "http://127.0.0.1:47321",
            "--token",
            "wb_invite_test",
            "--device",
            "macbook",
        ])
        .unwrap();

        match cli.command {
            Command::Invite(invite) => match invite.command {
                InviteSubcommand::Accept(args) => {
                    assert_eq!(args.url.as_deref(), Some("http://127.0.0.1:47321"));
                    assert_eq!(args.token, "wb_invite_test");
                    assert_eq!(args.device, "macbook");
                }
                other => panic!("expected invite accept, got {other:?}"),
            },
            other => panic!("expected invite command, got {other:?}"),
        }
    }

    #[test]
    fn parses_device_revoke() {
        let cli = Cli::try_parse_from([
            "workbench-mesh",
            "device",
            "revoke",
            "--target",
            "/tmp/project",
            "--home",
            "/tmp/home",
            "--device",
            "macbook",
        ])
        .unwrap();

        match cli.command {
            Command::Device(device) => match device.command {
                DeviceSubcommand::Revoke(args) => assert_eq!(args.device, "macbook"),
                other => panic!("expected device revoke, got {other:?}"),
            },
            other => panic!("expected device command, got {other:?}"),
        }
    }
}
