# ADR-0025: Default 50 sui-tool retries for the snapshot restore

- **Status:** Proposed (2026-11-06, release test issue 4), pending Owner review
- **Requirements:** R5 (5.6)
- **Amends:** ADR-0019 (traffic shaping was not the root cause of the restore failures)

## Context
`sui-tool download-formal-snapshot` restores the live object set and, in parallel, backfills the current epoch's
transaction digests by fetching checkpoints from Sui's public endpoint (`checkpoints.testnet.sui.io` on testnet). Sui's
source (`crates/sui-tool/src/lib.rs`, `backfill_epoch_transaction_digests`, v1.83.1) explains the failure mode: the
CPU-bound state accumulation can starve the async runtime long enough for a single checkpoint fetch to time out, and
that aborts the whole multi-hour restore. Each fetch is retried with exponential backoff (capped at 30 s) up to
`--max-retries`, default 10, which rides out only a few minutes of starvation.

Evidence:
- 2026-11-03: attempts 1 and 2 failed after ~24 min with traffic shaping on; the redeploy succeeded with it off. ADR-0019
  concluded shaping was the likely cause.
- 2026-11-06 release test, shaping off on every node: **4 of 6 first attempts failed** the same way, 26-28 minutes in,
  on a recent checkpoint fetch, with `--max-retries 10`. Every second attempt succeeded.
- Side experiment the same day: 3 extra testnet nodes with `SUI_SNAPSHOT_MAX_RETRIES=50` (no code change): **3 of 3
  first attempts succeeded** (restore 1h15m-1h21m).

A failed attempt costs ~25-28 minutes, and three failed attempts leave the node down until the next boot.

## Decision
Default `SUI_SNAPSHOT_MAX_RETRIES` to **50** (was 10, `sui-tool`'s own default), validated as an integer from 0 to 1000.
Keep 3 restore attempts and 50 parallel downloads.

## Alternatives considered
- **More restore attempts (3 to 5):** recovers in the end but wastes ~25-28 minutes per failed attempt.
- **Fewer parallel downloads:** not tested; the starvation is CPU-bound, so the effect is unclear.
- **Mysten's Requester Pays snapshot buckets or own S3 snapshots:** the failing step fetches checkpoints, not snapshot
  files, so a different snapshot source may not help (ADR-0006 option E).

## Consequences
- More first-attempt restores, so new and replacement nodes serve sooner.
- On a genuinely unreachable endpoint, a restore takes longer to give up (each failing request retries up to 50 times).
- Evidence is small (3 of 3 vs 2 of 6) and from one day on testnet; it is consistent with Sui's own explanation.
  Revisit if restores still fail on the first attempt.
- Traffic shaping stays off during bootstrap (ADR-0019): harmless, and it removes one variable.
