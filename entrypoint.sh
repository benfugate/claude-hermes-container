#!/bin/bash
set -e

# claude-hermes resolves its state directory from CWD as `.claude/hermes/`
# (src/paths.ts), so everything below assumes we run from /root and therefore
# land inside the volume-mounted /root/.claude/.
SETTINGS_DIR="/root/.claude/hermes"
SETTINGS_FILE="${SETTINGS_DIR}/settings.json"
LEGACY_DIR="/root/.claude/claudeclaw"

cd /root

# Create the directories the persistence env vars point at. The vars are set as
# Dockerfile ENV; only the mkdir has to happen here, because the volume does not
# exist at image-build time.
#
#   tmp/           TMPDIR on the same filesystem as the volume, so installs can
#                  rename() into /root/.claude/ without crossing devices (EXDEV)
#   npm-global/    npm -g prefix; its bin/ holds the ssh + scp wrappers
#   npm-cache/     npm + npx download cache
#   python-user/   pip user base (PEP 668 bypassed via PIP_BREAK_SYSTEM_PACKAGES)
#   pip-cache/     pip download cache
#   pnpm-global/   pnpm store, manifest and bin/
#   uv-tools/      one isolated venv per `uv tool install`
#   uv-tool-bin/   uv shim scripts on PATH
#   uv-cache/      shared uv / uvx cache
#   uv-python/     interpreters from `uv python install`
mkdir -p /root/.claude/tmp \
         /root/.claude/npm-global/bin /root/.claude/npm-cache \
         /root/.claude/python-user/bin /root/.claude/pip-cache \
         /root/.claude/pnpm-global \
         /root/.claude/uv-tools /root/.claude/uv-tool-bin \
         /root/.claude/uv-cache /root/.claude/uv-python

# ── File memory ───────────────────────────────────────────────────────────────
# claude-hermes resolves file memory as `<cwd>/memory` (src/paths.ts memoryDir),
# and cwd is /root — one level ABOVE the volume. Worse, prompts/RULES.md ships a
# non-overridable "MEMORY OVERRIDE" block telling the agent that <project-root>/
# memory/ is the *only* legal place to write, so it cannot opt out.
#
# That put every note in the container's writable layer. Unraid's CA Auto Update
# runs `dockerUpdateAll` nightly at 02:00 and RECREATES the container on each new
# image digest, so the agent silently lost all of its notes every day or two
# while its episodic layer (state.db, inside the volume) kept working — it
# remembered the conversations but not the conclusions.
#
# Redirect the directory into the volume, the same way /root/.ssh is redirected
# to /root/.claude/ssh. Done here rather than in the Dockerfile because the
# volume does not exist at image-build time.
mkdir -p /root/.claude/memory
if [ -d /root/memory ] && [ ! -L /root/memory ]; then
    # A real directory means notes written before this fix (or by a container
    # that predates it). Preserve them; -n so the volume copy always wins.
    cp -an /root/memory/. /root/.claude/memory/ 2>/dev/null || true
    rm -rf /root/memory
fi
ln -sfn /root/.claude/memory /root/memory

# ── OAuth token ───────────────────────────────────────────────────────────────
# cleanChildEnv() (upstream src/runner.ts) strips every CLAUDE_CODE_* var before
# spawning claude, so a CLAUDE_CODE_OAUTH_TOKEN set in the container template
# never reaches a turn. Re-expose it under a name that survives; the
# hermes-claude wrapper (HERMES_CLAUDE_BIN) turns it back.
if [ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]; then
    export HERMES_OAUTH_TOKEN="${CLAUDE_CODE_OAUTH_TOKEN}"
fi

# ── Stale PID file ────────────────────────────────────────────────────────────
# hermes refuses to start while hermes/daemon.pid names a live process. After an
# unclean stop the file holds 1, and inside a fresh container PID 1 is always
# alive (it is this script, then bun), so the daemon would never come back. Only
# one daemon runs per container, so any pid file at container start is stale.
rm -f "${SETTINGS_DIR}/daemon.pid"

# ── Init hooks ────────────────────────────────────────────────────────────────
# Lets one image serve more than one agent. A deployment mounts a directory of
# `*.sh` scripts at HERMES_INIT_DIR and each runs here, in name order, before
# hermes starts: seed hermes/settings.json, install a CLAUDE.md or .mcp.json,
# merge Claude Code settings. They run after the volume directories above exist,
# so uv/npm/pip installs land in the volume, and before the default settings
# below, so a hook that writes settings.json wins. A failing hook stops the
# container instead of starting a half-configured agent.
#
# Hooks run as root before anything else, so they must come from the operator,
# never from the agent. The agent can write anywhere in /root/.claude and that
# survives image updates, so a hook directory inside it would let one turn plant
# code that runs on every later start. Refuse it outright (realpath catches a
# symlink such as /root/memory). Mount the directory read-only.
INIT_DIR="${HERMES_INIT_DIR:-/etc/hermes/init.d}"
case "$(realpath -m "${INIT_DIR}")/" in
    /root/.claude/*|/root/memory/*)
        echo "[hermes] HERMES_INIT_DIR=${INIT_DIR} is inside the agent's volume; refusing to start." >&2
        exit 1
        ;;
esac
if [ -d "${INIT_DIR}" ]; then
    for hook in "${INIT_DIR}"/*.sh; do
        [ -f "${hook}" ] || continue
        echo "[hermes] init hook: ${hook}"
        # bash rather than ./hook: bind-mounted files often lack the exec bit.
        bash "${hook}"
    done
fi

# Do NOT bootstrap settings while an unmigrated claudeclaw directory is present.
#
# claude-hermes ships a one-shot migrator (src/migrate/legacy.ts) that copies
# .claude/claudeclaw -> .claude/hermes on first start. It refuses with status
# "conflict" if BOTH directories already exist without a MIGRATED marker. So
# creating a default settings.json here first would permanently block the
# migration and leave the real config stranded in the legacy directory.
if [ -d "${LEGACY_DIR}" ] && [ ! -f "${SETTINGS_DIR}/.MIGRATED" ] && [ ! -d "${SETTINGS_DIR}" ]; then
    echo "[hermes] Legacy claudeclaw directory found and hermes/ is absent."
    echo "[hermes] Leaving both alone so the built-in migrator can run."
elif [ ! -f "${SETTINGS_FILE}" ]; then
    mkdir -p "${SETTINGS_DIR}"
    cat > "${SETTINGS_FILE}" << 'EOF'
{
  "model": "opus",
  "telegram": {
    "token": "",
    "allowedUserIds": []
  },
  "discord": {
    "token": "",
    "allowedUserIds": [],
    "listenChannels": [],
    "statusChannelId": ""
  }
}
EOF
    echo "[hermes] Created default settings at ${SETTINGS_FILE}"
    echo "[hermes] Add your Discord bot token and allowedUserIds before use."
fi

# ── Scheduled session reset ───────────────────────────────────────────────────
# SESSION_RESET_CRON (5-field cron in TZ) clears every conversation's Claude
# session on a schedule, the same UPDATE hermes runs for /reset. hermes has no
# time-based reset of its own. Unset or "off" leaves conversations alone.
if [ -n "${SESSION_RESET_CRON:-}" ] && [ "${SESSION_RESET_CRON}" != "off" ]; then
    bun run /opt/hermes-container/session-reset.ts &
fi

exec bun run /app/src/index.ts "$@"
