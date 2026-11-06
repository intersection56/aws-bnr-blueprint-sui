# ADR-0007: NVMe instance store for /data

- **Status:** Accepted by owner
- **Date:** 2026-11-05
- **Deciders:** build agent
- **Requirements:** R3, R14.3

## Context
Sui produces about 4.26 checkpoints per second (measured 2026-11-02) and is RocksDB/IO heavy. The framework workflow
recommends io2 or instance store for block times under 10 s. Sui reports a pruned full node with indexes at ~2.5 TB
(Nov 2025).

## Decision
Use one NVMe instance-store volume (3,750 GB) at `/data`, ext4. Document `.8xlarge` (2 x 3,750 GB, RAID 0 by the
framework) as the growth path, and EBS as the persistent alternative.

## Alternatives considered
- **gp3 4,000 GB, 16,000 IOPS, 1,000 MiB/s on `r7i.4xlarge`:** ~$1,193/month on-demand vs ~$1,102 for `i7i.4xlarge`; ~$770 vs ~$510 on a 3-yr EC2 Instance Savings Plan (EBS is never discounted).
- **io2 4,000 GB, 16,000 IOPS:** ~$2,313/month on-demand.
- (All us-east-1, prices as of 2026-11-02.)

## Consequences
- Cheapest option at every term, and the fastest storage.
- **Data is lost on stop/start**, including a single-node redeploy; the node re-restores a snapshot automatically
  (measured 3h43m deploy-to-healthy on testnet, 2026-11-03).
- ~1.25 TB headroom at ~2.5 TB usage; the 12-month fit depends on an unpublished growth rate.

## Update 2026-11-05
- **Recovery time answered by the Owner:** hours after a stop/start are accepted. Upgrades avoid the stop/start with
  in-place upgrades and the never-downgrade safeguard (ADR-0022); production uses 3-node HA (ADR-0024).
- **Re-evaluated and kept.** Alternatives considered again for the upgrade-downtime problem: EBS gp3 (data survives
  stop/start; ~8% more on-demand; slower than NVMe; Sui asks for NVMe); local NVMe mirrored to a write-mostly EBS gp3
  volume (survives stop/start; ~4 TB gp3 extra, roughly $320/month; an mdadm layout the framework doesn't provide).
  Instance store stays the default.
- Community practice matches: performance-heavy chains use local NVMe and plan for data loss with redundancy and fast
  re-bootstrap rather than network disks (Tempo requires local NVMe; Solana operators prefer bare metal NVMe).
