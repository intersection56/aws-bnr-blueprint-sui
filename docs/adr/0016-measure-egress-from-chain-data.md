# ADR-0016: Measure egress from chain data for the cost model

- **Status:** Accepted by owner (recorded retroactively 2026-11-02)
- **Deciders:** build agent, after Owner pushback on the first estimate
- **Requirements:** R13

## Context
The first estimate (~1.2 TB, ~$100/month) used Sui's Nov 2025 archive growth figure and an assumed wire factor. The
Owner flagged that egress should be expensive. No operator, cloud provider or Sui itself publishes full-node egress figures.

## Decision
Measure the per-unit traffic from real chain data, and keep only counts as assumptions:
- Checkpoint rate from the public archive's `epochs.json`; sizes from the bucket listing (16,800 mainnet / 12,000 testnet samples over the last 28 / 20 epochs).
- Uncompressed and Snappy sizes from 280 decompressed checkpoints (state sync uses BCS + Snappy per `sui-network` source; protobuf used as a stand-in for BCS).
- Price with the AWS Price List API, us-east-1, retrieved 2026-11-02.

## Alternatives considered
- **Vendor or third-party figures:** none exist beyond a "1 Gbps" requirement.
- **Wait for the live test:** gives one node's numbers, not a model; the test will calibrate the model instead.

## Consequences
- Mainnet chain data measured at ~25.8 GB/day (2.6-8x Sui's Nov 2025 figure); per peer ~1.26 TB/month.
- Typical single node ~$1,410/month; busy node's egress $557 (same AZ) to $2,794 (internet + WAF).
- Peer counts and request rates remain assumptions until measured; the measurements are a point-in-time snapshot.
- **Updated 2026-11-03/05:** the model was calibrated with the testnet measurements (steady `NetworkOut` ~0.75 TB/month,
  3.8x the 2-peer model; 197 CloudWatch metrics; ~0.53 GB/day logs). Current README totals: single node ~$1,605/month,
  HA 2 nodes ~$3,239, HA 3 nodes ~$4,830 (us-east-1 on-demand, prices as of 2026-11-02). The figures above are the
  pre-test estimate, kept for history. Mainnet egress is still a calibration, to be measured in the release test.
