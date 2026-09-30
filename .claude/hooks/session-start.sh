#!/bin/bash
# SessionStart hook: bring up self-hosted Firecrawl + playwright-cli.

set -uo pipefail

# Only provision in Claude Code on the web. On a local machine Firecrawl is
# expected to be running already from the user's own setup, and a second stack
# would fight over the port. Exit silently: no output is a valid hook result.
if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# Export the connection settings before going async, so they are in place for
# the session even while image pulls are still running. Same defaults as
# setup-env.sh's write_env_file.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export FIRECRAWL_API_URL=\"http://localhost:${FIRECRAWL_PORT:-3663}\""
    echo "export FIRECRAWL_API_KEY=\"${FIRECRAWL_API_KEY:-local-self-hosted}\""
    echo "export CLOUDPLAY_CDP_ENDPOINT=\"http://localhost:${CHROMIUM_CDP_PORT:-9222}\""
  } >> "$CLAUDE_ENV_FILE"
fi

# Async mode -- this JSON line must be the first thing on stdout. It hands the
# rest of this script to the background so the session is usable immediately.
# Cold containers spend several minutes pulling images, which is why the
# timeout is generous; --wait 840 keeps setup-env.sh inside it.
echo '{"async": true, "asyncTimeout": 900000}'

exec "${PROJECT_DIR}/scripts/setup-env.sh" --wait 840
