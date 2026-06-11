# AGENTS.md — operator guide for `csillag/opencode`

This file is a runbook for **automated agents** (Claude, scripted runs) and
humans operating this fork.  It documents the only supported maintenance flow:
periodically rebase two long-lived feature branches onto the latest **upstream
release tag** (not the `dev` tip), then trigger a combined build.

If you are a new agent landing in this repo: **read this file end-to-end before
making any change**.  Skip Step 0 only if you have already read the file in this
conversation.

This runbook lives **only on this fork's `main` branch**.  The two feature
branches carry upstream's generic contributor `AGENTS.md` instead, so if the
working tree has a feature branch checked out (the usual state), read this
file via `git show origin/main:AGENTS.md` — grepping the checked-out copy
will silently find the wrong file.

---

## What lives here

This `main` branch holds only build infrastructure:

```
.github/workflows/build-combined.yml   # the only build entry point
README.md                              # short user-facing intro
AGENTS.md                              # this file
```

The actual code lives on two long-lived feature branches in this same fork
(`csillag/opencode`):

| Branch on `csillag/opencode`                  | Upstream of                                    | What it adds                                                                                                                                         |
| --------------------------------------------- | ---------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------- |
| `csillag/make-web-embeddable-in-iframes`      | `anomalyco/opencode`                           | Vite `base: './'`, CSP `'unsafe-eval'` (Zod 4), `getCurrentUrl` localStorage override.  ~1 commit ahead of base.                                     |
| `csillag/anthropic-prompt-cache-tuning`       | `anomalyco/opencode`                           | Anthropic 1h prompt-cache TTL (`opencode.json` `provider.anthropic.options.cacheTTL`), tool-order stabilization, TTL-aware cost split.  ~1 commit ahead of base. |

Both branches must always be rebased onto the **same** upstream release tag.
The combined-build workflow enforces this and refuses to build if the shared
merge-base of the two branches isn't exactly an upstream release tag.

---

## When to rebase

- **Whenever a new upstream release ships** that you want the fork's binaries
  to track.  Upstream releases are frequent (often daily); the binary's
  `--version` should reflect a release no more than a few days old.
- **Before every build the user explicitly asks for**, unless the user says
  otherwise.

If `git describe --tags --exact-match` on the current shared base already
reports a release tag less than ~3 days old, you may skip the rebase and just
re-trigger the build.

---

## Step 0 — Sanity checks before touching anything

Run these in `~/deai/opencode` (or wherever the working clone lives):

```sh
git status --short                        # must be clean; if not, ask the user
git remote -v                             # confirm `origin = csillag/opencode` and `upstream = anomalyco/opencode` exist
git fetch upstream --tags --prune
git fetch origin
```

If `upstream` remote is missing, add it:

```sh
git remote add upstream https://github.com/anomalyco/opencode.git
git fetch upstream --tags --prune
```

Note any uncommitted changes — do **not** stash without telling the user.

---

## Step 1 — Discover the latest upstream release tag

**Canonical form — query upstream's GH releases directly.**  Bypasses both
the SIGPIPE-under-pipefail trap and the local-tag-contamination trap (this
fork's own `v1.14.45-csillag.<sha>.<sha>` release tags out-sort upstream
`v1.14.45` under git's `v:refname` sort, because git's semver-pre-release
ordering is inverted from real semver).

```sh
LATEST=$(gh release view --repo anomalyco/opencode --json tagName -q .tagName)
echo "Latest upstream release: $LATEST"
```

If `gh` is unavailable, fall back to the local-tag-only query but only after
explicitly fetching upstream tags into a clean refs namespace and excluding
this fork's tags by strict semver pattern:

```sh
LATEST=$(git ls-remote --tags --refs upstream 'v*' \
  | awk '{sub(/refs\/tags\//,"",$2); print $2}' \
  | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' \
  | sort -V \
  | tail -1)
```

Cross-check against the GitHub Releases API to make sure your local tags are
fresh:

```sh
gh release view --repo anomalyco/opencode --json tagName,publishedAt -q '"\(.tagName)  published \(.publishedAt)"'
```

If the GH API reports a newer tag than your local `LATEST`, re-run
`git fetch upstream --tags --prune`.

The pattern `v[0-9]*` matters — upstream also tags VS Code releases as
`vscode-v0.0.X`.  Without the digit anchor, `--sort=-v:refname` will pick up
those by mistake.

---

## Step 2 — Rebase each feature branch onto `$LATEST`

Do them one at a time.  Confirm with the user before force-pushing.

> **Use the `--onto NEW_BASE HEAD~N` form, not the bare `git rebase NEW_BASE`.**
> Both feature branches are exactly **1 commit** ahead of their previous base
> (the `feat: ...` commit at HEAD).  The naive `git rebase v1.14.45` works
> only when the previous base is a *strict ancestor* of the new tag — which
> happens to hold today, but breaks the moment a branch was rebased onto
> `dev`'s tip and a release tag was then made on an *earlier* dev commit.
> In that scenario the naive form would silently absorb every dev commit
> between the new tag and the old base into the feature branch.
>
> The `--onto NEW_BASE HEAD~1` form replays exactly the top commit and
> nothing else — safe regardless of the relative position of new and old
> bases.  For branches with N feature commits, use `HEAD~N`.

After every rebase, **verify count is unchanged** with
`git rev-list --count "$LATEST..HEAD"` — should equal the number of feature
commits the branch carried before the rebase.

### iframe-embeddable

```sh
git checkout csillag/make-web-embeddable-in-iframes
git rebase --onto "$LATEST" HEAD~1
git rev-list --count "$LATEST..HEAD"   # must print 1
```

If conflicts: resolve by hand.  The branch typically only touches three files
(`packages/app/src/entry.tsx`, `packages/app/vite.config.ts`,
`packages/opencode/src/server/shared/ui.ts`).  Common upstream churn on
`shared/ui.ts` is the CSP `csp()` function — preserve the
`'unsafe-eval'` addition (rationale documented in the commit message).

After resolution:

```sh
git rebase --continue
```

Verify build sanity (TypeScript only — this branch has no test additions):

```sh
( cd packages/opencode && bun --bun tsc --noEmit -p . ) 2>&1 | rg -v 'node_modules' | rg 'src/(provider|session|server)' | head
```

### prompt-cache-tuning

```sh
git checkout csillag/anthropic-prompt-cache-tuning
git rebase --onto "$LATEST" HEAD~1
git rev-list --count "$LATEST..HEAD"   # must print 1
```

This branch touches (paths as of the v1.17.3 rebase, 2026-06-11):
- `packages/opencode/src/provider/transform.ts` (cache TTL injection in `applyCaching`)
- `packages/core/src/v1/config/provider.ts` (schema field; was
  `packages/opencode/src/config/provider.ts` before upstream's core/v1 split —
  git followed the rename automatically during the v1.17.3 rebase)
- `packages/opencode/src/provider/provider.ts` (provider→model option fallback)
- `packages/opencode/src/session/tools.ts` (tool sorting; was
  `packages/opencode/src/session/prompt.ts` until upstream extracted the
  tool-building code into `tools.ts` — if it moves again, find the new home
  with `git grep -n 'registry\.tools\|mcp\.tools()'` and re-apply both sort
  hunks there: registry tools by `id`, MCP tool entries by key)
- `packages/opencode/src/session/session.ts` (TTL-aware cost split in `getUsage`)
- `packages/opencode/test/provider/transform.test.ts` (TTL tests)
- `packages/opencode/test/session/usage-cache-cost.test.ts` (cost tests)

If `transform.ts` `applyCaching` was refactored upstream, re-apply the TTL
read (`model.options?.["cacheTTL"]`) and the per-provider injection.  If
`session.ts` `getUsage` shape changed, re-apply the cache_creation breakdown
read + the 1.6× billing for the 1h portion (in the v1.17.3 shape, the
TTL-split `cacheWriteCost` feeds upstream's cost expression, which also has a
copilot `totalNanoAiu` short-circuit — keep both).

After a large rebase, run `bun install` from the repo root before testing —
1500+ upstream commits routinely add workspace dependencies, and the tests
fail with `Cannot find package ...` until the lockfile is reinstalled.

Verify by running the TTL + cost tests after rebase:

```sh
( cd packages/opencode && bun test test/provider/transform.test.ts test/session/usage-cache-cost.test.ts ) | tail -5
```

Both files together should report ~266 pass / 0 fail (the count drifts upward
as upstream grows `transform.test.ts`; 0 fail is the invariant).

---

## Step 3 — Push both branches with `--force-with-lease`

```sh
git checkout csillag/make-web-embeddable-in-iframes
git push --force-with-lease origin csillag/make-web-embeddable-in-iframes --no-verify

git checkout csillag/anthropic-prompt-cache-tuning
git push --force-with-lease origin csillag/anthropic-prompt-cache-tuning --no-verify
```

`--no-verify` is required because the husky pre-push hook on this fork runs
`bun typecheck` across all workspaces, including
`@opencode-ai/http-recorder` which has pre-existing upstream type breakage
unrelated to anything in this fork.  The push is safe — it only touches the
two feature branches in your own fork.

`--force-with-lease` (preferred over `--force`) refuses the push if someone
else pushed to the branch since you last fetched it.  Important if multiple
people or sessions can touch this fork.

---

## Step 4 — Verify both branches share the same base on origin

Mandatory before triggering the build — the workflow fails out otherwise.

```sh
git fetch origin
BASE=$(git merge-base origin/csillag/make-web-embeddable-in-iframes origin/csillag/anthropic-prompt-cache-tuning)
git describe --tags --exact-match --match 'v[0-9]*' "$BASE"
```

Expected output: the upstream tag you rebased onto (e.g. `v1.14.45`).
If `git describe` errors out, the branches are not on the same release
commit — re-do Step 2 for whichever branch is wrong.

---

## Step 5 — Trigger the combined build

```sh
gh workflow run build-combined.yml --repo csillag/opencode
```

Watch:

```sh
sleep 5
RUN=$(gh run list --workflow=build-combined.yml --repo csillag/opencode --limit 1 --json databaseId -q '.[0].databaseId')
gh run watch "$RUN" --repo csillag/opencode --interval 30
```

A clean build is ~3 minutes.  On success the release lands at:

```
https://github.com/csillag/opencode/releases/tag/v<UPSTREAM>-csillag.<N>.<IFRAME-SHA>.<CACHE-SHA>
```

`<N>` is a per-upstream-version build counter the prep job computes as
max(existing counters for this upstream version) + 1 — it makes repeated
builds against the same upstream release distinguishable both in the tag and
in the binary.  The binary's `opencode --version` reports
`<UPSTREAM>-csillag.<N>` (no SHAs) — the SHAs only appear in the GitHub
release tag for traceability, and `smart-install.sh` relies on stripping
exactly the two trailing hex groups to recover the binary version from the
tag.  Releases tagged before the counter existed
(`v<UPSTREAM>-csillag.<sha>.<sha>`) count as build 1 of their upstream
version.

---

## Step 6 — Verify the published release

```sh
RELEASE_TAG=$(gh release list --repo csillag/opencode --limit 1 --json tagName -q '.[0].tagName')
gh release view "$RELEASE_TAG" --repo csillag/opencode --json tagName,publishedAt,assets -q '{tag: .tagName, published: .publishedAt, assets: [.assets[] | "\(.name)  \(.size)"]}'
```

Expected: 12 zip assets (linux ×6, darwin ×3, windows ×3).

---

## Common errors and how to react

| Symptom in workflow run | Likely cause | Fix |
|---|---|---|
| `Shared base ... is NOT an upstream release tag` (prep job exits 1) | Step 4's check failed; one or both branches not on a release tag | Redo Step 2 against `$LATEST`; force-push; retry |
| `git rebase` reports conflicts in `shared/ui.ts` (iframe branch) | Upstream changed CSP function | Re-apply `'unsafe-eval'` to `script-src`; keep upstream's other changes |
| `git rebase` reports conflicts in `transform.ts` (cache branch) | Upstream refactored `applyCaching` | Re-apply `model.options?.["cacheTTL"]` read + per-provider TTL injection |
| `bun test` fails on TTL or cost tests | Test fixtures reference shape that upstream changed | Re-read `getUsage` in `session.ts`, update test fixtures to match; do not change the 1.6× multiplier or the cache_creation field path |
| Pre-push hook fails on unrelated package | Pre-existing upstream type breakage | Use `--no-verify` (only for pushes to your own feature branches) |

---

## Local builds (for hand-testing, not CI)

If you need a local-only build with the same version-string format CI produces:

```sh
LATEST=$(git tag -l 'v[0-9]*' --sort=-v:refname | head -1)
OPENCODE_VERSION="${LATEST#v}-csillag" \
  bun run --cwd packages/opencode script/build.ts
# binaries land in packages/opencode/dist/opencode-<arch>/
```

Setting `OPENCODE_VERSION` to `<release>-csillag` makes the script bypass its
default branch-name + timestamp formatting (see
`packages/script/src/index.ts`) and use that string verbatim as
`Script.version`, which becomes `opencode --version`.

(CI additionally appends a `.<N>` build counter to the version — see Step 5.
For local hand-test builds the bare `<release>-csillag` form is fine and has
the side benefit that `smart-install.sh` will treat the machine as outdated
and reinstall a real release on its next run.)

To build only your current platform's binary instead of all 12:

```sh
OPENCODE_VERSION="${LATEST#v}-csillag" \
  bun run --cwd packages/opencode script/build.ts --single
```

---

## What NOT to do

- **Do not rebase onto `upstream/dev`.**  The build refuses to run unless the
  shared base is a release tag.  The point of pinning to releases is that
  upstream releases are smoke-tested; `dev` is not.
- **Do not bypass the workflow's release-base check** (`allow_non_release_base=true`)
  unless the user explicitly asks for it and accepts the consequences.
- **Do not change the workflow file from a feature branch.**  Workflow
  edits live on `main`.  GH Actions reads `workflow_dispatch` workflows from
  the repository default branch (currently `main`).
- **Do not introduce a third feature branch** without first updating both the
  workflow and this file.  The combine step assumes exactly two branches.
- **Do not retag a release.**  Each build gets a unique tag via the SHA suffix.
  If you really need to overwrite, delete the release on GitHub first.
- **Do not use the bare `git rebase NEW_BASE` form.**  Always
  `git rebase --onto NEW_BASE HEAD~N` (N = number of feature commits on the
  branch).  See the rationale block in Step 2.

---

## Quick-reference invocation

For an autonomous run with no questions to ask.  Both branches today carry
exactly **1** feature commit, so the per-branch `HEAD~1` is hard-coded; if a
branch ever grows more commits, update the loop.

```sh
set -euo pipefail
cd ~/deai/opencode
git fetch upstream --tags --prune
git fetch origin

# gh release view bypasses both pitfalls: no SIGPIPE, no local-tag pollution
# from this fork's own `v<X>-csillag.<sha>.<sha>` release tags.  See Step 1.
LATEST=$(gh release view --repo anomalyco/opencode --json tagName -q .tagName)
echo "Rebasing both feature branches onto $LATEST"

for BR in csillag/make-web-embeddable-in-iframes csillag/anthropic-prompt-cache-tuning; do
  git checkout "$BR"
  # --onto NEW_BASE HEAD~N replays exactly the top N commits and nothing else,
  # immune to the relative position of NEW_BASE vs the previous base.  If you
  # use the bare `git rebase $LATEST` form here and a release tag is older than
  # the branch's current base, you will silently absorb the dev-only delta
  # between $LATEST and the old base into the feature branch.
  git rebase --onto "$LATEST" HEAD~1   # FIXME: stops here on conflict
  test "$(git rev-list --count "$LATEST..HEAD")" = 1 \
    || { echo "post-rebase: $BR has more than 1 commit ahead of $LATEST"; exit 1; }
  git push --force-with-lease origin "$BR" --no-verify
done

# sanity: shared base must equal the release tag
BASE=$(git merge-base origin/csillag/make-web-embeddable-in-iframes \
                      origin/csillag/anthropic-prompt-cache-tuning)
git describe --tags --exact-match --match 'v[0-9]*' "$BASE"

# build
gh workflow run build-combined.yml --repo csillag/opencode
```

This script does **not** auto-resolve conflicts.  When the rebase stops on
conflict, the agent should pause and either resolve in code or ask the user
for guidance.
