#!/bin/bash
# SessionStart hook (matcher: compact): after a compaction, point Claude at the
# latest handoff doc so it reloads the current project state.

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

latest=$(ls -1 "${PROJECT_DIR}"/docs/handoffs/*.md 2>/dev/null | sort | tail -n 1)
[ -z "$latest" ] && exit 0

echo "Context was just compacted. Read the latest handoff before continuing: ${latest#"${PROJECT_DIR}"/}"
echo "Earlier handoffs are in docs/handoffs/ if you need more history."
