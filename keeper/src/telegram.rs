//! Optional Telegram notifications (Bot API `sendMessage`).
use anyhow::{Context, Result};
use std::time::Duration;

#[derive(Clone)]
pub struct Telegram {
    client: reqwest::Client,
    token: String,
    chat_id: String,
}

impl Telegram {
    pub fn new(token: String, chat_id: String) -> Result<Self> {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .build()?;
        Ok(Self {
            client,
            token,
            chat_id,
        })
    }

    pub async fn send(&self, text: &str) -> Result<()> {
        let url = format!("https://api.telegram.org/bot{}/sendMessage", self.token);
        let body =
            serde_json::json!({ "chat_id": self.chat_id, "text": text, "parse_mode": "HTML" });
        let res = self
            .client
            .post(url)
            .json(&body)
            .send()
            .await
            .context("Telegram request failed")?;
        anyhow::ensure!(
            res.status().is_success(),
            "Telegram returned {}",
            res.status()
        );
        Ok(())
    }
}
