# ADR-0001: Record architecture decisions

- **Status:** Accepted by owner
- **Date:** 2026-11-02
- **Deciders:** Owner (requested); build agent (wrote)

## Context
The blueprint was first built by following the framework's add-protocol workflow, which is a build checklist, not a
requirements or decision process. The Owner wanted requirements documents and ADRs before testing, so that the test has
agreed pass criteria and decisions can be reviewed and revisited.

## Decision
Use a Kiro spec (`.kiro/specs/sui-rpc-node-blueprint/requirements.md`, `design.md`, `tasks.md`, `traceability.md`), the
format the framework itself uses, plus ADRs in `docs/adr/`. Decisions already made are recorded retroactively and marked
as such. Neither directory is in the npm package's `files` list, so users installing the blueprint do not download them.

## Alternatives considered
- **AI-DLC** (AI-Driven Development Life Cycle): a fuller lifecycle with team checkpoints. Heavier than a ~2,000-line
  blueprint needs, and not used anywhere in the Node Runners ecosystem. Reconsider if the Owner's organisation requires it.
- **Keep a narrative session log only:** no acceptance criteria, no alternatives or consequences per decision.

## Consequences
- The one-day test verifies requirements, with results traced in `traceability.md`.
- The retroactive records are reconstructions; they may miss reasoning that was never written down.
- New decisions from now on get an ADR when made.
