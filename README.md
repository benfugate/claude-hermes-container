# claude-hermes-container

[![Build and Push Docker Image](https://github.com/benfugate/claude-hermes-container/actions/workflows/publish.yml/badge.svg)](https://github.com/benfugate/claude-hermes-container/actions/workflows/publish.yml)

[claude-hermes](https://github.com/sypsyp97/claude-hermes) packaged as a long-running
container, published to `ghcr.io/benfugate/claude-hermes-container:latest` for `linux/amd64`.

Upstream publishes no image, so this repository supplies only the packaging: a
Dockerfile and an entrypoint. **The application is not vendored here** — `upstream/`
is a git submodule pinned to a specific commit.

## How it tracks upstream

Rebuilds are event-driven, with no Actions `schedule:` trigger anywhere (scheduled
workflows are auto-disabled after 60 days of repository inactivity):

| Change | Update path |
|---|---|
| Upstream app code | Dependabot `gitsubmodule` PR (tracks newest upstream **tag**) → **merged by hand** → publish |
| Base image digest | Dependabot `docker` PR (digest only) → auto-approved and auto-merged → publish |
| Claude Code CLI | Dependabot `npm` PR on `claude-code/package.json` → auto-approved and auto-merged → publish |
| Action versions | Dependabot `github-actions` PR → merged by hand |

Submodule bumps are deliberately *not* auto-merged: this container holds SSH keys to
the homelab hosts, so new upstream application code gets reviewed before it ships.
Every PR is still built by `ci.yml` first.

Each image is labelled with the exact upstream revision it was built from:

```bash
docker image inspect ghcr.io/benfugate/claude-hermes-container:latest \
  --format '{{ index .Config.Labels "dev.fugate.upstream.ref" }}'
```

## Deployment notes

- **No published port.** claude-hermes removed the upstream web dashboard; Telegram
  and Discord are the only interfaces.
- **State lives in `/root/.claude`** (declared as a volume). claude-hermes resolves
  its own state to `.claude/hermes/` relative to the working directory.
- **Migration from claudeclaw** is automatic: on first start it copies
  `.claude/claudeclaw` to `.claude/hermes` and archives the original. The entrypoint
  deliberately skips bootstrapping default settings while an unmigrated legacy
  directory is present, because the migrator refuses to run if both directories exist.
- The Chromium/Playwright runtime libraries are **not** installed. They are only
  needed by the dev-browser plugin, which is reached through `preflight`, and
  `plugins.preflightOnStart` defaults to false. Enabling preflight means adding them back.

## Local build

```bash
git clone --recurse-submodules https://github.com/benfugate/claude-hermes-container
cd claude-hermes-container
docker build -t claude-hermes:local .
```

## Verifying the tracking still works

Dependabot only re-evaluates on its own schedule or when `.github/dependabot.yml`
changes — a submodule pointer change alone does **not** trigger it. To prove the
mechanism end to end, pin `upstream/` back to an older tag, touch the Dependabot
config, and confirm a bump PR appears:

```bash
git -C upstream checkout v1.0.3 && git add upstream
printf '\n#\n' >> .github/dependabot.yml
git commit -am "test tracking" && git push
```

This was last verified on 2026-09-17: Dependabot proposed `faea5da` → `1c8f7d6`
(v1.0.3 → v1.1.0).
