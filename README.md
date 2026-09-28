# claude-hermes-container

[![Build and Push Docker Image](https://github.com/benfugate/claude-hermes-container/actions/workflows/publish.yml/badge.svg)](https://github.com/benfugate/claude-hermes-container/actions/workflows/publish.yml)

[claude-hermes](https://github.com/sypsyp97/claude-hermes) packaged as a long-running
container, published to `ghcr.io/benfugate/claude-hermes-container:latest` for `linux/amd64`.

Upstream publishes no image, so this repository supplies only the packaging: a
Dockerfile and an entrypoint. **The application is not vendored here** — `upstream/`
is a git submodule pinned to a specific commit.

## How it tracks upstream

Updates arrive as Dependabot PRs. Every merge to `main` publishes a new image:

| Change | Update path |
|---|---|
| Upstream app code | Dependabot `gitsubmodule` PR (tracks newest upstream **tag**) → AI security review → auto-merged if `safe`, else by hand → publish |
| Base image digest | Dependabot `docker` PR (digest only) → auto-approved and auto-merged → publish |
| Claude Code CLI | Dependabot `npm` PR on `claude-code/package.json` → auto-approved and auto-merged → publish |
| Action versions | Dependabot `github-actions` PR → merged by hand |

This container holds SSH keys to the homelab hosts, so upstream bumps are reviewed
before they ship. Claude Code, running DeepSeek V4.1 Flash through OpenRouter, reads
the full diff with read-only tools (`.github/scripts/review-upstream.sh`) and posts a
verdict on the PR. Only `safe` auto-merges. `needs_human` and `unsafe` wait for you.
Binary changes, rewritten history and diffs over 15,000 lines always go to a human.

The review needs an `OPENROUTER_API_KEY` **Dependabot** secret. Without it the
review fails and the PR waits for you.

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
