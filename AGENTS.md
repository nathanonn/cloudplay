## Handoffs

- Commit at each **checkpoint** without asking: a unit of work (feature, fix,
  decision) that is done and verified, or the point before switching to an
  unrelated task. The handoff each commit carries is what survives autocompact.
- Before every commit, run the `handoff-doc` skill to write a new handoff in
  `docs/handoffs/` (`YYYYMMDD_NN_slug.md`, next `NN` for the day), and include
  it in that commit.
- Only the main session commits. Subagents report their changes back instead,
  since a handoff needs the full session context.
- After an autocompact, read the latest handoff in `docs/handoffs/` before
  continuing. Read earlier ones too if the latest leaves gaps.

## Firecrawl

- **Always use Firecrawl skills** (firecrawl, firecrawl-scrape, firecrawl-search, etc.) for web searches and scraping. Avoid the built-in WebFetch/WebSearch tools.
- Firecrawl is self-hosted at `http://localhost:3663`. Use the `firecrawl` command to interact with it.
- **NEVER run `firecrawl --status`** — it checks cloud API auth and always shows "Not authenticated" for a local instance. Instead, check if Firecrawl is running with: `curl -s --noproxy '*' http://localhost:3663 > /dev/null 2>&1`.
- If Bash sandboxing is enabled, run all Firecrawl-related commands (including health checks) with `dangerouslyDisableSandbox: true`; the sandbox blocks access to the local API.
- Don't start or stop the Firecrawl stack yourself. On a local machine it is expected to already be running from the user's own setup (the SessionStart hook deliberately does nothing locally); if it is down, tell the user instead of trying to start it.
- **Sub-agents**: When spawning agents that may need web access, include these Firecrawl rules in the agent prompt so they use Firecrawl instead of built-in web tools.

## Cloud sessions (Claude Code on the web)

- Firecrawl and `playwright-cli` are provisioned automatically by the
  SessionStart hook (`.claude/hooks/session-start.sh` -> `scripts/setup-env.sh`).
  Do not start Firecrawl by hand, and don't run `./scripts/setup-env.sh --stop`.
- Check the stacks with `./scripts/setup-env.sh --status`. If Firecrawl is still
  booting, `./scripts/setup-env.sh --wait` blocks until it answers.
- The hook exports `FIRECRAWL_API_URL` and `FIRECRAWL_API_KEY`; a shell without
  them can `source .cloudplay/env.sh`.
- `playwright-cli` drives a browser running in a container over CDP; host-side
  Chromium cannot reach the network in this sandbox.
- See `docs/cloud-env-setup.md` for the constraints behind this setup.
