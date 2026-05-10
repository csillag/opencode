# csillag/opencode — build infra branch

This `main` branch hosts the GitHub Actions workflow that builds combined
binaries from two long-lived feature branches on this fork:

| Branch                                       | What it adds                                           |
| -------------------------------------------- | ------------------------------------------------------ |
| `csillag/make-web-embeddable-in-iframes`     | Vite `base: './'`, CSP `'unsafe-eval'` for Zod 4, `getCurrentUrl` localStorage override — lets the SPA mount inside an iframe at any URL subpath. |
| `csillag/anthropic-prompt-cache-tuning`      | Anthropic 1h prompt-cache TTL (configurable via `opencode.json` `provider.anthropic.options.cacheTTL`), tool-order stabilization for cache prefix determinism, TTL-aware cost split. |

Both branches are rebased manually onto upstream `dev` (anomalyco/opencode).
Their merge-base is treated as the shared upstream tip; the combine workflow
fast-forwards both branches onto a fresh checkout, builds binaries for four
targets (linux-arm64, linux-x64, darwin-arm64, darwin-x64), and publishes a
GitHub release.

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

Built binaries land in a release tagged `combined-<iframe-sha>-<cache-sha>`.

## Maintenance

When upstream `dev` advances:

1. Rebase `csillag/make-web-embeddable-in-iframes` onto the new tip; resolve
   conflicts; force-push with `--force-with-lease`.
2. Rebase `csillag/anthropic-prompt-cache-tuning` onto the **same** tip;
   resolve; force-push with `--force-with-lease`.
3. Run the workflow above. The merge-base check warns loudly if the two
   branches are not on the same upstream tip.

## Why no automatic CI on push

Push triggers in GitHub Actions require the workflow file to live on the
pushed branch. Putting `.github/workflows/build-combined.yml` on each feature
branch would duplicate infra and cause merge churn during rebases. Manual
dispatch from this `main` branch keeps the feature branches focused on
their actual code changes.
