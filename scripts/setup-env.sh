#!/usr/bin/env bash
# Provision self-hosted Firecrawl + playwright-cli for this workspace.
#
# Idempotent and safe to re-run: every step checks before it acts, so the
# common case (container already provisioned) exits in well under a second.
#
# Run modes:
#   ./scripts/setup-env.sh            provision in the foreground (npm installs,
#     (or --background)               image pulls, Chromium build, compose up -d)
#                                     but don't wait for Firecrawl to answer;
#                                     exits at once if another run holds the lock
#   ./scripts/setup-env.sh --wait [N] provision, then block until Firecrawl
#                                     answers, giving up N seconds (integer,
#                                     default 300) after the script started,
#                                     lock wait and provision included. The
#                                     SessionStart hook runs --wait 840.
#   ./scripts/setup-env.sh --status   report what is up, change nothing
#   ./scripts/setup-env.sh --stop     tear the stacks down
#
# See docs/cloud-env-setup.md for why each workaround below is needed.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${REPO_ROOT}/.cloudplay"
LOG_FILE="${STATE_DIR}/setup.log"
ENV_FILE="${STATE_DIR}/env.sh"
LOCK_FILE="${STATE_DIR}/setup.lock"

FIRECRAWL_PORT="${FIRECRAWL_PORT:-3663}"
CHROMIUM_CDP_PORT="${CHROMIUM_CDP_PORT:-9222}"
CHROMIUM_IMAGE="cloudplay-chromium:local"
CHROMIUM_CONTAINER="cloudplay-chromium"
FC_DIR="${REPO_ROOT}/docker/firecrawl"
CA_BUNDLE="${CCR_CA_BUNDLE:-/root/.ccr/ca-bundle.crt}"

mkdir -p "$STATE_DIR"

log() { printf '[setup-env %s] %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG_FILE" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

# curl that never routes through the agent proxy -- these are all loopback.
lcurl() { curl -s --noproxy '*' "$@"; }

PULL_ATTEMPTS="${PULL_ATTEMPTS:-4}"
# A positive integer only: 0 would skip every pull without a word, and a
# non-integer breaks seq. Fall back to the default rather than abort the setup.
if ! [[ "$PULL_ATTEMPTS" =~ ^[1-9][0-9]*$ ]]; then
  log "PULL_ATTEMPTS=${PULL_ATTEMPTS} is not a positive integer; using 4"
  PULL_ATTEMPTS=4
fi

# --------------------------------------------------------------------------
# Registry resilience
# --------------------------------------------------------------------------
# Anonymous Docker Hub pulls are rate-limited per egress IP, and cloud
# containers share IPs, so a cold provision can hit 429 Too Many Requests
# before it has pulled anything, and left to compose a single failed pull aborts
# the whole `compose up`. Docker Hub images are also served by Google's pull-through
# mirror (mirror.gcr.io), which does not share that limit, so it is the fallback.

# Print the mirror.gcr.io equivalent of a Docker Hub image ref; fail (and
# print nothing) for images hosted on any other registry.
hub_mirror_ref() {
  local ref="$1" first="${1%%/*}"
  if [[ "$ref" == */* && ( "$first" == *.* || "$first" == *:* || "$first" == localhost ) ]]; then
    [ "$first" = docker.io ] || return 1
    ref="${ref#docker.io/}"
  fi
  [[ "$ref" == */* ]] || ref="library/${ref}"
  printf 'mirror.gcr.io/%s' "$ref"
}

# retry_with_mirror REF CMD...: run `CMD REF`, then `CMD MIRROR_REF` for a
# Docker Hub image, with exponential backoff between rounds. On success
# USED_REF holds whichever ref worked.
retry_with_mirror() {
  local ref="$1" mirror attempt delay=5
  shift
  mirror="$(hub_mirror_ref "$ref")"
  for attempt in $(seq 1 "$PULL_ATTEMPTS"); do
    USED_REF="$ref"
    "$@" "$ref" >>"$LOG_FILE" 2>&1 && return 0
    if [ -n "$mirror" ]; then
      USED_REF="$mirror"
      "$@" "$mirror" >>"$LOG_FILE" 2>&1 && { log "${ref}: used mirror ${mirror}"; return 0; }
    fi
    [ "$attempt" -lt "$PULL_ATTEMPTS" ] || break
    log "${ref}: attempt ${attempt}/${PULL_ATTEMPTS} failed; retrying in ${delay}s"
    sleep "$delay"
    delay=$((delay * 2))
  done
  log "${ref}: giving up after ${PULL_ATTEMPTS} attempts; see $LOG_FILE"
  return 1
}

# Pull an image unless it is already present. A mirror pull is re-tagged
# under the original name, so compose finds it and never pulls itself.
pull_image() {
  docker image inspect "$1" >/dev/null 2>&1 && return 0
  log "pulling $1"
  retry_with_mirror "$1" docker pull || return 1
  [ "$USED_REF" = "$1" ] || docker tag "$USED_REF" "$1"
}

# Optional: an authenticated Docker Hub account gets a far higher pull limit.
# Set DOCKERHUB_USERNAME and DOCKERHUB_TOKEN in the environment to use it.
docker_hub_login() {
  [ -n "${DOCKERHUB_USERNAME:-}" ] && [ -n "${DOCKERHUB_TOKEN:-}" ] || return 0
  printf '%s' "$DOCKERHUB_TOKEN" \
    | docker login --username "$DOCKERHUB_USERNAME" --password-stdin >>"$LOG_FILE" 2>&1 \
    && log "logged in to Docker Hub as ${DOCKERHUB_USERNAME}" \
    || log "Docker Hub login failed; continuing anonymously"
}

firecrawl_up() { [ "$(lcurl -o /dev/null -w '%{http_code}' "http://localhost:${FIRECRAWL_PORT}/" 2>/dev/null)" = "200" ]; }
chromium_up()  { lcurl -o /dev/null "http://localhost:${CHROMIUM_CDP_PORT}/json/version" 2>/dev/null; }

# --------------------------------------------------------------------------
# 1. Docker daemon
# --------------------------------------------------------------------------
# The cloud container ships the docker CLI and dockerd but starts neither, and
# there is no systemd to start it for us. dockerd does not survive container
# recycling either, so this runs on every session -- not just first provision.
start_dockerd() {
  if docker info >/dev/null 2>&1; then return 0; fi
  if ! have dockerd; then log "dockerd not installed; skipping docker stacks"; return 1; fi

  log "starting dockerd"
  # setsid puts dockerd in its own session, so a signal to the hook's process
  # group (e.g. when the async hook times out) does not take the daemon down.
  local detach=nohup
  have setsid && detach=setsid
  # 9>&- matters: dockerd outlives this script, and without closing the lock fd
  # it inherits it and holds the setup lock forever -- every later run then
  # either skips its work or blocks.
  "$detach" dockerd >>"${STATE_DIR}/dockerd.log" 2>&1 9>&- &
  for _ in $(seq 1 30); do
    docker info >/dev/null 2>&1 && { log "dockerd ready"; return 0; }
    sleep 1
  done
  log "dockerd failed to start; see ${STATE_DIR}/dockerd.log"
  return 1
}

# --------------------------------------------------------------------------
# 2. Node CLIs
# --------------------------------------------------------------------------
install_clis() {
  local missing=()
  have firecrawl     || missing+=("firecrawl-cli@latest")
  have playwright-cli || missing+=("@playwright/cli@latest")
  if [ ${#missing[@]} -gt 0 ]; then
    log "installing: ${missing[*]}"
    npm install -g "${missing[@]}" >>"$LOG_FILE" 2>&1 \
      || log "npm install failed; see $LOG_FILE"
  fi
}

# --------------------------------------------------------------------------
# 3. playwright-cli config
# --------------------------------------------------------------------------
# Host-side Chromium cannot complete a TLS handshake through the agent proxy's
# CONNECT relay, so the browser runs in a container (see docker/chromium) and
# playwright-cli attaches over CDP. .playwright/ is gitignored, so the tracked
# template in config/ is the source of truth and gets rendered here.
write_playwright_config() {
  local template="${REPO_ROOT}/config/playwright-cli.config.json"
  local target="${REPO_ROOT}/.playwright/cli.config.json"
  [ -f "$template" ] || return 0
  mkdir -p "$(dirname "$target")"
  sed "s|__CDP_ENDPOINT__|http://localhost:${CHROMIUM_CDP_PORT}|" "$template" > "$target"
}

start_chromium() {
  chromium_up && return 0
  local ctx="${REPO_ROOT}/docker/chromium"
  [ -f "${ctx}/Dockerfile" ] || return 0

  if ! docker image inspect "$CHROMIUM_IMAGE" >/dev/null 2>&1; then
    if [ ! -r "$CA_BUNDLE" ]; then
      log "no CA bundle at ${CA_BUNDLE}; container browser would not trust intercepted TLS"
      return 1
    fi
    log "building ${CHROMIUM_IMAGE}"
    cp "$CA_BUNDLE" "${ctx}/ca-bundle.crt" || return 1
    local base
    base="$(sed -n 's/^ARG BASE_IMAGE=//p' "${ctx}/Dockerfile" | head -n1)"
    base="${base:-chromedp/headless-shell:latest}"
    # Pull the base first so the build finds it locally. A failed pull is not
    # fatal: the build below has retries and a mirror fallback of its own.
    pull_image "$base" || log "base image ${base} not pulled; building anyway"
    # BuildKit may still re-resolve the base image against its registry even
    # when it is present locally, so the build gets the retry + mirror treatment.
    build_chromium() { docker build --build-arg "BASE_IMAGE=$1" -t "$CHROMIUM_IMAGE" "$ctx"; }
    retry_with_mirror "$base" build_chromium \
      || { log "chromium build failed; see $LOG_FILE"; return 1; }
  fi

  docker rm -f "$CHROMIUM_CONTAINER" >/dev/null 2>&1
  log "starting ${CHROMIUM_CONTAINER} on CDP port ${CHROMIUM_CDP_PORT}"
  docker run -d --name "$CHROMIUM_CONTAINER" \
    -p "127.0.0.1:${CHROMIUM_CDP_PORT}:9222" \
    --shm-size=1g --restart unless-stopped \
    "$CHROMIUM_IMAGE" >>"$LOG_FILE" 2>&1
}

# --------------------------------------------------------------------------
# 4. Firecrawl stack
# --------------------------------------------------------------------------
compose_args() {
  printf -- '-f %s' "${FC_DIR}/docker-compose.yml"
  # The proxy-CA overlay applies only where TLS is actually intercepted, so the
  # base compose stays usable on an ordinary host.
  [ -r "$CA_BUNDLE" ] && printf -- ' -f %s' "${FC_DIR}/docker-compose.proxy-ca.yml"
}

start_firecrawl() {
  firecrawl_up && return 0
  [ -f "${FC_DIR}/docker-compose.yml" ] || return 0

  # Upstream requests nofile=65535; this VM's hard limit is lower and runc
  # refuses to create the container when the request exceeds it.
  export FIRECRAWL_NOFILE="${FIRECRAWL_NOFILE:-$(ulimit -Hn)}"
  export FIRECRAWL_PORT
  [ -r "$CA_BUNDLE" ] && export CCR_CA_BUNDLE="$CA_BUNDLE"

  # Pull up front, in parallel, each image with its own retries and mirror
  # fallback. Left to compose, one failed pull interrupts all the others.
  local img pids=() failed=0 pid
  # shellcheck disable=SC2046
  while read -r img; do
    [ -n "$img" ] || continue
    pull_image "$img" &
    pids+=("$!")
  done < <(docker compose $(compose_args) config --images 2>>"$LOG_FILE")
  for pid in "${pids[@]}"; do wait "$pid" || failed=1; done
  if [ "$failed" -ne 0 ]; then
    log "firecrawl images incomplete; not starting the stack"
    return 1
  fi

  log "starting firecrawl stack on port ${FIRECRAWL_PORT}"
  # shellcheck disable=SC2046
  docker compose $(compose_args) up -d >>"$LOG_FILE" 2>&1 \
    || log "firecrawl compose up failed; see $LOG_FILE"
}

# --------------------------------------------------------------------------
# 5. Environment file
# --------------------------------------------------------------------------
# Point the Firecrawl CLI at the local instance. Self-hosted Firecrawl runs
# with USE_DB_AUTHENTICATION=false and accepts any bearer token, but the CLI
# still insists on one being present.
write_env_file() {
  cat > "$ENV_FILE" <<EOF
# Generated by scripts/setup-env.sh -- source this to talk to the local stacks.
export FIRECRAWL_API_URL="http://localhost:${FIRECRAWL_PORT}"
export FIRECRAWL_API_KEY="\${FIRECRAWL_API_KEY:-local-self-hosted}"
export CLOUDPLAY_CDP_ENDPOINT="http://localhost:${CHROMIUM_CDP_PORT}"
EOF
}

wait_for_firecrawl() {
  # The deadline counts from script start (bash's SECONDS), not from here, so
  # a slow lock wait or provision cannot push the hook past its asyncTimeout.
  # 10#: a leading zero would otherwise be read as octal ("--wait 09" errors).
  # Check before testing the deadline, so a provision that already overran it
  # still gets one look rather than a failure without checking at all.
  local deadline=$((10#${1:-300}))
  until firecrawl_up; do
    if [ $SECONDS -ge $deadline ]; then
      log "firecrawl did not become ready within ${1:-300}s of setup start"
      return 1
    fi
    sleep 5
  done
  log "firecrawl ready at http://localhost:${FIRECRAWL_PORT}"
  return 0
}

provision() {
  install_clis
  write_env_file
  write_playwright_config
  if start_dockerd; then
    docker_hub_login
    start_chromium
    start_firecrawl
  fi
}

status() {
  printf 'docker daemon : %s\n' "$(docker info >/dev/null 2>&1 && echo running || echo down)"
  printf 'firecrawl     : %s (http://localhost:%s)\n' "$(firecrawl_up && echo up || echo down)" "$FIRECRAWL_PORT"
  printf 'chromium cdp  : %s (http://localhost:%s)\n' "$(chromium_up && echo up || echo down)" "$CHROMIUM_CDP_PORT"
  printf 'firecrawl-cli : %s\n' "$(have firecrawl && firecrawl --version 2>/dev/null || echo missing)"
  printf 'playwright-cli: %s\n' "$(have playwright-cli && echo installed || echo missing)"
}

stop() {
  # The overlay interpolates CCR_CA_BUNDLE even for `down`, so it must be
  # exported here too or compose aborts before stopping anything.
  [ -r "$CA_BUNDLE" ] && export CCR_CA_BUNDLE="$CA_BUNDLE"
  # shellcheck disable=SC2046
  docker compose $(compose_args) down >>"$LOG_FILE" 2>&1 \
    || log "firecrawl compose down failed; see $LOG_FILE"
  docker rm -f "$CHROMIUM_CONTAINER" >/dev/null 2>&1
  log "stacks stopped"
}

case "${1:-}" in
  --status) status; exit 0 ;;
  --stop)   stop; exit 0 ;;
  --wait)
    # Reject a non-integer timeout up front: in $(( )) it would otherwise be
    # evaluated as an expression and abort only after provisioning has run.
    case "${2:-300}" in *[!0-9]*) echo "usage: setup-env.sh [--wait [seconds]|--status|--stop]" >&2; exit 2 ;; esac
    # A concurrent background run may already hold the lock; wait it out.
    exec 9>"$LOCK_FILE"
    # Bounded: never let a stale holder wedge session startup.
    flock -w 120 9 || log "proceeding without the setup lock"
    provision
    # Only waiting from here on; don't hold up a concurrent run meanwhile.
    flock -u 9
    wait_for_firecrawl "${2:-300}"
    exit $?
    ;;
  ""|--background)
    # Non-blocking: if another run already holds the lock there is nothing to do.
    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then exit 0; fi
    if firecrawl_up && chromium_up && have firecrawl && have playwright-cli; then
      write_env_file; write_playwright_config; exit 0
    fi
    provision
    exit 0
    ;;
  *) echo "usage: setup-env.sh [--wait [seconds]|--status|--stop]" >&2; exit 2 ;;
esac
