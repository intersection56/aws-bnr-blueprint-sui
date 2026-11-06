# Sui Full Node Runner

A community blueprint for [AWS Blockchain Node Runners](https://aws-samples.github.io/aws-blockchain-node-runners/) that deploys a [Sui](https://sui.io) **full node** for serving RPC (gRPC / gRPC-Web) on **mainnet** or **testnet**.

The node runs the official MystenLabs `sui-node` release binary (SHA-256 verified), bootstraps from the latest cryptographically verified **formal snapshot**, and serves the Sui gRPC API on a VPC-internal port. It is a non-validator full node: it verifies and executes certified checkpoints but cannot sign transactions.

> Community blueprints are maintained by their authors and are not reviewed or endorsed by AWS. Review the scripts in `configurations/` and `user-data/` before deploying to production.

## When to use this blueprint

Use it when the **applications that read from Sui run in AWS**: exchanges, wallets, indexers, back ends. The RPC port stays private in the same VPC, close to those applications, with no public endpoint to secure and no internet egress for RPC traffic. That is the main reason node operators run RPC nodes on AWS despite the higher price (see [AWS vs bare metal](#aws-vs-bare-metal)).

Consider other options when:
- **You are building a public RPC service with no AWS applications behind it.** Rented bare metal with included bandwidth is cheaper, from a host that explicitly allows blockchain nodes; this blueprint does not deploy there.
- **Your application has high traffic and you don't want to operate nodes.** Mysten Labs recommends dedicated nodes or a professional RPC provider over its rate-limited public endpoints ([RPC best practices](https://docs.sui.io/references/sui-api/rpc-best-practices)).

**Recommended setup:** a **3-node HA deployment** for production (`samples/.env-mainnet-sui-node-full-ha`), a single node for development, testing or non-critical use. See [High Availability (HA) Deployment](#high-availability-ha-deployment) for what HA does and doesn't protect against.

## Blueprint Package Structure

```
aws-bnr-blueprint-sui/
├── package.json                          # "aws-blockchain-node-runner" protocol configuration
├── README.md
├── configurations/
│   └── sui-node-v1.83.1-full.sh          # mainnet and testnet release (install/run dispatch)
├── samples/
│   ├── .env-mainnet-sui-node-full
│   ├── .env-mainnet-sui-node-full-arm64
│   ├── .env-mainnet-sui-node-full-ha     # 3 nodes, recommended for production
│   ├── .env-testnet-sui-node-full
│   └── .env-testnet-sui-node-full-ha     # 3 nodes, for testing HA cheaply
├── user-data/
│   ├── node.sh                           # protocol-level setup, "node" systemd service
│   ├── syncchecker.sh                    # CloudWatch metrics + traffic shaping control
│   └── common/
│       ├── install-sui-binaries.sh       # sui-node / sui-tool + genesis.blob, checksum-verified
│       ├── sui-version.sh                # version helpers (never-downgrade safeguard)
│       ├── write-fullnode-config.sh      # fullnode.yaml for the selected network
│       └── download-snapshot.sh          # formal snapshot restore via sui-tool
├── test/sui-configuration.test.ts        # integration tests against the core ConfigurationLoader
├── scripts/
│   ├── validate.sh                       # install into Node Runners, test, cdk synth every sample
│   ├── bump.sh                           # move a network to a new sui-node release
│   ├── upgrade-in-place.sh               # upgrade a single node over SSM, without a redeploy
│   ├── check-release.sh                  # compare pins with the latest releases (release-watch)
│   └── release-lib.sh                    # helpers shared by the scripts above
└── .github/workflows/
    ├── ci.yml                            # ShellCheck + validate.sh on push, PR and weekly
    └── release-watch.yml                 # daily: open an issue when a pin falls behind
```

## Overview of Deployment Architectures

### Single Node Deployment

```
                    ┌──────────────────────── VPC ─────────────────────────┐
                    │  ┌───────────── EC2 (i7i.4xlarge / i8g.4xlarge) ────┐│
 Sui peers ◄──────► │  │ sui-node (systemd "node", user bcuser)           ││
 8084/udp (public)  │  │   P2P        0.0.0.0:8084/udp                    ││
                    │  │   RPC        <internal-ip>:9000  (gRPC, /health) ││◄── VPC clients
                    │  │   metrics    127.0.0.1:9184                      ││
                    │  │   admin      127.0.0.1:1337                      ││
                    │  │ /data (NVMe instance store) - RocksDB            ││
                    │  │ syncchecker.timer ──► CloudWatch (CWAgent)       ││
                    │  └──────────────────────────────────────────────────┘│
                    └──────────────────────────────────────────────────────┘
```

1. The node syncs certified checkpoints from Sui seed peers and other full nodes over P2P (UDP 8084).
2. The RPC port (9000) is reachable only from inside the VPC (security group scoped to the VPC CIDR).
3. `syncchecker.sh` reads the node's Prometheus metrics locally and publishes `c1_block_height`, `c1_blocks_behind` and `c1_seconds_behind` to CloudWatch (plus a stack-level `c1_seconds_behind` for the [lag alarm](#lag-alarm)).

### High Availability (HA) Deployment

1. An Auto Scaling group runs `HA_NUMBER_OF_NODES` identical full nodes (**3** in the HA samples, recommended for production) behind an **internal** Application Load Balancer on port 9000. The framework places nodes in public subnets across the region's Availability Zones.
2. The ALB health-checks `GET /health`. sui-node returns 200 only after it has executed checkpoints and, with indexing enabled, its live-object indexes are within 60 checkpoints of the executed tip, so nodes still restoring or indexing get no traffic. **Plain `/health` does not check freshness:** a node that has stopped following the chain but whose indexes match its own tip still returns 200 (in the 2026-11-03 test it returned 200 while ~44,000 checkpoints behind). Lag is covered by an alarm instead; see [Lag alarm](#lag-alarm) and the reasoning below.
3. **Bootstrap time and replacement:** a new node takes hours to become healthy (~3h40m on testnet; mainnet not measured). The HA sample sets the health-check grace period to 24 hours so the Auto Scaling group does not replace nodes that are still bootstrapping. See [Health Check Failures (HA)](#health-check-failures-ha).
4. **Protocol note:** the framework's ALB forwards HTTP/1.1. sui-node supports **gRPC-Web** over HTTP/1.1 (for example, `@mysten/sui` gRPC-Web transport), so gRPC-Web clients work through the ALB. Native gRPC (HTTP/2) clients such as `grpcurl` should target node instances directly inside the VPC.

#### What HA gives you, and what it doesn't

HA mode has not yet been deployed in a live test (planned for the release test). The blueprint makes no availability promise.

**It protects against:**
- **Loss of one node or its disk** (hardware failure, host retirement, instance-store loss, a stopped instance): the other nodes keep serving and the Auto Scaling group launches a replacement, which bootstraps for hours.
- **One Availability Zone failing**, because nodes are spread across zones.
- **Upgrade downtime:** releases roll out one node at a time (`maxBatchSize: 1`, `minInstancesInService: 1`). With **3 nodes, 2 keep serving** while each node rebuilds; with 2 nodes, a single node serves alone for each node's rebuild (about 7-8 hours in total on testnet numbers, longer on mainnet, every mainnet release).

**It does not protect against** problems shared by every node:
- A bad release or configuration (all nodes launch from the same template), or a missed protocol upgrade.
- A Sui network halt (there have been several, for example [January 2026](https://blog.sui.io/sui-mainnet-network-stall-resolution/) and [May 2026](https://blog.sui.io/sui-mainnet-halts-resolved-after-major-upgrade/)) or a full AWS region outage.
- Mysten Labs' free snapshot bucket being unavailable: every replacement node bootstraps from it.

**Behaviour to know about:**
- **No session stickiness:** consecutive requests can reach different nodes a few checkpoints apart, so a client can briefly see newer then older state.
- **History after a restore:** a node restored from a formal snapshot has no transaction history before the snapshot epoch. With the default 2-epoch retention, history queries to a replacement node can return `OUT_OF_RANGE` for about 2 days. The same applies to a single node after any redeploy that stops and starts the instance.

**Why the health check stays at plain `/health`:** sui-node's `/health?threshold_seconds=N` would also fail nodes that fall behind. But the framework's Auto Scaling group uses the load balancer's health checks to decide replacements, so a lagging node would be destroyed and rebuilt for hours, and during a Sui network halt every node would fail at once and all of them would be replaced. The load balancer itself would cope (it [fails open](https://docs.aws.amazon.com/elasticloadbalancing/latest/application/target-group-health-checks.html) when every target is unhealthy), but the replacements would turn a halt into a longer outage. Until the framework can separate "stop sending traffic" from "replace the node", lag is handled by the [lag alarm](#lag-alarm) (ADR-0023).

## Supported Configurations

### Available Configurations

| Configuration | Network | Release tag | Notes |
|---|---|---|---|
| `sui-node-v1.83.1-full.sh` | mainnet | `mainnet-v1.83.1` | Default |
| `sui-node-v1.83.1-full.sh` | testnet | `testnet-v1.83.1` | |

Sui publishes **separate releases per network**. The install phase downloads release `${BC_NETWORK}-<version>` and fails if that release does not exist for the selected network. Both networks are currently on v1.83.1, so one configuration serves both; when their versions differ, each network has its own configuration file, and the samples pair each network with its own. See [Maintenance](#maintenance).

The live testnet test (2026-11-03, [test report](docs/testnet-test-report.md)) ran v1.83.0. v1.83.1 has not been deployed live yet; the configuration keys, `sui-tool` flags and `/health` logic this blueprint uses are unchanged between the two in Sui's source.

What the configuration provides:

- `rpc.enable-indexing: true`: gRPC indexes for owned objects, balances and the ledger-history list APIs.
- Pruning recommended by Sui for RPC full nodes: 5 epochs of object versions, 2 epochs of transactions, effects and events.
- Archival fallback: on for testnet (free HTTPS endpoint), opt-in for mainnet (see [Configuration Options](#configuration-options)).
- JSON-RPC: Sui has deprecated JSON-RPC, and this release serves gRPC, gRPC-Web and `/health` on port 9000.

## Infrastructure Requirements

### Recommended Instance Types

Sui's suggested minimum for a full node is 8 physical cores (16 vCPU), 128 GB RAM and a 4 TB NVMe SSD.

| CPU | Instance | vCPU | RAM | Local NVMe |
|---|---|---|---|---|
| x86_64 (default) | `i7i.4xlarge` | 16 | 128 GiB | 1 x 3,750 GB |
| ARM_64 (Graviton4) | `i8g.4xlarge` | 16 | 128 GiB | 1 x 3,750 GB |

### Regions

- **Tested:** us-east-1 (testnet, 2026-11-03). Prices in this README are for us-east-1.
- **Default recommendation: a North American region.** Mysten Labs' free formal-snapshot bucket, which every new or replacement node restores from, is currently hosted in North America only ([Available data stores](https://docs.sui.io/operators/data-management/available-data-stores)). Elsewhere, expect slower bootstrap (not measured), or use Mysten's Requester Pays S3 snapshot buckets, which needs code changes this blueprint doesn't include.
- `i7i` and `i8g` are not offered in every region or Availability Zone (for example, `i7i.4xlarge` is not offered in us-east-1e). Set `AWS_AZ` for single-node stacks if a deploy fails with insufficient capacity.

### Storage Requirements

- **Type:** NVMe instance store. Sui produces several checkpoints per second and is I/O-heavy (RocksDB), which favours local NVMe. The node-runner guidance for sub-10-second block times is io2 or instance store.
- **Size:** 3,750 GB. Sui notes that a node without pruning can grow past 7 TB. This blueprint applies Sui's RPC pruning profile, which keeps disk use far lower. Watch disk usage on the CloudWatch dashboard and lower `SUI_NUM_EPOCHS_TO_RETAIN` if the volume fills.
- **Instance store is ephemeral.** Data is lost when the instance stops (including a single-node redeploy that stops and starts the instance). On the next boot `/data` is empty, and the node automatically restores a fresh formal snapshot.
- **Snapshot space:** `sui-tool` downloads and restores into `/data/sui`. No separate staging volume is needed.

**Data size and 12-month projection.** These are Sui's published mainnet figures, which are a point in time ([Sui storage docs](https://docs.sui.io/concepts/sui-architecture/sui-storage), "as of November 2025"):

| Item | Size (Sui, Nov 2025) | Relevance |
|---|---|---|
| Pruned full node with RPC indexes | ~2.5 TB | Steady-state `/data` usage for this blueprint's profile |
| ...of which `indexes/` | ~1.5 TB, grows with TPS | Main growth driver |
| Formal snapshot download | ~30 GB (Sui, mainnet, Nov 2025); **~105 GB measured for testnet on 2026-11-03** | One-time inbound per restore (inbound transfer is free). Treat the mainnet figure as out of date |
| Unpruned full node (for comparison) | ~16 TB | Not used by this blueprint |
| Growth examples (unpruned) | ~10 GB/day at ~18 TPS, ~40 GB/day at ~183 TPS | Sui publishes no growth rate for pruned nodes |

At ~2.5 TB the 3,750 GB volume has ~1.25 TB of headroom. Sui does not publish a growth rate for pruned nodes, so the projection below assumes a range, not a measured value:

| Assumed growth | Headroom lasts | 12-month outlook on 3,750 GB |
|---|---|---|
| 3 GB/day | ~13 months | Fits |
| 10 GB/day (Sui's lowest published rate, for unpruned nodes) | ~4 months | Does not fit |

For a 12-month deployment, watch the `disk_used_percent` trend for `/data` during the first weeks. If growth is above ~3 GB/day, move to `i7i.8xlarge` or `i8g.8xlarge` (2 x 3,750 GB). The framework stripes both NVMe disks into one 7,500 GB `/data` (RAID 0) when `DATA_VOLUMES_COUNT="1"` and `DATA_VOL_1_TYPE="instance-store"`, so only `INSTANCE_TYPE` changes. Prices are in [Monthly Cost Estimate](#monthly-cost-estimate).

To use EBS instead (data survives stop/start, but costs more and is slower), set `INSTANCE_TYPE="r7i.4xlarge"` (or `r8g.4xlarge`), `DATA_VOL_1_TYPE="io2"` (or `gp3`), `DATA_VOL_1_SIZE="4000"` and suitable `DATA_VOL_1_IOPS` / `DATA_VOL_1_THROUGHPUT`. See the [Configuration Reference](https://aws-samples.github.io/aws-blockchain-node-runners/docs/guides/configuration-reference). The cost comparison is in [Instance store vs EBS](#instance-store-vs-ebs-long-term).

### Network Traffic

- **Inbound:** checkpoint data from peers, continuous because Sui produces several checkpoints per second. Inbound data transfer is not charged.
- **Outbound:** state sync served to other peers on 8084/udp, plus any RPC responses to public IPs. This is billed as data transfer out to the internet. RPC to clients inside the VPC and same AZ is not charged; cross-AZ traffic is.
- **Traffic shaping:** enabled in the samples (`TRAFFIC_SHAPING_RATE_MBIT="40"`). The limit is **off during bootstrap**: `node.sh` stops `net-rules.service` before the install phase, and `syncchecker.sh` keeps it off until `/data/init-completed` exists. (The framework starts the limit during setup, and in testing on 2026-11-03 two snapshot-restore attempts timed out with it on.) After bootstrap, `syncchecker.sh` removes the limit while the node is behind (more than `TRAFFIC_SHAPING_MAX_BLOCKS_BEHIND` checkpoints, or executed checkpoints older than 120 s) and applies it again once the node is in sync. With `TRAFFIC_SHAPING_ENABLED="false"` it keeps the limit off; the framework would otherwise leave it on. Only traffic to public IPs is shaped. VPC traffic, such as RPC to your clients, is not.

**Outbound traffic estimate: how it was calculated.** Sui does not publish full node egress figures; the only published figure is a 1 Gbps network requirement. So the per-unit traffic below was **measured from real chain data** on 2026-11-02, and only the counts (peers, request rates, subscribers) are assumptions. Replace the assumptions with your measured `NetworkOut` after the first week.

*Step 1. Measure the chain's data rate.* Mysten Labs publishes every checkpoint to a public archive (`https://checkpoints.<network>.sui.io`, bucket `mysten-<network>-checkpoints`, documented in [Sui's Available Data Stores](https://docs.sui.io/operators/data-management/available-data-stores)). Each checkpoint is one zstd-compressed protobuf file (`<seq>.binpb.zst`). The method:
- Read `epochs.json` (the last checkpoint of every epoch) to get checkpoints per epoch. A Sui epoch is about 24 hours.
- Read the bucket listing, which reports each file's size without downloading it. Sample 6 random runs of 100 consecutive checkpoints per epoch, over the last 28 mainnet epochs (16,800 checkpoints) and the last 20 testnet epochs (12,000 checkpoints).
- Download a subset (210–280 checkpoints) and decompress it to measure the uncompressed size. Also Snappy-compress the decompressed bytes to approximate the P2P wire format.
- Decode the protobuf structure of 140 checkpoints to count transactions and their size.

*Step 2. Work out what goes on the wire.* Sui's state sync, the P2P protocol peers use to fetch checkpoints from your node, encodes messages as BCS with Snappy compression (`BcsSnappyCodec` in `crates/sui-network/build.rs`, sui v1.82.3). The archive uses zstd, which compresses better. The protobuf files were Snappy-compressed as a stand-in for BCS: both are compact binary encodings of the same data, but this is an approximation. Each peer that syncs from your node fetches each checkpoint's contents once.

*Step 3. Multiply by counts and price it* with the AWS unit prices in [Monthly Cost Estimate](#monthly-cost-estimate). Months are 730 hours (30.42 days).

**Measured inputs.** These are a point-in-time snapshot (samples from roughly Oct–Nov 2026); they change with chain activity.

| Measurement | Mainnet | Testnet | Sample |
|---|---|---|---|
| Checkpoints per epoch (~1 day) | ~368,130 (~4.26/s) | ~378,477 (~4.38/s) | Last 28 / 20 epochs, `epochs.json` |
| Average checkpoint, zstd (archive) | 68.5 KiB (p50 58.7, p95 148, p99 221, max 435) | 10.5 KiB | 16,800 / 12,000 checkpoints |
| Chain data, zstd | ~25.8 GB/day | ~4.1 GB/day | Derived from the two rows above |
| Uncompressed protobuf / zstd | ~4.1x | – | 280 mainnet checkpoints |
| Snappy (P2P wire) / zstd | ~1.6x | – | 280 mainnet checkpoints |
| Transactions per checkpoint | ~37.8 (~160 TPS) | – | 140 mainnet checkpoints |
| Transaction with effects and events | ~3.2 KiB each (objects are a further ~70% of checkpoint bytes) | – | 140 mainnet checkpoints |
| Burstiness | The busiest 100-checkpoint window was ~4.1x the median | – | 168 windows |

For comparison, Sui's own storage page reported ~3–10 GB/day of archive growth "as of November 2025" ([Sui storage docs](https://docs.sui.io/concepts/sui-architecture/sui-storage)). The measured mainnet rate today is 2.6–8x higher.

**Traffic per unit (derived from the measurements):**

| Traffic type | Calculation | Mainnet / month | Testnet / month |
|---|---|---|---|
| One peer state-syncing from this node | zstd size x 1.6 x checkpoints/day x 30.42 days | ~1.26 TB (3.8 Mbit/s average) | ~0.20 TB (0.6 Mbit/s) |
| One gRPC client streaming full checkpoints, uncompressed | zstd size x 4.1 x checkpoints/day x 30.42 days | ~3.24 TB (9.9 Mbit/s) | – |
| Same client with zstd negotiated (sui-node supports zstd) | zstd size x checkpoints/day x 30.42 days | ~0.79 TB | – |
| Point reads (objects, transactions, balances) | requests/s x ~4 KiB x 2,628,000 s; the 4 KiB is an assumption based on the measured 3.2 KiB transaction record plus overhead | 100 req/s: ~1.1 TB; 500 req/s: ~5.4 TB; 2,000 req/s: ~21.5 TB | – |

**How many peers sync from your node.** This is an assumption. A node dials 4 peers by default (`target-concurrent-connections`, sui-config v1.82.3 source), and inbound connections have no default cap. Each node downloads each checkpoint once, so across the network uploads roughly equal downloads. Publicly reachable nodes carry the share of nodes that are not reachable. The scenarios below use 2 peers as a baseline, 5 for a busy node and 10 for a very busy one. The **monthly estimate uses 3.8 peer-equivalents**, calibrated from the testnet measurement on 2026-11-03 (see [Monthly Cost Estimate](#monthly-cost-estimate)).

| Scenario (mainnet) | Peers | Outbound P2P / month |
|---|---|---|
| Quiet | 1 | ~1.26 TB |
| Baseline | 2 | ~2.51 TB |
| **Calibrated (used in the estimate)** | **3.8** | **~4.78 TB** |
| Busy | 5 | ~6.28 TB |
| Very busy | 10 | ~12.57 TB |
| Ceiling with traffic shaping at 40 / 20 / 10 Mbit/s | Limit saturated all month | ~13.14 / ~6.57 / ~3.29 TB |

**What traffic shaping does here.** The framework describes savings of "up to ~85%" for chains whose P2P egress is far above the limit, such as Solana, whose README puts unshaped egress at 100–200 TiB/month. Sui's measured P2P egress is much lower, because peers pull each checkpoint once instead of the network re-broadcasting it. Even 10 peers (~38 Mbit/s) stay under the default 40 Mbit/s limit, so shaping reduces none of these scenarios and only caps the worst case. A 10–20 Mbit/s limit would cut busy-node P2P egress, at the cost of serving syncing peers more slowly. Shaping never affects RPC served through the ALB, because the node only talks to the ALB's private IPs.

### Monthly Cost Estimate

> **These are point-in-time prices.** All AWS prices below come from the AWS Price List API (`pricing:GetProducts`) and the Savings Plans API (`describe-savings-plans-offering-rates`). They are for **us-east-1**, on-demand Linux unless stated, and were retrieved **2026-11-02** (price list published 2026-10-29). AWS prices change over time and differ by region. Check the [AWS Pricing Calculator](https://calculator.aws/) or the APIs for current figures. Months are **730 hours**, the same convention as the Avalanche community blueprint. Free-tier allowances are noted separately; they are taken from AWS pricing pages and apply per account, not per node.

**Unit prices used (us-east-1, retrieved 2026-11-02):**

| Service | Item | Price |
|---|---|---|
| EC2 | `i7i.4xlarge` (16 vCPU, 128 GiB, 1 x 3,750 GB NVMe) | $1.5101/h |
| EC2 | `i8g.4xlarge` (16 vCPU, 128 GiB, 1 x 3,750 GB NVMe) | $1.3728/h |
| EC2 | `i7i.8xlarge` / `i8g.8xlarge` (32 vCPU, 256 GiB, 2 x 3,750 GB NVMe) | $3.0202/h / $2.7456/h |
| EC2 | `r7i.4xlarge` / `r8g.4xlarge` (EBS-only alternative) | $1.0584/h / $0.94256/h |
| EBS | gp3 storage / IOPS above 3,000 / throughput above 125 MiB/s | $0.08 per GB-month / $0.005 per IOPS-month / $0.04 per MiB/s-month |
| EBS | io2 storage / IOPS (up to 32,000) | $0.125 per GB-month / $0.065 per IOPS-month |
| VPC | Public IPv4 address (in use) | $0.005/h |
| Data transfer | Out to internet: first 10 TB / next 40 TB / next 100 TB / over 150 TB per month | $0.09 / $0.085 / $0.07 / $0.05 per GB, after the 100 GB/month account-wide free tier |
| Data transfer | Inter-region us-west-2 to us-east-1 (mainnet archive fallback only) | $0.02/GB |
| S3 | GET requests, us-west-2 (Requester Pays archive) | $0.004 per 10,000 |
| ELB | Application Load Balancer (HA only) | $0.0225/h + $0.008 per LCU-hour |
| Data transfer | Cross-AZ within the region (EC2, ELB) | $0.01/GB each direction. The Price List also lists $0.00 cross-AZ usage types, so check your bill; $0.01 is used here as the conservative figure |
| WAF | Web ACL / rule / requests (only if RPC is exposed to the internet) | $5.00 per web ACL-month / $1.00 per rule-month / $0.60 per million requests |
| CloudWatch | Custom metrics (first 10,000) | $0.30 per metric-month |
| CloudWatch | Logs ingestion (Standard) / storage | $0.50/GB / $0.03 per GB-month |
| CloudWatch | API requests (`PutMetricData`) / dashboard | $0.01 per 1,000 / $3.00 per dashboard-month |

**What the framework provisions per node** (from the framework source, not from pricing):
- An 80 GB gp3 root volume at the 3,000 IOPS baseline: $6.40/month.
- A public IPv4 address, because nodes run in public subnets: $3.65/month.
- The CloudWatch agent publishing per-vCPU CPU, per-device disk I/O, disk, memory, netstat and swap metrics every 60 s, plus `syslog` and `cloud-init-output.log` with 7-day retention. `syslog` includes the sui-node service output.
- One CloudWatch dashboard per stack.

**Estimated monthly cost, typical deployment (on-demand, us-east-1, prices as of 2026-11-02; test measurements from a testnet deployment on 2026-11-03).** This assumes the blueprint default: RPC clients inside the VPC in the same AZ. Peer traffic uses the testnet measurement (below) calibrated to mainnet.

| Component | Mainnet x86 (`i7i.4xlarge`) | Mainnet ARM (`i8g.4xlarge`) | Testnet x86 | Mainnet HA, 2 x `i7i.4xlarge` | Mainnet HA, 3 x `i7i.4xlarge` (recommended) |
|---|---|---|---|---|---|
| EC2 compute | $1,102.37 | $1,002.14 | $1,102.37 | $2,204.75 | $3,307.11 |
| Data volume (instance store) | $0 (included) | $0 (included) | $0 (included) | $0 (included) | $0 (included) |
| Root EBS (80 GB gp3) | $6.40 | $6.40 | $6.40 | $12.80 | $19.20 |
| Public IPv4 | $3.65 | $3.65 | $3.65 | $7.30 | $10.95 |
| Data transfer out (P2P) | $420.89 (~4.78 TB, calibrated) | $420.89 (~4.78 TB, calibrated) | $58.54 (~0.75 TB, **measured**) | $850.79 (~9.55 TB, calibrated) | $1,260.73 (~14.33 TB, calibrated) |
| RPC data transfer (same-AZ VPC clients) | $0 | $0 | $0 | $0 | $0 |
| CloudWatch custom metrics (**197 per node, measured**) | $59.10 | $59.10 | $59.10 | $118.20 | $177.30 |
| CloudWatch Logs (**~0.53 GB/day per node, measured**) | $8.15 | $8.15 | $8.15 | $16.31 | $24.46 |
| CloudWatch API + dashboard | $4.75 | $4.75 | $4.75 | $6.50 | $8.25 |
| Application Load Balancer, internal (assumed 1 LCU average) | – | – | – | $22.27 | $22.27 |
| **Total / month** | **~$1,605** | **~$1,505** | **~$1,243** | **~$3,239** | **~$4,830** |
| CloudWatch share of total | ~4.5% | ~4.8% | ~5.8% | ~4.4% | ~4.3% |

Notes on the HA columns:
- **3 nodes:** peer egress of ~14.33 TB crosses the first 10 TB pricing tier, so part of it is billed at $0.085/GB. With Graviton (`i8g.4xlarge`) the 3-node total is about **$4,530**.
- **Savings Plans** discount compute only (see [Compute Optimization](#compute-optimization)): the 3-node x86 total falls to about **$4,100** with a 1-year Compute Savings Plan and about **$3,050** with a 3-year EC2 Instance Savings Plan (both no upfront).
- Nodes are spread across Availability Zones, so busy RPC clients will also reach nodes in other zones; see placement B in [Busy RPC node](#busy-rpc-node-egress-and-network-services).
- Every column also carries one stack-level metric for the [lag alarm](#lag-alarm) (+$0.30/month), plus $0.10/month per alarm.

**What was measured and how it was applied** (testnet, `i7i.4xlarge`, one deployment, point in time):
- **CloudWatch metrics:** `aws cloudwatch list-metrics --namespace CWAgent` returned 197 metrics for the instance. The earlier estimate was ~150.
- **Logs:** `IncomingBytes` on `/aws/ec2/blockchain-nodes/systemd-services` was 123.8 MB over 5h37m, including the whole bootstrap, so ~0.53 GB/day. The earlier assumption was 2 GB/day.
- **Peer traffic:** `NetworkOut` was 1.03 GB in the first full hour after the node caught up (~2.3 Mbit/s), so ~0.75 TB/month. That is **3.8x** the per-peer model for testnet (0.198 TB/month). Mainnet uses the same factor: 3.8 x 1.257 TB = ~4.78 TB/month. This is a calibration from one hour on one testnet node, not a mainnet measurement; it replaces the earlier "2 peers" assumption until mainnet is measured.

**P2P sensitivity (mainnet x86, everything else as above):**

| Peer-equivalents served by the node | Data transfer out | Total / month |
|---|---|---|
| 1 | $104.13 | ~$1,289 |
| 2 | $217.26 | ~$1,402 |
| 3.8 (calibrated from the testnet measurement) | $420.89 | ~$1,605 |
| 5 (busy) | $556.65 | ~$1,741 |
| 10 (very busy) | $1,111.15 | ~$2,296 |
| Traffic shaping ceiling at 40 / 20 / 10 Mbit/s | $1,159.60 / $582.30 / $286.65 | – |

Calculation: data transfer = (outbound GB − 100 GB account-wide free tier) x tiered internet price ($0.09/GB for the first 10 TB, then $0.085/GB). Outbound GB = peer-equivalents x per-peer traffic from [Network Traffic](#network-traffic). Totals add the fixed per-node lines from the table above.

Assumptions you should check against your own deployment:
- **CloudWatch metrics:** 197 per node was measured on `i7i.4xlarge` (16 vCPU). The count depends on vCPUs (16 x 4 CPU series), block devices and mounts, so other instance sizes differ. The workflow's rule of thumb is ~15% of the total for CloudWatch; here it is ~5% because compute dominates. Count yours with `aws cloudwatch list-metrics --namespace CWAgent --dimensions Name=InstanceId,Value=$INSTANCE_ID --query 'length(Metrics)'`.
- **CloudWatch Logs:** ~0.53 GB/day at `SUI_RUST_LOG="info"` was measured on testnet. Mainnet carries more transactions and may log more. 2 GB/day would cost ~$31/month and 5 GB/day ~$77/month. Check the `IncomingBytes` metric on the `/aws/ec2/blockchain-nodes/systemd-services` log group. To reduce it, set `SUI_RUST_LOG="warn"`.
- **Free tiers** (account-wide, from AWS pricing pages, not deducted above except the 100 GB data transfer): 10 custom metrics, 1M API requests, 5 GB log ingestion and 3 dashboards per month.
- **One-time and occasional costs:** the formal snapshot and the ~1.2 GB release download are inbound, so they are free. The testnet formal snapshot was ~105 GB (2026-11-03), much larger than the ~30 GB Sui documented for mainnet in Nov 2025. Inbound since a redeploy totalled 319 GB, all free. Mainnet archive fallback is opt-in and Requester Pays. It costs $0.02/GB plus $0.004 per 10,000 GETs when the node runs outside us-west-2, and is only used while catching up. One day of mainnet checkpoints is ~25.8 GB (measured), so about $0.52 per day of catch-up.
- **Not included:** taxes, support plans and Savings Plans (see below). RPC to clients outside the VPC or in other AZs is covered in the next section.

#### Busy RPC node: egress and network services

Where RPC clients connect from matters as much as how busy the node is. Three placements are priced below, each at three load levels. Traffic per unit comes from the measurements in [Network Traffic](#network-traffic). The load levels are assumptions, anchored to published request limits:
- Mysten's public endpoint: 10 requests/s per IP, documented as 100 requests per 30 s ([Sui RPC best practices](https://docs.sui.io/references/sui-api/rpc-best-practices); [Sui forum, 2024 rate limit change](https://forums.sui.io/t/upcoming-public-rpc-rate-limit-changes/45753)).
- OnFinality free tier: 40 req/s ([OnFinality Sui page](https://onfinality.io/en/networks/sui)).
- Shared provider plans: raised from 60 to 200 req/s ([Sui forum, Dec 2023](https://forums.sui.io/t/triple-rps-boost-update-to-maximise-dapp-performance-in-the-bull-market/45164)).

A dedicated busy node is assumed to sustain several times a shared plan's limit.

| Load level | Peers | Point reads | Full-checkpoint gRPC streams | P2P out / month | RPC out / month |
|---|---|---|---|---|---|
| Moderate | 2 | 100 req/s | 1 (zstd negotiated) | ~2.51 TB | ~1.86 TB |
| **Busy** | 5 | 500 req/s | 3 (uncompressed) | ~6.28 TB | ~15.11 TB |
| Very busy | 10 | 2,000 req/s | 10 (uncompressed) | ~12.57 TB | ~53.97 TB |

**Egress and network services per month, by where RPC clients are** (prices as of 2026-11-02, point in time):

| Client placement | Moderate | **Busy** | Very busy | What is billed |
|---|---|---|---|---|
| A. Same VPC, same AZ (blueprint default) | $217 | **$557** | $1,111 | P2P internet egress only; same-AZ RPC is free |
| B. Same VPC, other AZs | $254 | **$859** | $2,190 | A, plus RPC bytes x $0.01/GB out x 2 (both sides) |
| C. Internet, via internet-facing ALB + WAF | $581 | **$2,794** | $9,078 | P2P + RPC internet egress, ALB hours and LCUs, WAF |

How placement C was calculated (busy column):
- **Data transfer out:** P2P plus RPC, 21.4 TB, minus the 100 GB free tier, at tiered internet rates: **$1,861**.
- **ALB:** $0.0225 x 730 h, plus LCU-hours. For EC2 targets, 1 LCU covers 1 GB processed per hour; 15.11 TB / 730 h ≈ 20.7 LCUs, x $0.008 x 730: **$137**. This assumes reused (keep-alive) connections, so bytes rather than new connections set the LCU count.
- **WAF:** $5 web ACL + 2 rules ($2), e.g. a rate-based rule and an IP allowlist, plus 500 req/s x 2,628,000 s = 1.31 billion requests x $0.60 per million: **$795**. Managed rule groups cost extra. Above a few hundred req/s, the WAF request fee is the second-largest line.
- **Total:** **$2,794**. Compute, storage, CloudWatch and IPv4 from the typical table come on top.

What this means:
- With RPC kept in the VPC and same AZ, a busy node's egress is ~$557/month, about half the compute cost. Exposed to the internet, the same load costs ~$2,794/month, about 2.5x compute.
- Streaming clients that negotiate zstd use ~4x less bandwidth than uncompressed ones (0.79 vs 3.24 TB/month each).
- Bandwidth: average outbound is ~65 Mbit/s busy and ~200 Mbit/s very busy, but chain data bursts to ~4x the median. Plan for several hundred Mbit/s at peak, plus catch-up after downtime.
- Limits of this estimate: peer counts and request rates are assumptions; the per-unit sizes are measured. The P2P wire factor uses protobuf as a stand-in for BCS. The ~4 KiB point read is an average, and list and streaming calls are much larger. Replace the assumptions with a week of `NetworkOut` data split by port (8084/udp for P2P, 9000/tcp for RPC).

#### Instance store vs EBS (long-term)

The workflow asks for this comparison for long-term deployments. Savings Plans discount compute only. EBS is always billed at the on-demand rate. Monthly compute plus data storage, us-east-1, retrieved 2026-11-02 (point in time):

| Option | On-demand | 1-yr EC2 Instance SP, No Upfront | 3-yr EC2 Instance SP, No Upfront |
|---|---|---|---|
| `i7i.4xlarge` + 3,750 GB instance store | $1,102.37 | $715.33 | $509.91 |
| `i8g.4xlarge` + 3,750 GB instance store | $1,002.14 | $649.77 | $463.33 |
| `r7i.4xlarge` + 4,000 GB gp3 (16,000 IOPS, 1,000 MiB/s) | $1,192.63 | $931.09 | $770.47 |
| `r8g.4xlarge` + 4,000 GB gp3 (16,000 IOPS, 1,000 MiB/s) | $1,108.07 | $875.15 | $732.11 |
| `r7i.4xlarge` + 4,000 GB io2 (16,000 IOPS) | $2,312.63 | $2,051.09 | $1,890.47 |

Instance store is the cheapest option on-demand, and the gap widens with Savings Plans, because the whole instance-store price is discountable while the $420–$1,540/month of EBS is not. EBS keeps data across stop/start.

## Setup Instructions

> For general Node Runners setup (cloning, `npm install`, CDK bootstrap), see [Getting Started](https://aws-samples.github.io/aws-blockchain-node-runners/docs/getting-started/quickstart).

### Option 1: AI-Driven Deployment (Recommended)

Install the blueprint into your Node Runners checkout, then run this in Kiro (or your AI assistant of choice):

```bash
npm install github:intersection56/aws-bnr-blueprint-sui --legacy-peer-deps
```

```
@deploy using sui blueprint on testnet
```

On first use of a community blueprint, the AI workflow runs an automated security review of its scripts before deploying.

### Option 2: Manual Deployment

#### Prerequisites

1. AWS CLI configured with appropriate credentials
2. Node.js 18+ and npm installed
3. A checkout of [aws-blockchain-node-runners](https://github.com/aws-samples/aws-blockchain-node-runners) with `npm install` completed
4. CDK bootstrapped in your target region

**Tip**: Use [AWS CloudShell](https://docs.aws.amazon.com/cloudshell/latest/userguide/welcome.html) for a pre-configured environment with all tools ready.

Install this blueprint (the `--legacy-peer-deps` flag is required because the Node Runners framework is not published to npm):

```bash
npm install github:intersection56/aws-bnr-blueprint-sui --legacy-peer-deps
# or, from a local clone:
npm install /path/to/aws-bnr-blueprint-sui --legacy-peer-deps --install-links
```

#### Step 1: Configure Environment

```bash
# Mainnet, single node (x86_64)
cp node_modules/aws-bnr-blueprint-sui/samples/.env-mainnet-sui-node-full .env

# Mainnet, single node (Graviton)
cp node_modules/aws-bnr-blueprint-sui/samples/.env-mainnet-sui-node-full-arm64 .env

# Mainnet, HA (3 nodes, recommended for production)
cp node_modules/aws-bnr-blueprint-sui/samples/.env-mainnet-sui-node-full-ha .env

# Testnet, single node
cp node_modules/aws-bnr-blueprint-sui/samples/.env-testnet-sui-node-full .env

# Testnet, HA (3 nodes)
cp node_modules/aws-bnr-blueprint-sui/samples/.env-testnet-sui-node-full-ha .env
```

Edit `.env` with your AWS account details:

```bash
AWS_ACCOUNT_ID="your-account-id"
AWS_REGION="us-east-1"
```

#### Step 2: Choose Configuration

`CLIENT_CONFIG` selects the sui-node release. Keep the value from the sample for your network; the release must exist for `BC_NETWORK`:

```bash
# mainnet
BC_NETWORK="mainnet"
CLIENT_CONFIG="sui-node-v1.83.1-full.sh"

# testnet
BC_NETWORK="testnet"
CLIENT_CONFIG="sui-node-v1.83.1-full.sh"
```

#### Step 3: Deploy

```bash
# Bootstrap CDK (first time only)
npx cdk bootstrap

# Deploy the stack
npx cdk deploy --json --outputs-file deploy-output.json
```

**AI Alternative**: run `@deploy using sui blueprint on mainnet` to have the AI workflow choose a sample, deploy, and run an initial health check.

For advanced options (HA mode, multiple stacks, maintenance), see the [Deployment Guide](https://aws-samples.github.io/aws-blockchain-node-runners/docs/guides/deployment-guide).

#### Step 4: Monitor Deployment

`cdk deploy` returns before node setup finishes. Setup downloads the ~1.2 GB release archive, restores the latest formal snapshot, and then the node builds its gRPC indexes on first start. Measured on testnet with `i7i.4xlarge` (2026-11-03):

| Phase | Testnet duration |
|---|---|
| `cdk deploy` | ~4 min |
| Release download and checksum | ~30 s |
| Formal snapshot download (~105 GB) | ~6 min |
| Snapshot verification and restore | ~1h40m |
| gRPC index build (RPC and P2P ports closed until it finishes) | ~1h50m |
| Catch-up to the chain tip | a few minutes |
| **Deploy to healthy** | **~3h40m** |

Mainnet has not been measured. Its database is several times larger (~2.5 TB for a pruned node with indexes, per Sui, Nov 2025, against ~0.4 TB on testnet), so expect a substantially longer bootstrap. A failed restore attempt adds its own duration again: each retry starts the download over.

```bash
DASHBOARD_NAME=$(cat deploy-output.json | jq -r '..|.DashboardName? | select(. != null)')
echo "Dashboard: https://console.aws.amazon.com/cloudwatch/home?region=$AWS_REGION#dashboards:name=$DASHBOARD_NAME"
```

Key metrics (namespace `CWAgent`):
- **c1_block_height**: last executed checkpoint
- **c1_blocks_behind**: `highest_known_checkpoint - last_executed_checkpoint` (should fall to near 0)
- **c1_seconds_behind**: age of the last executed checkpoint in seconds (extra metric published by this blueprint)
- **System metrics**: CPU, memory, disk usage

#### Step 5: Verify Node Operation

```bash
INSTANCE_ID=$(cat deploy-output.json | jq -r '..|.InstanceId? | select(. != null)')
aws ssm start-session --target $INSTANCE_ID --region $AWS_REGION

# On the instance:
sudo systemctl status node
sudo journalctl -u node -f

# Sync progress (metrics are bound to localhost)
curl -s http://127.0.0.1:9184/metrics | grep -E '^(highest_known_checkpoint|highest_synced_checkpoint|last_executed_checkpoint|current_epoch) '

# Chain identity and version
curl -s http://127.0.0.1:9184/metrics | grep '^uptime'

# Health: 200 once synced and indexed. threshold_seconds also fails the
# check when the last executed checkpoint is older than N seconds.
INTERNAL_IP=$(hostname -I | awk '{print $1}')
curl -i "http://$INTERNAL_IP:9000/health?threshold_seconds=60"
```

From another host in the VPC with [grpcurl](https://github.com/fullstorydev/grpcurl):

```bash
grpcurl -plaintext <node-internal-ip>:9000 sui.rpc.v2.LedgerService/GetServiceInfo
grpcurl -plaintext <node-internal-ip>:9000 sui.rpc.v2.LedgerService/GetCheckpoint
```

## Configuration Options

### Sui Protocol Variables

| Variable | Description | Default |
|---|---|---|
| `SUI_ENABLE_INDEXING` | `rpc.enable-indexing`: build gRPC indexes (owned objects, balances, ledger history). `true`/`false` | `true` |
| `SUI_NUM_EPOCHS_TO_RETAIN` | Epochs of historical object versions to keep (`0` = aggressive pruning, only for nodes that serve no reads) | `5` |
| `SUI_NUM_EPOCHS_TO_RETAIN_FOR_CHECKPOINTS` | Epochs of transactions, effects and events to keep (min `2`) | `2` |
| `SUI_ARCHIVE_FALLBACK` | `auto`: on for testnet, off for mainnet. `true` on mainnet enables the Requester Pays S3 archive. `false` disables it. | `auto` |
| `SUI_RUST_LOG` | `RUST_LOG` filter for sui-node | `info` |
| `SUI_SNAPSHOT_MAX_RETRIES` | `sui-tool --max-retries`: retries per failed HTTP request during the snapshot restore | `10` |
| `SUI_SNAPSHOT_PARALLEL_DOWNLOADS` | `sui-tool --num-parallel-downloads` (1-200). Lower it if restores time out against Sui's public endpoints | `50` |
| `SUI_ALLOW_DOWNGRADE` | Never-downgrade safeguard. `false`: when setup re-runs after an [in-place upgrade](#single-node-in-place-upgrade), keep the newer installed release for the same network. `true`: install exactly `CLIENT_CONFIG`, to roll back on purpose | `false` |

Numeric and boolean values are validated at setup. Invalid values fail the setup instead of being written to `fullnode.yaml`.

### Snapshot

`SNAPSHOT_ENABLED="true"` (default) restores the latest formal snapshot with:

```
sui-tool download-formal-snapshot --latest --network <network> --genesis <genesis.blob> \
  --path /data/sui/db --num-parallel-downloads 50 --no-sign-request
```

This uses Mysten Labs' free endpoints (`https://formal-snapshot.<network>.sui.io`, hosted in North America) and verifies the restored state against the committee's end-of-epoch commitment. The restore is skipped whenever `/data/sui/db/live` already exists. Formal snapshots hold only the live object set, so the node has no transaction history from before the snapshot epoch. For older history, use Sui's Archival Service or an indexer.

### Mainnet archival fallback (optional)

Archival fallback lets a node that fell behind its peers' retention fetch missing checkpoints from an archive. On mainnet the archive is a **Requester Pays** S3 bucket (`mysten-mainnet-checkpoints`, us-west-2): your account pays the egress, and the instance role needs `s3:GetObject` on `arn:aws:s3:::mysten-mainnet-checkpoints/*`. The framework does not grant this permission. Add it to the instance role yourself before you set `SUI_ARCHIVE_FALLBACK="true"`.

## Troubleshooting

### Node Not Starting

1. **View node service logs in CloudWatch**:
   ```bash
   aws logs tail /aws/ec2/blockchain-nodes/systemd-services --follow --filter-pattern "node.service"

   export INSTANCE_ID=$(cat deploy-output.json | jq -r '..|.InstanceId? | select(. != null)')
   aws logs tail /aws/ec2/blockchain-nodes/systemd-services --follow --log-stream-names $INSTANCE_ID --filter-pattern "node.service"
   ```

2. **Check setup (binary download, snapshot restore)**:
   ```bash
   aws logs tail /aws/ec2/blockchain-nodes/cloud-init-output --follow --log-stream-names $INSTANCE_ID
   # Filter for blueprint steps:
   aws logs tail /aws/ec2/blockchain-nodes/cloud-init-output --log-stream-names $INSTANCE_ID \
     --filter-pattern '?"[install-sui]" ?"[sui-config]" ?"[sui-snapshot]"'
   ```

3. **If CloudWatch logs are not available, connect via SSM**:
   ```bash
   aws ssm start-session --target $INSTANCE_ID --region $AWS_REGION
   sudo systemctl status node
   sudo journalctl -u node -n 200 --no-pager
   sudo cat /home/bcuser/sui-config/fullnode.yaml
   ```

Common causes:

| Symptom | Cause | Fix |
|---|---|---|
| `release <network>-vX.Y.Z not found` | `CLIENT_CONFIG` version does not exist for `BC_NETWORK` | Use the configuration that matches the network (see [Supported Configurations](#supported-configurations)) |
| `checksum mismatch` | Corrupted download or tampered asset | Redeploy. If it persists, check the release on GitHub. |
| `genesis.blob checksum does not match` | Network was re-genesised (testnet) or the download was corrupted | Update the pinned checksum in `install-sui-binaries.sh` after verifying the new genesis upstream |
| `formal snapshot restore failed` | Endpoint unreachable or out of disk | Check outbound internet access and `df -h /data`. Setup retries on the next boot. |
| `Snapshot restore attempt N failed` after `Error performing GET https://checkpoints.<network>.sui.io/... operation timed out` | Requests to Sui's public checkpoint endpoint timing out. In testing this happened while traffic shaping was on during bootstrap | The blueprint now keeps shaping off during bootstrap. Each failed attempt re-downloads the snapshot, so check `systemctl is-active net-rules.service` (should be `inactive` until setup completes). If it persists, set `SUI_SNAPSHOT_PARALLEL_DOWNLOADS` lower (e.g. `20`) and redeploy |
| Node behind after restart | Catching up from the last executed checkpoint | Wait, or stop the node, remove `/data/sui/db` and redeploy to restore a fresh snapshot |
| `Address already in use` | Another process on 9000/9184/8084 | Find it with `sudo ss -lntup` |

**Solution**: Fix the specific issue and restart the service:
```bash
aws ssm start-session --target $INSTANCE_ID --region $AWS_REGION
sudo systemctl restart node
sudo systemctl status node
```

### Metrics Not Appearing

```bash
aws logs tail /aws/ec2/blockchain-nodes/systemd-services --follow --log-stream-names $INSTANCE_ID --filter-pattern "syncchecker"

# On the instance
sudo systemctl status syncchecker.timer
sudo journalctl -u syncchecker.service -n 50
sudo systemctl status amazon-cloudwatch-agent
```

`c1_*` metrics stay at 0 until `/data/init-completed` exists and sui-node exposes metrics on `127.0.0.1:9184`.

### Lag alarm

Plain `/health` does not detect a node that has stopped following the chain (see [High Availability (HA) Deployment](#high-availability-ha-deployment)), so create a CloudWatch alarm on how far behind the nodes are. Every node publishes `c1_seconds_behind` with a `StackName` dimension as well as per instance, so **one alarm per stack covers every node**, including HA replacements. Nodes only publish it once they are serving, so a node that is still bootstrapping doesn't trigger it.

```bash
STACK_NAME="sui-mainnet-sui-node-v-full"   # the CloudFormation stack name: sui-<network>-sui-node-v-full, with STACK_NAME_PREFIX- in front if set
TOPIC_ARN="arn:aws:sns:$AWS_REGION:$AWS_ACCOUNT_ID:your-alerts-topic"

aws cloudwatch put-metric-alarm --region "$AWS_REGION" \
  --alarm-name "$STACK_NAME-sui-seconds-behind" \
  --alarm-description "A Sui node is more than 60 s behind the chain for 5 minutes" \
  --namespace CWAgent --metric-name c1_seconds_behind \
  --dimensions Name=StackName,Value="$STACK_NAME" \
  --statistic Maximum --period 60 --evaluation-periods 5 \
  --threshold 60 --comparison-operator GreaterThanThreshold \
  --treat-missing-data notBreaching \
  --alarm-actions "$TOPIC_ARN" --ok-actions "$TOPIC_ARN"
```

- **When it fires on one node:** check that node's per-instance `c1_seconds_behind` and its logs (see [Node Not Starting](#node-not-starting)). In HA, you can take a stuck node out of rotation by deregistering it from the target group, or restart `node.service`.
- **When it fires on every node at once:** check [status.sui.io](https://status.sui.io/) for a network halt before changing anything. Replacing nodes during a halt only adds bootstrap time.
- `--treat-missing-data notBreaching` keeps it quiet while nodes bootstrap. It also means a node that stops publishing entirely doesn't trigger this alarm; in HA, alarm on the target group's `UnHealthyHostCount` for that case.
- The alarm costs $0.10/month; the stack-level metric adds $0.30/month.

### Health Check Failures (HA)

```bash
NODE_INTERNAL_IP=$(aws ec2 describe-instances --instance-ids $INSTANCE_ID \
    --query 'Reservations[*].Instances[*].PrivateIpAddress' --output text)

# From within the VPC (body explains the failure)
curl -i http://$NODE_INTERNAL_IP:9000/health
```

`/health` returns an error while the node has no executed checkpoint or while its live-object indexes trail the executed tip by more than 60 checkpoints, for example during the initial index build. **When the grace period ends, the Auto Scaling group replaces any node that is still unhealthy, and the replacement starts its bootstrap from scratch.** If nodes are replaced before they finish bootstrapping, raise `HA_ALB_HEALTHCHECK_GRACE_PERIOD_MIN`. The HA sample uses 1,440 minutes (24 h), because mainnet bootstrap time is not yet measured. Alternatively, suspend replacement until the nodes serve, then resume it:

```bash
ASG=$(aws autoscaling describe-auto-scaling-groups --query "AutoScalingGroups[?contains(AutoScalingGroupName, 'sui')].AutoScalingGroupName" --output text)
aws autoscaling suspend-processes --auto-scaling-group-name "$ASG" --scaling-processes ReplaceUnhealthy
# ...once every node returns /health 200:
aws autoscaling resume-processes --auto-scaling-group-name "$ASG" --scaling-processes ReplaceUnhealthy
```

The lifecycle-hook timeout (`HA_NODES_HEARTBEAT_DELAY_MIN`) is not a constraint: the framework completes the hook early in setup, before the snapshot restore.

For more detailed troubleshooting, see the [Troubleshooting Guide](https://aws-samples.github.io/aws-blockchain-node-runners/docs/guides/troubleshooting).

## Upgrades

Sui ships testnet releases every Tuesday and mainnet releases every second Wednesday. A release that contains a protocol change must be installed **before** the change takes effect, or the node cannot follow the chain ([Updating a full node](https://docs.sui.io/operators/full-node/updates)). Plan to apply every release for your network; the [release watch](#maintenance) opens an issue for each one.

How you upgrade depends on the deployment mode (ADR-0022):

| Mode | How | Downtime |
|---|---|---|
| Single node | **In place over SSM** with `scripts/upgrade-in-place.sh`, then bring the stack in line at a planned window | Minutes (sui-node restarts and catches up) |
| HA | `scripts/bump.sh` and a **rolling** `cdk deploy` | None if all goes well; capacity is reduced while each node rebuilds |

A `cdk deploy` that changes the version always stops and starts single-node instances (CloudFormation applies a user-data change that way). With instance store, that empties `/data`, and the node restores a fresh snapshot: in the testnet redeploy test (2026-11-03) it was healthy again **3h43m** later. That is why single nodes upgrade in place.

### Single node: in-place upgrade

```bash
# 1. Check the release, then upgrade the running node (asks for confirmation)
scripts/upgrade-in-place.sh --instance-id $INSTANCE_ID --version v1.84.0 --region $AWS_REGION --dry-run
scripts/upgrade-in-place.sh --instance-id $INSTANCE_ID --version v1.84.0 --region $AWS_REGION

# 2. At the next planned window: bring the stack in line with the node
scripts/bump.sh mainnet v1.84.0      # or testnet
scripts/validate.sh
npx cdk deploy --json --outputs-file deploy-output.json   # stops/starts the instance
```

The script refuses HA instances and downgrades. It reads the node's network and installed release over SSM, checks that the release is published with SHA-256 digests for both architectures, then runs the blueprint's own installer on the instance (the same checksum verification as a deploy), restarts `node.service`, and waits up to 20 minutes for `/health?threshold_seconds=120` to return 200. It needs `ssm:SendCommand`, `ssm:GetCommandInvocation` and `ec2:DescribeInstances`.

**Never-downgrade safeguard.** After an in-place upgrade, the stack still names the older version. If setup re-runs before you redeploy (a stop/start, EC2 host maintenance or retirement), the installer sees that a newer release for the same network is installed and **keeps it** rather than reinstalling the older one, logging a warning. An older sui-node might not follow the chain after a protocol upgrade. To roll back on purpose, use `scripts/upgrade-in-place.sh ... --allow-downgrade`, or set `SUI_ALLOW_DOWNGRADE="true"` in `.env` and redeploy.

Before upgrading, read the [release notes](https://github.com/MystenLabs/sui/releases) for `fullnode.yaml` changes. An in-place upgrade replaces binaries only; configuration or blueprint changes need a redeploy.

### HA: rolling redeploy

1. Run `scripts/bump.sh <network> <version>` (see [Maintenance](#maintenance)). It adds the configuration file for the new release, points that network's samples at it and updates `package.json`. The version comes from the file name, and the release tag is `<network>-<version>`.
2. Check the [release notes](https://github.com/MystenLabs/sui/releases) for `fullnode.yaml` changes and update `user-data/common/write-fullnode-config.sh` if needed.
3. Set `CLIENT_CONFIG` in `.env` and redeploy: `npx cdk deploy --json --outputs-file deploy-output.json`.

HA instances are replaced one at a time, keeping at least one in service. New instances start empty, restore a snapshot and build indexes before they pass the ALB health check, which takes hours (see Step 4). With 3 nodes, 2 keep serving during each node's rebuild; with 2 nodes, one serves alone. A replacement node also has no transaction history before its snapshot epoch for about 2 days (see [What HA gives you](#what-ha-gives-you-and-what-it-doesnt)). Don't use `upgrade-in-place.sh` on HA nodes: the Auto Scaling group launches replacements from the stack's version. Stopping an instance in the group gets it replaced, not restarted. See the [Deployment Guide](https://aws-samples.github.io/aws-blockchain-node-runners/docs/guides/deployment-guide#ha-deployments-rolling-updates).

A plain reboot keeps instance-store data; in the reboot test the node was serving again within ~3 minutes. With EBS storage, a redeploy reuses the existing database. See [How a redeploy applies changes](https://aws-samples.github.io/aws-blockchain-node-runners/docs/guides/deployment-guide#how-a-redeploy-applies-changes-single-node).

## Cost Optimization

Approximate us-east-1 on-demand prices. These are **point-in-time** values from the AWS Price List API, retrieved 2026-11-02 (published 2026-10-29), using 730 h/month:

| Instance | $/hour | ~$/month |
|---|---|---|
| `i7i.4xlarge` (mainnet/testnet x86_64, default) | 1.5101 | ~1,102 |
| `i8g.4xlarge` (mainnet ARM_64) | 1.3728 | ~1,002 |
| `i7i.8xlarge` (x86_64, 7,500 GB /data upgrade) | 3.0202 | ~2,205 |
| `i8g.8xlarge` (ARM_64, 7,500 GB /data upgrade) | 2.7456 | ~2,004 |

Same source and method as the [Avalanche community blueprint](https://github.com/karimakacem/aws-bnr-blueprint-avalanche)'s price table (us-east-1, on-demand, 730 h). The API returned exactly Avalanche's published rates for its instance types, so the two blueprints' figures can be compared directly: `i7i.xlarge` $0.3775/h (~$276), `i7i.2xlarge` $0.755/h (~$551), `i8g.2xlarge` $0.6864/h (~$501). Sui's `.4xlarge` sizes are exactly 2x the Avalanche `.2xlarge` rates.

### Storage Optimization

- **Storage:** the instance store is included in the instance price. There is no separate EBS data-volume charge, only the 80 GB root volume ($6.40/month, as of 2026-11-02). An equivalent 4,000 GB EBS data volume adds $420/month (gp3) to $1,540/month (io2). See [Instance store vs EBS](#instance-store-vs-ebs-long-term).
- Keep the RPC pruning profile, and lower `SUI_NUM_EPOCHS_TO_RETAIN` if you don't need historical object versions. Moving to a `.8xlarge` for disk space doubles compute cost, so check the disk growth trend first.

### Compute Optimization

- **Compute:** the Graviton `i8g.4xlarge` costs ~9% less than `i7i.4xlarge` for the same vCPU, RAM and disk. That is the same ~9% Avalanche reports for `i8g.2xlarge` vs `i7i.2xlarge`. Savings Plans lower both further. Savings Plans rates for us-east-1, No Upfront, retrieved 2026-11-02 (point in time):

  | Instance | 1-yr Compute SP | 3-yr Compute SP | 1-yr EC2 Instance SP | 3-yr EC2 Instance SP |
  |---|---|---|---|---|
  | `i7i.4xlarge` | $1.1759/h (−22%) | $0.8383/h (−44%) | $0.9799/h (−35%) | $0.6985/h (−54%) |
  | `i8g.4xlarge` | $1.0680/h (−22%) | $0.7615/h (−45%) | $0.8901/h (−35%) | $0.6347/h (−54%) |

- A stopped testnet node stops compute charges; the root EBS volume is still billed. On instance store it restores a snapshot on the next start.

### AWS vs bare metal

For comparison, list prices checked on 2026-11-05 for 3 servers close to Sui's minimum (16 cores, 128 GB RAM, ~4 TB NVMe). Point-in-time; check current prices.

| Option (3 nodes) | Per month | Egress | Notes |
|---|---|---|---|
| This blueprint, HA, `i7i.4xlarge` | ~$4,830 on-demand; ~$3,050 with a 3-year EC2 Instance Savings Plan | Billed per GB (~$1,260 of the total) | 3 Availability Zones, automated replacement |
| Rented bare metal, for example [Latitude.sh](https://www.latitude.sh/pricing) `m4.metal.medium` | ~$1,370 | 20 TB/month per server included | 16 physical cores per server; you build the deployment tooling |
| [Hetzner AX102](https://www.hetzner.com/dedicated-rootserver/ax102/) | ~EUR 777 + EUR 387 setup | Unlimited at 1 Gbit/s | Germany and Finland only; Hetzner [cut off Solana nodes in 2022](https://www.cherryservers.com/blog/does-hetzner-accept-crypto) under its terms |

Bare metal is cheaper because bandwidth is included and you get more physical cores for the money, and its local disks keep their data across reboots and upgrades. This blueprint doesn't run there: it depends on CDK, CloudFormation, Auto Scaling, the load balancer, SSM and CloudWatch. Running nodes next to the applications that use them is the usual reason operators pay for AWS (see [When to use this blueprint](#when-to-use-this-blueprint)). Confirm in writing that any host allows blockchain nodes before relying on it. The [AWS Acceptable Use Policy](https://aws.amazon.com/aup/) doesn't prohibit them.

### Network Optimization

- **Network:** P2P traffic on 8084/udp is billed as data transfer out to the internet ($0.09/GB for the first 10 TB after the 100 GB account-wide free tier, us-east-1, as of 2026-11-02). Each peer syncing from a mainnet node adds ~1.26 TB/month (~$113), measured 2026-11-02. Keep the ALB internal unless you must expose RPC publicly.
- **Client placement is the biggest lever.** For a busy node, RPC in the same VPC and AZ costs ~$557/month in egress, other AZs ~$859 and the internet (ALB + WAF) ~$2,794. See [Busy RPC node](#busy-rpc-node-egress-and-network-services).
- Ask streaming gRPC clients to accept zstd compression. Each full-checkpoint stream drops from ~3.24 to ~0.79 TB/month.
- Measure `NetworkOut` during the first week. The default 40 Mbit/s shaping limit is above even 10 peers (~38 Mbit/s), so it only caps the worst case (~13.1 TB, ~$1,160/month). Set `TRAFFIC_SHAPING_RATE_MBIT` to 10–20 to cut P2P cost, accepting slower service to syncing peers.
- If RPC is internet-facing, WAF request fees ($0.60 per million) become significant above a few hundred req/s. Keep heavy internal consumers on the private path.
- Leave mainnet archival fallback off unless you need it. It is Requester Pays.
- CloudWatch is ~6% of the estimate. To lower it, set `SUI_RUST_LOG="warn"` to cut log ingestion.

## Security Considerations

- **RPC is VPC-only.** sui-node binds RPC to the instance's internal IP (`json-rpc-address: <internal-ip>:9000`) and the security group allows 9000/tcp only from the VPC CIDR. The RPC has no authentication of its own. Don't expose it to the internet directly. If you must, use the HA ALB with `HA_ALB_INTERNET_FACING`, a restrictive `HA_ALB_ALLOWED_CIDR` and an ACM certificate, and add rate limiting (e.g. AWS WAF).
- **Only P2P is public.** 8084/udp is open to the internet because Sui peering requires it.
- **Metrics and admin are host-local.** Prometheus binds to `127.0.0.1:9184` (Sui's default is `0.0.0.0`). The admin API, which has no auth, stays on `127.0.0.1:1337`. Neither port is opened in the security group.
- **Supply chain.** The release archive is checked against the SHA-256 digest GitHub publishes for the asset, and the blueprint fails closed if the digest is missing. `genesis.blob` is pinned by SHA-256. The formal snapshot is verified by `sui-tool` against the validator committee's commitment.
- **Least privilege.** sui-node and sui-tool run as `bcuser`, not root, with `NoNewPrivileges=true`.
- **No secrets.** A full node holds no funds or validator keys. `fullnode.yaml` contains no credentials. Mainnet archival fallback uses the instance role, never access keys.
- No SSH. Use AWS Systems Manager Session Manager.

## FAQ

**Q: Can this run a Sui validator?**

A: No. This blueprint deploys RPC full nodes only. Validators need consensus keys, staking and a different configuration.

**Q: Does it serve JSON-RPC?**

A: No. Sui has deprecated JSON-RPC, and port 9000 on this release serves gRPC, gRPC-Web and `/health`. Migrate clients to gRPC (see Sui's data serving roadmap).

**Q: Can I query transactions from before the node was deployed?**

A: Only within the retention window, and only from the snapshot epoch onward. Formal snapshots don't include history. For older data, use Sui's Archival Service or an indexer.

**Q: Why does each network need its own configuration file?**

A: MystenLabs publishes per-network release binaries (`mainnet-vX`, `testnet-vX`). Testnet usually runs a newer version than mainnet.

**Q: Why instance store if data is lost on stop?**

A: Sui is I/O-heavy and produces several checkpoints per second. Local NVMe gives the best performance at no extra storage cost, and the node rebuilds itself automatically from a verified snapshot. Choose EBS if you need data to survive stop/start.

**Q: Is devnet supported?**

A: No. Devnet is wiped regularly, which would invalidate the pinned genesis checksum.

## Additional Resources

- [Sui Full Node Configuration](https://docs.sui.io/operators/full-node/sui-full-node)
- [Sui Database Snapshots](https://docs.sui.io/operators/snapshots)
- [Sui Data Management (pruning)](https://docs.sui.io/operators/data-management/managing-data)
- [Sui Available Data Stores](https://docs.sui.io/operators/data-management/available-data-stores)
- [Sui Node Monitoring](https://docs.sui.io/operators/full-node/monitoring)
- [Sui releases](https://github.com/MystenLabs/sui/releases)
- Cost estimate sources:
  - [Sui mainnet checkpoint archive](https://checkpoints.mainnet.sui.io/epochs.json) and [testnet archive](https://checkpoints.testnet.sui.io/epochs.json): the measured traffic data
  - [Sui storage figures (Nov 2025)](https://docs.sui.io/concepts/sui-architecture/sui-storage)
  - [Sui RPC best practices (public endpoint rate limits)](https://docs.sui.io/references/sui-api/rpc-best-practices)
  - Sui source, v1.82.3: [`crates/sui-network/build.rs`](https://github.com/MystenLabs/sui/blob/mainnet-v1.82.3/crates/sui-network/build.rs) (state sync codec) and [`crates/sui-config/src/p2p.rs`](https://github.com/MystenLabs/sui/blob/mainnet-v1.82.3/crates/sui-config/src/p2p.rs) (peer defaults)
  - [AWS Price List API](https://docs.aws.amazon.com/awsaccountbilling/latest/aboutv2/price-changes.html), [Savings Plans offering rates API](https://docs.aws.amazon.com/savingsplans/latest/APIReference/API_DescribeSavingsPlansOfferingRates.html) and [AWS Pricing Calculator](https://calculator.aws/)
- [Node Runners Configuration Reference](https://aws-samples.github.io/aws-blockchain-node-runners/docs/guides/configuration-reference)
- [Node Runners Deployment Guide](https://aws-samples.github.io/aws-blockchain-node-runners/docs/guides/deployment-guide)

## Support

- **Blueprint issues** (install, configuration, scripts, samples): open an issue in this blueprint's GitHub repository. This is a community blueprint, so please don't file its issues in the Node Runners repository.
- **Node Runners framework** (CDK stacks, `cdk deploy`, HA infrastructure): see the [Troubleshooting Guide](https://aws-samples.github.io/aws-blockchain-node-runners/docs/guides/troubleshooting) and [Configuration Reference](https://aws-samples.github.io/aws-blockchain-node-runners/docs/guides/configuration-reference), then the [aws-blockchain-node-runners repository](https://github.com/aws-samples/aws-blockchain-node-runners/issues).
- **Sui protocol and `sui-node`**: see the [Sui documentation](https://docs.sui.io) and the [Sui repository](https://github.com/MystenLabs/sui/issues).

## Maintenance

Sui ships new releases on a fixed schedule, **separately for each network**: testnet every Tuesday and mainnet every second Wednesday ([Updating a full node](https://docs.sui.io/operators/full-node/updates)), and a node that falls too far behind can stop following the chain when the protocol version moves. This blueprint pins one release per network (see [Available Configurations](#available-configurations)).

A daily `release-watch` workflow compares each network's pinned version with the latest `mainnet-v*` and `testnet-v*` releases from MystenLabs, and opens one issue per new release. To move a network to a new release:

```bash
scripts/bump.sh --show                     # pinned version per network, and the latest release
scripts/bump.sh mainnet v1.84.0            # or: testnet v1.84.0
scripts/validate.sh                        # tests + cdk synth of every sample
```

`bump.sh` checks that the release exists with SHA-256 digests for both architectures, adds or renames the configuration file, repoints that network's samples, rebuilds `availableConfigurations` in `package.json`, and removes configuration files that no sample uses anymore. It commits nothing. It lists any remaining mentions of the old version (README tables, docs) for you to update by hand. Before bumping, read the release notes for `fullnode.yaml` or `sui-tool` changes.

`scripts/validate.sh` installs this blueprint into a clean Node Runners checkout, runs the integration tests, and synthesizes every sample. CI runs it on every push and weekly against Node Runners `main`.
