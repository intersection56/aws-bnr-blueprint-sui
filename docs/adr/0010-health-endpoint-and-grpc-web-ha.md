# ADR-0010: sui-node /health for HA; gRPC-Web only through the ALB

- **Status:** Accepted by owner
- **Date:** 2026-11-05
- **Deciders:** build agent
- **Requirements:** R12

## Context
The framework's HA mode uses an ALB target group with an HTTP/1.1 health check on a path and port. In `sui-rpc-api`
v1.82.3 (unchanged in v1.83.1), `GET /health` fails until a checkpoint has executed and, with indexing on, the live-object index is within 60
checkpoints of the executed tip; `?threshold_seconds=N` adds a staleness check. `sui-node` serves gRPC-Web
(`tonic_web::GrpcWebLayer`) over HTTP/1.1, while native gRPC needs HTTP/2 end to end.

## Decision
Health-check `GET /health` on port 9000, HTTP 200 only, 1,440-minute (24 h) grace period (revised 2026-11-03 from 240 minutes). Document that gRPC-Web works through
the ALB and native gRPC must target instances inside the VPC.

## Alternatives considered
- **Custom health script on another port:** duplicates logic `sui-node` already has.
- **`/health?threshold_seconds=60` in the ALB path:** stricter. Query strings are supported (ALB accepts `/path?query`; the framework passes the path through, checked 2026-11-05), but rejected for now because the Auto Scaling group replaces ELB-unhealthy nodes; see ADR-0023.
- **Changing the framework to a gRPC target group:** out of scope for a community blueprint.

## Consequences
- Nodes that are restoring or indexing receive no traffic.
- The grace period was first set to 240 minutes as a guess. The testnet test measured 3h43m deploy-to-healthy with the restore succeeding first time (2026-11-03); mainnet holds several times more data and is unmeasured. Because the Auto Scaling group replaces nodes that are still unhealthy when the grace period ends, and replacement restarts the bootstrap, the sample now uses 24 hours. Shorten it once mainnet bootstrap is measured. Suspending `ReplaceUnhealthy` until nodes serve is documented as an alternative.
- The lifecycle hook (`defaultResult: ABANDON`) is not a risk: the framework completes it early in setup, before the restore.
- Native-gRPC users of HA must bypass the ALB.
- **Updated 2026-11-05:** plain `/health` does not check freshness (a node ~44,000 checkpoints behind returned 200 in the
  test), so a lagging node keeps receiving traffic. Covered by a stack-level lag alarm instead; reasoning and the
  upstream request in ADR-0023. The HA samples now run 3 nodes (ADR-0024).
