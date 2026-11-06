# Testnet test report

Live tests of this blueprint on Sui **testnet** in a personal test AWS account (us-east-1): a first test on
2026-11-03, and the pre-publish **release test** on 2026-11-06 ([below](#release-test-2026-11-06)). They are the live
verification required by requirement 18 (`.kiro/specs/sui-rpc-node-blueprint/requirements.md`); per-requirement status
is in `traceability.md`. Mainnet was not deployed in either test.

All times are UTC. All figures are point-in-time measurements on testnet and may differ for other regions, instance
types, client versions or mainnet. Anything not measured is marked as such.

# First test (2026-11-03)

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

## Not yet tested (as of 2026-11-03)

- sui-node v1.83.1, the version the blueprint now pins for both networks (this test ran v1.83.0 on testnet). The
  configuration keys, `sui-tool` flags and `/health` logic the blueprint relies on are unchanged in Sui's source.
- Stop/start with the final issue-2 fix (only a plain reboot has been tested).
- HA mode (3 nodes behind the internal ALB, 1,440-minute health-check grace period; 2 nodes at the time of this test).
- In-place upgrades (`scripts/upgrade-in-place.sh`) and the never-downgrade safeguard, added after this test.
- The stack-level lag metric and alarm, added after this test.
- Amazon Inspector and CIS Ubuntu benchmark on a live node.
- Mainnet: bootstrap time, disk use (~2.5 TB pruned with indexes per Sui, Nov 2025, on 3,750 GB) and egress are modelled, not measured. Mainnet is not part of the pre-publish release test (testnet only); the HA sample's 24-hour grace period is an estimate for mainnet.

# Release test (2026-11-06)

## Summary

**Result: pass with issues.** Blueprint commit `0f34116` (sui-node v1.83.1), framework commit `2db9ea3`, testnet only
(Owner decision). A single-node stack and a 3-node HA stack ran in parallel. Every functional check passed, including
the in-place upgrade, the never-downgrade safeguard across a stop/start, the issue-2 fix on a real stop/start, HA
failover and replacement, and the lag alarm. Two issues were found and fixed in the blueprint (issues 4 and 5); one
check could not be completed (CIS benchmark).

| | Single node | 3-node HA |
|---|---|---|
| Deploy (`cdk deploy`) | 4 min | 3.5 min |
| Deploy to serving and in sync | ~4h30m (restore attempt 1 failed) | ~4 h for all 3 (2 of 3 restores failed attempt 1) |
| In-place upgrade v1.83.0 to v1.83.1 | 1m08s total; healthy and in sync 20 s after restart | not applicable (refused by design) |
| Stop/start to serving and in sync | ~3h30m (instance store rebuilt) | not applicable (instances are replaced) |
| Reboot to healthy | - | 2m43s; load balancer kept serving |
| Node lost to replacement healthy | - | ~3h30m; load balancer kept serving on 2 nodes |
| Estimated cost (us-east-1 on-demand) | ~$15 | ~$44 |

A side experiment (3 extra single nodes, ~$8) tested the fix for issue 4. Total estimated cost ~$67.

## Setup

| Field | Value |
|---|---|
| Region | us-east-1; single node pinned to us-east-1a; HA across all default-VPC public subnets |
| Instances | `i7i.4xlarge` (x86_64, 16 vCPU, 128 GiB, 1 x 3,750 GB NVMe), standard shared-tenancy EC2, Ubuntu 24.04 (AMI built 2026-10-23) |
| Single node | `samples/.env-testnet-sui-node-full`, `CLIENT_CONFIG` set to a **test-only** `sui-node-v1.83.0-full.sh` (a copy of the v1.83.1 file, added only to the test checkout, never committed) so an in-place upgrade to v1.83.1 could be tested before a newer testnet release existed |
| HA | `samples/.env-testnet-sui-node-full-ha` (3 nodes, v1.83.1), `STACK_NAME_PREFIX="ha"` so both stacks could run at once |
| Install | Blueprint installed from a clean clone of the commit into two fresh framework checkouts; installed copies checked identical to the commit |
| Before deploying | Synthesized templates: 9000/tcp only from the VPC CIDR and the ALB security group, 8084/udp from the internet, ALB `internal`, ASG desired 3 / grace 24 h. The CDK bootstrap stack had been deleted from the account since the first test and was re-created |

## Timeline

| Event | Time |
|---|---|
| Both stacks deployed | 01:31:45-01:35:54 |
| HA: Auto Scaling tried us-east-1e first (`i7i.4xlarge` not offered there), then launched in us-east-1a, c, d | 01:34:46-01:34:55 |
| All 4 nodes: release downloaded and SHA-256 verified; traffic shaping inactive during bootstrap | ~01:37-01:38 |
| Restore attempt 1 **failed** on the single node and 2 HA nodes (checkpoint fetch timeout, 26-28 min in); retried automatically | 02:04-02:06 |
| HA1 restored on attempt 1 (1h15m); the others restored on attempt 2 (1h22m-1h50m) | 02:53-03:56 |
| HA1 serving (load balancer healthy) while 71,943 checkpoints behind; in sync minutes later; shaping enabled once in sync | 04:34-05:00 |
| All 3 HA nodes healthy and in sync; lag alarm back to OK | 05:36 |
| HA: reboot of one node | 05:56-05:59 |
| HA: P2P of one node blocked for 13.5 minutes (lag test) | 06:05-06:19 |
| HA: one node terminated; replacement launched 1.5 min later in us-east-1a | 06:26-06:27 |
| Single: in-place upgrade v1.83.0 to v1.83.1 | 06:33:23-06:34:31 |
| Single: stop/start; safeguard kept v1.83.1; restore attempt 1 succeeded (1h21m) | 06:34:45-07:59 |
| Side experiment: 3 single nodes with `SUI_SNAPSHOT_MAX_RETRIES=50`; all restored on attempt 1 | 07:13-08:44 |
| HA replacement healthy and in sync (restore attempt 1 failed, attempt 2 succeeded) | 09:58 |
| Single node in sync on v1.83.1 after the rebuild | 10:05 |
| Both stacks destroyed | 10:07-10:10 |

## Functional checks

| Check | Result |
|---|---|
| Release download, SHA-256 verification, genesis pin | PASS on all 4 nodes |
| Traffic shaping off during bootstrap; enabled once in sync (issues 1 and 3) | PASS on every node |
| `node.service` 0 restarts, runs as `bcuser` | PASS on every node |
| Listeners: RPC on the internal IP only; metrics and admin on 127.0.0.1; only P2P on 0.0.0.0:8084/udp | PASS on every serving node |
| RPC, metrics and admin not reachable on public IPs (probed from outside AWS) | PASS (all time out) |
| Amazon Inspector network reachability | PASS: only 8084/udp reachable from the internet, on every node |
| Chain identity (`4c78adac`, testnet) and version | PASS |
| HA: `/health` through the internal ALB | PASS (200 throughout, including during the reboot, the P2P block and the node loss) |
| HA: **gRPC-Web through the ALB** (`LedgerService/GetServiceInfo`) | PASS: HTTP 200, `grpc-status:0`, chain `testnet`, server `sui-node/1.83.1` |
| HA: native gRPC (HTTP/2) through the ALB | Fails, as documented (native gRPC must target instances directly) |
| HA: unsupported AZ (us-east-1e) | PASS: Auto Scaling launched in other zones; nodes spread over 3 AZs, also after the replacement |
| HA: reboot | PASS: out of rotation ~1.5 min; boot gate `skip`; `/data` mounted before `node.service`; data intact; not replaced (grace period) |
| HA: node terminated | PASS: 2 nodes kept serving; replacement launched in 1.5 min and healthy ~3h30m later |
| **Freshness gap** (plain `/health`) | Confirmed as documented: a node cut off from P2P stayed healthy in the ALB, with `/health` 200 and `?threshold_seconds=60` 503, for 13.5 minutes |
| **Lag alarm** (stack-level `c1_seconds_behind`) | PASS after the fix for issue 5: fired ~8 min after the P2P block, cleared ~6 min after catch-up; also fired during each node's post-bootstrap catch-up (correct: those nodes were already receiving traffic) |
| In-place upgrade tool | PASS: dry run, plan, SHA-256 verified install, restart, healthy and in sync 20 s later; refused a live HA instance |
| **Never-downgrade safeguard** across a stop/start (stack still `v1.83.0`) | PASS: installer logged "testnet-v1.83.1 is installed (upgraded in place) and is newer than the requested v1.83.0; keeping it", and the node rebuilt and served on v1.83.1 |
| Issue-2 fix on a real stop/start | PASS: `node.service` did not start before `/data` existed (0 restarts, no panic); started after `data.mount` |
| Amazon Inspector package scan | Completed; see below |
| CIS Ubuntu Level 1 benchmark (Amazon Inspector) | **Not completed**: the scan failed twice (the Inspector plugin exits with an error on these nodes and Inspector reports it as timed out), including on idle nodes |

## Amazon Inspector results

2,753 package findings per node, identical on all 4 nodes, all from the Ubuntu 24.04 image; none from the blueprint:
- ~2,732 are Linux kernel CVEs (`linux-image-aws`) with **no fix available** from Ubuntu at the time (160 critical, 867
  high, 50 medium, 1,655 untriaged).
- ~20 have a fix available (brotli, bind9, libpcre2, apt, python-pip, python3-wheel, libmspack, python3-twisted).
  `unattended-upgrades` is enabled on the image (11 security updates pending; next run the same morning), so these are
  installed automatically. Kernel fixes also need a reboot, which keeps instance-store data.

## Measurements

| Measurement | Value |
|---|---|
| `cdk deploy` | 3.5-4 min |
| Restore, successful attempt | 1h15m-1h50m (9 restores) |
| Failed restore attempt (time lost) | 26-28 min each |
| Index build | ~1h40m-1h50m |
| Deploy to healthy (no failed attempt) | ~3h00m (HA1) |
| `/data` used when in sync | ~390-400 GB of 3.4 TB |
| In-place upgrade | 1m08s end to end; 20 s from restart to in sync |
| Reboot to healthy (HA) | 2m43s |
| Lag alarm, block to ALARM / recovery to OK | ~8 min / ~6 min |

## Issues found

| # | Symptom | Root cause | Fix | Retested |
|---|---|---|---|---|
| 4 | **4 of 6 first restore attempts failed** after 26-28 minutes with a checkpoint fetch timeout from `checkpoints.testnet.sui.io`, with traffic shaping **off** on every node. Each failure cost ~27 minutes. | Not traffic shaping (issue 1's conclusion was incomplete). Per `sui-tool`'s own source, the CPU-bound restore can starve its async runtime so that a single checkpoint fetch keeps timing out; after `--max-retries` (default 10, backoff capped at 30 s) the whole restore aborts. | Default `SUI_SNAPSHOT_MAX_RETRIES` raised from 10 to **50**, validated 0-1000 (ADR-0025, proposed). | Side experiment with 50: **3 of 3 first attempts succeeded** (1h15m-1h21m). Small sample; consistent with Sui's explanation. |
| 5 | The documented lag alarm (1-minute periods, 5 evaluation periods) returned to **OK** while a node was ~78,000 s behind. | The sync checker runs every 60-90 s, so some 1-minute periods had no sample from the lagging node; the Maximum then came only from healthy nodes. The README also wrongly said bootstrapping nodes never trigger the alarm; they do during the post-bootstrap catch-up, correctly. | README command changed to 5-minute periods (`--period 300 --evaluation-periods 2 --datapoints-to-alarm 2`) and the wording corrected (ADR-0023 update). | Yes: the corrected alarm stayed in ALARM through a node's whole catch-up, fired on the P2P block and cleared after recovery. |

Both fixes are verified locally (41/41 tests, all samples synthesize, ShellCheck clean); neither was redeployed.

## Cost

Estimated from instance runtimes (us-east-1 on-demand, prices re-checked 2026-11-05): 39 node-hours of
`i7i.4xlarge` (~$59) plus root EBS, public IPv4, CloudWatch, testnet egress and the ALB (~$8), **~$67** in total: single
node ~$15, HA ~$44, side experiment ~$8. Not reconciled with the bill.

## Teardown

Both stacks and the 3 experiment stacks destroyed; the test alarm, the CIS scan configuration and Amazon Inspector
(enabled for EC2 only for this test) removed or disabled again. No instances, volumes, load balancers, alarms or
dashboards remain. The CloudWatch agent's log groups were kept (7-day retention). The CDK bootstrap stack re-created for
this test was kept.

## Not yet tested (as of 2026-11-06)

- Mainnet (bootstrap time, disk use against 3,750 GB, egress): modelled only.
- An HA rolling upgrade (`cdk deploy` to a new version replacing nodes one at a time).
- The CIS Ubuntu benchmark.
- `SUI_SNAPSHOT_MAX_RETRIES=50` as a deployed default (tested only through `.env` in the side experiment).
