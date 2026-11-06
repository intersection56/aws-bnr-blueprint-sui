# ADR-0011: RPC pruning and indexing profile

- **Status:** Accepted by owner
- **Date:** 2026-11-05
- **Deciders:** build agent
- **Requirements:** R6.3

## Context
Without pruning a Sui node can exceed 7 TB (Sui docs). Sui documents a "full node with indexing but limited object
history" profile for RPC nodes. JSON-RPC is deprecated and gRPC needs `rpc.enable-indexing: true` for list queries.

## Decision
Defaults: `rpc.enable-indexing: true`, `num-epochs-to-retain: 5`, `num-epochs-to-retain-for-checkpoints: 2`,
`periodic-compaction-threshold-days: 1`. All tunable through `SUI_*` variables, validated (ADR-0015).

## Alternatives considered
- **Aggressive pruning (0 epochs), no indexing:** smallest disk, but cannot answer index-backed queries.
- **Full object history:** much larger disk; needs special snapshots.

## Consequences
- Answers current-state and indexed queries; history only within a few epochs (a Sui epoch is about a day).
- Older data must come from Sui's Archival Service or an indexer.
- **Updated 2026-11-05:** with 2 epochs of transaction retention, a node restored from a formal snapshot (every
  single-node redeploy, every HA replacement) has no transaction history for about 2 days while the window refills;
  history queries can return `OUT_OF_RANGE` (ADR-0006 update). Raising retention lengthens that refill and grows the disk.
