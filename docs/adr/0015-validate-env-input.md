# ADR-0015: Validate .env input before writing config

- **Status:** Accepted by owner
- **Date:** 2026-11-05
- **Deciders:** build agent
- **Requirements:** R6.4

## Context
`SUI_*` values come from the user's `.env`, are injected by CDK into `/etc/cdk_environment`, and are written into a YAML
heredoc by a root script. Unvalidated values could inject YAML keys or break the file.

## Decision
Validate every value before writing: integers match `^[0-9]+$`, booleans are `true`/`false`, archive fallback is
`auto`/`true`/`false`, checkpoint retention is at least 2. Fail without writing on any violation.

## Alternatives considered
- **Pass through and let `sui-node` reject bad config:** fails later, and does not prevent key injection.

## Consequences
- Bad input fails fast with a clear message; tested with `SUI_NUM_EPOCHS_TO_RETAIN='5; rm -rf /'`.
- New variables must get a validator when added.
- **Updated 2026-11-05:** `SUI_ALLOW_DOWNGRADE` (ADR-0022) is validated as `true` or `false`; anything else fails the
  install.
