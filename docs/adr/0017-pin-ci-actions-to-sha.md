# ADR-0017: Pin GitHub Actions to commit SHAs

- **Status:** Accepted by owner (recorded retroactively 2026-11-02)
- **Deciders:** build agent, after an ASH finding
- **Requirements:** R15.4

## Context
The CI used `actions/checkout@v4` and `actions/setup-node@v4`. The framework's `ci-workflows.md` allows major tags for
first-party actions but welcomes SHA pins. ASH (semgrep and opengrep) flagged the mutable tags as a supply-chain risk.

## Decision
Pin both to full commit SHAs with a version comment: `actions/checkout@11d5960a...7262 # v4.4.0`,
`actions/setup-node@49933ea5...0020 # v4.4.0`. Keep `permissions: contents: read`.

## Alternatives considered
- **Keep major tags:** allowed by framework policy, but leaves a scanner finding and a tag-repointing risk.

## Consequences
- ASH reran clean.
- Pins need periodic updates (Dependabot or manual).
