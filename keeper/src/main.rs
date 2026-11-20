//! Bastion keeper: executes the orders of a Bastion vault when their conditions are met.
mod config;
mod keeper;
mod telegram;
mod vault;

use anyhow::Result;
use tracing_subscriber::EnvFilter;

#[tokio::main]
async fn main() -> Result<()> {
    dotenvy::dotenv().ok();
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .init();

    let config = config::Config::from_env()?;
    let keeper = keeper::Keeper::connect(config).await?;
    match std::env::args().nth(1).as_deref() {
        None | Some("run") => keeper.run().await,
        Some("once") => {
            for (id, outcome) in keeper.tick().await? {
                println!("order {id}: {outcome:?}");
            }
            Ok(())
        }
        Some(other) => anyhow::bail!("unknown command `{other}` (expected `run` or `once`)"),
    }
}
