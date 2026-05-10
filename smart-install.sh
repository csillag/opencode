#!/usr/bin/env bash
# smart-install.sh — idempotent installer for csillag/opencode.
#
# Cheap-path: when `opencode --version` already matches the latest released
# binary version, exits 0 without doing anything else (no OS/arch detection,
# no download, no PATH writes).  Safe to invoke from cron, shell rc files,
# or system-startup scripts that want to keep opencode current.
#
# Slow-path (binary missing or outdated): defers to the full installer at
# install.sh in this same repo, passing through any args.
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/csillag/opencode/main/smart-install.sh | bash
#
# With pass-through args (e.g. for cron, no shell rc edits):
#   curl -fsSL https://raw.githubusercontent.com/csillag/opencode/main/smart-install.sh | bash -s -- --no-modify-path
#
set -euo pipefail
REPO=csillag/opencode
INSTALLER_URL="https://raw.githubusercontent.com/${REPO}/main/install.sh"

# 1. Resolve the latest released tag from GH API.  Fail loudly if unreachable —
#    a network blip should not silently leave the system unupgraded.
LATEST_TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
if [ -z "$LATEST_TAG" ]; then
    echo "smart-install: failed to fetch latest release tag from github.com/${REPO}" >&2
    exit 1
fi

# 2. Derive what `opencode --version` would report for that tag.
#    Tag format: `v<upstream>-csillag.<iframe-sha>.<cache-sha>`
#    Binary form: `<upstream>-csillag` (no leading v, no trailing SHAs)
LATEST_BINARY_VERSION=$(echo "$LATEST_TAG" \
  | sed -E 's/^v//; s/\.[0-9a-f]+\.[0-9a-f]+$//')

# 3. Compare against installed binary, if any.
if command -v opencode >/dev/null 2>&1; then
    INSTALLED_VERSION=$(opencode --version 2>/dev/null || echo "")
    if [ "$INSTALLED_VERSION" = "$LATEST_BINARY_VERSION" ]; then
        echo "opencode $INSTALLED_VERSION already up-to-date (latest: $LATEST_BINARY_VERSION, release tag $LATEST_TAG)"
        exit 0
    fi
    echo "opencode upgrade: $INSTALLED_VERSION -> $LATEST_BINARY_VERSION (release tag $LATEST_TAG)"
else
    echo "opencode not installed; installing $LATEST_BINARY_VERSION (release tag $LATEST_TAG)"
fi

# 4. Defer to the full installer.  We pipe through bash so a cron/rc invocation
#    of smart-install.sh works with no local install.sh present.  Pass through
#    any args (commonly `--no-modify-path` for non-interactive contexts).
curl -fsSL "$INSTALLER_URL" | bash -s -- "$@"
