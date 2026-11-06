# Testnet test report

Live test of this blueprint on Sui **testnet**, run on 2026-11-03 in a personal test AWS account. It is the live
verification required by requirement 18 (`.kiro/specs/sui-rpc-node-blueprint/requirements.md`); per-requirement status
is in `traceability.md`.

All times are UTC. All figures are point-in-time measurements from this one run, on testnet, and may differ for other
regions, instance types, client versions or mainnet. Anything not measured is marked as such.

## Summary

**Result: pass with issues.** Deploy, snapshot restore, RPC serving, health checks, a transaction through the node,
a redeploy (instance stop/start) and a plain reboot all passed. Three defects were found that only a live deployment
could show; all three are fixed in the blueprint (see [Issues found](#issues-found)).

| | |
|---|---|
| Deploy to healthy and in sync | ~3h40m (formal snapshot restore ~1h40m, index build ~1h50m) |
| Redeploy (stop/start, instance store wiped) to healthy | 3h43m |
| Plain reboot to healthy | ~3 min |
| Disk used when in sync | 393 GB of 3.4 TB |
| Total runtime / estimated cost | 9h47m running / ~$16.50 (us-east-1 on-demand) |

**Not yet verified live:** the stop/start path of the issue-2 fix, HA mode, Amazon Inspector and CIS benchmark scans,
and mainnet. These are planned for the final release test.

## Setup

| Field | Value |
|---|---|
| Region / AZ | us-east-1 / us-east-1a (pinned: `i7i.4xlarge` is not offered in us-east-1e) |
| Sample | `samples/.env-testnet-sui-node-full`; only `AWS_ACCOUNT_ID`, `AWS_REGION` and `AWS_AZ` changed |
| Instance | `i7i.4xlarge` (x86_64, 16 vCPU, 128 GiB, 1 x 3,750 GB NVMe), Ubuntu 24.04 |
| Client | `sui-node 1.83.0-16d2dc1e05ed` (configuration `sui-node-v1.83.0-full.sh`) |
| Framework | `aws-samples/aws-blockchain-node-runners` commit `d1adb0a` (2026-11-02) |
| Stack | 7 resources: EC2 instance, security group, IAM role, instance profile and policy, CloudWatch dashboard, CDK metadata |

Pre-flight checks: default VPC present, `i7i.4xlarge` available in the chosen AZ, vCPU quota sufficient, CDK
bootstrapped, a budget alert created before deploying.

## Timeline

### Day 1: first deploy (stopped before the node was serving)

| Event | Time | Elapsed |
|---|---|---|
| `npx cdk deploy` started | 02:43:33 | 0 |
| Stack `CREATE_COMPLETE` | 02:47:53 | 4m20s |
| Release archive downloaded and SHA-256 verified (1.19 GB in ~10 s) | 02:49:17 | 5m44s |
| `genesis.blob` verified; `fullnode.yaml` written | 02:49:41 | 6m08s |
| Snapshot restore attempt 1 started | 02:49:41 | 6m08s |
| Snapshot download complete (~105 GB at ~290 MB/s) | ~02:55 | ~12m |
| Attempt 1 failed (checkpoint fetch timeout, see issue 1) | 03:13:35 | 30m |
| Attempt 2 failed (same error) | 03:38:37 | 55m |
| Traffic shaping stopped by hand; attempt 3 started | ~03:40 | ~57m |
| Snapshot restored (attempt 3: 1h38m); `node.service` active; framework reports success | 05:17:57 | 2h34m |
| Index build running (`rpc_store` 153.9 GB, RPC and P2P not yet listening) | 06:34 | 3h51m |
| Instance stopped to save cost; the redeploy test needs a full rebuild anyway | 06:35:27 | 3h52m |

### Day 2: redeploy with the issue-1 fix (re-run contract test)

| Event | Time | Elapsed |
|---|---|---|
| `npx cdk deploy` with the fixed blueprint | 17:36:35 | 0 |
| Stack `UPDATE_COMPLETE`; same instance updated in place (stop/start) | 17:37:57 | 1m22s |
| Framework recreated the RAID 0 `/data` on the wiped instance store | ~17:38 | ~2m |
| Binaries kept on the root volume ("already installed"); genesis re-verified; config rewritten with the new public IP | 17:38:34 | 2m |
| Restore attempt 1 started, traffic shaping inactive | 17:38:34 | 2m |
| Passed the day-1 failure point with no error | 18:04:59 | 28m |
| **Snapshot restored on attempt 1** (1h42m); `node.service` active | 19:20:47 | 1h44m |
| Index build finished (~1h50m); RPC and P2P listening | ~21:10 | ~3h34m |
| `/health` 200; catching up at ~300 checkpoints/s | 21:11:40 | 3h35m |
| **Caught up**; `/health?threshold_seconds=60` 200; shaping enabled once in sync | 21:19:05 | 3h43m |
| Transaction test passed | 23:17:35 | 5h41m |
| Plain reboot (`systemctl reboot`) | 23:24:33 | 5h48m |
| After reboot: healthy and in sync | 23:27:30 | 5h51m |
| `npx cdk destroy` completed | 23:35:53 | 5h59m |

## Functional checks

| Check | Expected | Result |
|---|---|---|
| Service running, no restart loop | `active`, `NRestarts=0` | PASS |
| Runs as `bcuser` | `bcuser` | PASS |
| Listeners | 9000/tcp on the internal IP only; 9184 and 1337 on 127.0.0.1; 8084/udp on 0.0.0.0 | PASS (8080 not listening) |
| RPC not on loopback | `sui` CLI to `127.0.0.1:9000` refused | PASS |
| RPC, metrics and admin not reachable from the internet | 9000, 9184, 1337 on the public IP refused or time out | PASS (all time out from an external machine) |
| Checkpoints advancing | `last_executed_checkpoint` increases | PASS (~300/s while catching up) |
| Correct chain | testnet chain identifier | PASS (`4c78adac`) |
| Health | `/health` 200; `?threshold_seconds=60` 200 when caught up | PASS (503 while catching up, as designed) |
| gRPC from inside the VPC | services listed, chain `testnet` | PASS (10 Sui v2/v2alpha services; `GetServiceInfo` returns `testnet`, `sui-node/1.83.0-16d2dc1e05ed`) |
| CloudWatch metrics | `c1_block_height`, `c1_blocks_behind`, `c1_seconds_behind` in `CWAgent` | PASS |
| Traffic shaping off during bootstrap, on when in sync | per ADR-0019 | Day 1 FAIL (issue 1); redeploy PASS after the fixes for issues 1 and 3 |
| Transaction through the node | testnet transfer succeeds | PASS |
| Redeploy (stop/start) | node returns healthy | PASS with issues (issues 2 and 3 found) |
| Plain reboot | starts after `/data` is mounted, no restarts, no setup re-run, healthy | PASS |

### Transaction test

A throwaway testnet address was funded with 1 SUI from the public faucet. The `sui` CLI (same release, checksum
verified) was pointed at the node's internal RPC address from a shell on the instance.

| | Test transfer | Return to faucet |
|---|---|---|
| Digest | `6kAwTLecuC8bcreq57rXnbC5YqqyjEbVMi9sX9yZxb4p` | `5XkZGaajUAcuTw9xUNrpoJCdNpxhtymz6d2wL3ugtiQK` |
| Amount | 0.010 SUI | 0.987 SUI |
| Status / checkpoint | success / 402,555,262 | success / 402,555,607 |
| Gas | 0.001 SUI | 0.001 SUI |

The first transaction was confirmed independently through Sui's public testnet endpoint. 0.997 SUI went back to the
faucet; 0.001 SUI dust remains, below the minimum gas budget.

## Measurements

| Measurement | Value | Notes |
|---|---|---|
| `cdk deploy` | 4m20s | |
| Release install | ~34 s | 1.19 GB archive |
| Formal snapshot download | ~105 GB at ~290 MB/s | Sui documents ~30 GB for mainnet (Nov 2025); testnet is much larger today |
| Snapshot restore | 1h38m-1h42m per successful attempt | ~15 of 16 cores busy |
| Index build | ~1h50m | ~840-990% CPU, ~11 GB RSS |
| Deploy to healthy and in sync | ~3h40m (redeploy 3h43m) | |
| `/data` after restore / when in sync | 225 GB / 393 GB | `store` 216 GB, `rpc_store` 176 GB, `checkpoints` 1.2 GB; 24 h growth not measured |
| Steady-state `NetworkOut` | 1.03 GB/h (~2.3 Mbit/s), ~0.75 TB/month | One full hour after sync; RPC traffic negligible, so effectively all P2P |
| Inbound during bootstrap | ~319 GB | Not billed |
| CloudWatch custom metrics | 197 per node | Estimate before the test was ~150 |
| Log volume | ~0.5 GB/day (including bootstrap) | Estimate before the test was 2 GB/day |
| Memory, steady state | ~16 GB used, the rest page cache, of 123 GiB | |
| P2P vs RPC split, peer count | not measured | |

These values replaced the assumptions in the README cost model ("Monthly Cost Estimate") and timings.

## Issues found

| # | Symptom | Root cause | Fix | Retested |
|---|---|---|---|---|
| 1 | Snapshot restore attempts 1 and 2 each failed after ~24 min with an HTTP timeout fetching checkpoints from `checkpoints.testnet.sui.io`. Each retry re-downloaded ~105 GB. | The framework starts traffic shaping (40 Mbit/s egress cap) at setup, and the sync checker exited early until `/data/init-completed` existed, so shaping stayed on during bootstrap while `sui-tool` made many parallel requests. A related framework behaviour: the shaping unit is started even when `TRAFFIC_SHAPING_ENABLED` is not `true`. | `node.sh` stops shaping before the install phase; `syncchecker.sh` keeps it off until init completes and whenever shaping is disabled; new settings `SUI_SNAPSHOT_MAX_RETRIES` and `SUI_SNAPSHOT_PARALLEL_DOWNLOADS`. ADR-0019. | Yes: the redeploy restored on attempt 1 with shaping off. Two runs with shaping off succeeded and two with it on failed; strong evidence, not a controlled experiment. |
| 2 | After stop/start, `node.service` started at boot before the framework recreated `/data`; `sui-node` aborted with "Permission denied" and was restarted once. Harmless here, but it could have written the database to the root volume if the empty mount point had been writable. | The unit had no dependency on `/data`. The framework's fstab entry is `nofail`, which gives no boot ordering. | `RequiresMountsFor=/data` plus `ConditionPathIsMountPoint=/data` in `node.service`. ADR-0020. (A first fix using only the condition was rejected on review: on a plain reboot it could skip the service and leave the node down.) | Plain reboot: yes, started after `data.mount` with 0 restarts. Stop/start path: not yet; planned for the final release test. |
| 3 | The sync checker logged "net-rules.service not found" although the unit existed, so shaping was never re-enabled after sync. | `systemctl list-unit-files \| grep -q ...` under `set -o pipefail`: `grep -q` exits early, `systemctl` gets SIGPIPE (141) and the pipeline fails at random. | Replaced with `systemctl cat net-rules.service >/dev/null 2>&1`. | Yes: shaping was enabled once in sync. |

Regression tests for all three issues are in `test/sui-configuration.test.ts`. Local verification after the fixes:
30/30 Jest tests, `cdk synth` of all 4 samples, ShellCheck clean.

## Cost

| Period | State | Duration | Estimated cost |
|---|---|---|---|
| Day 1 | running | 3h49m | ~$6.40 |
| Overnight | stopped (root EBS and dashboard only) | ~11h | ~$0.14 |
| Day 2 | running | 5h58m | ~$9.95 |
| **Total** | | **9h47m running** | **~$16.50** |

Estimated at ~$1.67/hour running (EC2, root EBS, public IPv4, CloudWatch, testnet P2P egress), us-east-1 on-demand
prices as of 2026-11-02. Not reconciled with the bill.

## Teardown

`npx cdk destroy` removed all 7 stack resources, including the instance and dashboard; no volumes were left. The
CloudWatch agent's log groups were kept; they have 7-day retention, so the data expires on its own.

## Findings for the Node Runners framework

To be reported upstream:

1. `net-rules.service` (traffic shaping) is enabled and started regardless of `TRAFFIC_SHAPING_ENABLED`, and is active
   during bootstrap, when snapshot downloads run. Sync checkers that exit early when shaping is disabled never remove it.
2. The `dummy` and `solana` sync checkers detect `net-rules.service` with `grep -q` under `pipefail` (issue 3), so
   detection fails at random.
3. Single-node user-data passes an unused `AWS_AZ` to `Fn::Sub` (cfn-lint W1019 warning on every synth).
4. Reinstalling a local blueprint with `npm install <path> --install-links` without bumping its version can leave a
   stale copy in `node_modules`; remove `node_modules/<package>` first.
5. Services enabled at boot that use instance-store data can start before `/data` is mounted (`nofail` gives no
   ordering); `RequiresMountsFor=/data` avoids it.
6. The HA Auto Scaling group always uses the load balancer's health checks (`additionalTypes: [ELB]` in
   `ha-nodes-construct.ts`), so a blueprint cannot separate "stop sending traffic" from "replace the node". For chains
   whose nodes take hours to bootstrap, a freshness check (Sui's `/health?threshold_seconds=N`) would then rebuild
   lagging nodes, and replace every node during a network halt. Suggested: an option for EC2-only Auto Scaling health
   checks (keeping ELB checks for routing), or an instance maintenance policy that launches before terminating.

## Not yet tested

- sui-node v1.83.1, the version the blueprint now pins for both networks (this test ran v1.83.0 on testnet). The
  configuration keys, `sui-tool` flags and `/health` logic the blueprint relies on are unchanged in Sui's source.
- Stop/start with the final issue-2 fix (only a plain reboot has been tested).
- HA mode (3 nodes behind the internal ALB, 1,440-minute health-check grace period; 2 nodes at the time of this test).
- In-place upgrades (`scripts/upgrade-in-place.sh`) and the never-downgrade safeguard, added after this test.
- The stack-level lag metric and alarm, added after this test.
- Amazon Inspector and CIS Ubuntu benchmark on a live node.
- Mainnet: bootstrap time, disk use (~2.5 TB pruned with indexes per Sui, Nov 2025, on 3,750 GB) and egress are modelled, not measured.
