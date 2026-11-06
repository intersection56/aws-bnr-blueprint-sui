# ADR-0012: Archive fallback on for testnet, opt-in for mainnet

- **Status:** Accepted by owner
- **Date:** 2026-11-05
- **Deciders:** build agent
- **Requirements:** R6.6, R6.7

## Context
Archive fallback lets a lagging node fetch checkpoints its peers have pruned. Testnet uses a free HTTPS endpoint
(30-day retention). Mainnet uses a Requester Pays S3 bucket (`mysten-mainnet-checkpoints`, us-west-2) that needs
`s3:GetObject` in the instance role and bills egress; the framework does not grant that permission. Sui says not to put
access keys in `fullnode.yaml`.

## Decision
`SUI_ARCHIVE_FALLBACK=auto` (default): on for testnet, off for mainnet. `true` on mainnet enables the S3 archive with
instance-role credentials only.

## Alternatives considered
- **On for mainnet by default:** would fail without the IAM permission and silently add cost.
- **Access keys in config:** rejected by Sui's guidance and the no-secrets rule.

## Consequences
- A mainnet node that falls far behind may need manual intervention or a snapshot re-restore.
- When enabled, catch-up costs ~$0.02/GB plus GETs (~$0.52 per day of mainnet checkpoints, as of 2026-11-02).
