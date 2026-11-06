# ADR-0020: Start node.service only when /data is mounted

- **Status:** Accepted by owner 2026-11-03 (revised the same day). Plain reboot verified live 2026-11-03; stop/start path pending (final release test)
- **Deciders:** build agent, from the redeploy test
- **Requirements:** R8.5, R9.1

## Context
`node.service` is enabled (`WantedBy=multi-user.target`), so systemd starts it at every boot. `/data` is instance store,
which is blank after a stop/start. The framework recreates the RAID and mounts `/data` later in boot, during
setup. In the redeploy test, the service started 42 s before the RAID existed. `sui-node` tried to create its
database under the empty, root-owned `/data` directory on the root filesystem, failed with `Permission denied`, panicked
(SIGABRT core dump), was auto-restarted once and aborted again. The framework then stopped it before re-running `node.sh`.
Nothing was written to the root disk, but only because of directory permissions.

## Decision
Add to the `[Unit]` section:
- `RequiresMountsFor=/data`: order the service after the `/data` mount and require it. On a plain reboot the node waits
  for the mount; after a stop/start the old fstab device never appears, the mount fails, and the service is not started
  (no crash loop) until setup rebuilds `/data` and `node.sh` starts it.
- `ConditionPathIsMountPoint=/data`: a second guard against ever running on the root disk.

**Revision (same day):** the first version used only `ConditionPathIsMountPoint`. On review it was found to be unsafe:
the framework writes `/data` to fstab with `nofail`, and systemd does not order `nofail` mounts before services. On a
plain reboot the condition could be checked before `/data` was mounted, the start skipped, and, because the framework's
boot gate then takes the "skip" path, the node would stay down. `RequiresMountsFor` provides the missing ordering.

## Alternatives considered
- **`ConditionPathExists=/data/sui/db/live`:** also blocks the bad start, but would block genesis-sync mode
  (`SNAPSHOT_ENABLED=false`), where `sui-node` creates `live/` itself.
- **Don't enable the unit; let `node.sh` start it every boot:** a plain reboot (framework "skip" gate) would then
  leave the node stopped.

## Consequences
- No crash loop or core dumps at boot after a stop/start; no risk of writing chain data to the root volume.
- Plain reboot (verified live 2026-11-03, hot-patched unit): `data.mount` mounted at 23:24:56, node started at 23:24:58, 0 restarts, framework gate "skip", healthy in ~3 min.
- Stop/start: the fstab mount waits for the missing device (systemd default device timeout, ~90 s) before failing; boot is not blocked (`nofail`). *(To verify in the final release test.)*
- If `/data` is ever not a mount (misconfiguration), the node silently stays stopped; `node.sh`'s post-start
  `is-active` check turns that into a setup failure.
