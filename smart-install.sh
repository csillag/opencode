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
# --check mode: report only.  Prints `opencode ok` when up-to-date, otherwise
# `download <url>` with the release archive that install.sh would fetch.
# Never downloads or installs.  Use this from automation that wants to decide
# whether an install is needed (e.g. a packager, a healthcheck, an apt-like
# wrapper) without committing to the slow path.
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/csillag/opencode/main/smart-install.sh | bash
#
# With pass-through args (e.g. for cron, no shell rc edits):
#   curl -fsSL https://raw.githubusercontent.com/csillag/opencode/main/smart-install.sh | bash -s -- --no-modify-path
#
set -euo pipefail
REPO=csillag/opencode
APP=opencode
INSTALLER_URL="https://raw.githubusercontent.com/${REPO}/main/install.sh"

check_only=false
passthrough=()
while [ $# -gt 0 ]; do
    case "$1" in
        --check) check_only=true; shift ;;
        *) passthrough+=("$1"); shift ;;
    esac
done

# 1. Resolve the latest released tag from GH API.  Fail loudly if unreachable —
#    a network blip should not silently leave the system unupgraded.
LATEST_TAG=$(curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
  | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p')
if [ -z "$LATEST_TAG" ]; then
    echo "smart-install: failed to fetch latest release tag from github.com/${REPO}" >&2
    exit 1
fi

# 2. Derive what `opencode --version` would report for that tag.
#    Tag format:  `v<upstream>-csillag.<N>.<iframe-sha>.<cache-sha>`
#    Binary form: `<upstream>-csillag.<N>` (no leading v, no trailing SHAs)
#    N is a per-upstream-version build counter (set by build-combined.yml), so
#    rebuilds against the same upstream release are distinguishable here.
#    Legacy pre-counter tags (`v<upstream>-csillag.<sha>.<sha>`) reduce to
#    `<upstream>-csillag` under the same sed, matching their binaries' output.
#    The `-csillag` segment is not hex, so the strip can never eat the version.
LATEST_BINARY_VERSION=$(echo "$LATEST_TAG" \
  | sed -E 's/^v//; s/\.[0-9a-f]+\.[0-9a-f]+$//')

# 3. Compare against installed binary, if any.
installed_ok=false
if command -v opencode >/dev/null 2>&1; then
    INSTALLED_VERSION=$(opencode --version 2>/dev/null || echo "")
    if [ "$INSTALLED_VERSION" = "$LATEST_BINARY_VERSION" ]; then
        installed_ok=true
    fi
fi

if [ "$installed_ok" = "true" ]; then
    if [ "$check_only" = "true" ]; then
        echo "opencode ok"
    else
        echo "opencode $INSTALLED_VERSION already up-to-date (latest: $LATEST_BINARY_VERSION, release tag $LATEST_TAG)"
    fi
    exit 0
fi

# 4. Either missing or outdated.  In --check mode, derive the URL install.sh
#    would download (mirrors install.sh's detection — keep in sync) and print
#    it; do not invoke curl on the archive.
if [ "$check_only" = "true" ]; then
    raw_os=$(uname -s)
    case "$raw_os" in
      Darwin*) os="darwin" ;;
      Linux*) os="linux" ;;
      MINGW*|MSYS*|CYGWIN*) os="windows" ;;
      *) echo "smart-install: unsupported OS '$raw_os'" >&2; exit 1 ;;
    esac

    arch=$(uname -m)
    [ "$arch" = "aarch64" ] && arch="arm64"
    [ "$arch" = "x86_64" ] && arch="x64"

    if [ "$os" = "darwin" ] && [ "$arch" = "x64" ]; then
        rosetta_flag=$(sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)
        [ "$rosetta_flag" = "1" ] && arch="arm64"
    fi

    combo="$os-$arch"
    case "$combo" in
      linux-x64|linux-arm64|darwin-x64|darwin-arm64|windows-x64) ;;
      *) echo "smart-install: unsupported OS/arch '$combo'" >&2; exit 1 ;;
    esac

    is_musl=false
    if [ "$os" = "linux" ]; then
        [ -f /etc/alpine-release ] && is_musl=true
        if command -v ldd >/dev/null 2>&1; then
            ldd --version 2>&1 | grep -qi musl && is_musl=true
        fi
    fi

    needs_baseline=false
    if [ "$arch" = "x64" ]; then
        if [ "$os" = "linux" ]; then
            grep -qwi avx2 /proc/cpuinfo 2>/dev/null || needs_baseline=true
        elif [ "$os" = "darwin" ]; then
            avx2=$(sysctl -n hw.optional.avx2_0 2>/dev/null || echo 0)
            [ "$avx2" = "1" ] || needs_baseline=true
        elif [ "$os" = "windows" ]; then
            ps="(Add-Type -MemberDefinition \"[DllImport(\"\"kernel32.dll\"\")] public static extern bool IsProcessorFeaturePresent(int ProcessorFeature);\" -Name Kernel32 -Namespace Win32 -PassThru)::IsProcessorFeaturePresent(40)"
            out=""
            if command -v powershell.exe >/dev/null 2>&1; then
                out=$(powershell.exe -NoProfile -NonInteractive -Command "$ps" 2>/dev/null || true)
            elif command -v pwsh >/dev/null 2>&1; then
                out=$(pwsh -NoProfile -NonInteractive -Command "$ps" 2>/dev/null || true)
            fi
            out=$(echo "$out" | tr -d '\r' | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')
            [ "$out" = "true" ] || [ "$out" = "1" ] || needs_baseline=true
        fi
    fi

    target="$os-$arch"
    [ "$needs_baseline" = "true" ] && target="$target-baseline"
    [ "$is_musl" = "true" ] && target="$target-musl"

    filename="$APP-$target.zip"
    url="https://github.com/${REPO}/releases/latest/download/$filename"
    echo "download $url"
    exit 0
fi

if [ -n "${INSTALLED_VERSION:-}" ]; then
    echo "opencode upgrade: $INSTALLED_VERSION -> $LATEST_BINARY_VERSION (release tag $LATEST_TAG)"
else
    echo "opencode not installed; installing $LATEST_BINARY_VERSION (release tag $LATEST_TAG)"
fi

# 5. Defer to the full installer.  We pipe through bash so a cron/rc invocation
#    of smart-install.sh works with no local install.sh present.  Pass through
#    any args (commonly `--no-modify-path` for non-interactive contexts).
curl -fsSL "$INSTALLER_URL" | bash -s -- "${passthrough[@]}"
