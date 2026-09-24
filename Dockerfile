# claude-hermes packaged as a long-running container.
#
# The application itself is NOT vendored here: `upstream/` is a git submodule
# pointing at sypsyp97/claude-hermes. Dependabot's `gitsubmodule` ecosystem
# bumps that pointer, which is what makes upstream tracking event-driven
# instead of relying on an Actions `schedule:` (those get auto-disabled after
# 60 days of repository inactivity).
FROM node:24-trixie-slim@sha256:8ec5d7557396cfe32d21c3f9c13072355ceab22b584578ca4bb28af31120cffe

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# git: claude-hermes shells out to it for the self-evolve journal and skill installs.
# jq/unzip/python3: used by the agent's own tooling at runtime, not by the build.
# NOTE: the Chromium/Playwright runtime libs that the claudeclaw image carries are
# deliberately omitted. They exist only for the dev-browser plugin, which reaches
# claude-hermes through `preflight`, and `plugins.preflightOnStart` is false by
# default (src/config.ts). If preflight is ever enabled, those libs must come back
# or headless Chromium aborts on launch.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    unzip \
    jq \
    python3 \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Bun — claude-hermes is a Bun program (bun:sqlite backs its state engine).
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:$PATH"

# UV (fast Python package manager, for agent-installed Python tooling)
RUN curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:$PATH"

# The Claude Code CLI is the actual inference path: claude-hermes spawns
# `claude` per turn, so the container authenticates with the subscription
# rather than an API key.
# Version comes from claude-code/package.json, bumped by Dependabot.
COPY claude-code/package.json /tmp/claude-code/package.json
RUN npm install -g pnpm \
    "@anthropic-ai/claude-code@$(node -p "require('/tmp/claude-code/package.json').dependencies['@anthropic-ai/claude-code']")" \
    && rm -rf /tmp/claude-code

# ── Persistence env vars ──────────────────────────────────────────────────────
# Redirect each package manager's install paths and cache into /root/.claude/
# (the volume) so agent-installed tooling survives image rebuilds and container
# recreation. Declared as ENV rather than exported in the entrypoint so that
# `docker exec` shells inherit them too.
ENV IS_SANDBOX=1 \
    TMPDIR=/root/.claude/tmp \
    NPM_CONFIG_PREFIX=/root/.claude/npm-global \
    NPM_CONFIG_CACHE=/root/.claude/npm-cache \
    PYTHONUSERBASE=/root/.claude/python-user \
    PIP_USER=1 \
    PIP_BREAK_SYSTEM_PACKAGES=1 \
    PIP_CACHE_DIR=/root/.claude/pip-cache \
    PNPM_HOME=/root/.claude/pnpm-global \
    UV_TOOL_DIR=/root/.claude/uv-tools \
    UV_TOOL_BIN_DIR=/root/.claude/uv-tool-bin \
    UV_CACHE_DIR=/root/.claude/uv-cache \
    UV_PYTHON_INSTALL_DIR=/root/.claude/uv-python

# /root/.claude/npm-global/bin MUST stay first. That directory lives in the
# volume, and the ssh/scp wrappers that give this container access to the
# homelab hosts are installed there — they only win over /usr/bin because of
# this ordering. Reordering this line silently breaks SSH after the next pull.
ENV PATH="/root/.claude/npm-global/bin:/root/.claude/python-user/bin:/root/.claude/pnpm-global/bin:/root/.claude/uv-tool-bin:$PATH"

# The pinned submodule is the application. Copying it (rather than cloning at
# build time) keeps the build reproducible from the committed pointer.
WORKDIR /app
COPY upstream/ /app/
RUN bun install --frozen-lockfile

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Claude Code config, hermes settings/state/logs, and agent-installed tooling.
VOLUME /root/.claude

# No EXPOSE: claude-hermes removed the web dashboard upstream. Telegram and
# Discord are the only interfaces, so nothing listens on a port.

ENTRYPOINT ["/entrypoint.sh"]
CMD ["start"]
