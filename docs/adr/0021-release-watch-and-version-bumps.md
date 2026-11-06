# ADR-0021: Daily release watch and scripted version bumps

- **Status:** Accepted by owner (2026-11-05; proposed by the agent)
- **Requirements:** R2 (2.5, 2.6)

## Context
Sui releases separately per network on a fixed schedule (testnet every Tuesday, mainnet every second Wednesday;
https://docs.sui.io/operators/full-node/updates), and a node that falls too far behind can stop following the
chain when the protocol version moves. Three days after the live test, both pins were stale: mainnet `v1.82.3` vs
`v1.83.1` (protocol version 141), testnet `v1.83.0` vs `v1.83.1`.

The four `karimakacem` community blueprints (Avalanche, Arbitrum, Arc, Robinhood) ship a `release-watch` workflow
that opens an issue when a pinned client is behind, a `bump.sh` that repins, and a Maintenance section in the README.
Their scripts assume one Docker-image configuration file and use `releases/latest`, which does not fit Sui's
per-network release tags. On 2026-11-05 all three repositories that had received release-watch issues still had them
open, some for over two weeks: the automation reports stale pins but does not keep a blueprint current.

## Decision
- `scripts/check-release.sh`: for each network in `package.json`, read the pin from that network's samples and compare
  it with the newest published `<network>-vX.Y.Z` release. Open one issue per new release; `DRY_RUN=1` only prints.
- `.github/workflows/release-watch.yml`: runs it daily (weekly until 2026-11-05; changed because testnet ships Tuesdays and mainnet every second Wednesday, so a Monday run lagged by up to 6 days); actions pinned to commit SHAs (ADR-0017).
- `scripts/bump.sh <network> <version>`: verify the release and its SHA-256 digests for both architectures, add the
  configuration file, repoint that network's samples, rebuild `availableConfigurations` from the samples, update the
  test's `PINNED` map, delete unused configuration files, and list remaining mentions of the old version.
- Configuration scripts carry no version text, so they are byte-identical copies.
- A test checks that `package.json`, the samples and `configurations/` list exactly the same files.

## Alternatives considered
- **Copy the karimakacem scripts unchanged:** they model one image per configuration and a single upstream "latest".
- **Automatic bump pull requests:** a Sui bump needs release-note review (`fullnode.yaml`, `sui-tool`, protocol
  changes) and ideally a live test; an issue keeps a human in the loop.
- **No automation, README note only:** the pins went stale within three days of the test.

## Consequences
- Issues arrive about weekly for testnet and every two weeks for mainnet; someone has to act on them. The pattern in other blueprints shows that
  issues alone are not enough.
- `bump.sh` does not edit prose: README tables and docs are listed for a manual update.
- A bump is verified statically (release metadata, tests, synth); live verification of a new version is still a
  separate step.
