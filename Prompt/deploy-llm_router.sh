#!/usr/bin/env bash
#
# deploy-llm_router.sh — push LLM Router to a host over SSH and run it with podman-compose.
#
#   ./deploy-llm_router.sh                 interactive menu (llm.rv.lan, llm2.rv.lan, jumppy-03@192.168.67.216, local, custom)
#   ./deploy-llm_router.sh llm2.rv.lan     no menu
#   ./deploy-llm_router.sh local           run on this machine
#   ./deploy-llm_router.sh bob@10.0.0.5:22 any host as user@host:port
#
# Options / environment:
#   -u USER, SSH_USER    SSH login (default: your current user)
#   -p PORT, SSH_PORT    SSH port (default: 3388)
#   -d DIR,  DEPLOY_DIR  directory under the remote home (default: llm-router)
#   --test               only run the endpoint tests + banner against a target
#   --curls HOST         write curls-HOST.sh: ready-to-run curl tests for every route and API
#   -n, --dry-run        show what would be copied to the host, change nothing
#   --export HOST [FILE] save the host's configuration (connections, routes, keys) to FILE
#   --import HOST FILE   restore a configuration file onto HOST (replaces everything)
#   --rollback HOST      switch back to the image that ran before the last deploy
#   --with NAME          also deploy a sidecar (sidecars/NAME/module.sh); --with-0claude is the same
#   --without NAME       stop a sidecar; data kept
#
# Sidecars are modules: each sidecars/NAME/module.sh implements the same hooks (prepare, deploy,
# wait, test, banner, remove, debug) and the flow below calls them in order. 0claude's module runs
# 0claude's own installer, which asks for the Anthropic API key and mints its tokens; the module
# then reads those back and registers the connection in the router.
#   --debug HOST         collect a diagnostic report (host + this machine) into ./debug/, secrets redacted
#   -v, --verbose        trace every command (bash -x) — pair with --debug when reporting a problem
#   --no-pause           do not wait for Enter at the end (scripts, CI)
#   --no-sudo-pass       do not reuse the ssh password for sudo on the host
#   --accept-ports       non-interactive: take the port plan's proposals for ports in use
#   --test-routes        during a deploy, also send one completion through every route (--test always does)
#   --status HOST        container states, the checks and the banner — nothing is changed
#   --json               after --test / --status / a deploy, print one JSON summary line (for automation)
#   --copy-id            install your ssh key on the host so no password is needed next time
#
# Passwords: when the host needs one, it is asked ONCE and reused for every ssh/rsync
# call (via SSH_ASKPASS, no extra tools) and for sudo on the host during the run. It is
# never written to logs or reports; the temporary copy on the host is removed at the end.
#
# The window stays open at the end and on errors ("Press Enter to close"); a failure also writes a
# debug report automatically. Paste that file when asking for help.
#
# The remote side keeps its .env (admin token) between deploys; the first deploy generates one.

if [[ "${BASH_VERSINFO[0]:-0}" -lt 4 ]]; then
  printf 'This needs bash 4 or newer (found %s). macOS: brew install bash, then run it with that bash.\n' "${BASH_VERSION:-unknown}" >&2
  exit 1
fi
set -euo pipefail
set -E   # so the ERR trap fires inside functions too

ERR_CMD=""; ERR_LINE=""; CURRENT_STEP=""; INTERNAL=0; COLLECT_ON_FAIL=0; PAUSE=1; DEBUG_FILE=""
SSH=(ssh); SSH_PASS=""; HAVE_PASS=0; ASKPASS_FILE=""; PW_CAPTURED=0; NO_SUDO_PASS=0; COPY_ID=0; VERBOSE=0
SUDO=(sudo); SUDO_HELPER=""; REMOTE_PASS_FILE=".llmrouter-sudo-pass"
# Host ports (overridable in .env: PORT_LLM, PORT_OLLAMA, PORT_ADMIN, PORT_0CLAUDE)
P_LLM=1145; P_OLLAMA=1133; P_ADMIN=1234; P_0C=1235
trace_off() { { set +x; } 2>/dev/null; }
trace_on() { [[ "$VERBOSE" == 1 ]] && set -x; return 0; }
on_err() { [[ -z "$ERR_CMD" ]] && { ERR_CMD="$3"; ERR_LINE="$2"; }; return 0; }
trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR
trap 'on_exit $?' EXIT

SSH_PORT="${SSH_PORT:-3388}"
SSH_USER="${SSH_USER:-}"
DEPLOY_DIR="${DEPLOY_DIR:-llm-router}"
HOSTS=(llm.rv.lan llm2.rv.lan jumppy-03@claude01.vr.lan local local-only custom)
# ACCESS_CHOICE is written to the host's .env as ACCESS. Every target sets it: remote hosts and
# "local" choose lan, "local-only" chooses local. It is only ever empty on a code path that names no
# target at all, and an empty ACCESS in .env now means lan — see load_access, which explains why an
# absent setting must not be read as "closed".
ACCESS_CHOICE=""
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- output helpers ----------
if [[ -t 1 ]]; then
  B=$'\e[1m'; DIM=$'\e[2m'; GREEN=$'\e[32m'; RED=$'\e[31m'; BLUE=$'\e[34m'; YEL=$'\e[33m'; R=$'\e[0m'
else
  B=''; DIM=''; GREEN=''; RED=''; BLUE=''; YEL=''; R=''
fi
step() { CURRENT_STEP="$*"; printf '%s\n' "${BLUE}${B}==>${R} ${B}$*${R}"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$R" "$*"; }
fail() { printf '  %s✗%s %s\n' "$RED" "$R" "$*"; }
note() { printf '  %s%s%s\n' "$DIM" "$*" "$R"; }
die()  { printf '%sError:%s %s\n' "$RED" "$R" "$*" >&2; exit 1; }

usage() { awk 'NR>1 && !/^#/ {exit} NR>1 {sub(/^# ?/, ""); print}' "${BASH_SOURCE[0]}"; }

# ---------- exit handling ----------
pause_if_interactive() {
  [[ "$PAUSE" == 1 && "$INTERNAL" == 0 && -t 0 && -t 1 ]] || return 0
  printf '\n%s' "${DIM}Press Enter to close…${R}"
  read -r _ || true
}

cleanup_secrets() {
  trace_off
  rm -f "${SUDO_HELPER:-}" "${ASKPASS_FILE:-}" "$HOME/$REMOTE_PASS_FILE" "${REMOTE_ENV_COPY:-}" 2>/dev/null || true
  if [[ "$INTERNAL" == 0 && "$HAVE_PASS" == 1 && -n "${DEST:-}" ]]; then
    "${SSH[@]}" "${SSH_OPTS[@]}" -o ConnectTimeout=5 "$DEST" "rm -f ~/$REMOTE_PASS_FILE" >/dev/null 2>&1 || true
  fi
  unset LLMR_SSH_PASS SSHPASS SSH_PASS
}

on_exit() {
  local rc="$1"
  trap - EXIT
  cleanup_secrets
  if [[ "$INTERNAL" == 1 ]]; then
    if (( rc != 0 )); then
      printf '\n  %s✗ remote phase failed (exit %s)%s%s\n' "$RED" "$rc" "${CURRENT_STEP:+ during: $CURRENT_STEP}" "$R"
      [[ -n "$ERR_CMD" ]] && printf '    line %s: %s\n' "$ERR_LINE" "$ERR_CMD"
    fi
    exit "$rc"
  fi
  if (( rc != 0 )); then
    echo
    fail "${B}Failed (exit $rc)${R}${CURRENT_STEP:+ during: $CURRENT_STEP}"
    [[ -n "$ERR_CMD" ]] && note "line $ERR_LINE: $ERR_CMD"
    if [[ "$COLLECT_ON_FAIL" == 1 && "$LIBS_LOADED" == 1 ]]; then
      collect_debug "${TARGET:-local}" || true
    else
      note "run with --debug HOST to collect a diagnostic report, or -v to trace commands"
    fi
  fi
  pause_if_interactive
  exit "$rc"
}

# ---------- diagnostics ----------

# ---------- package location ----------
is_package() { [[ -f "$1/compose.yaml" && -d "$1/router" && -f "$1/caddy/Caddyfile" ]]; }

# locate_package makes SRC point at the unpacked llm-router package. Running the
# script from a Downloads folder next to llm-router.zip is the common case, so
# that is handled rather than refused.
locate_package() {
  is_package "$SRC" && return 0
  local cand
  for cand in "$SRC/llm-router" "$SRC/../llm-router"; do
    if is_package "$cand"; then SRC="$(cd "$cand" && pwd)"; note "using the package at $SRC"; return 0; fi
  done
  if [[ -f "$SRC/llm-router.zip" ]]; then
    command -v unzip >/dev/null 2>&1 || die "found llm-router.zip next to this script but unzip is not installed"
    if [[ -t 0 ]]; then
      read -rp "Found llm-router.zip next to this script. Unpack it to $SRC/llm-router and deploy from there? [Y/n] " yn
      [[ "$yn" =~ ^[Nn] ]] && die "unzip llm-router.zip and run llm-router/deploy-llm_router.sh"
    fi
    unzip -q -o "$SRC/llm-router.zip" -d "$SRC"
    is_package "$SRC/llm-router" || die "llm-router.zip did not contain the package (no llm-router/compose.yaml)"
    SRC="$SRC/llm-router"
    note "unpacked to $SRC"
    return 0
  fi
  die "this script must run from inside the llm-router package: compose.yaml, router/ and caddy/ next to it.
       Unzip llm-router.zip and run llm-router/deploy-llm_router.sh (nothing was sent to the host)."
}

# ---------- libraries ----------
# The bulk of the script lives in deploy/lib/*.sh inside the package; the entry file only
# holds what is needed to find the package and start (menu, locate, traps, main).
LIBS_LOADED=0
load_libs() {
  [[ "$LIBS_LOADED" == 1 ]] && return 0
  local f
  for f in "$SRC"/deploy/lib/*.sh; do
    [[ -f "$f" ]] || die "missing $f: the package is incomplete (unzip llm-router.zip again)"
    # shellcheck source=/dev/null
    source "$f"
  done
  LIBS_LOADED=1
}

# ---------- target menu ----------
# parse_target accepts host, user@host, host:port or user@host:port.
parse_target() {
  local in="$1"
  [[ -n "$in" ]] || die "no host given"
  # Every path that names a remote host lands here — the menu, a typed entry, and a target passed on
  # the command line. Deploying to another machine is an unambiguous statement that it should be
  # reachable from this one, so say so rather than leaving it to a default.
  ACCESS_CHOICE=lan
  if [[ "$in" == *:* ]]; then SSH_PORT="${in##*:}"; in="${in%:*}"; fi
  if [[ "$in" == *@* ]]; then SSH_USER="${in%%@*}"; in="${in#*@}"; fi
  [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || die "invalid ssh port '$SSH_PORT'"
  # No user given: if the menu knows this host as user@host, use that user.
  if [[ -z "$SSH_USER" ]]; then
    local h
    for h in "${HOSTS[@]}"; do
      if [[ "$h" == *"@$in" ]]; then SSH_USER="${h%%@*}"; note "logging in as $SSH_USER (from the menu entry $h)"; break; fi
    done
  fi
  TARGET="$in"
}

custom_target() {
  local in
  read -rp "Host (host, user@host, or user@host:port; default port $SSH_PORT): " in
  parse_target "$in"
}

choose_target() {
  if [[ -n "${1:-}" ]]; then
    if [[ "$1" == "custom" ]]; then custom_target; else parse_target "$1"; fi
    return
  fi
  [[ -t 0 ]] || { local IFS='|'; die "no target given. Usage: $0 <${HOSTS[*]}|user@host:port>"; }
  echo "${B}Deploy LLM Router to:${R}"
  local i=1 h
  for h in "${HOSTS[@]}"; do
    case "$h" in
      custom)     printf '  %d) custom (enter a host)\n' "$i" ;;
      local)      printf '  %d) local          (this machine, reachable on the LAN)\n' "$i" ;;
      local-only) printf '  %d) Local          (only local access, closed to the network)\n' "$i" ;;
      *)          printf '  %d) %s\n' "$i" "$h" ;;
    esac
    i=$((i + 1))
  done
  while true; do
    read -rp "Choice [1-${#HOSTS[@]}]: " c
    if [[ "$c" =~ ^[0-9]+$ ]] && ((c >= 1 && c <= ${#HOSTS[@]})); then c="${HOSTS[c - 1]}"; fi
    case "$c" in
    custom) custom_target; return ;;
    local) TARGET=local; ACCESS_CHOICE=lan; return ;;
    # Deploys to this machine AND publishes every port on 127.0.0.1 only. The distinction from
    # "local" is not where it installs -- both install here -- but who can reach it afterwards.
    local-only) TARGET=local; ACCESS_CHOICE=local; return ;;
    "") ;;
    *)
      # A menu entry or anything typed at the prompt: host, user@host, or user@host:port.
      # parse_target sets ACCESS_CHOICE=lan for all of them.
      parse_target "$c"; return ;;
    esac
    echo "Pick a number between 1 and ${#HOSTS[@]}, or type a host."
  done
}

# ---------- phase run ON the deployment machine (local mode, or via ssh) ----------

ENV_FILE=".env"   # the orchestrator points this at a fetched copy of the host's .env

# ---------- port plan ----------

# ---------- sidecars (modules) ----------
SIDECAR_ENV_CHANGED=0
SIDECAR_APPLY=""
SIDECAR_FORCE_REGISTER=0
SIDECAR_REGISTERED=0
ROUTE_TESTS="${ROUTE_TESTS:-0}"
SCHEME="http"
LOADED_SIDECAR=""

# ---------- endpoint tests + banner (run from wherever the user is) ----------

# ---------- remote orchestration ----------

DRY_RUN=0
WITH_0CLAUDE=0
ZC_KEY=""
ACTIVE_SIDECARS=""
REMOTE_ENV_COPY=""
ORIG_ARGS=()
main() {
  ORIG_ARGS=("$@")
  local mode="deploy" target="" file=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
    -u | --user) SSH_USER="$2"; shift 2 ;;
    -p | --port) SSH_PORT="$2"; shift 2 ;;
    -d | --dir) DEPLOY_DIR="$2"; shift 2 ;;
    -n | --dry-run) DRY_RUN=1; shift ;;
    --export) mode="export"; shift ;;
    --import) mode="import"; shift ;;
    --rollback) mode="rollback"; shift ;;
    --with-0claude) SIDECAR_ADD=0claude; shift ;;
    --without-0claude) SIDECAR_REMOVE=0claude; shift ;;
    --with) SIDECAR_ADD="$2"; shift 2 ;;
    --without) SIDECAR_REMOVE="$2"; shift 2 ;;
    --debug) mode="debug"; shift ;;
    --debug-here) mode="debug-here"; shift ;; # internal
    -v | --verbose) VERBOSE=1; export PS4='+ [${BASH_SOURCE##*/}:${LINENO}] '; set -x; shift ;;
    --no-pause) PAUSE=0; shift ;;
    --no-sudo-pass) NO_SUDO_PASS=1; shift ;;
    --accept-ports) PORTS_ACCEPT=1; shift ;;
    --test-routes) ROUTE_TESTS=1; shift ;;
    --json) JSON_OUT=1; shift ;;
    --sidecar-apply) mode=sidecar-apply; SIDECAR_APPLY="$2"; shift 2 ;;
    --sidecar-enable) mode=sidecar-enable; SIDECAR_APPLY="$2"; shift 2 ;;
    --sidecar-disable) mode=sidecar-disable; SIDECAR_APPLY="$2"; shift 2 ;;
    --sidecar-remove) mode=sidecar-remove; SIDECAR_APPLY="$2"; shift 2 ;;
    --sidecar-register) mode=sidecar-register; SIDECAR_APPLY="$2"; shift 2 ;;
    --status) mode=status; shift ;;
    --copy-id) COPY_ID=1; shift ;;
    --rollback-here) mode="rollback-here"; shift ;; # internal
    --test) mode="test"; shift ;;
    --curls) mode="curls"; shift ;;
    --here) mode="here"; shift ;;           # internal: run the local phase (used over ssh)
    --test-here) mode="test-here"; shift ;; # internal: tests against 127.0.0.1 on the host
    -h | --help) PAUSE=0; usage; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) if [[ -z "$target" ]]; then target="$1"; else file="$1"; fi; shift ;;
    esac
  done
  case "$mode" in
  here | test-here | rollback-here | debug-here) INTERNAL=1 ;;
  esac
  # Everything below needs the libraries; from a Downloads folder that means finding the package first.
  if ! is_package "$SRC"; then
    locate_package
    # Hand over to the package's own copy of this script so the entry and the libraries
    # always come from the same version (a stale entry next to a new zip must not mix).
    if [[ -f "$SRC/deploy-llm_router.sh" && "${LLMR_REEXEC:-0}" != 1 ]]; then
      note "continuing with the package's own deploy script ($SRC/deploy-llm_router.sh)"
      LLMR_REEXEC=1 exec bash "$SRC/deploy-llm_router.sh" "${ORIG_ARGS[@]}"
    fi
  fi
  load_libs
  case "$mode" in
  debug-here) debug_here ;;
  debug)
    choose_target "$target"
    if [[ "$TARGET" != "local" ]]; then ssh_setup "$TARGET"; capture_password "$DEST"; fi
    collect_debug "$TARGET"
    ;;
  export) choose_target "$target"; export_config "$TARGET" "$file" ;;
  curls)
    choose_target "$target"
    if [[ "$TARGET" == "local" ]]; then cd "$SRC"; load_ports; sidecar_state_local; TOKEN="$(env_get ADMIN_TOKEN)"; curl_sheet localhost "$TOKEN"
    else ssh_setup "$TARGET"; capture_password "$DEST"; TOKEN="$(remote_token "$DEST")"; sidecar_state_remote "$DEST"; curl_sheet "$TARGET" "$TOKEN"; fi
    ;;
  rollback-here) rollback_here ;;
  rollback)
    choose_target "$target"; COLLECT_ON_FAIL=1; locate_package
    if [[ "$TARGET" == "local" ]]; then rollback_here; TOKEN="$(env_get ADMIN_TOKEN)"; run_tests localhost "$TOKEN" || true; banner localhost "$TOKEN"
    else
      ssh_setup "$TARGET"; capture_password "$DEST"; send_sudo_password "$DEST"
      "${SSH[@]}" -t "${SSH_OPTS[@]}" "$DEST" "cd '$DEPLOY_DIR' && bash ./deploy-llm_router.sh --rollback-here"
      TOKEN="$(remote_token "$DEST")"; run_tests "$TARGET" "$TOKEN" || true; banner "$TARGET" "$TOKEN"
    fi
    ;;
  import) [[ -n "$file" ]] || die "usage: $0 --import HOST FILE"; choose_target "$target"; import_config "$TARGET" "$file" ;;
  here) deploy_here ;;
  test-here)
    ROUTE_TESTS="${ROUTE_TESTS:-1}"
    cd "$SRC"
    load_ports; sidecar_state_local
    run_tests 127.0.0.1 "$(env_get ADMIN_TOKEN)" || true
    verify_sidecars
    ;;
  sidecar-apply|sidecar-enable|sidecar-disable|sidecar-remove|sidecar-register)
    # host side, called by the host agent for the admin UI: stand an add-on up/down/away or
    # recreate it with the current credentials; progress goes to stdout for the GUI's log
    cd "$SRC"; INTERNAL=1; PAUSE=0; PORTS_ACCEPT=1
    case "$mode" in
      sidecar-apply)   sidecar_apply "$SIDECAR_APPLY" ;;
      sidecar-enable)  sidecar_enable "$SIDECAR_APPLY" ;;
      sidecar-disable) sidecar_disable "$SIDECAR_APPLY" ;;
      sidecar-remove)  sidecar_remove "$SIDECAR_APPLY" ;;
      sidecar-register) sidecar_register "$SIDECAR_APPLY" ;;
    esac
    ;;
  status)
    MODE_NAME=status
    choose_target "$target"
    if [[ "$TARGET" == "local" ]]; then
      cd "$SRC"; load_ports
      step "Containers on $(hostname)"; podman ps -a --filter name=llmrouter --format '  {{.Names}}  {{.Status}}' 2>/dev/null || true
      podman pod ps --filter name=claudewrap --format '  pod {{.Name}}  {{.Status}}' 2>/dev/null || true
      run_tests localhost "$(env_get ADMIN_TOKEN)" || true; banner localhost "$(env_get ADMIN_TOKEN)"
      if [[ "${JSON_OUT:-0}" == 1 ]]; then json_summary localhost "$(env_get ADMIN_TOKEN)"; fi
    else
      ssh_setup "$TARGET"
      if capture_password "$DEST" 2>/dev/null && TOKEN="$(remote_token "$DEST")" && [[ -n "$TOKEN" ]]; then
        sidecar_state_remote "$DEST"
        step "Containers on $TARGET"
        "${SSH[@]}" "${SSH_OPTS[@]}" "$DEST" "podman ps -a --filter name=llmrouter --format '  {{.Names}}  {{.Status}}'; podman pod ps --filter name=claudewrap --format '  pod {{.Name}}  {{.Status}}' 2>/dev/null; true" || true
      else
        read -rsp "Admin token for $TARGET: " TOKEN; echo
      fi
      run_tests "$TARGET" "$TOKEN" || true
      banner "$TARGET" "$TOKEN"
      if [[ "${JSON_OUT:-0}" == 1 ]]; then json_summary "$TARGET" "$TOKEN"; fi
    fi
    ;;
  test)
    ROUTE_TESTS=1
    MODE_NAME=test
    choose_target "$target"
    if [[ "$TARGET" == "local" ]]; then
      cd "$SRC"; run_tests localhost "$(env_get ADMIN_TOKEN)" || true; banner localhost "$(env_get ADMIN_TOKEN)"
      if [[ "${JSON_OUT:-0}" == 1 ]]; then json_summary localhost "$(env_get ADMIN_TOKEN)"; fi
    else
      ssh_setup "$TARGET"
      if capture_password "$DEST" 2>/dev/null && TOKEN="$(remote_token "$DEST")" && [[ -n "$TOKEN" ]]; then
        sidecar_state_remote "$DEST"
      else
        read -rsp "Admin token for $TARGET: " TOKEN; echo
      fi
      run_tests "$TARGET" "$TOKEN" || true
      if [[ -n "${ACTIVE_SIDECARS:-}" ]]; then
        step "Sidecar checks on $TARGET"
        "${SSH[@]}" -t "${SSH_OPTS[@]}" "$DEST" "cd '$DEPLOY_DIR' && ROUTE_TESTS=1 bash ./deploy-llm_router.sh --test-here" || true
      fi
      banner "$TARGET" "$TOKEN"
      if [[ "${JSON_OUT:-0}" == 1 ]]; then json_summary "$TARGET" "$TOKEN"; fi
    fi
    ;;
  deploy)
    choose_target "$target"; COLLECT_ON_FAIL=1
    if [[ "$TARGET" == "local" ]]; then deploy_local; else deploy_remote "$TARGET"; fi
    ok "${B}Deployment finished${R}"
    ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; elif is_package "$SRC"; then load_libs; fi
