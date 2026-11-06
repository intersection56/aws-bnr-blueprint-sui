# ADR-0022: In-place upgrades for single nodes, rolling redeploys for HA, never-downgrade safeguard

- **Status:** Accepted (2026-11-05, decided by the Owner); live verification pending (release test)
- **Requirements:** R2 (2.7, 2.8)
- **Amends:** ADR-0005 (the installed version can differ from `CLIENT_CONFIG` after an in-place upgrade)

## Context
Sui ships testnet every Tuesday and mainnet every second Wednesday; releases with a protocol change must be applied
before activation, or the node cannot follow the chain (https://docs.sui.io/operators/full-node/updates). Mysten's
procedure is stop, replace the binary, restart: minutes.

This blueprint's upgrade path was `cdk deploy` with a new `CLIENT_CONFIG`. That changes the instance's user data, so
CloudFormation stops and starts a single-node instance, the instance store is wiped, and the node re-bootstraps: 3h43m
in the 2026-11-03 testnet test, longer on mainnet, twice a month on mainnet.

Options considered (details in the project notes): A in-place upgrade over SSM; B HA by default; C EBS instead of
instance store (~8% more on-demand with gp3, slower than NVMe); D NVMe mirrored to EBS (~$320/month extra, mdadm
layout the framework doesn't provide); E own snapshots in same-region S3 (unverified whether they include the gRPC
index).

The main risk of A: the stack still names the old version, and the framework rewrites `/etc/cdk_environment` from
user data on every boot. Any later setup re-run (stop/start, host maintenance or retirement) would reinstall the older
version, which may not follow the chain after a protocol upgrade.

## Decision
1. **Single node: in place over SSM** with `scripts/upgrade-in-place.sh`: refuses HA instances and downgrades, checks
   the release and its SHA-256 digests, runs the blueprint's own installer on the instance, restarts `node.service`,
   waits for `/health?threshold_seconds=120`. Then bring the stack in line (`scripts/bump.sh` + `cdk deploy`) at a
   planned window.
2. **Never-downgrade safeguard** in `install-sui-binaries.sh`: if the installed release (from the release marker on
   the root volume) is for the same network and newer than the requested version, keep it and log a warning.
   `SUI_ALLOW_DOWNGRADE="true"` (validated `true`/`false`) or the installer's `--allow-downgrade` flag rolls back on
   purpose. Logic in `user-data/common/sui-version.sh`, tested by running it.
3. **HA: rolling redeploy** (`scripts/bump.sh` + `cdk deploy`). Not in place: the Auto Scaling group launches
   replacements from the stack's launch template.

## Alternatives considered
- **Emergency-only in-place procedure without the safeguard:** leaves the silent-downgrade risk.
- **Options B-E** above: B is adopted for production separately (ADR-0024) but does not help single nodes; C, D, E
  have cost, performance or verification gaps.

## Consequences
- Single-node upgrades take minutes instead of hours; database, indexes and history are kept.
- The installed version can be newer than `CLIENT_CONFIG` until the stack is redeployed; the installer logs this on
  every re-run. A redeploy still stops and starts the instance (hours on instance store); schedule it.
- In-place upgrades replace binaries only. Releases that need `fullnode.yaml` or blueprint changes need a redeploy.
- Operators need `ssm:SendCommand`, `ssm:GetCommandInvocation` and `ec2:DescribeInstances`.
- Verified locally (2026-11-05): the safeguard decision in 8 cases (Jest), the upgrade script against a stubbed AWS
  CLI (all refusal paths, dry run, confirmation, full run, rollback flag; the remote scripts are valid POSIX sh).
  **Not yet verified live:** in-place upgrade on a real node, then a stop/start keeping the newer version.
