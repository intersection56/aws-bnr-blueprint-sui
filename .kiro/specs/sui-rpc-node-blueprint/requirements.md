# Requirements Document

## Introduction

This document specifies `aws-bnr-blueprint-sui`, a community blueprint for the AWS Blockchain Node Runners framework
(v2, "Path B" external npm package). It deploys a **non-validator Sui full node** that serves RPC (gRPC, gRPC-Web and
`GET /health`) on Sui **mainnet** and **testnet**, in the framework's single-node and HA deployment modes.

**Provenance (read this first).** These requirements were written **retroactively on 2026-11-02**, after the first build,
at the owner's request to put the project under a spec-driven process before testing. They describe the intended
behaviour of the existing implementation, add requirements that the build exposed as missing (cost, licensing, scans),
and mark what is not yet verified. The first real verification is the one-day testnet test (`docs/testnet-test-report.md`).
Decisions behind these requirements are recorded as ADRs in `docs/adr/`. Status per requirement is in
[`traceability.md`](./traceability.md).

**Out of scope:** Sui validators, devnet, archive (unpruned) nodes, GraphQL / indexer stacks, JSON-RPC (removed from
`sui-node` by Sui), and changes to the Node Runners framework itself.

## Glossary

- **Blueprint**: this npm package, `aws-bnr-blueprint-sui`, installed into a Node Runners checkout's `node_modules/`.
- **Framework**: AWS Blockchain Node Runners v2 (`aws-samples/aws-blockchain-node-runners`), which provides the CDK app, `ConfigurationLoader`, storage setup, CloudWatch agent, traffic shaping and the `syncchecker.timer`.
- **Node**: one EC2 instance running `sui-node` as the systemd service `node`.
- **CLIENT_CONFIG**: the configuration script name, `sui-node-vX.Y.Z-full.sh`; its version is the single source of truth.
- **Release_Tag**: the MystenLabs GitHub release `${BC_NETWORK}-vX.Y.Z` (Sui publishes separate releases per network).
- **Formal_Snapshot**: Sui's verifiable end-of-epoch live-object snapshot, restored with `sui-tool download-formal-snapshot`.
- **Internal_IP**: the instance's private IPv4 from IMDSv2.
- **Checkpoint**: Sui's unit of certified chain progress (the "block" equivalent for the framework's `c1_*` metrics).
- **Re-run_Contract**: the framework rule that `node.sh` runs on first boot and again on every configuration-changing redeploy, against existing data, with `node.service` stopped.
- **Owner**: the person publishing and maintaining the blueprint.

## Requirements

### Requirement 1: Framework package conformance

**User Story:** As a Node Runners user, I want to install the Sui blueprint like any other blueprint, so that I can deploy it with the standard framework workflow.

#### Acceptance Criteria

1. THE Blueprint SHALL be an npm package named `aws-bnr-blueprint-sui` with a `peerDependencies` entry `aws-blockchain-node-runners: >=2.0.0` and an `"aws-blockchain-node-runner"` field.
2. THE `"aws-blockchain-node-runner"` field SHALL declare `BLOCKCHAIN_PROTOCOL: "sui"`, `BC_NETWORKS`, `supportedDeploymentModes`, `defaultConfiguration`, `availableConfigurations`, `defaultInstanceTypes`, `requiredPorts`, `monitoring`, `storage` and `customEnvVarsNamePrefix: "SUI"`.
3. WHEN the Blueprint is installed with `npm install <source> --legacy-peer-deps` THEN THE Framework's `ConfigurationLoader` SHALL load it and validate every sample `.env` without errors other than the account ID placeholder.
4. THE Blueprint SHALL follow the framework naming conventions: configuration scripts `{client}-{version}-{type}.sh`, samples `.env-{network}-{client}-{type}[-ha|-arm64]`, service name `node`, user `bcuser`.
5. THE npm package `files` list SHALL include only `configurations/`, `samples/`, `user-data/`, `README.md` and `LICENSE`.

### Requirement 2: Supported networks and client versions

**User Story:** As an operator, I want to choose mainnet or testnet with a pinned `sui-node` version, so that deployments are reproducible.

#### Acceptance Criteria

1. THE Blueprint SHALL support `BC_NETWORK` values `mainnet` and `testnet` only.
2. WHEN `BC_NETWORK` is any other value THEN THE install phase SHALL exit non-zero before downloading anything.
3. THE version installed SHALL be derived only from the `CLIENT_CONFIG` file name (`sui-node-(vX.Y.Z)-full.sh`), except that criterion 7 MAY keep a newer installed release.
4. WHEN the Release_Tag `${BC_NETWORK}-vX.Y.Z` does not exist THEN THE install phase SHALL exit non-zero with a message naming the network and version.
5. THE Blueprint SHALL ship exactly the configurations its samples use, at least one per supported network (currently `v1.83.1` for both mainnet and testnet), and every versioned configuration script SHALL be identical apart from its file name.
6. THE Blueprint SHALL check daily whether each network's pinned release is behind the latest MystenLabs release for that network, and SHALL open an issue when it is (ADR-0021).
7. WHEN setup re-runs and a release newer than the requested version is already installed for the same network THEN THE install phase SHALL keep the installed release and log a warning, unless `SUI_ALLOW_DOWNGRADE` is `true` or `--allow-downgrade` is passed; `SUI_ALLOW_DOWNGRADE` SHALL be validated as `true` or `false` (ADR-0022).
8. THE Blueprint SHALL provide an in-place upgrade tool for single-node stacks that refuses HA instances and downgrades by default, verifies the release and its SHA-256 digests, uses the blueprint's own installer, and waits for the node to report healthy and in sync (ADR-0022).

### Requirement 3: Deployment modes and hardware

**User Story:** As an operator, I want single-node and HA deployments on hardware that meets Sui's full-node minimum, so that the node keeps up with the chain.

#### Acceptance Criteria

1. THE Blueprint SHALL support `single-node` and `ha-nodes` deployment modes.
2. THE default instance types SHALL meet Sui's suggested full-node minimum of 16 vCPU and 128 GB RAM (`i7i.4xlarge` for x86_64, `i8g.4xlarge` for ARM_64).
3. THE `/data` volume SHALL be NVMe instance store, at least 3,500 GiB, ext4.
4. WHERE more disk is needed THE Blueprint SHALL support larger instance-store types (e.g. `i7i.8xlarge`) through `INSTANCE_TYPE` alone, using the framework's RAID 0 assembly.
5. THE Blueprint SHALL ship samples for mainnet x86_64, mainnet ARM_64, mainnet HA and testnet x86_64.

### Requirement 4: Client installation integrity

**User Story:** As an operator, I want the node software verified before it runs, so that a tampered or corrupted download cannot be executed.

#### Acceptance Criteria

1. THE install phase SHALL download the release asset only from `https://github.com/MystenLabs/sui/releases/download/` for the CPU architecture (`ubuntu-x86_64` or `ubuntu-aarch64`).
2. THE install phase SHALL verify the asset's SHA-256 against the digest published in the GitHub release metadata.
3. IF the digest is missing, malformed or does not match THEN THE install phase SHALL delete the download and exit non-zero.
4. THE install phase SHALL install only `sui-node` and `sui-tool`, owned by `bcuser`, mode 0755.
5. THE install phase SHALL verify `genesis.blob` against a SHA-256 pinned per network in the Blueprint, and IF it does not match THEN SHALL delete it and exit non-zero.
6. THE install phase SHALL NOT execute any downloaded script.

### Requirement 5: Bootstrap from a verified snapshot

**User Story:** As an operator, I want a new node to start from recent verified state, so that it does not need weeks to sync from genesis.

#### Acceptance Criteria

1. WHEN `SNAPSHOT_ENABLED` is `true` AND no database exists at `/data/sui/db/live` THEN THE install phase SHALL restore the latest Formal_Snapshot for the network with `sui-tool download-formal-snapshot --no-sign-request`, running as `bcuser`.
2. THE restore SHALL use `sui-tool`'s default `normal` verification against the committee commitment.
3. WHEN a database already exists at `/data/sui/db/live` THEN THE install phase SHALL skip the restore.
4. IF the restore fails after 3 attempts THEN THE install phase SHALL exit non-zero, leaving no `live/` directory.
5. WHEN `SNAPSHOT_ENABLED` is not `true` AND no database exists THEN THE install phase SHALL log a warning that the node will sync from genesis.
6. THE `sui-tool` retry count and parallel downloads SHALL be configurable through `SUI_SNAPSHOT_MAX_RETRIES` and `SUI_SNAPSHOT_PARALLEL_DOWNLOADS`, default to 50 retries (raised from `sui-tool`'s own 10 on 2026-11-06 after issue 4; ADR-0025) and 50 parallel downloads, and be validated (retries 0-1000; parallel downloads 1-200) before use. *(Added 2026-11-03 after issue 1.)*

### Requirement 6: Node configuration

**User Story:** As an operator, I want `fullnode.yaml` generated correctly for the network, so that the node peers, prunes and indexes as an RPC node should.

#### Acceptance Criteria

1. THE install phase SHALL write `/home/bcuser/sui-config/fullnode.yaml` on every run, atomically.
2. THE configuration SHALL include the documented Sui seed peers for the selected network.
3. THE configuration SHALL set `rpc.enable-indexing` from `SUI_ENABLE_INDEXING` (default `true`), `num-epochs-to-retain` from `SUI_NUM_EPOCHS_TO_RETAIN` (default 5) and `num-epochs-to-retain-for-checkpoints` from `SUI_NUM_EPOCHS_TO_RETAIN_FOR_CHECKPOINTS` (default 2).
4. IF any `SUI_*` value is not of its expected form (integer, `true`/`false`, `auto`/`true`/`false`) OR the checkpoint retention is below 2 THEN THE install phase SHALL exit non-zero without writing the file.
5. WHEN the instance has a public IPv4 THEN THE configuration SHALL advertise it as the P2P `external-address`; otherwise it SHALL omit it and log a warning.
6. WHEN `SUI_ARCHIVE_FALLBACK` is `auto` THEN THE configuration SHALL enable archival fallback for testnet (public HTTPS endpoint) and disable it for mainnet; WHEN it is `true` on mainnet THEN it SHALL use the Requester Pays S3 archive with instance-role credentials only.
7. THE configuration SHALL contain no credentials.

### Requirement 7: Network exposure

**User Story:** As a security owner, I want only the ports Sui needs to be reachable, and the RPC to be private by default, so that the unauthenticated APIs are not exposed to the internet.

#### Acceptance Criteria

1. THE RPC listener (gRPC, gRPC-Web, `/health`) SHALL bind to `Internal_IP:9000`, never `0.0.0.0`.
2. THE security group SHALL allow 9000/tcp only from the VPC CIDR (`requiredPorts` `public: false`).
3. THE P2P listener SHALL bind to `0.0.0.0:8084/udp` and SHALL be the only port open to `0.0.0.0/0`.
4. THE Prometheus metrics endpoint SHALL bind to `127.0.0.1:9184` and the admin API to `127.0.0.1:1337`; neither SHALL appear in `requiredPorts`.
5. THE validator `network-address` SHALL bind to `127.0.0.1`.
6. IN HA mode THE load balancer SHALL be internal by default.

### Requirement 8: Process and privilege

**User Story:** As a security owner, I want the node to run with least privilege, so that a compromise of `sui-node` has limited impact.

#### Acceptance Criteria

1. THE node SHALL run as the systemd service `node`, with `User=bcuser`, `Group=bcuser` and `EnvironmentFile=/etc/cdk_environment`.
2. THE service SHALL set `NoNewPrivileges=true`, `Restart=always`, `LimitNOFILE=1048576` and a stop timeout of at least 300 s.
3. THE runtime phase SHALL NOT read `/etc/cdk_environment` directly (it is root-only); it SHALL rely on systemd's `EnvironmentFile`.
4. THE Blueprint's AWS API use SHALL be limited to `cloudwatch put-metric-data` and IMDSv2 metadata reads.
5. THE service SHALL start only after `/data` is mounted and SHALL NOT start when `/data` is not a mounted filesystem (`RequiresMountsFor=/data`, `ConditionPathIsMountPoint=/data`); on a plain reboot it SHALL start without manual intervention. *(Added 2026-11-03 after issue 2; revised the same day.)*

### Requirement 9: Re-run safety

**User Story:** As an operator, I want redeploys to apply configuration changes without losing chain data, so that upgrades are routine.

#### Acceptance Criteria

1. WHEN `node.sh` runs again on an instance with existing data THEN THE Blueprint SHALL replace binaries and configuration to match the current `CLIENT_CONFIG`, skip the snapshot restore, and restart `node.service`.
2. THE Blueprint SHALL NOT delete, move or reformat chain data; `rm -rf` SHALL be used only on the temporary download directory.
3. IF setup fails THEN `node.sh` SHALL exit non-zero, so the framework retries on the next boot.
4. WHEN setup completes and `node.service` is active THEN `node.sh` SHALL create `/data/init-completed`.

### Requirement 10: Monitoring

**User Story:** As an operator, I want sync health in CloudWatch, so that I can see whether the node is keeping up.

#### Acceptance Criteria

1. WHILE `/data/init-completed` exists THE sync checker SHALL publish `c1_block_height` (last executed checkpoint) and `c1_blocks_behind` (highest known minus last executed checkpoint) to namespace `CWAgent` with dimension `InstanceId`, once per `TRAFFIC_SHAPING_CHECK_INTERVAL_SEC`.
2. THE sync checker SHALL also publish `c1_seconds_behind` (age of the last executed checkpoint).
3. THE sync checker SHALL read metrics only from `127.0.0.1:9184`.
4. IF metrics are unavailable THEN THE sync checker SHALL publish zeros and treat the node as not in sync.
5. WHILE metrics are available THE sync checker SHALL also publish `c1_seconds_behind` with dimension `StackName`, so one alarm per stack covers every node; THE README SHALL document that alarm (ADR-0023).

### Requirement 11: Traffic shaping

**User Story:** As an operator, I want outbound P2P bandwidth capped once the node is in sync, so that data transfer costs are bounded.

#### Acceptance Criteria

1. WHERE `TRAFFIC_SHAPING_ENABLED` is `true` AND the node is in sync THE sync checker SHALL start `net-rules.service`.
2. WHEN the node is more than `TRAFFIC_SHAPING_MAX_BLOCKS_BEHIND` checkpoints behind, OR the last executed checkpoint is older than 120 s, OR metrics are unavailable THEN THE sync checker SHALL stop `net-rules.service`.
3. THE README SHALL state that, at the measured Sui traffic levels, the default 40 Mbit/s limit caps the worst case but does not reduce typical egress.
4. WHILE `/data/init-completed` does not exist THE Blueprint SHALL keep `net-rules.service` stopped: `node.sh` SHALL stop it before the install phase and the sync checker SHALL stop it if it is running. *(Added 2026-11-03 after issue 1: the framework starts shaping during setup, and two restore attempts timed out with it on.)*
5. WHEN `TRAFFIC_SHAPING_ENABLED` is not `true` THEN THE sync checker SHALL stop `net-rules.service` if it is running, because the framework starts it regardless of the setting. *(Added 2026-11-03.)*

### Requirement 12: HA health checking

**User Story:** As an operator of an HA deployment, I want the load balancer to send traffic only to synced, indexed nodes.

#### Acceptance Criteria

1. THE HA sample SHALL health-check `GET /health` on port 9000 and accept only HTTP 200.
2. THE HA sample SHALL use a health-check grace period long enough for binary download, snapshot restore and index build on mainnet, so the Auto Scaling group does not replace nodes that are still bootstrapping (currently 1,440 minutes; testnet deploy-to-healthy measured at 3h43m on 2026-11-03, mainnet not measured). *(Revised 2026-11-03 from 240 minutes.)*
3. THE README SHALL explain that unhealthy nodes are replaced after the grace period, and document suspending `ReplaceUnhealthy` as an alternative.
4. THE README SHALL state that the framework's HTTP/1.1 load balancer supports gRPC-Web clients but not native gRPC.
5. THE HA samples SHALL use plain `/health` (no `threshold_seconds`) while the framework's Auto Scaling group replaces nodes the load balancer marks unhealthy, and THE README SHALL explain why and what HA does and does not protect against (ADR-0023).
6. THE HA samples SHALL run 3 nodes, the recommended production setup (ADR-0024).

### Requirement 13: Cost documentation

**User Story:** As a prospective operator, I want a realistic monthly cost with its method and sources, so that I can budget before deploying.

#### Acceptance Criteria

1. THE README SHALL provide the framework workflow's full cost request: instance recommendation, storage type and size with a 12-month projection, monthly outbound P2P traffic in TB, a traffic-shaping assessment, and a monthly estimate covering compute, storage, data transfer (with and without shaping) and CloudWatch.
2. EVERY AWS price SHALL be labelled with its source, region and retrieval date as point-in-time.
3. THE README SHALL explain how traffic figures were calculated, which inputs were measured and which were assumed, and list the information sources.
4. THE README SHALL include the busy-RPC and client-placement scenarios (same AZ, cross-AZ, internet via ALB + WAF).
5. THE README SHALL compare instance store with EBS under on-demand and Savings Plans pricing.

### Requirement 14: User documentation

**User Story:** As a user, I want a README that follows the framework template, so that I can deploy, verify, troubleshoot and upgrade the node.

#### Acceptance Criteria

1. THE README SHALL contain the sections required by the framework workflow (architecture, configurations, infrastructure, setup steps 1-5, configuration options, troubleshooting, upgrades, cost optimization, security considerations, FAQ, resources, support).
2. THE README SHALL state that the node is not a validator and does not serve JSON-RPC.
3. THE README SHALL document the instance-store trade-off (data lost on stop/start, automatic snapshot restore).
4. THE README SHALL state the intended use (an RPC node for applications running in AWS) and point to alternatives for other cases (ADR-0024).

### Requirement 15: Verification and CI

**User Story:** As the Owner, I want automated checks, so that changes cannot silently break the blueprint.

#### Acceptance Criteria

1. THE Blueprint SHALL include integration tests that run against the Framework's real `ConfigurationLoader` and cover protocol config, ports, health path, every sample, required files, configuration-script parity, RPC/metrics binds and the service definition.
2. `scripts/validate.sh` SHALL install the Blueprint into a clean Framework checkout, run the tests, and `cdk synth` every sample without AWS credentials.
3. ALL shell scripts SHALL pass `shellcheck -S warning`.
4. THE CI workflow SHALL pin third-party and first-party GitHub Actions to full commit SHAs and declare least-privilege `permissions`.

### Requirement 16: Security scanning

**User Story:** As a security owner, I want the blueprint scanned at the right points, so that issues are found before deploying and before publishing.

#### Acceptance Criteria

1. BEFORE the first deploy THE Owner SHALL run ASH and a secrets scan with no unresolved findings.
2. BEFORE publishing THE Owner SHALL re-run ASH and a secrets scan (including git history), run a threat model, and resolve or record every finding.
3. DURING the first live test THE Owner SHALL scan the running instance (Amazon Inspector, CIS Ubuntu benchmark).
4. NO tool SHALL upload project files to an external or AI service without the Owner's explicit consent.
5. Suppressions of false positives SHALL be inline and carry a reason.

### Requirement 17: Licensing

**User Story:** As the Owner, I want a single, deliberate licence, so that users and reviewers know their rights.

#### Acceptance Criteria

1. THE `LICENSE` file, the `package.json` `license` field and every source-file header SHALL name the same licence and the correct copyright holder.
2. WHERE the chosen licence or the ecosystem convention requires per-file headers THE source files SHALL carry them (Apache-2.0: an SPDX identifier, per the community blueprints; ADR-0018).

### Requirement 18: Operational verification

**User Story:** As the Owner, I want evidence from a real deployment, so that the blueprint is known to work and the cost model uses measured values.

#### Acceptance Criteria

1. BEFORE publishing THE Owner SHALL deploy the testnet sample for at least one day and record the results in `docs/testnet-test-report.md`.
2. THE test SHALL show: setup completes, `node.service` stays active with no restart loop, checkpoints advance, `/health` returns 200, RPC is not reachable from the internet, and `c1_*` metrics appear in CloudWatch.
3. THE test SHALL measure snapshot restore time, index build time, `/data` usage, `NetworkOut`, peer count, CloudWatch metric count and log volume, and these SHALL replace the corresponding assumptions in the README.
4. BEFORE publishing THE final release test SHALL cover, on the published version: a fresh single-node deploy with a live stop/start and a plain reboot; an in-place upgrade followed by a stop/start that keeps the newer release; a 3-node HA deployment on testnet including loss of one node; and the lag alarm. Mainnet is not deployed before publishing (Owner decision 2026-11-05), so THE README SHALL state that mainnet bootstrap time, disk use and egress are modelled, not measured.

## Open questions for the Owner

Answered 2026-11-05 (decisions by the Owner unless marked; reasoning in ADRs 0013, 0018, 0022-0024):

1. **Availability target / HA size:** no numeric availability target is promised. Production uses **HA with 3 nodes**;
   a single node is for development, testing or non-critical use (ADR-0024).
2. **Single-node recovery time:** accepted as hours after a stop/start (instance store; measured 3h43m on testnet).
   Upgrades avoid it with in-place upgrades over SSM (minutes) and the never-downgrade safeguard (ADR-0022).
3. **Monthly cost ceiling:** **not applicable** (Owner decision 2026-11-09): the blueprint sets no cost ceiling; the
   README documents costs instead (single node ~$1,605, 3-node HA ~$4,830 on-demand, ~$3,050 with a 3-year EC2
   Instance Savings Plan, us-east-1, prices as of 2026-11-02).
4. **Upgrade cadence** (from Mysten Labs, https://docs.sui.io/operators/full-node/updates): apply every release for
   the network (testnet every Tuesday, mainnet every second Wednesday); releases with a protocol change must be
   installed before activation. The release watch runs daily.
5. **Licence and copyright holder:** Apache-2.0, aligned with the community blueprints; copyright holder confirmed by
   the Owner under Amazon's open-source process (ADR-0018).
6. **Publishing target:** public GitHub repository `intersection56/aws-bnr-blueprint-sui` (install with
   `npm install github:intersection56/aws-bnr-blueprint-sui --legacy-peer-deps`). Catalog submission: **confirmed**
   by the Owner (2026-11-09).
7. **Supported regions:** us-east-1 tested; North American regions recommended by default, because Mysten Labs' free
   formal-snapshot bucket is in North America only (agent recommendation from Mysten's docs).
8. **Release test scope** (added): testnet only, single node and 3-node HA (scenario A). Mainnet is not tested before publishing (Owner decision 2026-11-05).
