//! Keeper configuration, read from environment variables (see `.env.example`).
use alloy::{primitives::Address, signers::local::PrivateKeySigner};
use anyhow::{Context, Result};
use std::{env, str::FromStr, time::Duration};

#[derive(Debug, Clone)]
pub struct Config {
    pub rpc_url: String,
    pub chain_id: u64,
    pub vault: Address,
    /// `None` in dry-run mode: orders are simulated but never sent.
    pub signer: Option<PrivateKeySigner>,
    pub poll_interval: Duration,
    /// Refuse to send transactions above this gas price (wei).
    pub max_gas_price: u128,
    pub telegram: Option<(String, String)>,
}

fn var(key: &str) -> Option<String> {
    env::var(key)
        .ok()
        .map(|v| v.trim().to_owned())
        .filter(|v| !v.is_empty())
}

fn parse<T: FromStr>(key: &str, default: T) -> Result<T>
where
    T::Err: std::fmt::Display,
{
    match var(key) {
        Some(raw) => raw
            .parse()
            .map_err(|e| anyhow::anyhow!("invalid {key}: {e}")),
        None => Ok(default),
    }
}

impl Config {
    pub fn from_env() -> Result<Self> {
        let dry_run: bool = parse("DRY_RUN", false)?;
        let signer = if dry_run {
            None
        } else {
            let key = var("KEEPER_PRIVATE_KEY")
                .context("KEEPER_PRIVATE_KEY is required unless DRY_RUN=true")?;
            Some(
                key.parse::<PrivateKeySigner>()
                    .context("KEEPER_PRIVATE_KEY is not a valid private key")?,
            )
        };
        let max_gwei: u64 = parse("MAX_GAS_PRICE_GWEI", 5)?;
        let telegram = match (var("TELEGRAM_BOT_TOKEN"), var("TELEGRAM_CHAT_ID")) {
            (Some(token), Some(chat)) => Some((token, chat)),
            _ => None,
        };
        Ok(Self {
            rpc_url: var("RPC_URL").context("RPC_URL is required")?,
            chain_id: parse("CHAIN_ID", 97)?,
            vault: var("VAULT_ADDRESS")
                .context("VAULT_ADDRESS is required")?
                .parse()
                .context("invalid VAULT_ADDRESS")?,
            signer,
            poll_interval: Duration::from_secs(parse("POLL_INTERVAL_SECS", 15)?),
            max_gas_price: u128::from(max_gwei) * 1_000_000_000,
            telegram,
        })
    }

    pub fn dry_run(&self) -> bool {
        self.signer.is_none()
    }
}
