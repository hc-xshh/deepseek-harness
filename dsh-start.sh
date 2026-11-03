#!/usr/bin/env bash
# Launch the DeepSeek Harness Web GUI from this checkout.
#
# Checks the toolchain, dependencies, build artifacts, API key, and port before
# running `pnpm dsh web`. `--detach` runs it in the background under a log file;
# `--status`, `--stop`, and `--restart` manage that background instance.
# Every launch fast-forwards the checkout to its upstream and rebuilds what the
# merge moved; --no-update skips that, --update makes it mandatory. `--dev` hands
# off to `pnpm run dev:web`, which rebuilds client artifacts on edit.
set -euo pipefail

# Resolve the checkout through symlinks so a ~/.local/bin/dsh-start link works.
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
  LINK_DIR="$(cd -- "$(dirname -- "$SOURCE")" && pwd -P)"
  SOURCE="$(readlink -- "$SOURCE")"
  case "$SOURCE" in /*) ;; *) SOURCE="$LINK_DIR/$SOURCE" ;; esac
done
SCRIPT_DIR="$(cd -- "$(dirname -- "$SOURCE")" && pwd -P)"
REPO_ROOT="$SCRIPT_DIR"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/dsh-start"

# pnpm resolves the `dsh` script from the working directory, so the caller's cwd
# must not decide which checkout (or none) gets launched.
cd -- "$REPO_ROOT"

PORT=3080
HOST=127.0.0.1
OPEN=1
DEV=0
BUILD=0
DETACH=0
FORCE=0
REPLACE=0
UPDATE=0
NO_UPDATE=0
ACTION=start

if [ -t 2 ]; then
  C_INFO=$'\033[36m' C_WARN=$'\033[33m' C_ERR=$'\033[31m' C_DIM=$'\033[2m' C_OFF=$'\033[0m'
else
  C_INFO= C_WARN= C_ERR= C_DIM= C_OFF=
fi

info() { printf '%s==>%s %s\n' "$C_INFO" "$C_OFF" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die() { printf '%s[x]%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage: ./dsh-start.sh [options]

Start the DeepSeek Harness Web GUI from this checkout (default: foreground,
http://127.0.0.1:3080).

Every launch first fast-forwards the checkout to its upstream, then reinstalls
dependencies and rebuilds artifacts when that moved them. An offline, dirty, or
diverged checkout is reported and the launch continues on the current commit.

Options:
  --port <n>     Listen port (default 3080).
  --host <addr>  Bind address; one concrete local interface address (default 127.0.0.1).
  --no-open      Do not open a browser.
  --dev          Use `pnpm run dev:web`: build once, then rebuild client artifacts
                 on every source edit while serving.
  --build        Run `pnpm run build:artifacts` before starting.
  --detach       Run in the background; prints the URL and writes a log file.
  --status       Report the background instance started by this script.
  --stop         Stop the background instance started by this script.
  --restart      Stop, then start detached.
  --replace      Stop whatever holds the port (another dsh web included), then start.
  --no-update    Skip the automatic upstream check for this launch.
  --update       Require the update: stop the launch when the checkout cannot be
                 fast-forwarded (default is best effort, see below).
  --check-update Report whether the checkout is behind its upstream, then exit
                 (exit 0 = up to date, 1 = behind or unable to check).
  --force        Start even when the Node.js engine floor or build artifacts fail checks.
  -h, --help     Show this help.

State (pid + log) lives in ${XDG_STATE_HOME:-~/.local/state}/dsh-start/.
EOF
}

# --- argument parsing -------------------------------------------------------

while [ $# -gt 0 ]; do
  case "$1" in
    --port)      [ $# -ge 2 ] || die "--port needs a value"; PORT="$2"; shift 2 ;;
    --port=*)    PORT="${1#*=}"; shift ;;
    --host)      [ $# -ge 2 ] || die "--host needs a value"; HOST="$2"; shift 2 ;;
    --host=*)    HOST="${1#*=}"; shift ;;
    --no-open)   OPEN=0; shift ;;
    --dev)       DEV=1; shift ;;
    --build)     BUILD=1; shift ;;
    --detach)    DETACH=1; shift ;;
    --status)    ACTION=status; shift ;;
    --stop)      ACTION=stop; shift ;;
    --restart)   ACTION=restart; shift ;;
    --force)     FORCE=1; shift ;;
    --replace)   REPLACE=1; shift ;;
    --update)    UPDATE=1; shift ;;
    --no-update) NO_UPDATE=1; shift ;;
    --check-update) ACTION=check-update; shift ;;
    -h|--help)   usage; exit 0 ;;
    *)           usage >&2; die "unknown argument: $1" ;;
  esac
done

[[ "$PORT" =~ ^[0-9]+$ ]] || die "--port must be a number, got: $PORT"
(( PORT >= 1 && PORT <= 65535 )) || die "--port must be within 1-65535"
[ "$DEV" -eq 0 ] || [ "$DETACH" -eq 0 ] || die "--dev cannot be combined with --detach"
[ "$UPDATE" -eq 0 ] || [ "$ACTION" = start ] || die "--update applies only when starting"
[ "$NO_UPDATE" -eq 0 ] || [ "$ACTION" = start ] || die "--no-update applies only when starting"
[ "$UPDATE" -eq 0 ] || [ "$NO_UPDATE" -eq 0 ] || die "--update and --no-update are mutually exclusive"

PID_FILE="$STATE_DIR/web-$PORT.pid"
LOG_FILE="$STATE_DIR/web-$PORT.log"
[ "$HOST" = "127.0.0.1" ] && URL="http://127.0.0.1:$PORT" || URL="http://$HOST:$PORT"

# --- helpers ----------------------------------------------------------------

port_in_use() {
  ss -Hltn "sport = :$PORT" 2>/dev/null | grep -q .
}

# Human-readable owners of the listen port, for the busy-port diagnostics.
port_holders_desc() {
  local pid cmd out=()
  for pid in $(port_pids); do
    cmd="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null | cut -c1-100)"
    out+=("pid $pid: ${cmd:-?}")
  done
  printf '%s' "${out[*]:-unknown}"
}

running_pid() {
  [ -f "$PID_FILE" ] || return 1
  local pid
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null || return 1
  printf '%s' "$pid"
}

kill_tree() {
  local pid="$1" sig="${2:-TERM}" kid
  for kid in $(pgrep -P "$pid" 2>/dev/null || true); do
    kill_tree "$kid" "$sig"
  done
  kill -"$sig" "$pid" 2>/dev/null || true
}

# Pids currently holding the listen port, used because the pnpm wrapper can exit
# or be reparented before the node process it started does.
port_pids() {
  ss -Hltnp "sport = :$PORT" 2>/dev/null | grep -oE 'pid=[0-9]+' | cut -d= -f2 | sort -u
}

# The CLI prints a per-launch browser-trust token; a plain URL without it gets a 401.
instance_url() {
  local tokenized
  tokenized="$(grep -oE "https?://[^[:space:]]*token=[A-Za-z0-9_-]+" "$LOG_FILE" 2>/dev/null | tail -n 1 || true)"
  printf '%s' "${tokenized:-$URL}"
}

stop_instance() {
  local pid targets=()
  if pid="$(running_pid)"; then targets+=("$pid"); fi
  # The wrapper's tree can miss the real listener after a reparent, so the
  # processes holding the port are always stop targets.
  for pid in $(port_pids); do
    case " ${targets[*]:-} " in *" $pid "*) ;; *) targets+=("$pid") ;; esac
  done
  if [ ${#targets[@]} -eq 0 ]; then
    rm -f "$PID_FILE"
    info "no background instance recorded for port $PORT"
    return 1
  fi
  info "stopping pids: ${targets[*]}"
  for pid in "${targets[@]}"; do kill_tree "$pid" TERM; done
  for _ in $(seq 1 20); do
    if ! port_in_use; then
      rm -f "$PID_FILE"
      info "stopped"
      return 0
    fi
    sleep 0.25
  done
  warn "port $PORT still held after SIGTERM; sending SIGKILL"
  for pid in "${targets[@]}" $(port_pids); do kill_tree "$pid" KILL; done
  rm -f "$PID_FILE"
  info "stopped"
  rm -f "$PID_FILE"
  info "stopped"
}

# --- checks -----------------------------------------------------------------

require_checkout() {
  [ -f "$REPO_ROOT/package.json" ] || die "no package.json in $REPO_ROOT"
  grep -q '"@deepseek-ai/dsh-root"' "$REPO_ROOT/package.json" \
    || die "$REPO_ROOT is not the DeepSeek Harness checkout"
}

# Compare "major.minor" against the repository's Node floor (24.9).
node_below_floor() {
  local version major minor
  version="$1"; version="${version#v}"
  major="${version%%.*}"; minor="${version#*.}"; minor="${minor%%.*}"
  (( major * 1000 + minor < 24 * 1000 + 9 ))
}

# A shell opened before the nvm default changed keeps resolving the system node,
# which is usually older. Prefer the newest nvm-installed node that meets the
# floor so the launcher works from any terminal.
prefer_supported_node() {
  local current dir version best=""
  current="$(node -v 2>/dev/null || true)"
  [ -n "$current" ] || return 0
  node_below_floor "$current" || return 0
  local versions="${NVM_DIR:-$HOME/.nvm}/versions/node"
  [ -d "$versions" ] || return 0
  for dir in "$versions"/*; do
    [ -x "$dir/bin/node" ] || continue
    version="$(basename "$dir")"; version="${version#v}"
    node_below_floor "$version" && continue
    if [ -z "$best" ] || [ "$(printf '%s\n%s\n' "$best" "$version" | sort -V | tail -1)" = "$version" ]; then
      best="$version"
    fi
  done
  [ -n "$best" ] || return 0
  export PATH="$versions/v$best/bin:$PATH"
  info "PATH node $current is below the 24.9 floor; using nvm's v$best instead"
}

check_node() {
  command -v node >/dev/null 2>&1 || die "node not found in PATH"
  prefer_supported_node
  local version
  version="$(node -v 2>/dev/null)"; version="${version#v}"
  if node_below_floor "$version"; then
    if [ "$FORCE" -eq 1 ]; then
      warn "Node.js v$version is below the declared floor 24.9; continuing because of --force"
    else
      warn "Node.js v$version is below the declared floor 24.9 (pnpm prints an engine warning)"
      warn "the GUI usually still boots; pass --force to silence this check"
    fi
  fi
  command -v pnpm >/dev/null 2>&1 || die "pnpm not found in PATH"
}

check_dependencies() {
  [ -d "$REPO_ROOT/node_modules" ] || die "node_modules missing; run: pnpm install"
}

check_artifacts() {
  local missing=()
  [ -f "$REPO_ROOT/apps/web/dist/index.html" ] || missing+=("apps/web/dist")
  [ -f "$REPO_ROOT/packages/client/modules/lib/client.js" ] || missing+=("packages/client/*/lib")
  [ -f "$REPO_ROOT/packages/host/webserver/lib/index.js" ] || missing+=("packages/host/*/lib")
  [ ${#missing[@]} -eq 0 ] && return 0
  if [ "$FORCE" -eq 1 ]; then
    warn "build artifacts missing (${missing[*]}); continuing because of --force"
    return 0
  fi
  die "build artifacts missing (${missing[*]}); run with --build or: pnpm run build:artifacts"
}

check_api_key() {
  [ -n "${DEEPSEEK_API_KEY:-}" ] && return 0
  grep -qs 'DEEPSEEK_API_KEY' "$REPO_ROOT/.env" && return 0
  grep -qs 'DEEPSEEK_API_KEY' "${DSH_HOME:-$HOME/.dsh}/.credentials.yaml" && return 0
  warn "no DEEPSEEK_API_KEY found (env, .env, or ${DSH_HOME:-$HOME/.dsh}/.credentials.yaml)"
  warn "the GUI will open, but turns fail until a key is configured in settings"
}

# --- repository update ------------------------------------------------------

# Fetch the current branch's upstream and echo "upstream behind ahead".
git_fetch_state() {
  local branch upstream remote
  branch="$(git symbolic-ref --quiet --short HEAD || true)"
  [ -n "$branch" ] || die "detached HEAD; run 'git switch <branch>' before updating"
  upstream="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  [ -n "$upstream" ] || die "branch '$branch' has no upstream; set one with 'git branch --set-upstream-to=origin/$branch'"
  remote="${upstream%%/*}"
  info "fetching $upstream"
  git fetch --prune --quiet "$remote" || die "git fetch $remote failed"
  printf '%s %s %s\n' "$upstream" \
    "$(git rev-list --count "HEAD..$upstream")" \
    "$(git rev-list --count "$upstream..HEAD")"
}

check_update() {
  command -v git >/dev/null 2>&1 || die "git not found in PATH"
  git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || die "$REPO_ROOT is not a git checkout"
  local state upstream behind ahead
  state="$(git_fetch_state)"
  read -r upstream behind ahead <<< "$state"
  if [ "$behind" -eq 0 ]; then
    info "up to date: $(git -C "$REPO_ROOT" rev-parse --short HEAD) ($upstream)"
    [ "$ahead" -eq 0 ] || warn "branch also has $ahead local commit(s) not yet upstream"
    return 0
  fi
  printf '%s commit(s) behind %s (HEAD %s)\n' "$behind" "$upstream" "$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
  git -C "$REPO_ROOT" --no-pager log --oneline -10 "HEAD..$upstream"
  return 1
}

# Fast-forward to the upstream commit and refresh whatever that moved.
#
# `mode` is `strict` (a checkout that cannot be updated stops the launch) or
# `auto` (unusable states are reported and reported only, so the GUI still
# starts on the current checkout). A merge that already happened is never rolled
# back: failing to install or rebuild after it stops the launch in both modes.
update_checkout() {
  local mode="$1" soft=0
  if [ "$mode" = auto ]; then soft=1; fi

  local fail=""
  if ! command -v git >/dev/null 2>&1; then
    fail="git not found in PATH"
  elif ! git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
    fail="$REPO_ROOT is not a git checkout"
  fi
  if [ -n "$fail" ]; then
    if [ "$soft" -eq 1 ]; then warn "$fail; skipping update"; return 0; fi
    die "$fail"
  fi

  local branch upstream remote behind ahead before after changed
  branch="$(git -C "$REPO_ROOT" symbolic-ref --quiet --short HEAD || true)"
  if [ -z "$branch" ]; then
    if [ "$soft" -eq 1 ]; then warn "detached HEAD; skipping update"; return 0; fi
    die "detached HEAD; run 'git switch <branch>' before updating"
  fi
  upstream="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  if [ -z "$upstream" ]; then
    if [ "$soft" -eq 1 ]; then warn "branch '$branch' has no upstream; skipping update"; return 0; fi
    die "branch '$branch' has no upstream; set one with 'git branch --set-upstream-to=origin/$branch'"
  fi
  remote="${upstream%%/*}"

  info "checking $upstream for updates"
  local fetch_cmd=(git -C "$REPO_ROOT" fetch --prune --quiet "$remote")
  if command -v timeout >/dev/null 2>&1; then
    fetch_cmd=(timeout 120 "${fetch_cmd[@]}")
  fi
  if [ "$soft" -eq 1 ]; then
    if ! "${fetch_cmd[@]}" 2>/dev/null; then
      warn "git fetch failed (offline?); starting with the current checkout"
      return 0
    fi
  elif ! "${fetch_cmd[@]}"; then
    die "git fetch $remote failed"
  fi

  behind="$(git -C "$REPO_ROOT" rev-list --count "HEAD..$upstream")"
  ahead="$(git -C "$REPO_ROOT" rev-list --count "$upstream..HEAD")"
  if [ "$behind" -eq 0 ]; then
    info "up to date: $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
    return 0
  fi
  # Local commits are expected on a personal fork: rebase them onto the upstream
  # instead of refusing. A dirty tree always stops the update first, because a
  # rebase would otherwise mix user edits into the rewrite.
  if [ -n "$(git -C "$REPO_ROOT" status --porcelain --untracked-files=no)" ]; then
    if [ "$soft" -eq 1 ]; then
      warn "uncommitted changes in tracked files; skipping update"
      return 0
    fi
    warn "uncommitted changes in tracked files:"
    git -C "$REPO_ROOT" status --short --untracked-files=no >&2
    die "commit or stash them before updating"
  fi

  local merge_base
  merge_base="$(git -C "$REPO_ROOT" merge-base HEAD "$upstream")"
  before="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"

  if [ "$ahead" -gt 0 ]; then
    info "rebasing $ahead local commit(s) onto $upstream (skip with --no-update)"
    if ! git -C "$REPO_ROOT" rebase --quiet "$upstream"; then
      git -C "$REPO_ROOT" rebase --abort >/dev/null 2>&1 || true
      if [ "$soft" -eq 1 ]; then
        warn "rebase conflicted and was aborted; starting with the current checkout"
        return 0
      fi
      die "rebase onto $upstream conflicted; abort finished, resolve manually then rerun"
    fi
  else
    info "updating $behind commit(s) from $upstream (skip with --no-update)"
    if ! git -C "$REPO_ROOT" merge --ff-only --quiet "$upstream"; then
      if [ "$soft" -eq 1 ]; then
        warn "fast-forward failed; starting with the current checkout"
        return 0
      fi
      die "git merge --ff-only failed"
    fi
  fi

  after="$(git -C "$REPO_ROOT" rev-parse --short HEAD)"
  info "checkout updated: $before -> $after"
  git -C "$REPO_ROOT" --no-pager log --oneline -10 "$merge_base..$after" >&2

  changed="$(git -C "$REPO_ROOT" diff --name-only "$merge_base" "$after")"
  if printf '%s\n' "$changed" | grep -qE '^(pnpm-lock\.yaml|pnpm-workspace\.yaml|package\.json)$'; then
    info "dependency manifests changed; running pnpm install"
    pnpm install || die "pnpm install failed"
  fi
  info "rebuilding artifacts"
  pnpm run build:artifacts || die "build:artifacts failed"
}

# Report pending upstream commits without touching the working tree, for the
# case where a live instance makes an update impossible right now.
update_hint() {
  command -v git >/dev/null 2>&1 || return 0
  git -C "$REPO_ROOT" rev-parse --git-dir >/dev/null 2>&1 || return 0
  local upstream behind
  upstream="$(git -C "$REPO_ROOT" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  [ -n "$upstream" ] || return 0
  git -C "$REPO_ROOT" fetch --prune --quiet "${upstream%%/*}" 2>/dev/null || return 0
  behind="$(git -C "$REPO_ROOT" rev-list --count "HEAD..$upstream" 2>/dev/null || echo 0)"
  if [ "$behind" -gt 0 ]; then
    info "$behind new commit(s) on $upstream; apply with: $0 --replace --port $PORT"
  fi
  return 0
}

# --- actions ----------------------------------------------------------------

serve_foreground() {
  local args=(dsh web --port "$PORT" --host "$HOST")
  [ "$OPEN" -eq 1 ] || args+=(--no-open)
  info "starting $URL (Ctrl+C to stop)"
  exec pnpm "${args[@]}"
}

serve_detached() {
  mkdir -p "$STATE_DIR"
  : > "$LOG_FILE"
  info "starting detached: $URL"
  local args=(dsh web --port "$PORT" --host "$HOST" --no-open)
  nohup pnpm "${args[@]}" >> "$LOG_FILE" 2>&1 < /dev/null &
  local pid=$!
  printf '%s' "$pid" > "$PID_FILE"
  disown "$pid" 2>/dev/null || true

  local i j
  for i in $(seq 1 120); do
    if port_in_use; then
      # The trust token is printed just after the listener binds.
      for j in $(seq 1 40); do
        grep -q 'token=' "$LOG_FILE" 2>/dev/null && break
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.25
      done
      info "running (pid $pid)"
      info "url:  $(instance_url)"
      info "log:  $LOG_FILE"
      info "stop: $0 --stop --port $PORT"
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      warn "process exited before listening; last log lines:"
      tail -n 20 "$LOG_FILE" >&2 || true
      rm -f "$PID_FILE"
      return 1
    fi
    sleep 0.5
  done
  warn "still not listening after 60s; see $LOG_FILE"
  return 1
}

dev_serve() {
  check_dependencies
  local args=(run dev:web --poll -- --port "$PORT" --host "$HOST")
  [ "$OPEN" -eq 1 ] || args+=(--no-open)
  info "starting dev loop (rebuild on edit): $URL"
  exec pnpm "${args[@]}"
}

print_status() {
  local pid
  if pid="$(running_pid)"; then
    printf 'running  pid %s  %s\n' "$pid" "$(instance_url)"
    printf 'log      %s\n' "$LOG_FILE"
    port_in_use || printf 'note     pid alive but port %s is not listening\n' "$PORT"
    return 0
  fi
  if port_in_use; then
    printf 'not managed by this script, but port %s is in use (another dsh?)\n' "$PORT"
    return 0
  fi
  printf 'stopped  port %s is free\n' "$PORT"
  return 1
}

do_start() {
  require_checkout
  check_node
  check_dependencies

  # Never update underneath a live process: stop it first, or refuse loudly.
  if running_pid >/dev/null || port_in_use; then
    if [ "$REPLACE" -eq 1 ]; then
      info "stopping the instance on port $PORT: $(port_holders_desc)"
      stop_instance >/dev/null 2>&1 || true
      for pid in $(port_pids); do kill_tree "$pid" TERM; done
      sleep 1
      port_in_use && die "could not free port $PORT"
    elif [ "$UPDATE" -eq 1 ]; then
      die "an instance already holds port $PORT; add --replace to update and restart it"
    else
      if pid="$(running_pid)"; then
        info "already running at $(instance_url) (pid $pid)"
      else
        info "port $PORT is already in use: $(port_holders_desc)"
      fi
      info "add --replace to restart through this script, or --status for details"
      [ "$NO_UPDATE" -eq 0 ] && update_hint
      exit 0
    fi
  fi

  if [ "$NO_UPDATE" -eq 0 ]; then
    if [ "$UPDATE" -eq 1 ]; then
      update_checkout strict
    else
      update_checkout auto
    fi
  fi

  [ "$BUILD" -eq 0 ] || { info "building artifacts"; pnpm run build:artifacts; }

  if [ "$DEV" -eq 1 ]; then
    check_api_key
    dev_serve
  fi

  check_artifacts
  check_api_key
  if [ "$DETACH" -eq 1 ]; then
    serve_detached
  else
    serve_foreground
  fi
}

case "$ACTION" in
  status)
    print_status
    ;;
  stop)
    stop_instance || true
    ;;
  restart)
    stop_instance || true
    DETACH=1
    do_start
    ;;
  check-update)
    require_checkout
    check_update
    ;;
  start)
    do_start
    ;;
esac
