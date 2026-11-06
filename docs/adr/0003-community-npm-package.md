# ADR-0003: Distribute as a community npm package

- **Status:** Accepted
- **Date:** 2026-11-05
- **Deciders:** Owner (requested); build agent at owner's direction (wrote)
- **Requirements:** R1

## Context
The framework supports built-in blueprints (`blueprints/` in the core repo) and external ones installed from npm or
GitHub. Its add-protocol workflow notes that since the v2 core blueprint lock (June 2026), new protocols are added as
community blueprints. The `ConfigurationLoader` treats both identically.

## Decision
Ship `aws-bnr-blueprint-sui` as a standalone package ("Path B"), installed with `--legacy-peer-deps` because the
framework is not on the npm registry. Reuse the Avalanche community blueprint's `scripts/validate.sh` and CI shape.

## Alternatives considered
- **Built-in blueprint via core-repo PR:** not accepted for new protocols under the v2 lock.

## Consequences
- The Owner maintains and publishes it; AWS does not review or endorse community blueprints.
- Users' AI workflow runs the framework's community security review before first deploy.
- Listing in the community catalog needs a PR to the framework site.

## Update 2026-11-05
- **Distribution is a public GitHub repository, not the npm registry.** The Node Runners community confirmed that
  community blueprints live in the author's own public GitHub repo (npm optional), installed with
  `npm install github:<owner>/<repo> --legacy-peer-deps`; internal GitLab does not work. Repository:
  `intersection56/aws-bnr-blueprint-sui` (`package.json` `repository`, `homepage`, `bugs`, `author` set). None of the
  five published community blueprints is on npm either. The package layout is still an npm package, which is what
  `npm install github:` needs.
- Spec-driven docs (`.kiro/specs/`, `docs/adr/`) are welcome on top of the standard layout, per the same answer.
- Release tag at publish: `v2.0.0`, matching `package.json` `version`.
