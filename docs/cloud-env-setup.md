# Auto-provisioning Firecrawl + playwright-cli in Claude Code on the web

This documents how `cloudplay` brings up a self-hosted Firecrawl stack and a
working `playwright-cli` automatically in a Claude Code cloud session, and —
more usefully — *why* the setup looks the way it does. Most of the shape comes
from five constraints of the sandbox that are not obvious until you hit them.

## What runs, and when

| Piece | Path |
| --- | --- |
| SessionStart hook | `.claude/hooks/session-start.sh` |
| Hook registration | `.claude/settings.json` |
| Provisioning script | `scripts/setup-env.sh` |
| Firecrawl stack | `docker/firecrawl/docker-compose.yml` |
| TLS-interception overlay | `docker/firecrawl/docker-compose.proxy-ca.yml` |
| Containerised browser | `docker/chromium/Dockerfile` |
| playwright-cli config template | `config/playwright-cli.config.json` |

The hook fires on every session start, in this order:

1. Unless `CLAUDE_CODE_REMOTE=true`, it exits silently. Locally, Firecrawl is
   expected to be running already, and a second stack would fight over the port.
2. It appends `FIRECRAWL_API_URL`, `FIRECRAWL_API_KEY` and
   `CLOUDPLAY_CDP_ENDPOINT` to `$CLAUDE_ENV_FILE`, honouring `FIRECRAWL_PORT`,
   `CHROMIUM_CDP_PORT` and `FIRECRAWL_API_KEY` if they are set. Doing this
   before going async means the session has them even while images pull.
3. It prints `{"async": true, "asyncTimeout": 900000}`, so the session is usable
   immediately, and `exec`s `scripts/setup-env.sh --wait 840`.

The script is idempotent. When everything is already up, a re-run takes about
30 ms.

`scripts/setup-env.sh` also works as a standalone environment setup script if
you would rather configure it in the Claude Code web UI. The hook is the
primary path because it is the only one that survives container recycling
(see below).

```bash
./scripts/setup-env.sh            # provision, don't wait for Firecrawl
./scripts/setup-env.sh --wait [N] # provision, then block until Firecrawl answers
./scripts/setup-env.sh --status   # report, change nothing
./scripts/setup-env.sh --stop     # tear down
```

The default mode (also spelled `--background`) is not a background job. It runs
the whole provision in the foreground (npm installs, image pulls, the Chromium
build, `docker compose up -d`) and only skips waiting for Firecrawl to answer.
If another run already holds the setup lock, it exits at once.

`--wait [N]` takes an integer number of seconds (default 300) and measures it
from script start, so the time spent waiting for the lock and provisioning
counts against it. A non-integer `N` is rejected with exit 2, and a timeout
exits 1. The hook's 840 s keeps the script inside the 900 s `asyncTimeout`.
`--wait` releases the setup lock once provisioning is done, so its polling
never holds up another run.

## The five constraints

### 1. Nothing persists, so a one-time setup script is not enough

The cloud container is reclaimed after inactivity and the repo is re-cloned on
the next session. More specifically, **`dockerd` is installed but not running
and there is no systemd to start it** — `/var/run/docker.sock` simply does not
exist. Any approach that provisions once at environment-creation time leaves
later sessions with a dead daemon.

That is why the work lives in a SessionStart hook rather than in the web UI's
environment setup script: the hook runs every session, and the script's
idempotency check makes the warm case free.

The script starts `dockerd` with `setsid ... 9>&-` (or `nohup` where `setsid`
is missing). `setsid` puts the daemon in its own session, so a signal to the
hook's process group, such as when the async hook times out, does not take
`dockerd` down with it. Closing fd 9 is not cosmetic: `dockerd` outlives the
script, and without it the daemon inherits the `flock` file descriptor and
holds the setup lock for its entire life, which wedges every subsequent run.

### 2. Upstream's compose asks for a `nofile` limit this VM cannot grant

Upstream sets `ulimits.nofile` to 65535. This VM's hard limit is 20000, and
`runc` refuses to create the container at all rather than clamping:

```
error setting rlimits for ready process: error setting rlimit type 7:
operation not permitted
```

The vendored compose reads `${FIRECRAWL_NOFILE}`, which `setup-env.sh` sets
from the live `ulimit -Hn`.

### 3. Outbound TLS is intercepted — by two different CAs

This is the constraint that costs the most time, because the symptom rarely
names the cause.

Host processes reach the internet through the agent proxy at `$HTTPS_PROXY`
and must trust `/root/.ccr/ca-bundle.crt`. Containers do **not** use that
proxy; their egress is transparently intercepted by a *different* authority:

| Path | Presented chain |
| --- | --- |
| Host, via `$HTTPS_PROXY` | `CCR agent-proxy interception CA` |
| Container, transparent | `sandbox-egress-gateway ... Egress Gateway CA` |

`/root/.ccr/ca-bundle.crt` is the only file carrying both, so that is what gets
installed everywhere. `/root/.ccr/agent-proxy-ca.crt` alone is not enough for
containers — it was the first thing tried, and it does not work.

Without this, `playwright-service` does not merely scrape badly, it **exits 1
at boot**: its entrypoint corepack-downloads pnpm and dies on
`SELF_SIGNED_CERT_IN_CHAIN`. The stack looks half-up and every JS-rendered
scrape degrades silently. `docker-compose.proxy-ca.yml` mounts the bundle and
sets `NODE_EXTRA_CA_CERTS` / `SSL_CERT_FILE` for the affected services. It is a
separate overlay file, applied only when the CA bundle exists, so the base
compose stays usable on an ordinary host.

### 4. Host-side Chromium cannot get through the proxy at all

`playwright-cli` on the host fails every navigation with
`net::ERR_CONNECTION_RESET`. The proxy's own status endpoint shows the tunnel
opening and then dying mid-handshake:

```
ws_closed_mid_exchange example.com:443
tunnel closed (code 1006) after 6s; 1793 B sent, 39 B received, client reading
```

`curl`, `npm` and `docker pull` go through the same proxy without trouble, so
this is specific to Chromium's TLS handshake. Disabling ECH, QUIC, and
post-quantum key shares (the usual middlebox culprits, and the reason the
ClientHello is ~1800 B) changed nothing.

Containers, however, take the *other* egress path from constraint 3 — and
Firecrawl's own containerised Chromium renders pages fine. So the browser runs
in a container and `playwright-cli` attaches to it over CDP
(`browser.cdpEndpoint`), which is the arrangement `docker/chromium` exists to
support.

Two details there are worth keeping:

- Chromium on Linux reads the **NSS shared DB**, not `/etc/ssl/certs`, so the
  bundle is imported with `certutil` into `/root/.pki/nssdb` as well as the
  OpenSSL store. Installing it only into the OpenSSL store leaves you at
  `ERR_CERT_AUTHORITY_INVALID`.
- `chromedp/headless-shell` ships **no CA store whatsoever**, so
  `ca-certificates` is installed first. Debian's apt repos are plain HTTP, so
  that bootstrap step needs no trust of its own.

A version-matched Playwright *server* (`browser.remoteEndpoint`) would be
richer than CDP, but `@playwright/cli` currently pins
`playwright-core@1.63.0-alpha-2026-08-05` and no published image matches an
alpha build. CDP is version-tolerant, so that is what is used.

### 5. Docker Hub rate-limits anonymous pulls, and the egress IP is shared

A cold provision once died with

```
failed to resolve reference "docker.io/library/rabbitmq:3-management":
unexpected status from HEAD request ... 429 Too Many Requests
```

Anonymous Docker Hub pulls are limited per source IP, and cloud sessions share
egress IPs, so the quota can be spent before this session pulls anything.
Left to `docker compose up`, that one failed pull interrupted every other pull
in flight and the stack never came up. Retrying alone does not help much: the
quota refills over hours, not seconds.

So `setup-env.sh` now pulls every image itself before `compose up`, in
parallel, each with up to `PULL_ATTEMPTS` (default 4) rounds and exponential
backoff (5 s, 10 s, 20 s). Within a round, a Docker Hub image that fails is
retried from Google's pull-through mirror, `mirror.gcr.io`, which does not
share Hub's anonymous limit, and re-tagged under its original name, so compose
finds it locally and never pulls. Images on other registries (`ghcr.io`) get
the retries without the mirror.

The Chromium build needs the same treatment separately. BuildKit re-resolves
the `FROM` image against its registry (`load metadata for docker.io/...`)
even when the image is already local. The Dockerfile therefore takes its base
as `ARG BASE_IMAGE`, and a failed build is retried with the mirror's copy.

If `DOCKERHUB_USERNAME` and `DOCKERHUB_TOKEN` are set in the environment, the
script also runs `docker login` first. An authenticated account gets a much
higher pull limit.

## Connecting to the local instance

Firecrawl runs with `USE_DB_AUTHENTICATION=false` and accepts any bearer token,
but the CLI still requires one to be present. The hook exports these values via
`$CLAUDE_ENV_FILE`, and `.cloudplay/env.sh` carries the same for shells that
need to source them:

```bash
export FIRECRAWL_API_URL="http://localhost:3663"
export FIRECRAWL_API_KEY="local-self-hosted"
export CLOUDPLAY_CDP_ENDPOINT="http://localhost:9222"
```

Port 3663 is this project's convention, used by the hook, the scripts and
`CLAUDE.md`; upstream defaults to 3002. With authentication off, the compose
file publishes the API on `127.0.0.1` only, as `setup-env.sh` does for the
Chromium CDP port. Anything bound to `0.0.0.0` would be an open scraping proxy
for whoever can reach the host.

Do not run `firecrawl --status` — it checks cloud API auth and always reports
"Not authenticated" against a local instance. Use `./scripts/setup-env.sh
--status` instead.

## Which Firecrawl this runs

The compose file tracks `ghcr.io/firecrawl/firecrawl:latest`. Firecrawl
publishes no semantic version tag for self-hosting — `latest` is built from
upstream `main`, and the image records the commit it was built from:

```bash
docker run --rm --entrypoint sh ghcr.io/firecrawl/firecrawl:latest \
  -c 'cat /app/BUILD_SHA'
```

The consequence worth knowing: because a fresh container pulls `latest`, two
sessions a week apart can be running different Firecrawl builds, and an
upstream regression arrives without any change on our side. To freeze it,
replace the tag with the digest from `docker image inspect ... RepoDigests`.

The compose project is named `cloudplay-firecrawl`, so its containers come up as
`cloudplay-firecrawl-api-1` and so on (`docker logs cloudplay-firecrawl-api-1`
is the first place to look when the API misbehaves). Upstream's project name is
plain `firecrawl`. Keeping the names apart means a local upstream checkout's
stack is never the one `setup-env.sh --stop` tears down.

## Known limitations

Verified against the running stack rather than assumed — `search`, `map`,
`scrape` and `crawl` all work on self-host with no extra configuration.

- **LLM-backed extraction needs `OPENAI_API_KEY`.** Without it the `json`
  format fails soft rather than erroring: the response is `success: true` with
  `"json": null` and the reason tucked into a `warning` field
  (`Incorrect API key provided: ''`). Credits are still counted. `agent` and
  `extract` depend on the same key. The compose file passes it through when
  set.
- **`SEARXNG_ENDPOINT` is optional, not required.** Self-hosted search works
  out of the box: upstream's `apps/api/src/search/v2/index.ts` (in
  [firecrawl/firecrawl](https://github.com/firecrawl/firecrawl), not this repo)
  tries SearXNG only when the endpoint is configured and otherwise falls back
  to DuckDuckGo. Set it if you
  want a search backend you control, not to make search function.
- **`map` returns same-domain URLs only.** Mapping a single-page site with no
  internal links returns `[]` — `example.com` is a trap here, since its one
  link points off-site to iana.org. Real sites behave normally
  (docs.firecrawl.dev returns ~1200 links, playwright.dev ~350).
- **The browser runs in a container**, so local paths passed to
  `playwright-cli upload` resolve against the container filesystem, not the
  repo.
- **First run on a genuinely cold container is slow** — several GB of images.
  With the images already pulled, bringing the stacks back up after a restart
  takes roughly 25 seconds. The ~30 ms figure above is a re-run with everything
  already up.
- **`playwright-cli` may report a skill version mismatch** against the vendored
  `.claude/skills/playwright-cli`. `playwright-cli install --skills` updates it,
  but that rewrites tracked files, so it is left as a deliberate manual step.
