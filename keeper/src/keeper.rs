//! Polls the vault for executable orders, simulates each one, then sends it.
use crate::config::Config;
use crate::telegram::Telegram;
use crate::vault::{Vault, describe_revert};
use alloy::{
    network::EthereumWallet,
    primitives::{Address, U256, utils::format_units},
    providers::{DynProvider, Provider, ProviderBuilder},
    sol,
};
use anyhow::{Context, Result};
use tracing::{info, warn};

sol! {
    #[sol(rpc)]
    interface IERC20Meta {
        function symbol() external view returns (string);
        function decimals() external view returns (uint8);
    }
}

/// What happened to one order during a pass.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// Simulation passed; nothing sent because the keeper runs in dry-run mode.
    WouldExecute {
        amount_out: U256,
    },
    Executed {
        amount_out: U256,
        tx: String,
    },
    Skipped(String),
}

pub struct Keeper {
    provider: DynProvider,
    vault: Address,
    /// Address used as `msg.sender` when simulating.
    sender: Address,
    config: Config,
    telegram: Option<Telegram>,
}

impl Keeper {
    pub async fn connect(config: Config) -> Result<Self> {
        let url = config
            .rpc_url
            .parse()
            .context("RPC_URL is not a valid URL")?;
        let provider = match &config.signer {
            Some(signer) => ProviderBuilder::new()
                .wallet(EthereumWallet::from(signer.clone()))
                .connect_http(url)
                .erased(),
            None => ProviderBuilder::new().connect_http(url).erased(),
        };
        let chain_id = provider
            .get_chain_id()
            .await
            .context("cannot reach the RPC")?;
        anyhow::ensure!(
            chain_id == config.chain_id,
            "RPC is on chain {chain_id}, expected {}",
            config.chain_id
        );

        let vault = Vault::new(config.vault, &provider);
        let on_chain_keeper = vault
            .keeper()
            .call()
            .await
            .context("VAULT_ADDRESS is not a Bastion vault")?;
        let sender = match &config.signer {
            Some(signer) => {
                let me = signer.address();
                anyhow::ensure!(
                    me == on_chain_keeper || me == vault.owner().call().await?,
                    "wallet {me} is neither the vault keeper ({on_chain_keeper}) nor its owner"
                );
                me
            }
            None => on_chain_keeper,
        };
        let telegram = match config.telegram.clone() {
            Some((token, chat)) => Some(Telegram::new(token, chat)?),
            None => None,
        };
        info!(vault = %config.vault, %sender, dry_run = config.dry_run(), "keeper ready");
        Ok(Self {
            provider,
            vault: config.vault,
            sender,
            config,
            telegram,
        })
    }

    pub async fn run(&self) -> Result<()> {
        loop {
            if let Err(err) = self.tick().await {
                warn!(%err, "pass failed");
            }
            tokio::time::sleep(self.config.poll_interval).await;
        }
    }

    /// One pass over the orders that are ready now.
    pub async fn tick(&self) -> Result<Vec<(U256, Outcome)>> {
        let vault = Vault::new(self.vault, &self.provider);
        let ids = vault.executableOrders().call().await?;
        let mut outcomes = Vec::with_capacity(ids.len());
        for id in ids {
            let outcome = match self.execute(id).await {
                Ok(outcome) => outcome,
                Err(err) => Outcome::Skipped(format!("{err:#}")),
            };
            match &outcome {
                Outcome::Skipped(reason) => warn!(%id, %reason, "order skipped"),
                other => info!(%id, outcome = ?other, "order processed"),
            }
            outcomes.push((id, outcome));
        }
        Ok(outcomes)
    }

    async fn execute(&self, id: U256) -> Result<Outcome> {
        let vault = Vault::new(self.vault, &self.provider);
        let call = vault.execute(id).from(self.sender);

        // 1. Simulate: never pay gas for a transaction that would revert.
        let amount_out = match call.call().await {
            Ok(out) => out,
            Err(err) => {
                let reason = err.as_revert_data().and_then(|data| describe_revert(&data));
                return Ok(Outcome::Skipped(reason.unwrap_or_else(|| err.to_string())));
            }
        };
        if self.config.dry_run() {
            return Ok(Outcome::WouldExecute { amount_out });
        }

        // 2. Refuse to overpay during gas spikes.
        let gas_price = self.provider.get_gas_price().await?;
        if gas_price > self.config.max_gas_price {
            return Ok(Outcome::Skipped(format!(
                "gas price {gas_price} wei above MAX_GAS_PRICE_GWEI"
            )));
        }

        // 3. Send and wait for the receipt.
        let receipt = call.send().await?.get_receipt().await?;
        let tx = receipt.transaction_hash.to_string();
        anyhow::ensure!(receipt.status(), "transaction {tx} reverted");
        let amount_out = receipt
            .decoded_log::<Vault::OrderExecuted>()
            .map(|log| log.data.amountOut)
            .unwrap_or(amount_out);

        if let Some(tg) = &self.telegram {
            let text = self.describe_execution(id, amount_out, &tx).await;
            if let Err(err) = tg.send(&text).await {
                warn!(%err, "telegram notification failed");
            }
        }
        Ok(Outcome::Executed { amount_out, tx })
    }

    async fn describe_execution(&self, id: U256, amount_out: U256, tx: &str) -> String {
        let vault = Vault::new(self.vault, &self.provider);
        let Ok(order) = vault.getOrder(id).call().await else {
            return format!("✅ Order #{id} executed\n<code>{tx}</code>");
        };
        let (sym_in, dec_in) = self.token(order.tokenIn).await;
        let (sym_out, dec_out) = self.token(order.tokenOut).await;
        format_execution(
            id,
            &format_amount(U256::from(order.amountIn), dec_in),
            &sym_in,
            &format_amount(amount_out, dec_out),
            &sym_out,
            order.remaining,
            tx,
        )
    }

    async fn token(&self, address: Address) -> (String, u8) {
        let token = IERC20Meta::new(address, &self.provider);
        let symbol = token
            .symbol()
            .call()
            .await
            .unwrap_or_else(|_| address.to_string());
        let decimals = token.decimals().call().await.unwrap_or(18);
        (symbol, decimals)
    }
}

/// Amount with at most 6 decimals, trailing zeros removed.
pub fn format_amount(amount: U256, decimals: u8) -> String {
    let text = format_units(amount, decimals).unwrap_or_else(|_| amount.to_string());
    let (int, frac) = text.split_once('.').unwrap_or((&text, ""));
    let frac: String = frac
        .chars()
        .take(6)
        .collect::<String>()
        .trim_end_matches('0')
        .to_owned();
    if frac.is_empty() {
        int.to_owned()
    } else {
        format!("{int}.{frac}")
    }
}

pub fn format_execution(
    id: U256,
    amount_in: &str,
    symbol_in: &str,
    amount_out: &str,
    symbol_out: &str,
    remaining: u32,
    tx: &str,
) -> String {
    let left = match remaining {
        0 => "ordre terminé".to_owned(),
        1 => "1 exécution restante".to_owned(),
        n => format!("{n} exécutions restantes"),
    };
    format!(
        "✅ Ordre #{id} exécuté\n{amount_in} {symbol_in} → {amount_out} {symbol_out}\n{left}\n\
         <a href=\"https://bscscan.com/tx/{tx}\">Voir la transaction</a>"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn amounts_are_trimmed() {
        assert_eq!(
            format_amount(U256::from(1_500_000_000_000_000_000u128), 18),
            "1.5"
        );
        assert_eq!(
            format_amount(U256::from(166_666_666_666_666_666u128), 18),
            "0.166666"
        );
        assert_eq!(format_amount(U256::from(100_000_000u64), 8), "1");
        assert_eq!(format_amount(U256::ZERO, 18), "0");
    }

    #[test]
    fn execution_message() {
        let text = format_execution(U256::from(2), "100", "USDT", "0.166666", "WBNB", 9, "0xabc");
        assert!(text.contains("Ordre #2 exécuté"));
        assert!(text.contains("100 USDT → 0.166666 WBNB"));
        assert!(text.contains("9 exécutions restantes"));
        assert!(
            format_execution(U256::ZERO, "1", "A", "2", "B", 0, "0x").contains("ordre terminé")
        );
    }
}
