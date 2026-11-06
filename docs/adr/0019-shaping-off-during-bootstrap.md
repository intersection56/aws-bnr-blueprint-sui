# ADR-0019: Keep traffic shaping off during bootstrap and when disabled

- **Status:** Accepted by owner 2026-11-03; verified live in the redeploy test 2026-11-03
- **Deciders:** build agent, from the first live test
- **Requirements:** R5.6, R11.1, R11.2, R11.4, R11.5
- **Amends:** ADR-0013 (traffic shaping default) and ADR-0006 (formal snapshot bootstrap)

## Context
In the first live testnet test (2026-11-03), two of three formal-snapshot restore attempts failed after about 24 minutes
with `Error performing GET https://checkpoints.testnet.sui.io/<seq>.binpb.zst ... operation timed out`. Each failure
discarded a 105 GB download and about 18 minutes of verification. A manual `curl` to the same URL from the instance took
24 ms at the same time.

Two framework behaviours combined:
1. The framework enables and starts `net-rules.service` (the outbound rate limit, 40 Mbit/s in the samples) during setup,
   before `node.sh` runs, **regardless of `TRAFFIC_SHAPING_ENABLED`** (`net-rules-start.sh` does not read it).
2. The original `syncchecker.sh` exited early while `/data/init-completed` was absent, and also when shaping was
   disabled. So it never removed the limit during bootstrap, and with shaping disabled it never removed it at all.

`sui-tool` (v1.82.3 and v1.83.0) runs a parallel summary sync and transaction-digest backfill against Sui's public
checkpoint endpoint (`--num-parallel-downloads` default 50, `--max-retries` default 10). After shaping was stopped by hand,
attempt 3 passed the failure point and completed. This is strong evidence, but one run does not prove that shaping was
the only cause.

## Decision
- `node.sh` stops `net-rules.service` before the install phase.
- `syncchecker.sh` stops it if running while `/data/init-completed` is absent, and whenever `TRAFFIC_SHAPING_ENABLED` is not `true`.
  When enabled and initialised, it applies the limit once in sync and removes it when behind, as before.
- Expose `SUI_SNAPSHOT_MAX_RETRIES` and `SUI_SNAPSHOT_PARALLEL_DOWNLOADS`, validated, with defaults equal to
  `sui-tool`'s own (10, 50). Keeping the defaults unchanged makes the redeploy test a clean check of the shaping explanation.

## Alternatives considered
- **Disable shaping in the samples:** avoids the bootstrap problem, but the framework would still start the limit, and
  the original checker would never remove it.
- **Raise retries or lower parallelism by default:** may also help, but would mix two changes in the retest. Kept as
  tunables for operators.
- **Change the framework:** the right long-term place for both behaviours, but out of scope for a community blueprint.
  Worth reporting upstream.

## Consequences
- Bootstrap traffic (snapshot download plus checkpoint fetches) is never rate-limited. That traffic is mostly inbound, which is not billed.
- `TRAFFIC_SHAPING_ENABLED="false"` now actually means no shaping.
- The framework's built-in Solana checker has the same early-exit pattern; this may affect other blueprints (not verified).
- Verified in the redeploy test (2026-11-03): the restore succeeded on the first attempt (1h42m) with shaping `inactive` throughout bootstrap. Two runs with shaping off succeeded and two with it on failed: strong evidence, not a controlled experiment. Issue 3 (the checker's unit detection under `pipefail`) was found and fixed in the same test, after which shaping was enabled once in sync.
- **Amended by ADR-0025 (2026-11-06):** the release test showed traffic shaping was not the root cause. With shaping off
  on every node, 4 of 6 first restore attempts still failed the same way; raising `SUI_SNAPSHOT_MAX_RETRIES` to 50 let
  3 of 3 succeed. Keeping shaping off during bootstrap stays: it is harmless and removes a variable.

