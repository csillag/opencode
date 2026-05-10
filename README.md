# csillag/opencode — build infra branch

This `main` branch hosts the GitHub Actions workflow that builds combined
binaries from two long-lived feature branches on this fork:

| Branch                                       | What it adds                                           |
| -------------------------------------------- | ------------------------------------------------------ |
| `csillag/make-web-embeddable-in-iframes`     | Vite `base: './'`, CSP `'unsafe-eval'` for Zod 4, `getCurrentUrl` localStorage override — lets the SPA mount inside an iframe at any URL subpath. |
| `csillag/anthropic-prompt-cache-tuning`      | Anthropic 1h prompt-cache TTL (configurable via `opencode.json` `provider.anthropic.options.cacheTTL`), tool-order stabilization for cache prefix determinism, TTL-aware cost split. |

Both branches are rebased manually onto the **latest upstream release tag**
(`v<major>.<minor>.<patch>`, e.g. `v1.14.45`), not the `dev` tip.  Their
merge-base is treated as the shared upstream version; the combine workflow
verifies the base is exactly an upstream release tag, then fast-forwards both
branches onto a fresh checkout, builds 12 binaries (linux ×6 / darwin ×3 /
windows ×3), and publishes a GitHub release.

The binary's `opencode --version` reports `<upstream-version>-csillag` (e.g.
`1.14.45-csillag`), matching the upstream release this build descends from.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/csillag/opencode/main/install.sh | bash
```

Auto-detects OS / arch / glibc-vs-musl / AVX2 (baseline) and downloads the
matching release asset.  Installs to `~/.opencode/bin/opencode` and adds the
directory to `$PATH` in your shell rc (override with `--no-modify-path`).

To pin a specific build:

```sh
curl -fsSL https://raw.githubusercontent.com/csillag/opencode/main/install.sh \
  | bash -s -- --version v1.14.45-csillag.d103e2889.cccfb448e
```

The script is a small fork of upstream's `opencode.ai/install` — see the
header of `install.sh` for the diff rationale.

## Maintenance procedure

The full rebase + build runbook is in [`AGENTS.md`](./AGENTS.md).  TL;DR:

1. Rebase both feature branches onto the **latest upstream release tag**
   (`v[0-9]*`), not the `dev` tip.  Releases are frequent — try to keep the
   base less than a few days old.
2. Force-push both branches to `origin` with `--force-with-lease`.
3. Trigger the combined build via `gh workflow run`.

The workflow refuses to build unless both branches share the same upstream
release tag as their merge-base.

## How to build

After rebasing one or both feature branches and force-pushing them to origin:

```sh
gh workflow run build-combined.yml --repo csillag/opencode --ref main
```

Or pin specific commits:

```sh
gh workflow run build-combined.yml \
  --repo csillag/opencode --ref main \
  --field iframe_ref=<sha> \
  --field cache_ref=<sha>
```

Built binaries land in a release tagged
`v<upstream-version>-csillag.<iframe-sha>.<cache-sha>` (e.g.
`v1.14.45-csillag.92bc6a51.707bea8a`).  The SHA suffix is for traceability;
the binary's `--version` strips it to `<upstream-version>-csillag`.

For the full rebase + verification + build runbook (including conflict
resolution per branch and the local-build recipe), see [`AGENTS.md`](./AGENTS.md).

## Why no automatic CI on push

Push triggers in GitHub Actions require the workflow file to live on the
pushed branch. Putting `.github/workflows/build-combined.yml` on each feature
branch would duplicate infra and cause merge churn during rebases. Manual
dispatch from this `main` branch keeps the feature branches focused on
their actual code changes.
