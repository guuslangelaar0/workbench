use std::path::PathBuf;

use anyhow::{Context, Result};
use clap::{Args, Parser, Subcommand};

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
struct AppendArgs {
    #[arg(long)]
    target: PathBuf,
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
    #[arg(long, default_value_t = 0)]
    since: u64,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Event(event) => run_event(event),
    }
}

fn run_event(event: EventCommand) -> Result<()> {
    match event.command {
        EventSubcommand::Append(args) => append_event(args),
        EventSubcommand::List(args) => list_events(args),
    }
}

fn append_event(args: AppendArgs) -> Result<()> {
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
    let store = MeshStore::open(args.target)?;
    for event in store.list_events_since(args.since)? {
        println!("{}", serde_json::to_string(&event)?);
    }
    Ok(())
}
