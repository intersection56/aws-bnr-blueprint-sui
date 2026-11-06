# Design Document

## Overview

`aws-bnr-blueprint-sui` plugs a Sui RPC full node into the AWS Blockchain Node Runners v2 framework. The framework owns
the AWS infrastructure (EC2, storage setup, security groups, ALB/ASG for HA, CloudWatch agent, traffic shaping, the
sync-checker timer). The blueprint owns everything Sui-specific: which binary to install and how to verify it, how to
bootstrap state, the `fullnode.yaml`, the service definition, and the health and metrics adapters.

**Provenance:** written retroactively on 2026-11-02 to describe the implemented design; see `requirements.md` and
`docs/adr/`. Unverified behaviour is marked *(to verify in test)*.

## Architecture

### Responsibilities

| Concern | Owned by | Where |
|---|---|---|
| VPC lookup, EC2, security groups from `requiredPorts`, ALB/ASG | Framework | `lib/common/*-construct.ts` |
| `/etc/cdk_environment`, `bcuser`, storage and RAID, CloudWatch agent, `net-rules.service`, `syncchecker.timer` | Framework | `assets/common/*` |
| Protocol declaration (ports, storage, instance types, env defaults) | Blueprint | `package.json` (R1, R3) |
| Protocol-level setup and `node` service | Blueprint | `user-data/node.sh` (R8, R9) |
| Version selection and install/run dispatch | Blueprint | `configurations/sui-node-vX.Y.Z-full.sh` (R2) |
| Binary + genesis install and verification | Blueprint | `user-data/common/install-sui-binaries.sh` (R4) |
| `fullnode.yaml` generation | Blueprint | `user-data/common/write-fullnode-config.sh` (R6, R7) |
| Formal snapshot restore | Blueprint | `user-data/common/download-snapshot.sh` (R5) |
| Metrics adapter and traffic shaping control | Blueprint | `user-data/syncchecker.sh` (R10, R11) |

### Component and boot flow

```
cloud-init (framework user-data)
  └─ node-setup.sh (framework): env file, bcuser, storage, CW agent, net-rules, syncchecker.timer
       └─ /opt/blueprints/user-data/node.sh                         [root]
            ├─ validate BC_NETWORK, CLIENT_CONFIG
            ├─ configurations/$CLIENT_CONFIG install                [root]
            │    ├─ common/install-sui-binaries.sh vX.Y.Z
            │    │    GitHub API -> asset URL + digest -> download -> sha256 -> extract sui-node, sui-tool
            │    │    sui-genesis -> genesis.blob -> sha256 vs pinned
            │    ├─ common/write-fullnode-config.sh
            │    │    IMDSv2 -> internal IP / public IP -> validate SUI_* -> fullnode.yaml (atomic)
            │    └─ common/download-snapshot.sh
            │         skip if /data/sui/db/live; else sui-tool restore as bcuser (3 attempts)
            ├─ install config script as /home/bcuser/bin/start-node.sh
            ├─ write + (re)start node.service
            └─ touch /data/init-completed
node.service                                                       [bcuser]
  └─ start-node.sh (no args) -> exec sui-node --config-path fullnode.yaml
syncchecker.timer -> syncchecker.sh                                [root, framework timer]
  └─ 127.0.0.1:9184/metrics -> CloudWatch c1_* ; start/stop net-rules.service
```

### Data layout

| Path | Contents | Lifetime |
|---|---|---|
| `/home/bcuser/bin/sui-node`, `sui-tool`, `.sui-release`, `start-node.sh` | Binaries, release marker, entrypoint | Replaced per run (R9) |
| `/home/bcuser/sui-config/fullnode.yaml`, `genesis.blob` | Generated config, verified genesis | Rewritten / re-verified per run |
| `/data/sui/db/live` | RocksDB (written by `sui-tool`, then `sui-node`) | Persistent until instance-store loss |
| `/data/.sui-download` | Release tarball during install | Deleted after install |
| `/data/init-completed`, `/data/snapshot_downloaded` | Sentinels | Persistent |

## Detailed design

### Version and release selection (R2; ADR-0005)
The configuration script parses `vX.Y.Z` from its own file name with an anchored regex. The release tag is
`${BC_NETWORK}-vX.Y.Z`. A missing release fails the install with a network-specific message. Versioned configuration
files are identical apart from their file name, which a test enforces.

### Upgrades and the never-downgrade safeguard (R2.7, R2.8; ADR-0022)
Single nodes upgrade in place: `scripts/upgrade-in-place.sh` (run by the operator) checks the instance is not in an
Auto Scaling group and is `single-node`, reads the network and release marker over SSM, checks the release and its
digests, then runs `install-sui-binaries.sh <version>` on the instance, restarts `node.service` and polls
`/health?threshold_seconds=120` (20 minutes). The installer's safeguard (`sui-version.sh`,
`sui_keep_newer_installed`) keeps an installed release for the same network that is newer than the requested one,
because the release marker lives on the root volume and survives a stop/start while `/etc/cdk_environment` is
rewritten from the stack's user data on every boot. `SUI_ALLOW_DOWNGRADE=true` (validated) or `--allow-downgrade`
overrides it; the flag is a CLI argument because the sourced environment file would overwrite an environment
variable. HA stacks upgrade with a rolling `cdk deploy`.

### Installation integrity (R4; ADR-0014)
GitHub release metadata gives the asset URL and its `digest`. The URL must start with the MystenLabs releases prefix,
and the digest must be 64 hex characters, or install fails. After download, `sha256sum` must match. Only `./sui-node` and
`./sui-tool` are extracted. Genesis is checked against per-network constants (allowlisted for detect-secrets with a
reason). A release marker skips re-download when the same asset is already installed.

### Bootstrap (R5; ADR-0006)
`sui-tool download-formal-snapshot --latest --network <net> --path /data/sui/db --num-parallel-downloads 50 --no-sign-request`
runs as `bcuser`. `sui-tool` writes to `<path>/staging` and renames to `<path>/live` only on success, which makes
`live/` a reliable idempotence guard. The restore is cryptographically verified (default `--verify normal`).
Formal snapshots carry no transaction history; with `rpc.enable-indexing` the node builds gRPC indexes on first start
*(duration to verify in test)*.

### Configuration generation (R6, R7; ADR-0009, ADR-0011, ADR-0012, ADR-0015)
`fullnode.yaml` keys were checked against `sui-config` v1.82.3 (kebab-case) and re-checked at v1.83.1 (2026-11-05: only
validator/consensus fields added, with defaults). Listeners: `json-rpc-address` (the
gRPC/REST/health listener despite its name) on the internal IP; `metrics-address` and the admin port on loopback;
`network-address` on loopback; `p2p-config.listen-address` on `0.0.0.0:8084`, with `external-address` set to the
public IPv4 when one exists. Seed peers are embedded from Sui's docs. Every `SUI_*` input is validated before the
heredoc is written, so `.env` values cannot inject YAML. The file is written to `.tmp` and renamed.

### Service (R8; ADR-0004)
`node.service`: `User=bcuser`, `EnvironmentFile=/etc/cdk_environment`, `Restart=always`, `RestartSec=30`,
`TimeoutStopSec=300`, `LimitNOFILE=1048576`, `NoNewPrivileges=true`, journal output. Further systemd sandboxing
(`ProtectSystem=strict`, `PrivateTmp`, ...) is deferred until write paths are confirmed in a live test.

### Monitoring and traffic shaping (R10, R11; ADR-0013)
`syncchecker.sh` parses Prometheus text with `awk`, tolerating labels and scientific notation (Ubuntu `mawk`
truncates large `%d` values). "Behind" means metrics missing, OR checkpoints behind > `TRAFFIC_SHAPING_MAX_BLOCKS_BEHIND`
(300 in samples), OR last executed checkpoint older than 120 s. Behind stops shaping; in sync starts it.
Once metrics are available, `c1_seconds_behind` is also published with dimension `StackName=$STACK_NAME` (the
CloudFormation stack name, from `/etc/cdk_environment`), so one alarm on its Maximum covers every node in the stack and
survives HA replacements (ADR-0023). The blueprint documents the alarm; it cannot create it (no CDK code, and the
instance role has no `cloudwatch:PutMetricAlarm`).

### HA (R12; ADR-0010)
The framework ALB health-checks `GET /health` on 9000. Per `sui-rpc-api` v1.82.3 source (unchanged in v1.83.1), `/health` fails until a
checkpoint has executed and, with indexing on, the live-object index is within 60 checkpoints of the executed tip.
The ALB target group is HTTP/1.1; `sui-node` serves gRPC-Web over HTTP/1.1 (`tonic_web::GrpcWebLayer`), so gRPC-Web works
through the ALB and native gRPC does not. Plain `/health` has no freshness check; `?threshold_seconds` is not used
because the framework's Auto Scaling group replaces ELB-unhealthy nodes, which would rebuild lagging nodes and replace
every node during a Sui network halt (ADR-0023). The HA samples run 3 nodes (ADR-0024).

### Storage (R3; ADR-0007, ADR-0008)
One instance-store volume at `/data`. On `.8xlarge` types the framework stripes both NVMe disks into one RAID 0 array.
Instance store is lost on stop/start, so a stopped node re-restores a snapshot *(restore time to verify in test)*.

## Failure modes

| Failure | Behaviour | Requirement |
|---|---|---|
| Release tag not found for network | Install exits non-zero; framework retries next boot | R2.4 |
| Missing or mismatched release digest | Download deleted; exit non-zero | R4.3 |
| Genesis mismatch (e.g. testnet re-genesis) | Genesis deleted; exit non-zero; pin must be updated | R4.5 |
| Invalid `SUI_*` value | Exit non-zero before writing config | R6.4 |
| No public IPv4 | Warning; P2P outbound-only | R6.5 |
| Snapshot endpoint unreachable | 3 attempts, then exit non-zero; no `live/` | R5.4 |
| `sui-node` crash | systemd restarts after 30 s | R8.2 |
| Node falls behind | Shaping lifted; `c1_blocks_behind` / `c1_seconds_behind` rise | R10, R11 |
| Instance stop/start | `/data` empty; full re-bootstrap on next boot | R3, R14.3 |

## Security design

- Private by default: RPC on the internal IP and VPC CIDR only; ALB internal; metrics and admin on loopback (R7).
- No secrets held or generated; no credentials in config; mainnet archive uses the instance role only (R6.7).
- Supply chain: digest-verified binaries, pinned genesis, verified snapshot, SHA-pinned CI actions (R4, R15.4).
- Least privilege: `bcuser`, `NoNewPrivileges`, minimal AWS API use (R8).
- Scanning gates and the no-upload-without-consent rule (R16).

## Testing strategy

| Level | What | Requirement |
|---|---|---|
| Static | ShellCheck; YAML generation with stubbed IMDS; metric-parser unit checks | R6, R10, R15.3 |
| Integration | 25 Jest tests against the real `ConfigurationLoader`; `cdk synth` of every sample (cdk-nag included) | R1, R3, R7, R12, R15 |
| Security | ASH (10 scanners), a second secrets/CVE/licence scanner, framework checklist; Inspector and CIS on the live node | R16 |
| Live | One-day testnet test, checks and measurements in `docs/testnet-test-report.md` | R18 |

## Cost model

Method, inputs and sources are in the README ("Network Traffic", "Monthly Cost Estimate") and ADR-0016 (R13).
Measured from chain data: checkpoint data rate, compression factors, transactions per
checkpoint. Measured in the testnet test (`docs/testnet-test-report.md`): CloudWatch metric count, log volume and
testnet P2P egress. Assumed: peer counts, request rates, point-read size.
