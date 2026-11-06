#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Move one network to a new sui-node release.
#
#   scripts/bump.sh --show               # pinned version per network + latest release
#   scripts/bump.sh <network> <version>  # e.g. scripts/bump.sh mainnet v1.84.0
#
# What it does:
#   1. Checks that release "<network>-<version>" is published with SHA-256
#      digests for the ubuntu-x86_64 and ubuntu-aarch64 archives.
#   2. Adds configurations/sui-node-<version>-full.sh if missing. Configuration
#      scripts are identical apart from their name (the version comes from the
#      file name), so it is a copy of an existing one.
#   3. Points every samples/.env-<network>-* at the new configuration.
#   4. Rebuilds availableConfigurations in package.json from the samples, and
#      sets defaultConfiguration to the first network's (mainnet) configuration.
#   5. Updates the pinned configuration for the network in the Jest test.
#   6. Deletes configuration files no sample uses anymore.
#   7. Lists remaining mentions of the old version for you to update by hand.
#
# Nothing is committed: review `git diff`, then run scripts/validate.sh.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/release-lib.sh
. scripts/release-lib.sh

TEST_FILE="test/sui-configuration.test.ts"

show() {
    local net cfg
    for net in $(networks); do
        cfg="$(pinned_config "$net")"
        printf '%-8s pinned %-26s latest release %s\n' "$net" "$cfg" "$(latest_tag "$net")"
    done
}

case "${1:-}" in
    --show) show; exit 0 ;;
    ""|-h|--help) sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

[ $# -eq 2 ] || die "usage: scripts/bump.sh <network> <version>  (or --show)"
net="$1"; version="$2"
networks | grep -qx "$net" || die "unknown network '$net' (supported: $(networks | tr '\n' ' '))"
printf '%s\n' "$version" | grep -Eq "$VERSION_RE" || die "version must look like v1.84.0, got '$version'"

old_cfg="$(pinned_config "$net")"
new_cfg="$(config_for_version "$version")"
[ "$old_cfg" != "$new_cfg" ] || die "$net already pins $new_cfg"

check_release "$net-$version"

# 2. Configuration script.
if [ ! -f "configurations/$new_cfg" ]; then
    cp "configurations/$old_cfg" "configurations/$new_cfg"
    chmod +x "configurations/$new_cfg"
    echo "added configurations/$new_cfg"
fi

# 3. Samples for this network.
for f in $(samples_for "$net"); do
    NEW="$new_cfg" perl -pi -e 's/^CLIENT_CONFIG=.*$/CLIENT_CONFIG="$ENV{NEW}"/' "$f"
    echo "updated $f"
done

# 4. package.json: the configurations the samples use, sorted by version.
used="$(for n in $(networks); do pinned_config "$n"; done | sort -u -V)"
default_cfg="$(pinned_config "$(networks | head -1)")"
tmp="$(mktemp)"
jq --arg def "$default_cfg" --argjson names "$(printf '%s\n' "$used" | jq -R . | jq -s .)" \
    '."aws-blockchain-node-runner".defaultConfiguration = $def
     | ."aws-blockchain-node-runner".availableConfigurations = [$names[] | {name: .}]' \
    package.json > "$tmp"
mv "$tmp" package.json
echo "updated package.json (default: $default_cfg; available: $(printf '%s\n' "$used" | tr '\n' ' '))"

# 5. Jest test: the PINNED map has one "  <network>: '<config>'," line per network.
NET="$net" NEW="$new_cfg" perl -pi -e \
    's/^(\s*\Q$ENV{NET}\E: \x27)[^\x27]*(\x27,?)$/$1$ENV{NEW}$2/' "$TEST_FILE"
grep -q "  $net: '$new_cfg'" "$TEST_FILE" || die "could not update the $net entry of PINNED in $TEST_FILE"
echo "updated $TEST_FILE"

# 6. Unused configuration files.
for f in configurations/"$CONFIG_PREFIX"*"$CONFIG_SUFFIX"; do
    if ! printf '%s\n' "$used" | grep -qx "$(basename "$f")"; then
        rm "$f"
        echo "removed $f (no sample uses it)"
    fi
done

# 7. What is left for a human.
old_version="$(version_of_config "$old_cfg")"
echo
if printf '%s\n' "$used" | grep -qx "$old_cfg"; then
    echo "note: $old_cfg is still used by another network; mentions of $old_version may be correct."
fi
echo "Remaining mentions of $old_version (README tables and docs need a manual update;"
echo "the test report and ADRs record history and normally stay as they are):"
grep -rn --exclude-dir=node_modules --exclude-dir=.git -F "$old_version" \
    README.md package.json samples configurations user-data test docs .kiro 2>/dev/null || echo "  (none)"
echo
echo "Next: read the $net-$version release notes, review 'git diff', then run scripts/validate.sh."
