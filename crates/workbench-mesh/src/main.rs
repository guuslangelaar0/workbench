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
    Serve(ServeArgs),
    Status(ClientArgs),
    Who(ClientArgs),
    Bench(BenchArgs),
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
    token: String,
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

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Event(event) => run_event(event),
        Command::Auth(auth) => run_auth(auth),
        Command::Invite(invite) => run_invite(invite),
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

fn run_invite(invite_command: InviteCommand) -> Result<()> {
    match invite_command.command {
        InviteSubcommand::Create(args) => invite_create(args),
        InviteSubcommand::Accept(args) => invite_accept(args),
    }
}

fn append_event(args: AppendArgs) -> Result<()> {
    auth::require_local_project_credential(&args.target, args.home)?;
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

fn invite_accept(args: InviteAcceptArgs) -> Result<()> {
    println!(
        "{}",
        auth::accept_invite(&args.target, args.home, &args.token, &args.device)?
    );
    Ok(())
}
