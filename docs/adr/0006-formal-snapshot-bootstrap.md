# ADR-0006: Bootstrap from a formal snapshot with sui-tool

- **Status:** Accepted by owner
- **Date:** 2026-11-05
- **Deciders:** build agent
- **Requirements:** R5

## Context
Sui says not to sync a full node from genesis. Options are RocksDB database snapshots (full DB copies, Requester Pays
buckets, bucket names not documented in current docs) or formal snapshots (live object set only, ~30 GB for recent
mainnet epochs per Sui's storage page, Nov 2025; free Cloudflare R2 endpoint; cryptographically verified on restore).
The framework's own snapshot mechanism downloads an HTTPS archive, which does not fit either.

## Decision
Use `sui-tool download-formal-snapshot --latest --no-sign-request` into `/data/sui/db`, as `bcuser`, with 3 attempts.
Skip when `/data/sui/db/live` exists. Keep `SNAPSHOT_ENABLED=true` only as the switch for this restore.

## Alternatives considered
- **RocksDB snapshot:** includes history and indexes, but is large, Requester Pays (egress billed), needs IAM the
  framework does not grant, and its bucket names were not confirmed in current docs.
- **Sync from genesis with archive fallback:** Sui advises against it; very slow.

## Consequences
- Free, verified, relatively small bootstrap.
- No transaction history before the snapshot epoch; the node builds gRPC indexes on first start.
- The free endpoint is hosted in North America; restores from other regions may be slower.

## Update 2026-11-05
- **Measured (testnet, 2026-11-03):** formal snapshot ~105 GB (far more than the ~30 GB Sui documented for mainnet in
  Nov 2025), restore ~1h40m per successful attempt, index build ~1h50m, deploy to healthy ~3h40m. Two attempts failed
  with traffic shaping on (ADR-0019). Mainnet not measured.
- **History gap after every restore:** Mysten notes formal snapshots don't suit RPC nodes that do historical lookups
  (https://docs.sui.io/operators/snapshots). With the 2-epoch transaction retention (ADR-0011) the history window
  refills in about 2 days, so every single-node redeploy and every HA replacement starts with no history; history
  queries can return `OUT_OF_RANGE` meanwhile. Documented in the README.
- **Region:** the free formal-snapshot bucket is in North America only, so the README recommends North American
  regions (requirements open question 7).
- **Considered, not adopted (option E):** publish own snapshots each epoch to same-region S3 (`db-checkpoint-config`)
  and restore from there; RocksDB snapshots include indexes, which might skip the index build. Unverified whether they
  include the gRPC `rpc_store`; would also remove the dependency on Mysten's bucket. Candidate for later work.
