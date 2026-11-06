# ADR-0002: Deploy a non-validator RPC full node

- **Status:** Accepted
- **Date:** 2026-11-05
- **Deciders:** Owner (requested); build agent at owner's direction (wrote)
- **Requirements:** R6, R7, R14.2

## Context
"Sui node" can mean a validator (consensus, staking, active set of at most 150) or a full node (verifies certified
checkpoints, serves reads, forwards transactions). The framework's add-protocol workflow states it covers RPC node
deployments only. All 10 published blueprints, built-in and community, are non-validator nodes.

## Decision
Deploy a non-validator Sui full node that serves RPC (gRPC, gRPC-Web, `/health`). No validator keys, no consensus
configuration, validator `network-address` bound to loopback.

## Alternatives considered
- **Validator:** needs four keys to generate and protect, on-chain candidate registration, a large minimum stake, more
  hardware (24 physical cores per Sui's operator notes), ports 8080-8084 open, and on-call operations. Out of framework scope.
- **Both, selectable:** doubles the surface and still needs key management the framework does not provide.

## Consequences
- No secrets to manage; a compromise exposes no funds or signing keys.
- Users wanting to stake must use a different tool or process.
