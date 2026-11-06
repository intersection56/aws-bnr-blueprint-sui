# ADR-0024: Intended use (applications in AWS) and 3-node HA for production

- **Status:** Accepted by owner (2026-11-05, decided by the Owner); HA live verification pending (release test)
- **Requirements:** R12 (12.6), R14 (14.4)

## Context
Two questions were open: who the RPC node is for, and how many HA nodes production needs.

**Cost** (us-east-1, on-demand, prices as of 2026-11-02, README method): single node ~$1,605/month; HA with 2 nodes
~$3,239; with 3 nodes ~$4,830 (~$4,100 with a 1-year Compute Savings Plan, ~$3,050 with a 3-year EC2 Instance
Savings Plan). Rented bare metal for 3 comparable servers was ~$1,370-1,665/month (Latitude.sh list prices,
2026-11-05), but this blueprint cannot deploy there.

**Why operators run nodes on AWS anyway:** mainly to sit next to the applications that use them (private RPC in the
VPC, lower latency, no public endpoint to secure, same IAM and monitoring), plus automation and recovery,
organisational reasons and policy safety. Performance-critical nodes (validators, high-throughput Solana RPC) tend to
run on bare metal; Coinbase runs its exchange on AWS and its Solana validators on bare metal.

**2 vs 3 nodes:** the framework replaces HA nodes one at a time with at least one in service, and each replacement
rebuilds for hours. With 2 nodes a single node serves alone through every rolling upgrade (mainnet every two weeks)
and every replacement, so a second failure in that window is an outage. With 3, two keep serving.

## Decision
1. **Intended use:** an RPC node for **applications running in AWS**. For a public RPC service with no AWS
   applications behind it, or for teams that don't want to operate nodes, the README points to alternatives (rented
   bare metal from a host that allows blockchain nodes; a professional RPC provider, as Mysten recommends).
2. **Production: HA with 3 nodes.** Both HA samples set `HA_NUMBER_OF_NODES="3"` (enforced by a test); a single node
   is for development, testing or non-critical use.

## Alternatives considered
- **2 nodes as the HA default:** ~$1,590/month cheaper on-demand, but no spare during upgrades and replacements.
- **Single node as the production default:** hours of downtime per upgrade or failure.

## Consequences
- Production cost is roughly 3x a single node; Savings Plans bring 3 nodes to ~$3,050/month (3-year).
- HA has not been deployed live yet; the release test includes a 3-node testnet HA deployment.
- HA still shares failure modes across nodes (bad release, missed protocol upgrade, Sui halt, region outage,
  dependency on Mysten's snapshot bucket); the README lists them.
