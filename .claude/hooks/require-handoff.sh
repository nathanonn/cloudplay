#!/bin/bash
# PreToolUse hook (Bash): gate `git commit` so every commit carries a new
# handoff doc from docs/handoffs/, written by the main session via handoff-doc.

set -uo pipefail

input=$(cat)
cmd=$(jq -r '.tool_input.command // ""' <<<"$input")

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput: {
    hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: $r}}'
  exit 0
}

grep -Eq '(^|[;&|(]|\s)git(\s+-[cC]\s+\S+)*\s+commit(\s|$)' <<<"$cmd" || exit 0

# Subagents lack the session context a handoff needs; only the main session
# commits. The hook input carries agent_id only for subagent tool calls.
if [ -n "$(jq -r '.agent_id // empty' <<<"$input")" ]; then
  deny "Subagents don't commit. Report your changes back; the main session writes the handoff and commits."
fi

# --amend rewrites a commit that already has its handoff.
grep -Eq -- '--amend' <<<"$cmd" && exit 0

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

# A handoff already staged as added passes.
[ -n "$(git -C "$PROJECT_DIR" diff --cached --name-only --diff-filter=A -- 'docs/handoffs/*.md')" ] && exit 0

# An untracked handoff passes only if this same command `git add`s it, since
# the hook runs before the command stages anything.
untracked=$(git -C "$PROJECT_DIR" ls-files --others --exclude-standard -- 'docs/handoffs/*.md')
add_args=$(grep -oE '(^|[;&|(]|\s)git(\s+-[cC]\s+\S+)*\s+add\s[^;&|]*' <<<"$cmd" | sed -E 's/.*\badd\s//' | tr -d "\"'")

set -f  # match globs in add args ourselves, not against the filesystem
for f in $untracked; do
  for tok in $add_args; do
    case "$tok" in
      -A|--all) exit 0 ;;
      -*) continue ;;
    esac
    tok="${tok#./}"; tok="${tok%/}"
    # Exact path or glob, or a directory containing the handoff ("." is the root).
    if [[ -z "$tok" || "$tok" == "." || "$f" == $tok || "$f" == $tok/* ]]; then
      exit 0
    fi
  done
done

if [ -n "$untracked" ]; then
  deny "The new handoff ($(echo $untracked)) isn't staged. Add it with git add in this commit command, or stage it first."
fi
deny "No new handoff in docs/handoffs/. Run the handoff-doc skill to write the next YYYYMMDD_NN_slug.md, stage it with this change, then commit again."
