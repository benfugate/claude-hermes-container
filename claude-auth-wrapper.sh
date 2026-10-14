#!/bin/bash
# Launched by claude-hermes in place of `claude` (HERMES_CLAUDE_BIN).
# Upstream cleanChildEnv() strips every CLAUDE_CODE_* var, so the template's
# CLAUDE_CODE_OAUTH_TOKEN never reaches a turn. entrypoint.sh re-exposes it as
# HERMES_OAUTH_TOKEN, which survives; restore it here. With no token set this
# is a plain passthrough to .credentials.json auth.
if [ -z "${CLAUDE_CODE_OAUTH_TOKEN:-}" ] && [ -n "${HERMES_OAUTH_TOKEN:-}" ]; then
    export CLAUDE_CODE_OAUTH_TOKEN="${HERMES_OAUTH_TOKEN}"
fi
exec /usr/local/bin/claude "$@"
