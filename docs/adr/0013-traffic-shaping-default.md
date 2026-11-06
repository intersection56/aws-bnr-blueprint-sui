# ADR-0013: Traffic shaping enabled at 40 Mbit/s

- **Status:** Accepted (recorded retroactively 2026-11-02; reviewed by the Owner 2026-11-05: keep 40 Mbit/s as a worst-case cap)
- **Deciders:** build agent; accepted by the Owner
- **Requirements:** R11

## Context
The framework recommends traffic shaping for block times under 10 s and describes savings of "up to ~85%" (Solana
egress is 100-200 TiB/month unshaped). The samples enabled it at the framework default of 40 Mbit/s. Later measurement
(ADR-0016) showed Sui P2P egress is much lower: ~3.8 Mbit/s per syncing peer, ~38 Mbit/s even with 10 peers.

## Decision
Keep shaping enabled at 40 Mbit/s, with a Sui-specific sync checker: shaping off when metrics are missing, more than 300
checkpoints behind, or more than 120 s stale.

## Alternatives considered
- **10-20 Mbit/s default:** would cut busy-node P2P egress (6.57 / 3.29 TB caps) but serve syncing peers more slowly.
- **Disabled by default:** no worst-case cap.

## Consequences
- At 40 Mbit/s shaping reduces none of the modelled scenarios; it only caps the worst case at ~13.1 TB/month (~$1,160).
- Shaping never applies to RPC through the ALB (the node talks to private ALB addresses).
- **Revisit** with the measured `NetworkOut` from the test; consider lowering the default.
- **Amended by ADR-0019** (2026-11-03): shaping is kept off during bootstrap and when disabled, after the live test found it active during the snapshot restore.
- **Reviewed 2026-11-05:** the measured testnet egress (~2.3 Mbit/s) and the mainnet calibration (~15 Mbit/s per node) both stay under 40 Mbit/s, so shaping still reduces no modelled scenario. The Owner chose to keep 40 Mbit/s as a worst-case cap rather than lower it, so syncing peers are not slowed.
