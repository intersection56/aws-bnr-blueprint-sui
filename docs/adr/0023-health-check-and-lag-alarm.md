# ADR-0023: Plain /health for the load balancer; a stack-level lag alarm for nodes that fall behind

- **Status:** Accepted by owner (2026-11-05, decided by the Owner); live verification pending (release test)
- **Requirements:** R10 (10.5), R12 (12.5)
- **Related:** ADR-0010 (health endpoint)

## Context
sui-node's plain `/health` checks that checkpoints have executed and, with indexing on, that the live-object index is
within 60 checkpoints of the node's own tip. It does not check freshness: staleness is only checked with
`?threshold_seconds=N` (sui-rpc-api `health.rs`, v1.83.1). In the 2026-11-03 test plain `/health` returned 200 while
the node was ~44,000 checkpoints behind, so an HA load balancer can keep sending traffic to a node that has stopped
following the chain.

Adding `?threshold_seconds=N` to `HA_ALB_HEALTHCHECK_PATH` is technically possible (ALBs accept `/path?query`; the
framework passes the path through). But the framework's Auto Scaling group uses ELB health checks
(`additionalTypes: [ELB]` in `ha-nodes-construct.ts`, not configurable by a blueprint) and replaces unhealthy
instances. A lagging node would be destroyed and rebuilt (hours). During a Sui network halt every node would fail at
once and all would be replaced. Halts are not rare: about 2.5 h on 2024-11-21, about 6 h on 2026-01-14, and three on
2026-05-28/29 totalling more than 15 h (Sui blog posts). The ALB itself fails open when every target is unhealthy, but
the replacements would turn a halt into a longer outage. Replacing a node also does not fix a missed protocol upgrade.

## Decision
1. Keep `HA_ALB_HEALTHCHECK_PATH="/health"` (enforced by a test).
2. `syncchecker.sh` also publishes `c1_seconds_behind` with dimension `StackName=$STACK_NAME` (only once metrics are
   available), so **one alarm per stack** on its Maximum covers every node and survives HA replacements. The README
   documents the `put-metric-alarm` command (60 s behind for 5 minutes, missing data not breaching) and how to respond.
   The blueprint cannot create the alarm itself (no CDK code; the instance role has no `PutMetricAlarm`).
3. Ask the framework to let blueprints separate "stop sending traffic" (ALB health) from "replace the node" (ASG
   health type), for example an option to use EC2-only ASG health checks (upstream report 6). Once available, use
   `/health?threshold_seconds=120` for routing only.

## Alternatives considered
- **Threshold now, large N (600-1,800 s):** still replaces every node in a halt longer than N; all three 2026 halts ran for hours.
- **Threshold plus suspending `ReplaceUnhealthy`:** also stops replacement of failed instances, removing a main benefit of HA.

## Consequences
- A lagging HA node keeps receiving traffic until someone acts on the alarm (deregister it or restart `node.service`).
- One extra CloudWatch metric per stack ($0.30/month) plus $0.10/month per alarm.
- `--treat-missing-data notBreaching` keeps the alarm quiet during bootstrap; a node that stops publishing entirely is
  covered in HA by an `UnHealthyHostCount` alarm, not this one.
- **Updated 2026-11-06 (release test, issue 5):** the alarm needs 5-minute periods (`--period 300 --evaluation-periods 2
  --datapoints-to-alarm 2`). With 1-minute periods it returned to OK while a node was ~78,000 s behind, because the sync
  checker runs every 60-90 s and some minutes had no sample from the lagging node. Also, nodes publish the stack metric
  during the post-bootstrap catch-up (not during restore and index build), so the alarm fires while a new node catches
  up; that is correct, because plain `/health` already routes traffic to it. Verified live: the corrected alarm fired
  ~8 minutes after a node's P2P was blocked and cleared ~6 minutes after it caught up; plain `/health` stayed 200 (and
  the target healthy) throughout, confirming the freshness gap this ADR describes.

