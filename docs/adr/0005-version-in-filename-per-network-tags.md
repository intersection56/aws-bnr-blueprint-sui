# ADR-0005: Version in the configuration file name; per-network release tags

- **Status:** Accepted by owner
- **Date:** 2026-11-05
- **Deciders:** build agent
- **Requirements:** R2

## Context
The framework's interface says the client version is encoded in the configuration file name, the single source of
truth, with no separate version field. Sui publishes separate releases per network (`mainnet-v1.82.3`, `testnet-v1.83.0`),
and testnet usually runs a newer version than mainnet.

## Decision
Name configurations `sui-node-vX.Y.Z-full.sh`; derive the release tag as `${BC_NETWORK}-vX.Y.Z`. Ship one configuration
per network's current release. Keep versioned scripts identical apart from their file name (enforced by a test). Fail if the
tag does not exist for the chosen network.

## Alternatives considered
- **Network in the file name** (`sui-node-mainnet-v1.82.3-full.sh`): redundant with `BC_NETWORK` and allows contradictions.
- **Floating "latest" release:** not reproducible.

## Consequences
- A mismatched pair (e.g. mainnet with a testnet-only version) fails fast with a clear message.
- Every Sui release needs a new configuration file; versions go stale quickly (testnet weekly, mainnet every two weeks).
  `scripts/bump.sh` and the daily release watch handle this (ADR-0021).
- When both networks are on the same version (v1.83.1 since 2026-11-05), one configuration file serves both; the
  blueprint ships only the files its samples use.
- **Amended by ADR-0022 (2026-11-05):** after an in-place upgrade of a single node, the installed release can be newer
  than `CLIENT_CONFIG` until the stack is redeployed; the installer's never-downgrade safeguard keeps it. The file name
  is still the source of truth for what a deploy requests.
