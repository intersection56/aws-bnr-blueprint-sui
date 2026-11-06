# ADR-0009: RPC private to the VPC; metrics and admin on loopback

- **Status:** Accepted by owner
- **Date:** 2026-11-05
- **Deciders:** build agent
- **Requirements:** R7

## Context
Sui's RPC has no authentication of its own. Sui's template binds metrics to `0.0.0.0:9184` and tells operators to
restrict it; the admin API (port 1337) is unauthenticated and can change log levels. The framework rule is: RPC on the
internal IP, P2P on `0.0.0.0`, metrics never on `0.0.0.0`.

## Decision
- RPC (`json-rpc-address`) on the internal IP:9000; security group from the VPC CIDR only; HA ALB internal by default.
- P2P on `0.0.0.0:8084/udp`, the only public port.
- Metrics on `127.0.0.1:9184`, admin on `127.0.0.1:1337`, validator `network-address` on `127.0.0.1`; none in `requiredPorts`.

## Alternatives considered
- **Public RPC by default:** exposes an unauthenticated API to the internet; costs ~5x more in egress at busy load.
  Users can opt in through the framework's internet-facing ALB settings with a CIDR allowlist, TLS and (recommended) WAF.

## Consequences
- Safe default; clients must be in the VPC or connect via peering, VPN or PrivateLink.
- Native gRPC from outside AWS needs extra work (see ADR-0010).
