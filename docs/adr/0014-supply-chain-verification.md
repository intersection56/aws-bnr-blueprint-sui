# ADR-0014: Verify release digest and pin genesis, fail closed

- **Status:** Accepted by owner (recorded retroactively 2026-11-02)
- **Deciders:** build agent
- **Requirements:** R4

## Context
The install phase runs as root at boot and downloads a ~1.2 GB binary archive plus `genesis.blob`. GitHub release
metadata publishes a SHA-256 `digest` per asset. Genesis never changes for a live network (testnet can be re-genesised).

## Decision
- Accept the asset only from the MystenLabs releases URL; require a 64-hex digest; verify `sha256sum`; delete and fail on mismatch.
- Pin per-network genesis SHA-256 in the script; fail and delete on mismatch.
- Extract only `sui-node` and `sui-tool`; never execute downloaded scripts.
- The genesis digests are allowlisted for detect-secrets with a reason (public values, false positive).

## Alternatives considered
- **Warn and continue when no digest** (as the BNB blueprint does): weaker; rejected.
- **Hardcode release digests:** more maintenance per release; the metadata digest is fetched over HTTPS from GitHub.

## Consequences
- A tampered or corrupted download cannot run.
- Trust rests on GitHub's metadata and TLS; a compromised GitHub release would publish a matching digest.
- A testnet re-genesis breaks installs until the pin is updated (clear error).
- **Updated 2026-11-05:** the never-downgrade safeguard (ADR-0022) keeps an already-installed newer release only if it
  was installed by this installer (release marker on the root volume), so every binary that runs has passed the same
  digest check. The in-place upgrade tool uses this installer rather than its own download.
