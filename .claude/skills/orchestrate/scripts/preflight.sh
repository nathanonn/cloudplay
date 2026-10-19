#!/usr/bin/env bash
# preflight.sh - orchestrate skill, step 1.
# Checks the main checkout before any sub-agent is dispatched and prints a
# KEY=value status block. Read-only: changes nothing in the repo.
#
# Exit codes:
#   0  OK to continue (WARN lines may still need attention)
#   1  error (not a git repo, bad usage)
#   2  STOP: on the default branch, main/master, or a detached HEAD
#      (ask for a branch; in no-ask mode, create the recommended one)
#   3  STOP: running inside a linked worktree, not the main checkout

set -euo pipefail

usage() {
  cat <<'EOF'
Usage: preflight.sh [--help]

Run from anywhere inside the repo's MAIN checkout (not a linked worktree).

Prints a status block:
  BRANCH=<name>          current branch (or HEAD if detached)
  DEFAULT=<name>         default branch (origin/HEAD, fallback "main")
  TREE=clean|dirty       working tree state (+ list of changed paths if dirty)
  WORKTREES=<n>          leftover .claude/worktrees/* worktrees (+ list)
  BASEREF=<value>        worktree.baseRef in the COMMITTED .claude/settings.json
  EFFORT_ENV=<v>|unset   CLAUDE_CODE_EFFORT_LEVEL (overrides per-call effort)
  BASE=<sha>             HEAD commit; brief this to every worktree agent
                         (omitted on STOP)

Exit: 0 ok (check WARN lines), 1 error, 2 STOP (default branch, main/master or
detached HEAD), 3 STOP (inside a linked worktree: cd to the main checkout).
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  "") ;;
  *) echo "ERROR: unknown argument: $1" >&2; usage >&2; exit 1 ;;
esac

if ! TOP=$(git rev-parse --show-toplevel 2>/dev/null); then
  echo "ERROR: not inside a git repository." >&2
  exit 1
fi
cd "$TOP"

warns=0
warn() { echo "WARN: $*"; warns=$((warns + 1)); }

# Running inside a linked worktree means we are not the orchestrator's checkout.
git_dir=$(git rev-parse --absolute-git-dir)
common_dir=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
if [ "$(cd "$git_dir" && pwd -P)" != "$common_dir" ]; then
  main_wt=$(git worktree list --porcelain | sed -n '1s/^worktree //p')
  echo "STOP: this is a linked worktree ($TOP), not the main checkout."
  echo "      The orchestrator dispatches, integrates and commits only from the main checkout: cd \"$main_wt\" and re-run."
  exit 3
fi

# Default branch: origin/HEAD, else "main".
DEFAULT=""
if ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null); then
  DEFAULT=${ref#origin/}
fi
if [ -z "$DEFAULT" ]; then
  DEFAULT=main
  warn "origin/HEAD is not set; assuming the default branch is 'main'."
fi

# Current branch ("HEAD" when detached).
if BRANCH=$(git symbolic-ref --quiet --short HEAD 2>/dev/null); then :; else BRANCH=HEAD; fi

echo "== orchestrate preflight =="
echo "REPO=$TOP"
echo "BRANCH=$BRANCH"
echo "DEFAULT=$DEFAULT"

# Tree state.
changes=$(git status --porcelain --untracked-files=normal)
if [ -z "$changes" ]; then
  echo "TREE=clean"
else
  n=$(printf '%s\n' "$changes" | wc -l | tr -d ' ')
  echo "TREE=dirty ($n paths)"
  printf '%s\n' "$changes" | head -n 20 | sed 's/^/  /'
  if [ "$n" -gt 20 ]; then echo "  ... ($((n - 20)) more)"; fi
  if printf '%s\n' "$changes" | grep -q '\.claude/worktrees/'; then
    warn ".claude/worktrees/ shows up as untracked; add it to .gitignore or 'git add -A' will stage worktrees."
  fi
fi

# Leftover sub-agent worktrees.
wt_lines=$(git worktree list --porcelain | awk '
  /^worktree /  { if (p != "") print p "\t" b "\t" l; p = substr($0, 10); b = "-"; l = "" }
  /^branch /    { b = substr($0, 8); sub("^refs/heads/", "", b) }
  /^detached/   { b = "(detached)" }
  /^locked/     { l = "locked" }
  END           { if (p != "") print p "\t" b "\t" l }
' | grep -F '/.claude/worktrees/' || true)
if [ -z "$wt_lines" ]; then
  echo "WORKTREES=0"
else
  n=$(printf '%s\n' "$wt_lines" | wc -l | tr -d ' ')
  echo "WORKTREES=$n"
  printf '%s\n' "$wt_lines" | while IFS=$'\t' read -r p b l; do
    echo "  $p  [$b]${l:+ $l}"
  done
  warn "leftover worktrees from an earlier run. Integrate or discard each, then run cleanup-worktree.sh <path> <branch>. A 'locked' one may belong to an agent that is still running."
fi

# worktree.baseRef in the committed settings (cloud sessions read only that file).
BASEREF=missing
if settings=$(git show HEAD:.claude/settings.json 2>/dev/null); then
  if command -v jq >/dev/null 2>&1; then
    v=$(printf '%s' "$settings" | jq -r '.worktree.baseRef // empty' 2>/dev/null || true)
    [ -n "$v" ] && BASEREF=$v
  else
    flat=$(printf '%s' "$settings" | tr -d ' \t\r\n')
    v=$(printf '%s' "$flat" | grep -o '"worktree":{[^}]*' | grep -o '"baseRef":"[^"]*"' | sed 's/.*:"//; s/"$//' || true)
    [ -n "$v" ] && BASEREF=$v
  fi
else
  BASEREF="missing (no committed .claude/settings.json)"
fi
echo "BASEREF=$BASEREF"
if [ "$BASEREF" != "head" ]; then
  warn "worktree.baseRef is not \"head\" in the committed .claude/settings.json. Worktree agents will start from origin/$DEFAULT, not this branch. Add {\"worktree\":{\"baseRef\":\"head\"}} or avoid isolation: \"worktree\"."
fi

# .claude/worktrees/ and Claude Code runtime files ignored? Otherwise
# `git add -A` stages them into commits.
if ! git check-ignore -q .claude/worktrees/probe 2>/dev/null; then
  warn ".claude/worktrees/ is not ignored by git (.gitignore or .git/info/exclude)."
fi
unignored=""
for probe in .claude/agent-registry.json .claude/checkpoints/probe .claude/mailbox/probe .claude/scheduled_tasks.lock; do
  git check-ignore -q "$probe" 2>/dev/null || unignored="$unignored ${probe%/probe}"
done
if [ -n "$unignored" ]; then
  warn "Claude Code runtime paths are not ignored:$unignored. Check 'git status --short' before any 'git add -A'."
fi

# Effort overrides: the env var beats every per-call effort, maxEffortLevel
# caps it. Either way the task labels would not match what runs.
if [ -n "${CLAUDE_CODE_EFFORT_LEVEL:-}" ]; then
  echo "EFFORT_ENV=$CLAUDE_CODE_EFFORT_LEVEL"
  warn "CLAUDE_CODE_EFFORT_LEVEL=$CLAUDE_CODE_EFFORT_LEVEL is set and overrides every per-call effort. Labels will not match what runs: say so in the report (or unset it in the session's settings)."
else
  echo "EFFORT_ENV=unset"
fi
for f in .claude/settings.json .claude/settings.local.json "${HOME:-/nonexistent}/.claude/settings.json" \
         /etc/claude-code/managed-settings.json /etc/claude-code/managed-settings.d/*.json \
         "/Library/Application Support/ClaudeCode/managed-settings.json"; do
  if [ -r "$f" ] && grep -q '"maxEffortLevel"' "$f" 2>/dev/null; then
    warn "maxEffortLevel appears in $f; per-call effort above that cap is lowered. Say so in the report."
  fi
done

# Session model: the script cannot see it.
echo "MODEL_CHECK=manual (confirm the session runs Opus 5.5; if not, tell the user once, or in no-ask mode add a report line)"

# STOP conditions last, so the status block is always complete.
ask="Ask the user for a branch (recommend the branch your system prompt designates, if any; otherwise claude/<slug>; in no-ask mode create that one without asking), then: git switch -c <name> (or git switch <name> if it exists)"
if [ "$BRANCH" = "HEAD" ]; then
  echo "STOP: detached HEAD. $ask"
  exit 2
fi
case "$BRANCH" in
  "$DEFAULT"|main|master)
    echo "STOP: on '$BRANCH' (the default branch). $ask"
    exit 2 ;;
esac

echo "BASE=$(git rev-parse HEAD)"
echo "RESULT=ok ($warns warning(s))"
exit 0
