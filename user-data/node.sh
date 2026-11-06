#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Sui full node initialization script (protocol level).
#
# Handles directories, ownership and the "node" systemd service, and delegates
# all client-specific work (binary download, genesis, fullnode.yaml, snapshot
# restore, runtime flags) to the configuration script named by CLIENT_CONFIG:
#   "<config> install" - during setup (this script, as root)
#   "<config>"         - at runtime, as /home/bcuser/bin/start-node.sh (bcuser)
#
# Re-run contract: the framework runs this on first boot AND on every redeploy
# that changes the configuration, against the existing /data with node.service
# already stopped. Everything below is idempotent: binaries and fullnode.yaml
# are replaced, the snapshot restore is skipped when a database exists, and
# chain data is never deleted.

set -euo pipefail

echo "Starting Sui full node setup..."

# shellcheck disable=SC1091  # written by the framework at boot
source /etc/cdk_environment

if [ -z "${BC_NETWORK:-}" ]; then
    echo "ERROR: BC_NETWORK is not set" >&2
    exit 1
fi
if [ -z "${CLIENT_CONFIG:-}" ]; then
    echo "ERROR: CLIENT_CONFIG is not set" >&2
    exit 1
fi
case "$BC_NETWORK" in
    mainnet|testnet) ;;
    *) echo "ERROR: unsupported BC_NETWORK '$BC_NETWORK' (expected 'mainnet' or 'testnet')" >&2; exit 1 ;;
esac

CONFIG_SCRIPT="/opt/blueprints/configurations/${CLIENT_CONFIG}"
if [ ! -f "$CONFIG_SCRIPT" ]; then
    echo "ERROR: configuration script not found: $CONFIG_SCRIPT" >&2
    echo "Available configurations:" >&2
    ls -la /opt/blueprints/configurations/ >&2 || true
    exit 1
fi

echo "Network: $BC_NETWORK"
echo "Client configuration: $CLIENT_CONFIG"

# Directory layout
mkdir -p /data/sui /home/bcuser/bin /home/bcuser/sui-config

# The framework starts traffic shaping (net-rules.service) during setup, before
# this script runs. Keep it off while bootstrapping: the snapshot restore makes
# many parallel requests to Sui's public endpoints and timed out with shaping on
# (test of 2026-11-03). syncchecker.sh re-enables it once the node is in sync.
systemctl stop net-rules.service 2>/dev/null || true

# Client install phase (binaries, genesis, fullnode.yaml, snapshot)
chmod +x "$CONFIG_SCRIPT"
"$CONFIG_SCRIPT" install

# Ownership: bcuser runs the node and owns its data
chown -R bcuser:bcuser /data/sui /home/bcuser

# Install the configuration script as the service entrypoint (replaced on
# every run so a changed CLIENT_CONFIG takes effect)
install -m 0755 -o bcuser -g bcuser "$CONFIG_SCRIPT" /home/bcuser/bin/start-node.sh
echo "Configuration script installed: $CLIENT_CONFIG"

# systemd service - name MUST be "node". sui-node keeps many RocksDB files and
# peer connections open, hence the high nofile limit. TimeoutStopSec gives
# RocksDB time to flush on shutdown.
cat > /etc/systemd/system/node.service <<'EOF'
[Unit]
Description=Sui Full Node
After=network-online.target
Wants=network-online.target
# Start only once the framework's /data filesystem is mounted.
# - RequiresMountsFor orders the service after the /data mount and requires it.
#   The framework's fstab entry is `nofail`, which on its own does not order the
#   mount before services, so without this the node can start before /data on a
#   plain reboot.
# - After a stop/start the instance store is blank, the fstab device never
#   appears and the mount fails; the service is then not started (no crash loop,
#   observed in the 2026-11-03 redeploy test) until setup rebuilds /data and
#   node.sh starts it.
# - ConditionPathIsMountPoint is a second guard against running on the root disk.
RequiresMountsFor=/data
ConditionPathIsMountPoint=/data

[Service]
Type=simple
User=bcuser
Group=bcuser
Restart=always
RestartSec=30
TimeoutStopSec=300
LimitNOFILE=1048576
Environment="PATH=/usr/local/bin:/usr/bin:/bin:/home/bcuser/bin"
EnvironmentFile=/etc/cdk_environment
ExecStart=/home/bcuser/bin/start-node.sh
StandardOutput=journal
StandardError=journal
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable node.service
systemctl restart node.service

echo "Waiting for sui-node to start..."
sleep 15
if ! systemctl is-active --quiet node.service; then
    echo "ERROR: node.service is not running" >&2
    journalctl -u node.service --no-pager -n 50 >&2 || true
    exit 1
fi

touch /data/init-completed
echo "Sui full node setup completed successfully"
