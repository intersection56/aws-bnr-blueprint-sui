#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
#
# Compare each network's pinned sui-node release with the latest MystenLabs
# release for that network. When a network is behind, open one issue per new
# release in this repository (needs the GitHub CLI and GH_TOKEN with
# issues:write; the release-watch workflow provides both).
#
# Usage: scripts/check-release.sh            # open issues when behind
#        DRY_RUN=1 scripts/check-release.sh  # only print what it finds
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/release-lib.sh
. scripts/release-lib.sh

for net in $(networks); do
    pinned_cfg="$(pinned_config "$net")"
    pinned="$(version_of_config "$pinned_cfg")"
    [ -n "$pinned" ] || die "cannot parse a version from $pinned_cfg"

    latest_full="$(latest_tag "$net")"
    [ -n "$latest_full" ] || die "no published $net-v* release found in $SUI_REPO"
    latest="${latest_full#"$net"-}"

    if [ "$(newer_version "$pinned" "$latest")" = "$pinned" ]; then
        echo "up to date: $net pins $pinned (latest release: $latest_full)"
        continue
    fi
    echo "behind: $net pins $pinned, latest release is $latest_full"

    title="Release watch: Sui $latest_full is available"
    if [ -n "${DRY_RUN:-}" ]; then
        echo "  (dry run) would open issue: $title"
        continue
    fi
    existing="$(gh issue list --state all --search "\"$title\" in:title" --json title \
        --jq ".[] | select(.title == \"$title\") | .title")"
    if [ -n "$existing" ]; then
        echo "  issue already exists: $title"
        continue
    fi
    body="$(cat <<EOF
This blueprint pins \`$net-$pinned\` (\`$pinned_cfg\`). [$latest_full](https://github.com/$SUI_REPO/releases/tag/$latest_full) is now the latest $net release.

Before bumping, read the release notes for \`fullnode.yaml\`, \`sui-tool\` or protocol-version changes. A node that falls too far behind can stop following the chain when the protocol version moves.

To bump, from a clone of this repository:

\`\`\`bash
scripts/bump.sh --show             # pinned versions and latest releases
scripts/bump.sh $net $latest
scripts/validate.sh                # tests + cdk synth
\`\`\`

Close this issue if you decide to skip the release; it will not be reopened.
EOF
)"
    gh issue create --title "$title" --body "$body"
done
