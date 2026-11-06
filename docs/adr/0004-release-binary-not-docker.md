# ADR-0004: Install the official release binary, not Docker

- **Status:** Accepted
- **Date:** 2026-11-05
- **Deciders:** build agent
- **Requirements:** R4, R8

## Context
The framework supports native binaries (Pattern A, `.sh` install/run dispatch, as BNB and Solana do) and docker-compose
(Pattern B, as Ethereum, Base and Avalanche do). MystenLabs publishes per-network release tarballs for Ubuntu x86_64 and
aarch64 with SHA-256 digests in the GitHub release metadata. Sui's own Docker Compose guide calls it not suitable for production.

## Decision
Download the release tarball, verify it (ADR-0014), extract only `sui-node` and `sui-tool`, and run `sui-node` directly
under systemd as `bcuser`.

## Alternatives considered
- **Docker image `mysten/sui-node`:** adds a container runtime and image pull, and needs image digest pinning; Sui's
  compose path is development-oriented.
- **Build from source with cargo:** long build times on every install, and more toolchain to trust.

## Consequences
- Simple systemd service; logs go to the journal; no Docker daemon.
- Each install downloads ~1.2 GB; a release marker skips this when the same asset is already installed.
- Glibc compatibility relies on MystenLabs' Ubuntu build matching the framework's Ubuntu 24.04 AMI (verified live 2026-11-03: `sui-node 1.83.0-16d2dc1e05ed` ran on the framework's Ubuntu 24.04 instance; v1.83.1 not yet run live).
