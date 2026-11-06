# Traceability Matrix

Links each requirement (`requirements.md`) to where it is implemented, how it is verified, and its status.
Status as of **2026-11-03 23:15 UTC**, after the redeploy test (node healthy and in sync; transaction test pending).

**Status key**
- **Verified (static):** checked by tests, `cdk synth`, ShellCheck, scans or a scripted local check.
- **Implemented, pending live test:** code exists and was reviewed, but behaviour on EC2 is unconfirmed. Verified by the live test in `docs/testnet-test-report.md`.
- **Partly met / Not met / Open:** see notes.

`T:` = Jest test in `test/sui-configuration.test.ts`. `TR` = `docs/testnet-test-report.md` (e.g. TR checks, TR measurements, TR issues); plain numbers like 15.4 in the first column are requirement criteria.

| Req | Implemented in | Verified by | Status |
|---|---|---|---|
| 1.1-1.2 Package and protocol field | `package.json` | T: "should load the Sui protocol configuration"; validate.sh install | Verified (static) |
| 1.3 Loader validates samples | `samples/*` | T: "should pass configuration validation…" x4; `cdk synth` x4 | Verified (static) |
| 1.4 Naming conventions | file names, `node.sh` | T: config-name regex; T: service is `node`, `User=bcuser` | Verified (static) |
| 1.5 `files` list | `package.json` | Review; validate.sh installs via `--install-links` (packs per `files`) | Verified (static) |
| 2.1-2.2 Networks only mainnet/testnet | `node.sh`, `install-sui-binaries.sh`, `write-fullnode-config.sh` | Review | Implemented, pending live test |
| 2.3 Version from file name | `configurations/*.sh` | Review | Verified (live 2026-11-03): log shows `v1.83.0` parsed, `testnet-v1.83.0` resolved |
| 2.4 Fail on missing release tag | `install-sui-binaries.sh` | Review; release tags confirmed to exist for both pinned versions (GitHub API) | Implemented, pending live test (happy path verified live 2026-11-03; failure path not exercised) |
| 2.5 Per-network configs, identical scripts | `configurations/*.sh` | T: "identical script for every available configuration"; T: "list exactly the pinned configurations, defaulting to mainnet" | Verified (static); v1.83.1 for both networks since 2026-11-05 (release assets and digests checked; config, `sui-tool` and `/health` source unchanged from the tested versions), not yet deployed live |
| 2.6 Daily release watch | `scripts/check-release.sh`, `.github/workflows/release-watch.yml`, `scripts/bump.sh` | `DRY_RUN=1` against live releases (behind before the bump, up to date after); `bump.sh` used for the v1.83.1 bump; bad input rejected without changes | Verified (static); workflow not yet run on GitHub |
| 2.7 Never-downgrade safeguard | `user-data/common/sui-version.sh`, `install-sui-binaries.sh`, `SUI_ALLOW_DOWNGRADE` | T: "never downgrade an in-place upgraded node unless allowed" (8 cases, runs the helper); T: "apply the safeguard in the installer and validate SUI_ALLOW_DOWNGRADE" | Verified (static); live check (in-place upgrade, then stop/start) in task 25a part 1 |
| 2.8 In-place upgrade tool | `scripts/upgrade-in-place.sh` | Stubbed-AWS-CLI test: bad input, HA tag, HA mode, downgrade, same version and missing release refused; dry run; confirmation; full run; rollback flag; remote scripts pass `sh -n` and ShellCheck `-s sh` | Verified (static); live in task 25a part 1 |
| 3.1 Deployment modes | `package.json` | T: modes; `cdk synth` single + HA | Verified (static) |
| 3.2 Default types meet Sui minimum | `package.json`, samples | Price List API specs (16 vCPU, 128 GiB) | Verified (static) |
| 3.3 `/data` instance store ≥ 3,500 GiB | `package.json`, samples | T: "should put /data on NVMe instance store" x4 | Verified (static) |
| 3.4 `.8xlarge` RAID path | framework `setup-storage.sh` | Source review of framework RAID logic | Implemented, pending live test |
| 3.5 Four samples | `samples/` | T: per-sample tests | Verified (static) |
| 4.1-4.3 Asset source and digest check | `install-sui-binaries.sh` | Review; manual download of mainnet x86 asset matched digest (2026-11-02) | Verified (live 2026-11-03): `SHA-256 verified`; failure path not exercised |
| 4.4 Only `sui-node`, `sui-tool` | `install-sui-binaries.sh` | Full tarball listing confirmed both present | Verified (live 2026-11-03) |
| 4.5 Genesis pinned | `install-sui-binaries.sh` | Pins computed from downloaded blobs 2026-11-02 | Verified (live 2026-11-03): `genesis.blob verified` |
| 4.6 No downloaded scripts executed | all scripts | Framework security checklist self-review; ASH | Verified (static) |
| 5.1-5.2 Formal snapshot restore, verified | `download-snapshot.sh` | Review of `sui-tool` v1.82.3 source (staging -> live) | Verified (live 2026-11-03) on attempt 3; attempts 1-2 failed (issue 1) |
| 5.3 Skip when DB exists | `download-snapshot.sh` | Review | Implemented, pending live test (redeploy test) |
| 5.4 Retries, no `live/` on failure | `download-snapshot.sh` | Review | Verified (live 2026-11-03): two failures retried, no partial `live/` |
| 5.5 Genesis-sync warning | `download-snapshot.sh` | Review | Implemented, pending live test |
| 5.6 Snapshot tuning settings, validated | `download-snapshot.sh`, `package.json`, samples | T: "should pass validated snapshot tuning settings to sui-tool"; local validation test (`x`, `0`, `201`, injection rejected); flags confirmed in `sui-tool` v1.82.3 and v1.83.0 source | Verified (live 2026-11-03): log shows `parallel=50, max-retries=10` passed to sui-tool |
| 6.1 Atomic write every run | `write-fullnode-config.sh` | Local run with stubbed IMDS | Verified (static) |
| 6.2 Seed peers | `write-fullnode-config.sh` | YAML parsed: mainnet 10, testnet 7 peers | Verified (static) |
| 6.3 Pruning and indexing values | `write-fullnode-config.sh` | YAML parsed; keys checked against `sui-config` v1.82.3 source | Verified (static); acceptance by `sui-node` pending live test |
| 6.4 Input validation | `write-fullnode-config.sh` | Local test: `'5; rm -rf /'` rejected | Verified (static) |
| 6.5 `external-address` from public IP | `write-fullnode-config.sh` | Local run with and without public IP | Verified (live 2026-11-03): `/ip4/<public-ip>/udp/8084` written |
| 6.6 Archive fallback policy | `write-fullnode-config.sh` | YAML parsed: testnet on, mainnet off by default | Verified (static) |
| 6.7 No credentials in config | `write-fullnode-config.sh` | Review; ASH detect-secrets; second secrets scanner | Verified (static) |
| 7.1 RPC on internal IP | `write-fullnode-config.sh` | T: RPC bound to internal IP; YAML parsed | Verified (live 2026-11-03): `ss` shows 9000 on the instance's internal IP only; CLI to 127.0.0.1:9000 refused |
| 7.2 9000 from VPC CIDR only | `package.json` | T: port 9000 `public: false`; synthesized SG inspected | Verified (live 2026-11-03): 9000 times out from the internet |
| 7.3 Only 8084/udp public | `package.json`, config | T: ports; synthesized SG inspected; `0.0.0.0` sweep | Verified (live 2026-11-03): 8084/udp on 0.0.0.0; 9000, 9184, 1337 time out from the internet |
| 7.4-7.5 Metrics, admin, network-address on loopback | `write-fullnode-config.sh` | T: metrics loopback; YAML parsed | Verified (live 2026-11-03): 9184 and 1337 on 127.0.0.1; 8080 not listening |
| 7.6 HA ALB internal | framework default, HA sample | Synthesized template: scheme `internal` | Verified (static) |
| 8.1-8.2 Service definition | `node.sh` | T: `node`, `User=bcuser`, `EnvironmentFile` | Verified (live 2026-11-03): active, `bcuser`, NRestarts 0 |
| 8.3 Runtime does not read env file | `configurations/*.sh` | Review | Implemented, pending live test |
| 8.4 Minimal AWS API use | `syncchecker.sh` | Self-review: only `cloudwatch put-metric-data` | Verified (static) |
| 8.5 Service waits for /data mount | `node.sh` (unit) | T: "should not start the node service unless /data is mounted" (both directives); `systemd-analyze verify`; live plain-reboot test | **Defect found live 2026-11-03** (issue 2); first fix flawed, revised; Verified (live, plain reboot 2026-11-03); stop/start path pending (final release test) |
| 9.1 Re-run replaces, skips restore, restarts | `node.sh`, helpers | Review | Verified (live 2026-11-03, redeploy after stop/start): storage rebuilt, binaries kept (marker), config rewritten with new public IP, restore re-run because `/data` was wiped, service restarted |
| 9.2 No chain data deletion | all scripts | Self-review: `rm -rf` only on temp dir | Verified (static) |
| 9.3 Non-zero on failure | all scripts | Review (`set -euo pipefail`, explicit exits) | Implemented, pending live test |
| 9.4 Sentinel | `node.sh` | T: `touch /data/init-completed` | Verified (live 2026-11-03): `/data/init-completed` at 05:18 |
| 10.1-10.2 `c1_*` metrics | `syncchecker.sh` | Parser unit check (plain, labelled, scientific notation) | Verified (live 2026-11-03): all three in `CWAgent`, updating |
| 10.3 Metrics from loopback only | `syncchecker.sh` | Review | Verified (static) |
| 10.4 Zeros when metrics missing | `syncchecker.sh` | Review | Implemented, pending live test |
| 10.5 Stack-level lag metric + documented alarm | `syncchecker.sh`, `README.md` (Lag alarm) | T: "publish a stack-level c1_seconds_behind for the lag alarm"; `STACK_NAME` confirmed in framework user data | Implemented, pending live test (task 25a part 1) |
| 11.1-11.2 Shaping control | `syncchecker.sh` | Local stub tests: in sync -> start, behind -> stop, no change otherwise | Verified (live 2026-11-03) with the issue-3 fix: off during bootstrap, enabled once in sync. Original checker failed (issues 1 and 3) |
| 11.3 README states shaping effect | `README.md` | Review | Verified (static) |
| 11.4 Shaping off during bootstrap | `node.sh`, `syncchecker.sh` | T: "should stop traffic shaping before the install phase", "should keep shaping off during bootstrap…"; local stub test (bootstrap with shaping active -> stopped) | Verified (live 2026-11-03, redeploy): `inactive` throughout bootstrap; restore succeeded on attempt 1 |
| 11.5 Shaping off when disabled | `syncchecker.sh` | Local stub test (`TRAFFIC_SHAPING_ENABLED=false`, active -> stopped) | Verified (static) |
| (issue 3) Reliable unit detection | `syncchecker.sh` | T: "should detect net-rules.service without a pipefail-unsafe grep -q pipe"; reproduced on the instance (`0 0 141 141 141`) | **Defect found live 2026-11-03**, fixed; Verified (live, hot-patched checker) |
| 12.1 HA health check `/health` 200 | HA sample | T: HA sample port/path/codes | Partly verified (live, single node): `/health` 200 when serving; `?threshold_seconds=60` 503 while behind, 200 once in sync. ALB behaviour not tested (no HA deploy) |
| 12.2 Grace period sufficient | HA sample (1,440 min) | Testnet deploy-to-healthy measured 3h43m (2026-11-03); T: HA grace period >= 600 min | Implemented, pending live test (no HA deployment yet; mainnet bootstrap not measured) |
| 12.3 README explains replacement and suspend option | `README.md` | Review | Verified (static) |
| 12.4 README states gRPC-Web limit | `README.md` | Review; `sui-rpc-api` source shows `GrpcWebLayer` | Verified (static) |
| 12.5 Plain `/health` in HA samples; README explains HA scope | HA samples, `README.md` | T: HA samples use `/health`; framework ASG uses ELB health checks (`ha-nodes-construct.ts`); ALB fail-open per AWS docs | Verified (static); HA not yet deployed |
| 12.6 3-node HA samples | `.env-mainnet-sui-node-full-ha`, `.env-testnet-sui-node-full-ha` | T: "should run 3 nodes" | Verified (static); live in task 25a part 2 |
| 13.1-13.5 Cost documentation | `README.md` | Review; Price List API values; measured traffic model | Verified (static); assumptions to replace with TR measurements |
| 14.1-14.3 README content | `README.md` | Review against framework template | Verified (static) |
| 14.4 Intended use and alternatives | `README.md` (When to use this blueprint; AWS vs bare metal) | Review | Verified (static) |
| 15.1-15.2 Tests and validate.sh | `test/`, `scripts/validate.sh` | 25/25 tests, 4/4 synth, run 4 times | Verified (static) |
| 15.3 ShellCheck | all scripts | `shellcheck -S warning` clean | Verified (static) |
| 15.4 CI pinned, least privilege | `.github/workflows/ci.yml` | ASH rerun clean; review | Verified (static) |
| 16.1 Pre-deploy scans clean | - | ASH 0 findings after fixes; second secrets scanner 0 | Verified |
| 16.2 Pre-publish scans | - | Not yet | Open |
| 16.3 Live-instance scans | - | Not yet | Open (test day) |
| 16.4 No upload without consent | - | One scanner sent files to an AI service in the Owner's own AWS account despite its scan-only flag | **Partly met** (one scan; later scans must avoid it) |
| 16.5 Inline suppressions with reasons | `install-sui-binaries.sh` | Review | Verified (static) |
| 17.1-17.2 Consistent licence | `LICENSE`, `package.json`, headers | Compared with the 5 community blueprints and apache.org (2026-11-05) | Verified (static): Apache-2.0 everywhere (ADR-0018); copyright holder confirmed by the Owner 2026-11-05 |
| 18.1-18.3 Live verification | - | Not yet | Partly verified (live 2026-11-03): one testnet test run (9h47m), all functional checks and the transaction test pass, measurements in TR, torn down; HA and the final release test pending |

## Summary

65 rows (counted 2026-11-03 23:15 UTC, after the redeploy test):
- Verified (static): 29
- Verified (live): 18
- Pending live test: 8
- Defect found and fixed: 2
- Open: 2
- Partly verified (live): 1
- At risk: 1
- Verified (scans): 1
- Partly met: 1
- Not met: 1
- In progress: 1

The open questions at the end of `requirements.md` are not rows; they need Owner decisions.

After the test, update this table: move rows to **Verified (live)** with the date, or record an issue in the TR issues table.
