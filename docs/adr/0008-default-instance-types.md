# ADR-0008: Default instance types i7i.4xlarge and i8g.4xlarge

- **Status:** Accepted by owner
- **Date:** 2026-11-05
- **Deciders:** build agent
- **Requirements:** R3.2

## Context
Sui's suggested full-node minimum is 8 physical cores (16 vCPU), 128 GB RAM and a 4 TB NVMe SSD. The instance must also
provide the instance-store volume chosen in ADR-0007.

## Decision
Defaults: `i7i.4xlarge` (x86_64) and `i8g.4xlarge` (ARM_64, Graviton4). Both have 16 vCPU, 128 GiB and 1 x 3,750 GB NVMe.
The same type is used for testnet.

## Alternatives considered
- **Smaller types for testnet** (`i7i.2xlarge` at ~$0.92/h, `i7i.xlarge` at ~$0.54/h): testnet carries ~6x less data
  (4.1 vs 25.8 GB/day measured), but these sizes are untested with Sui.
- **`i4i`/`i3en` older generations:** lower price-performance.

## Consequences
- ~$1,102/month (x86) and ~$1,002/month (ARM), us-east-1 on-demand as of 2026-11-02; Graviton ~9% cheaper, the same
  ratio the Avalanche blueprint reports.
- Testnet may be over-provisioned; revisit with test measurements.
- New accounts may need a vCPU quota increase.
