# Architecture Decision Records

Format: a lightweight Nygard/MADR style (context, decision, alternatives, consequences). One decision per file.
New decisions get the next number; superseded ADRs are kept and marked `Superseded by ADR-NNNN`.

**Provenance:** ADR-0002 to ADR-0017 record decisions made during the first build on 2026-11-02, before this process
existed. They were written retroactively, with the build agent as "Deciders", and were reviewed and accepted by the
Owner on 2026-11-05. Later changes get a new ADR or a dated update note; superseded ADRs are kept and marked
`Superseded by ADR-NNNN`. Requirements references (R*n*) point to `.kiro/specs/sui-rpc-node-blueprint/requirements.md`.

**Review status (2026-11-05):** all ADRs (0002-0024) have been reviewed and accepted by the Owner. ADRs 0003, 0005,
0006, 0007, 0010, 0011, 0014, 0015 and 0016 carry dated `Update 2026-11-05` notes, accepted together with the original
decision. Live verification is still pending for parts of 0020, 0022, 0023 and 0024 (release test); that does not
change their acceptance.

| ADR | Title | Status |
|---|---|---|
| [0001](0001-record-architecture-decisions.md) | Record architecture decisions | Accepted by owner |
| [0002](0002-non-validator-rpc-full-node.md) | Deploy a non-validator RPC full node | Accepted |
| [0003](0003-community-npm-package.md) | Distribute as a community npm package | Accepted |
| [0004](0004-release-binary-not-docker.md) | Install the official release binary, not Docker | Accepted |
| [0005](0005-version-in-filename-per-network-tags.md) | Version in the configuration file name; per-network release tags | Accepted by owner |
| [0006](0006-formal-snapshot-bootstrap.md) | Bootstrap from a formal snapshot with sui-tool | Accepted by owner |
| [0007](0007-instance-store-for-data.md) | NVMe instance store for /data | Accepted by owner |
| [0008](0008-default-instance-types.md) | Default instance types i7i.4xlarge and i8g.4xlarge | Accepted by owner |
| [0009](0009-private-rpc-loopback-admin.md) | RPC private to the VPC; metrics and admin on loopback | Accepted by owner |
| [0010](0010-health-endpoint-and-grpc-web-ha.md) | sui-node /health for HA; gRPC-Web only through the ALB | Accepted by owner |
| [0011](0011-rpc-pruning-and-indexing-profile.md) | RPC pruning and indexing profile | Accepted by owner |
| [0012](0012-archive-fallback-policy.md) | Archive fallback on for testnet, opt-in for mainnet | Accepted by owner |
| [0013](0013-traffic-shaping-default.md) | Traffic shaping enabled at 40 Mbit/s | Accepted (recorded retroactively 2026-11-02; reviewed by the Owner 2026-11-05: keep 40 Mbit/s as a worst-case cap) |
| [0014](0014-supply-chain-verification.md) | Verify release digest and pin genesis, fail closed | Accepted by owner (recorded retroactively 2026-11-02) |
| [0015](0015-validate-env-input.md) | Validate .env input before writing config | Accepted by owner |
| [0016](0016-measure-egress-from-chain-data.md) | Measure egress from chain data for the cost model | Accepted by owner (recorded retroactively 2026-11-02) |
| [0017](0017-pin-ci-actions-to-sha.md) | Pin GitHub Actions to commit SHAs | Accepted by owner (recorded retroactively 2026-11-02) |
| [0018](0018-licence.md) | Licence and copyright holder | Accepted by owner (2026-11-05). Publishing precondition met: the Owner confirmed the copyright holder under Amazon's open-source process (2026-11-05) |
| [0019](0019-shaping-off-during-bootstrap.md) | Keep traffic shaping off during bootstrap and when disabled | Accepted by owner 2026-11-03; verified live in the redeploy test 2026-11-03 |
| [0020](0020-node-service-requires-data-mount.md) | Start node.service only when /data is mounted | Accepted by owner 2026-11-03 (revised the same day). Plain reboot verified live 2026-11-03; stop/start path pending (final release test) |
| [0021](0021-release-watch-and-version-bumps.md) | Daily release watch and scripted version bumps | Accepted by owner (2026-11-05; proposed by the agent) |
| [0022](0022-upgrade-strategy.md) | In-place upgrades for single nodes, rolling redeploys for HA, never-downgrade safeguard | Accepted (2026-11-05, decided by the Owner); live verification pending (release test) |
| [0023](0023-health-check-and-lag-alarm.md) | Plain /health for the load balancer; stack-level lag alarm | Accepted by owner (2026-11-05, decided by the Owner); live verification pending (release test) |
| [0024](0024-target-use-and-ha-sizing.md) | Intended use (applications in AWS) and 3-node HA for production | Accepted by owner (2026-11-05, decided by the Owner); HA live verification pending (release test) |
