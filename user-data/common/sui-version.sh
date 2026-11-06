#!/bin/bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Version helpers for install-sui-binaries.sh (sourced, not run). Kept free of
# side effects so they can be tested on their own.
#
# The installer records the installed release in a marker file holding the
# release archive name, e.g. "sui-mainnet-v1.83.1-ubuntu-x86_64.tgz".

# Network and version from a marker value: prints "<network> <vX.Y.Z>", or
# nothing when the value is not a marker this blueprint wrote.
sui_marker_parse() {
    printf '%s\n' "${1:-}" | sed -nE 's/^sui-(mainnet|testnet)-(v[0-9]+\.[0-9]+\.[0-9]+)-ubuntu-(x86_64|aarch64)\.tgz$/\1 \2/p'
}

# True (0) when version $1 is strictly newer than version $2 (both vX.Y.Z).
sui_version_gt() {
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -1)" = "$1" ]
}

# Never-downgrade safeguard (ADR-0022). Decides whether to keep the installed
# release instead of installing the requested one.
#   $1 requested version (vX.Y.Z)   $2 network (BC_NETWORK)
#   $3 marker value (may be empty)  $4 allow downgrade ("true" to allow)
# Prints the installed version and returns 0 when the installed release is for
# the same network and newer than the requested one, and downgrades are not
# allowed. Returns 1 otherwise (install the requested version).
sui_keep_newer_installed() {
    local requested="$1" network="$2" marker="$3" allow="${4:-false}" parsed inst_net inst_ver
    [ "$allow" = "true" ] && return 1
    parsed="$(sui_marker_parse "$marker")"
    [ -n "$parsed" ] || return 1
    inst_net="${parsed% *}"
    inst_ver="${parsed#* }"
    [ "$inst_net" = "$network" ] || return 1
    if sui_version_gt "$inst_ver" "$requested"; then
        printf '%s\n' "$inst_ver"
        return 0
    fi
    return 1
}
