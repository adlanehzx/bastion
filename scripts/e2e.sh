#!/usr/bin/env bash
# End-to-end test: local anvil chain + mock market + vault, then the Rust keeper executes
# the DCA order and leaves the untriggered limit order alone.
set -euo pipefail
cd "$(dirname "$0")/.."

PORT=18546
RPC="http://127.0.0.1:${PORT}"
# Well-known anvil development keys (accounts 0 and 1). Never use them on a real network.
OWNER_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
KEEPER_KEY=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d
KEEPER_ADDR=0x70997970C51812dc3A010C7d01b50e0d17dc79C8

anvil --port "$PORT" --chain-id 31337 --silent &
ANVIL_PID=$!
trap 'kill $ANVIL_PID 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done

VAULT=$(cd contracts && KEEPER=$KEEPER_ADDR forge script script/LocalDemo.s.sol \
  --rpc-url "$RPC" --private-key "$OWNER_KEY" --broadcast 2>&1 | sed -n 's/.*VAULT=\(0x[0-9a-fA-F]*\).*/\1/p' | head -1)
[ -n "$VAULT" ] || { echo "deployment failed"; exit 1; }
echo "vault: $VAULT"

export RPC_URL=$RPC CHAIN_ID=31337 VAULT_ADDRESS=$VAULT RUST_LOG=warn
cargo build --quiet --manifest-path keeper/Cargo.toml
KEEPER_BIN=keeper/target/debug/bastion-keeper

echo "--- dry run"
DRY=$(DRY_RUN=true "$KEEPER_BIN" once)
echo "$DRY"
grep -q "order 0: WouldExecute" <<<"$DRY"
[ "$(grep -c '^order' <<<"$DRY")" -eq 1 ] || { echo "only the DCA order should be ready"; exit 1; }

echo "--- live run"
LIVE=$(KEEPER_PRIVATE_KEY=$KEEPER_KEY "$KEEPER_BIN" once)
echo "$LIVE"
grep -q "order 0: Executed" <<<"$LIVE"

REMAINING=$(cast call "$VAULT" "getOrder(uint256)((address,address,address,uint128,uint128,uint32,uint32,uint32,uint16,uint8,bool))" 0 --rpc-url "$RPC" | tr -d '()' | cut -d, -f8 | tr -d ' ')
[ "$REMAINING" = "4" ] || { echo "expected 4 executions left, got $REMAINING"; exit 1; }

echo "--- second pass: DCA not due again yet"
AGAIN=$(KEEPER_PRIVATE_KEY=$KEEPER_KEY "$KEEPER_BIN" once)
[ -z "$AGAIN" ] || { echo "nothing should run: $AGAIN"; exit 1; }

echo "--- a stranger's key is refused"
if KEEPER_PRIVATE_KEY=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a "$KEEPER_BIN" once 2>/dev/null; then
  echo "a non-keeper wallet was accepted"; exit 1
fi

echo "e2e OK"
