#!/bin/bash
set -e

# claude-hermes resolves its state directory from CWD as `.claude/hermes/`
# (src/paths.ts), so everything below assumes we run from /root and therefore
# land inside the volume-mounted /root/.claude/.
SETTINGS_DIR="/root/.claude/hermes"
SETTINGS_FILE="${SETTINGS_DIR}/settings.json"
LEGACY_DIR="/root/.claude/claudeclaw"

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

exec bun run /app/src/index.ts "$@"
