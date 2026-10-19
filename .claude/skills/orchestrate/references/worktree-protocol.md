# Worktree protocol

How the orchestrator keeps parallel writers apart with git worktrees, then brings
their work back into the feature branch without ever touching `main`.

Scripts live at `.claude/skills/orchestrate/scripts/` relative to the repo root
(SKILL.md gives the same folder as `${CLAUDE_SKILL_DIR}/scripts/`; that variable
is expanded only inside SKILL.md, not in this file or in your shell). Run them
from the main checkout, the repo root where the session started. Each prints
`KEY=value` lines and ends with a `RESULT=`, `STOP:` or `REFUSED:` line.

## Contents

1. Why the protocol looks like this
2. One-time repo setup
3. Preflight
4. Dispatch rules
5. Dirty tree before a worktree wave
6. Integrate
7. Conflicts and rollback
8. Cleanup
9. Push
10. Things not yet confirmed live

## 1. Why the protocol looks like this

- **Worktree agents branch from a commit, not from your working tree.** By default
  (`worktree.baseRef: "fresh"`) Claude Code bases them on `origin/<default>`, the
  default branch, not your feature branch. With `"head"` they start from the current
  local HEAD, including unpushed commits, but **never** from uncommitted edits.
- **Sub-agents cannot commit** in this repo: the commit hook
  (`.claude/hooks/require-handoff.sh`) denies `git commit` whenever the hook
  input carries an `agent_id`. Their work stays uncommitted in
  the worktree, and `worktree-agent-*` branches have no new commits, so merge and
  cherry-pick have nothing to take. Integration is a **patch transfer**.
- **Do not commit inside a worktree from the main session** either: the hook looks
  for a staged handoff in the main checkout, and committing there would fork the
  history away from the feature branch.
- **The orchestrator never enters a worktree** (`EnterWorktree`). It has to stay in
  the main checkout to run git there, integrate patches and commit.
- **`isolation: "remote"` is never used.** Inside a cloud session it silently falls
  back to an unisolated local agent.

## 2. One-time repo setup

- `.claude/settings.json`: `"worktree": {"baseRef": "head"}` and
  `"env": {"CLAUDE_CODE_ENABLE_TODO_TOOLS": "1"}`. Cloud sessions read only the
  committed project settings, so this has to be committed.
- `.gitignore`: `.claude/worktrees/`, so worktrees never show as untracked and
  `git add -A` never stages them.
- `.worktreeinclude`: `.cloudplay/env.sh` and `.playwright/cli.config.json`, so
  worktree agents get the Firecrawl env and the CDP config for `playwright-cli`.
  Both paths must be gitignored, or the list does nothing (they already are).

## 3. Preflight

```bash
bash .claude/skills/orchestrate/scripts/preflight.sh
```

| Output | Meaning | Action |
|---|---|---|
| `STOP: on 'main'` / `STOP: detached HEAD` (exit 2) | An orchestrated run would work on the default branch | AskUserQuestion for a branch: recommend the branch your system prompt designates, if any, else `claude/<slug>`; `git switch -c <name>` (or `git switch <name>`); re-run preflight. No-ask mode: skip the question, create the recommended branch, log it |
| `STOP: this is a linked worktree` (exit 3) | You drifted into a worktree | `cd` to the main checkout it prints and re-run |
| `TREE=dirty` | Uncommitted edits exist | Fine for read-only agents and a lone unisolated writer. Before a worktree wave, see §5 |
| `WORKTREES=n` > 0 | Leftovers from an earlier run | Ask the user whether to integrate or discard each, then cleanup (§8). A `locked` one may still be running: wait for its notification. No-ask mode: leave them untouched (no integrate, no cleanup, never `--force-unlock`) and list them under **Skipped** |
| `WARN: worktree.baseRef is not "head"` | Worktree agents would start from `origin/main` | Do not use worktree isolation this run: run writers one at a time, unisolated. Tell the user the settings key is missing* |
| `WARN: .claude/worktrees/ is not ignored` | `git add -A` would stage worktrees | Do not `git add -A` in the main checkout; stage explicit paths. Tell the user* |
| `WARN: Claude Code runtime paths are not ignored` | `git add -A` could stage harness files | Check `git status --short` before every `git add -A`; stage explicit paths if anything unexpected shows |
| `EFFORT_ENV=<level>` + `WARN: CLAUDE_CODE_EFFORT_LEVEL is set` | It overrides every per-call `effort` | Keep routing as usual, but labels no longer match what runs: say so in the report* |
| `WARN: maxEffortLevel appears in <file>` | Per-call `effort` above the cap is lowered | As above, for tasks routed above the cap* |
| `BASE=<sha>` | The commit worktree agents must start from | Put it in every worktree brief and in task metadata |

\* In no-ask mode, "tell the user" / "say so" becomes a line in the final report.

## 4. Dispatch rules

- **Reads before writes.** Explore and other read-only agents need no isolation and
  can run alongside anything.
- **Parallel writers get `isolation: "worktree"` on the Agent call.** Give each a
  disjoint set of owned files anyway: isolation prevents clobbering, it does not
  prevent conflicting decisions.
- **A lone writer** (no other writer running or about to run in the same wave) may
  run unisolated in the main checkout. It sees your uncommitted edits, needs no
  BASE check and no integration step. Prefer this for a single writer: it is
  simpler and cheaper.
- **Same files, different tasks** → run them in sequence, not in parallel, with the
  first one integrated before the second starts.
- **Wave N+1 depends on wave N's writes and uses worktrees** → the integrated result
  must be committed first (§5), because worktrees only see commits.
- At most 5 agents running at once, counting read-only ones and agents spawned by
  other skills.
- Each worktree brief includes BASE, the main checkout's absolute path (so the
  agent knows what not to edit), the HEAD check and repo-relative paths only. See
  [brief-template.md](brief-template.md).

## 5. Dirty tree before a worktree wave

Worktree agents would not see uncommitted edits. Make a checkpoint commit first,
following the repo's CLAUDE.md (Handoffs):

1. Run the `handoff-doc` skill to write the next `docs/handoffs/YYYYMMDD_NN_slug.md`.
2. Check `git status --short`, then `git add -A && git commit -m "<checkpoint
   message>"` (the hook accepts `-A` when the new handoff is untracked).
3. Re-run preflight and use the new `BASE`.

Do not work around this with `git stash`, `commit-tree` or `update-ref`: they
either hide the edits from you or bypass the handoff gate.

## 6. Integrate

Take finished agents one at a time, in dependency order (TaskList `blockedBy`).
The completion notification of a worktree agent that changed files carries
`worktreePath:` and `worktreeBranch:` (expected `.claude/worktrees/agent-a…` and
`worktree-agent-a…`). An agent that changed nothing has its worktree removed
automatically.

```bash
bash .claude/skills/orchestrate/scripts/integrate-worktree.sh <worktreePath> <worktreeBranch> <BASE>
```

Before applying, it prints `PRE_TREE=<sha>` and
`ROLLBACK: git read-tree -u --reset <PRE_TREE>`. Note both in the task metadata
until the task is verified. The rollback restores the index and working tree
exactly as they were before this patch (untracked files are left alone). It is
exact because the script refuses to run while any tracked file has unstaged edits.

| Exit | `RESULT` | Action |
|---|---|---|
| 0 | `applied` | The change is now **staged** in the main checkout. Check the `--stat` matches the task's owned files, read the diff, run the task's verification here, then mark the task completed and clean up |
| 0 | `empty` | The agent changed nothing against BASE. Check its report: was "nothing to change" correct? |
| 3 | `conflicts` | See §7 |
| 4 | `STOP: … does not descend from BASE` | The worktree started from another commit (baseRef missing, or the agent checked out something). Do not integrate; inspect by hand or re-dispatch |
| 5 | `STOP: unresolved conflicts` / `unstaged edits` | Finish the previous conflict, or `git add` your own edits (or checkpoint), then re-run |
| 1 | `failed` / `ERROR` | Read the `git:` lines; often a new file that already exists here. Nothing was applied |

Warnings to act on:

- `WARN: … commit(s) beyond BASE`: a sub-agent managed to commit (it should not).
  The commits are included in the patch; say so in the report.
- `--stat` lists files outside the agent's ownership: read those hunks before
  verifying. If they are unwanted, roll the whole patch back and re-brief the
  agent (or SendMessage it to revert them in its own worktree), then integrate
  again.

**Verification in the main checkout** must exclude `.claude/worktrees/`: test
runners with glob discovery and `grep -r` would otherwise pick up the worktree
copies. If a tool can't exclude it, run that verification after cleanup.

**Re-integrating a resumed agent.** The script always diffs the whole worktree
against BASE, so the second run re-applies everything the agent ever changed. If
that agent's earlier integration was the last one, roll it back with its
`ROLLBACK` line first, then integrate again. If other patches came after it, do
not roll back (that would undo them too); integrate again and re-check the
`--stat` for hunks you had removed by hand, since they come back.

`git apply --3way` stages what it applies, so after several integrations the index
holds the combined result.

## 7. Conflicts and rollback

`integrate-worktree.sh` leaves `<<<<<<< ours` / `>>>>>>> theirs` markers and lists
the files. "ours" is the main checkout (including earlier integrations), "theirs"
is this agent.

All conflict resolution happens in the main session. You hold the plan and the
settled decisions; no agent does. Never hand a conflict to a sub-agent.

1. **Resolve**: edit the markers, `git add <file>` for each resolved file, then run
   the verification of **both** tasks involved, since both changes now share the
   file.
2. **Keep ours for one file only** (the rest of the patch is wanted):
   `git checkout --ours -- <file> && git add <file>`.
3. **Abandon this agent's whole patch** (too big to resolve, or wrong): run the
   `ROLLBACK:` line the script printed, `git read-tree -u --reset <PRE_TREE>`. It
   removes every hunk of this patch, the clean ones too, and restores the exact
   pre-apply state. Then re-dispatch the task in sequence, after a checkpoint
   commit so its new worktree starts from the current state.

Do not abandon a patch with `git checkout --ours` alone: the agent's clean hunks
stay staged and the next checkpoint commit would capture a half-integrated task.

To avoid conflicts next time: disjoint file ownership, and same-file tasks in
sequence.

## 8. Cleanup

After the patch is applied and verified (or rolled back on purpose), and after your
last SendMessage follow-up to that agent:

```bash
bash .claude/skills/orchestrate/scripts/cleanup-worktree.sh <worktreePath> <worktreeBranch> --patch <PATCH>
```

Every check runs before anything is removed. The script refuses (exit 2, nothing
changed) when:

- the path is not under `<repo>/.claude/worktrees/`;
- `git worktree list --porcelain` shows the path on a different branch, or the
  path is gone but the branch is checked out in another worktree. Pair each
  `worktreePath` with the `worktreeBranch` from the **same** completion; with
  several agents finishing together a crossed pair would delete unintegrated work;
- the worktree is **locked**. Claude Code holds that lock while the agent runs, so
  wait for its completion notification. Only for a leftover from a dead or
  reclaimed session, re-run with `--force-unlock`;
- the branch is the default branch, `main`/`master`, the branch checked out here,
  or not named `worktree-*` (override the last one with `--any-branch` only if you
  are sure).

Then it removes the worktree, deletes the local branch, prunes metadata and deletes
the patch (`--patch` covers the case where `TMPDIR` differed between calls). At the
end of the run, `git worktree list` should show only the main checkout.

## 9. Push

Commit only at checkpoints, through `handoff-doc` → commit (see SKILL.md step 8).
Push only the feature branch: `git push -u origin HEAD`. Never push `main`, never
push `worktree-agent-*` branches, never `git push origin --delete` (the cloud proxy
rejects branch deletions, and these branches are local anyway). The cloud proxy
does **not** block pushes to `main`, so this discipline is the only guard.

## 10. Things not yet confirmed live

These come from docs and binary inspection, not from a live cloud run of this
skill. React to what you actually see:

- A worktree agent reports a HEAD different from BASE → `baseRef: head` did not
  take effect. Stop using worktrees this run, run writers sequentially and
  unisolated, and tell the user (no-ask mode: a report line).
- The completion lacks `worktreePath` / `worktreeBranch` → find them with
  `git worktree list --porcelain` (paths under `.claude/worktrees/`).
- The Agent tool has no `effort` parameter (Claude Code older than v2.1.292) →
  omit it, keep the intended effort in the task label, and say in the report that
  effort was not applied.
- `/tasks` shows an effort different from the label → `CLAUDE_CODE_EFFORT_LEVEL`
  or `maxEffortLevel` is in force (or Explore ignores per-call effort). Report
  the effort that ran.
- A worktree agent lacks `.cloudplay/env.sh` or `.playwright/cli.config.json`
  (`.worktreeinclude` did not copy them, or the session's setup hook had not
  written them yet) → it may `source <main checkout>/.cloudplay/env.sh`; reading
  that file is allowed by the brief. Report the gap.
- A resumed (SendMessage) worktree agent seems to work outside its worktree →
  stop resuming worktree agents; re-brief a fresh one instead.
- After a cloud resume, an `in_progress` agent never reports → the VM was probably
  reclaimed. Compare `git worktree list` with the task metadata and re-dispatch
  (SKILL.md "After a compaction or resume").
