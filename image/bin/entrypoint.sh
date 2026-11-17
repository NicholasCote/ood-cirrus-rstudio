#!/usr/bin/env bash
#
# CIRRUS RStudio Server entrypoint.  Usage: entrypoint.sh {rserver|bootstrap [cmd...]}
#
# Replaces rocker's /init, which needs root. In order:
#   1. give the runtime uid a name (nss_wrapper)
#   2. keep the session's writes out of the user's shared GLADE dotfiles
#   3. wait for the session password and proxy prefix from the init containers
#   4. start rserver behind the password gate and supervise it: end the
#      session when idle or at its maximum length, and exit 0 when it was
#      ended on purpose so OnDemand shows it as Completed
#
# `bootstrap` runs steps 1-3 and then execs cmd (or prints a summary). The
# tests use it, and it reproduces a session's environment without a server.

set -euo pipefail

PROG="cirrus-rstudio"
# stderr always: in bootstrap mode stdout belongs to the command.
log()  { printf '%s: %s\n' "$PROG" "$*" >&2; }
warn() { printf '%s: WARNING: %s\n' "$PROG" "$*" >&2; }
die()  { printf '%s: ERROR: %s\n' "$PROG" "$1" >&2; shift; for l in "$@"; do printf '%s:   %s\n' "$PROG" "$l" >&2; done; exit 1; }

usage() {
    cat >&2 <<USAGE
usage: entrypoint.sh rserver
       entrypoint.sh bootstrap [command...]
USAGE
}

MODE="${1:-rserver}"
case "$MODE" in
    rserver|bootstrap) shift || true ;;
    -h|--help) usage; exit 2 ;;
    *) printf '%s: ERROR: unknown mode: %s\n' "$PROG" "$MODE" >&2; usage; exit 2 ;;
esac

# ===========================================================================
# Session-local state, on container-local /tmp
# ===========================================================================
STATE_DIR="${CIRRUS_RSTUDIO_STATE_DIR:-/tmp/cirrus-rstudio}"
export CIRRUS_RSTUDIO_STATE_DIR="$STATE_DIR"

# Standalone runs may have no usable $HOME; never let ~ expand to /.
if [ -n "${HOME:-}" ] && [ ! -d "$HOME" ]; then
    mkdir -p -- "$HOME" 2>/dev/null || true
fi
if [ -z "${HOME:-}" ] || [ ! -d "${HOME:-}" ]; then
    warn "\$HOME is unset or unusable (${HOME:-<unset>}); using ${STATE_DIR}/home"
    export HOME="${STATE_DIR}/home"
fi

mkdir -p "${STATE_DIR}"/{database,server-data,cache,xdg-data,xdg-config,xdg-state,tmp,run} 2>/dev/null || true

# ===========================================================================
# 1. Runtime uid
#
# The pod runs as the user's real NFS uid, which has no entry in the image's
# /etc/passwd. rserver, git, ssh and the terminal prompt all look it up, and
# /etc is not writable, so nss_wrapper supplies the entry.
# ===========================================================================
setup_nss_wrapper() {
    local uid gid lib want_name want_group cur_name cur_group gecos
    local passwd_file group_file need_passwd=0 need_group=0
    uid="$(id -u)"
    gid="$(id -g)"

    # OOD sets USER and GROUP in the pod spec.
    want_name="${USER:-${NB_USER:-}}"
    case "${want_name}" in ''|*[!a-zA-Z0-9._-]*) want_name="" ;; esac
    [ -n "$want_name" ] || want_name="rstudio-${uid}"
    want_group="${GROUP:-}"
    case "${want_group}" in *[!a-zA-Z0-9._-]*) want_group="" ;; esac

    # `|| true`: no entry is the normal case here, and getent exits 2.
    cur_name="$(getent passwd "$uid" 2>/dev/null | cut -d: -f1 || true)"
    cur_group="$(getent group "$gid" 2>/dev/null | cut -d: -f1 || true)"

    # Container runtimes may synthesise an entry whose name is the uid
    # ("54321:*:54321:54321:container user:/:/bin/sh"). Treat that as no name.
    case "$cur_name" in
        ''|*[!0-9]*) [ -n "$cur_name" ] || need_passwd=1 ;;
        *) need_passwd=1 ;;
    esac
    if [ -n "$want_group" ] && [ "$cur_group" != "$want_group" ]; then
        need_group=1
    fi

    if [ "$need_passwd" -eq 0 ] && [ "$need_group" -eq 0 ]; then
        CIRRUS_RSTUDIO_USER="$cur_name"
        return 0
    fi

    lib="$(cat /opt/cirrus-rstudio/nss_wrapper_lib 2>/dev/null || true)"
    if [ -z "$lib" ] || [ ! -r "$lib" ]; then
        warn "libnss_wrapper.so was not found, so uid ${uid} has no user name."
        warn "RStudio will probably fail to start. This is an image bug."
        CIRRUS_RSTUDIO_USER="${cur_name:-$want_name}"
        return 0
    fi

    # The full name for the passwd entry (git's default author name). Cleaned
    # again here: a ':' or a newline would corrupt the line.
    gecos="$(printf '%s' "${CIRRUS_RSTUDIO_GECOS:-}" | tr -d '[:cntrl:]' | tr ':' ' ')"

    passwd_file="${STATE_DIR}/passwd"
    group_file="${STATE_DIR}/group"

    # Filter out any existing line for this uid: nss_wrapper returns the first
    # match. `|| true`: grep exits 1 if that leaves nothing.
    grep -v "^[^:]*:[^:]*:${uid}:" /etc/passwd > "$passwd_file" 2>/dev/null || true
    # /bin/bash: RStudio's Terminal uses the passwd shell, and the synthesised
    # /bin/sh (dash) has no line editing.
    printf '%s:x:%s:%s:%s:%s:/bin/bash\n' \
        "$want_name" "$uid" "$gid" "$gecos" "$HOME" >> "$passwd_file"

    if [ -n "$want_group" ]; then
        grep -v "^[^:]*:[^:]*:${gid}:" /etc/group > "$group_file" 2>/dev/null || true
        printf '%s:x:%s:\n' "$want_group" "$gid" >> "$group_file"
    else
        cp /etc/group "$group_file" 2>/dev/null || : > "$group_file"
        getent group "$gid" >/dev/null 2>&1 || printf '%s:x:%s:\n' "$want_name" "$gid" >> "$group_file"
    fi

    export NSS_WRAPPER_PASSWD="$passwd_file"
    export NSS_WRAPPER_GROUP="$group_file"
    export LD_PRELOAD="${lib}${LD_PRELOAD:+:${LD_PRELOAD}}"
    export USER="$want_name"
    export LOGNAME="${LOGNAME:-$want_name}"
    CIRRUS_RSTUDIO_USER="$want_name"
    log "uid ${uid} resolves as '${want_name}'${want_group:+, gid ${gid} as '${want_group}'}"
}
CIRRUS_RSTUDIO_USER=""
setup_nss_wrapper
export CIRRUS_RSTUDIO_USER

# ===========================================================================
# 2. Keep out of the shared home
#
# $HOME is GLADE, shared with Casper and Derecho. Caches and per-session state
# go to /tmp; what is worth keeping goes under one directory, ~/rstudio. Most
# important is the R library: packages built in this image do not load in R
# on Casper or Derecho, so they must not land in ~/R.
# ===========================================================================
PERSIST_DIR="${CIRRUS_RSTUDIO_PERSIST_DIR:-${HOME}/rstudio}"

# Refuse paths the user's other R and RStudio installs read.
persist_dir_is_safe() {
    local d="${1%/}"
    case "$d" in
        ""|"/"|"${HOME%/}") return 1 ;;
        "${HOME%/}"/.*)     return 1 ;;
        */.config|*/.config/*|*/.local|*/.local/*|*/.cache|*/.cache/*) return 1 ;;
        "${HOME%/}"/R|"${HOME%/}"/R/*) return 1 ;;
    esac
    return 0
}
if ! persist_dir_is_safe "$PERSIST_DIR"; then
    warn "${PERSIST_DIR} is also read by your Casper and Derecho sessions; using ${HOME}/rstudio instead."
    PERSIST_DIR="${HOME}/rstudio"
fi
if ! mkdir -p -- "$PERSIST_DIR" 2>/dev/null; then
    warn "could not create ${PERSIST_DIR}, so nothing will persist past this session."
    warn "Your home directory is not writable here, which usually means a failed NFS mount."
    PERSIST_DIR="${STATE_DIR}/persist"
    mkdir -p -- "$PERSIST_DIR"
fi
export CIRRUS_RSTUDIO_PERSIST_DIR="$PERSIST_DIR"

# Unprivileged rserver also writes its RPC key under XDG_CACHE_HOME.
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${STATE_DIR}/cache}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-${STATE_DIR}/xdg-state}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-${STATE_DIR}/xdg-data}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${STATE_DIR}/xdg-config}"
export TMPDIR="${TMPDIR:-${STATE_DIR}/tmp}"

# RStudio's preferences, layout and history, kept apart from any other RStudio
# the user runs (which reads ~/.config/rstudio and ~/.local/share/rstudio).
export RSTUDIO_CONFIG_HOME="${RSTUDIO_CONFIG_HOME:-${PERSIST_DIR}/config}"
export RSTUDIO_DATA_HOME="${RSTUDIO_DATA_HOME:-${PERSIST_DIR}/data}"
mkdir -p -- "$RSTUDIO_CONFIG_HOME" "$RSTUDIO_DATA_HOME" 2>/dev/null || \
    warn "could not create RStudio state under ${PERSIST_DIR}; settings will not persist"

# --- the R library ---------------------------------------------------------
R_VERSION_MM="$(R --version 2>/dev/null | head -1 | awk '{print $3}' | cut -d. -f1,2 || true)"
[ -n "$R_VERSION_MM" ] || R_VERSION_MM="4.6"
R_LIBS_USER_DIR="${PERSIST_DIR}/r-libs/${R_VERSION_MM}"
if ! mkdir -p -- "$R_LIBS_USER_DIR" 2>/dev/null; then
    warn "could not create ${R_LIBS_USER_DIR}; installed packages will not persist"
    R_LIBS_USER_DIR="${STATE_DIR}/r-libs"
    mkdir -p -- "$R_LIBS_USER_DIR"
fi
R_SITE_LIBS="/usr/local/lib/R/site-library:/usr/local/lib/R/library"

# A user's ~/.Renviron overrides R_LIBS_USER from the environment, and most R
# users here have one pointing at a Casper library. So the session reads a copy
# with its R_LIBS* lines removed and ours appended; everything else in it (API
# keys, proxies) still applies.
SESSION_RENVIRON="${STATE_DIR}/Renviron.session"
: > "$SESSION_RENVIRON"
if [ -r "${HOME}/.Renviron" ]; then
    grep -v '^[[:space:]]*R_LIBS' "${HOME}/.Renviron" >> "$SESSION_RENVIRON" 2>/dev/null || true
    log "using your ~/.Renviron, minus its R_LIBS settings"
fi
{
    printf '\n# --- set by the CIRRUS RStudio session ---\n'
    printf 'R_LIBS_USER=%s\n' "$R_LIBS_USER_DIR"
    printf 'R_LIBS=%s:%s\n'   "$R_LIBS_USER_DIR" "$R_SITE_LIBS"
} >> "$SESSION_RENVIRON"
export R_ENVIRON_USER="$SESSION_RENVIRON"
export R_LIBS_USER="$R_LIBS_USER_DIR"
export R_LIBS="${R_LIBS_USER_DIR}:${R_SITE_LIBS}"

# --- working directory: where the editor opens, nothing else ---------------
WORKDIR="${CIRRUS_RSTUDIO_WORKDIR:-$HOME}"
if [ ! -d "$WORKDIR" ]; then
    warn "'${WORKDIR}' is not a directory in this session; opening ${HOME} instead."
    warn "Mounted here: your home, /glade/work, /glade/campaign, /glade/collections and /gdex."
    WORKDIR="$HOME"
fi
export CIRRUS_RSTUDIO_WORKDIR="$WORKDIR"

# --- one ssh-agent per session ----------------------------------------------
# For bao-getkey, which loads a short-lived OpenBao SSH certificate into it so
# ssh to Casper/Derecho skips the two-factor prompt. On container-local /tmp,
# never the NFS home, so it ends with the pod and is never shared between
# sessions. Only for a real server: bootstrap runs should not leave agents.
SSH_AGENT_SOCK="${STATE_DIR}/ssh-agent.sock"
if [ "$MODE" = "rserver" ]; then
    if command -v ssh-agent >/dev/null 2>&1; then
        rm -f -- "$SSH_AGENT_SOCK"
        if ssh-agent -a "$SSH_AGENT_SOCK" >/dev/null; then
            export SSH_AUTH_SOCK="$SSH_AGENT_SOCK"
            log "ssh-agent started at ${SSH_AUTH_SOCK}"
        else
            warn "ssh-agent failed to start; bao-getkey will not work in this session."
        fi
    else
        warn "no ssh-agent in this image; bao-getkey will not work in this session."
    fi
fi

# --- handing the environment to the R session -------------------------------
# rserver builds a filtered environment for rsession, so none of the above
# reaches it on its own. bin/cirrus-rsession reads this file back.
SESSION_ENV_FILE="${STATE_DIR}/session-env"

# rsession's log is shown in the user's Console, so it runs at warn while
# rserver logs at info to the pod log.
SESSION_LOG_LEVEL="${CIRRUS_RSTUDIO_SESSION_LOG_LEVEL:-warn}"
case "$SESSION_LOG_LEVEL" in
    debug|info|warn|warning|error) ;;
    *)  warn "CIRRUS_RSTUDIO_SESSION_LOG_LEVEL=${SESSION_LOG_LEVEL} is not a level; using warn."
        SESSION_LOG_LEVEL=warn ;;
esac

{
    printf '# Written by entrypoint.sh; read by cirrus-rsession.\n'
    printf 'RS_LOG_LEVEL=%s\n'   "$SESSION_LOG_LEVEL"
    printf 'XDG_CACHE_HOME=%s\n' "$XDG_CACHE_HOME"
    printf 'TMPDIR=%s\n'         "$TMPDIR"
    printf 'R_ENVIRON_USER=%s\n' "$R_ENVIRON_USER"
    printf 'USER=%s\n'           "${USER:-}"
    printf 'LOGNAME=%s\n'        "${LOGNAME:-${USER:-}}"
    if [ -n "${NSS_WRAPPER_PASSWD:-}" ] && [ -n "${LD_PRELOAD:-}" ]; then
        printf 'LD_PRELOAD=%s\n'         "$LD_PRELOAD"
        printf 'NSS_WRAPPER_PASSWD=%s\n' "$NSS_WRAPPER_PASSWD"
        printf 'NSS_WRAPPER_GROUP=%s\n'  "$NSS_WRAPPER_GROUP"
    fi
    if [ -n "${SSH_AUTH_SOCK:-}" ]; then
        printf 'SSH_AUTH_SOCK=%s\n' "$SSH_AUTH_SOCK"
    fi
} > "$SESSION_ENV_FILE"

# The library path is set in R itself, by /usr/local/lib/R/etc/Rprofile.site
# sourcing this file: it runs after ~/.Renviron, so it wins. User library
# first, so install.packages() never offers to create one in ~/R.
RPROFILE_SESSION="${STATE_DIR}/Rprofile.session"
r_string() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }
{
    printf '## Written by entrypoint.sh at session start.\n'
    printf 'local({\n'
    printf '  user_lib <- %s\n'  "$(r_string "$R_LIBS_USER_DIR")"
    printf '  site <- %s\n'      "$(r_string "$R_SITE_LIBS")"
    printf '  dir.create(user_lib, recursive = TRUE, showWarnings = FALSE)\n'
    printf '  .libPaths(c(user_lib, unlist(strsplit(site, ":", fixed = TRUE))))\n'
    printf '  Sys.setenv(R_LIBS_USER = user_lib)\n'
    # Used by tools::R_user_dir() for package caches; ~/.cache is on GLADE.
    printf '  Sys.setenv(XDG_CACHE_HOME = %s)\n' "$(r_string "$XDG_CACHE_HOME")"
    printf '})\n'
} > "$RPROFILE_SESSION"

if [ ! -L /usr/local/lib/R/etc/Rprofile.site ] && ! grep -q 'Rprofile.session' /usr/local/lib/R/etc/Rprofile.site 2>/dev/null; then
    warn "/usr/local/lib/R/etc/Rprofile.site does not source ${RPROFILE_SESSION}, so"
    warn "R may install packages into a Casper or Derecho library. This is an image bug."
fi

# Terminal shell: RStudio's default runs bash with --posix, which shows the
# uid instead of the user name in the prompt. Seed cirrus-shell instead, only
# for keys the user has not set themselves.
seed_user_prefs() {
    local prefs="${RSTUDIO_CONFIG_HOME}/rstudio-prefs.json"
    mkdir -p -- "$(dirname -- "$prefs")" 2>/dev/null || return 0
    python3 - "$prefs" <<'PYPREFS' || warn "could not seed RStudio preferences at ${prefs}"
import json, os, sys

path = sys.argv[1]
try:
    with open(path) as fh:
        prefs = json.load(fh)
    if not isinstance(prefs, dict):
        raise ValueError("not an object")
except FileNotFoundError:
    prefs = {}
except Exception as exc:
    # Never overwrite a file we cannot parse; it holds the user's settings.
    print("cirrus-rstudio: WARNING: %s is not valid JSON (%s); leaving it alone." % (path, exc), file=sys.stderr)
    sys.exit(0)

defaults = {
    "posix_terminal_shell": "custom",
    "custom_shell_command": "/usr/local/bin/cirrus-shell",
    "custom_shell_options": "",
}
missing = {k: v for k, v in defaults.items() if k not in prefs}
if missing:
    prefs.update(missing)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(prefs, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)
PYPREFS
}
seed_user_prefs

SESSION_CONF="${STATE_DIR}/rsession.conf"
{
    printf '# Written by entrypoint.sh at session start.\n'
    printf 'session-default-working-dir=%s\n' "$WORKDIR"
    # No .RData written into the shared home on exit; R on Casper and Derecho
    # would silently load it.
    printf 'session-save-action-default=no\n'
} > "$SESSION_CONF"

# ===========================================================================
# 3. Session password and proxy prefix
#
# The init containers write both into a ConfigMap that is already mounted
# (empty) when this starts, and kubelet re-projects it a few seconds later.
# Wait for both rather than racing them.
# ===========================================================================
AUTH="${CIRRUS_RSTUDIO_AUTH:-password}"
CONFIG_WAIT="${CIRRUS_RSTUDIO_CONFIG_WAIT:-120}"
PASSWORD_FILE_OUT="${STATE_DIR}/session-password"
PASSWORD=""
BASE_URL="${CIRRUS_RSTUDIO_BASE_URL:-}"

read_password() {
    # `|| true`: a missing file or no password line is the normal waiting state.
    PASSWORD="$(grep -m1 '^password=' "$CIRRUS_RSTUDIO_PASSWORD_FILE" 2>/dev/null | cut -d= -f2- || true)"
}
read_base_url() {
    # The last line that looks like a path.
    BASE_URL="$(grep -oE '^[[:space:]]*/[^[:space:]]*' "$CIRRUS_RSTUDIO_BASE_URL_FILE" 2>/dev/null | tr -d '[:space:]' | tail -1 || true)"
}

need_password=0; need_base_url=0
if [ "$AUTH" = "password" ]; then
    [ -n "${CIRRUS_RSTUDIO_PASSWORD_FILE:-}" ] && need_password=1
    [ -z "$BASE_URL" ] && [ -n "${CIRRUS_RSTUDIO_BASE_URL_FILE:-}" ] && need_base_url=1
fi

waited=0
while :; do
    [ "$need_password" -eq 1 ] && read_password
    [ "$need_base_url" -eq 1 ] && read_base_url
    if { [ "$need_password" -eq 0 ] || [ -n "$PASSWORD" ]; } &&
       { [ "$need_base_url" -eq 0 ] || [ -n "$BASE_URL" ]; }; then
        break
    fi
    if [ "$waited" -ge "$CONFIG_WAIT" ]; then
        break
    fi
    [ "$waited" -eq 0 ] && log "waiting for the session password and proxy prefix from the init containers"
    sleep 1
    waited=$((waited + 1))
done

CONFIG_ERRORS=()
if [ "$need_password" -eq 1 ] && [ -z "$PASSWORD" ]; then
    CONFIG_ERRORS+=("no session password in ${CIRRUS_RSTUDIO_PASSWORD_FILE} after ${waited}s;"
                    "the add-passwd-to-cfg init container did not write one"
                    "(kubectl logs <pod> -c add-passwd-to-cfg).")
fi
if [ "$need_base_url" -eq 1 ] && [ -z "$BASE_URL" ]; then
    CONFIG_ERRORS+=("no proxy prefix in ${CIRRUS_RSTUDIO_BASE_URL_FILE} after ${waited}s;"
                    "the add-baseurl-to-cfg init container did not write one"
                    "(kubectl logs <pod> -c add-baseurl-to-cfg).")
fi
if [ "$AUTH" = "password" ] && [ "$need_password" -eq 0 ]; then
    CONFIG_ERRORS+=("CIRRUS_RSTUDIO_AUTH=password but CIRRUS_RSTUDIO_PASSWORD_FILE is not set.")
fi

if [ -n "$PASSWORD" ]; then
    ( umask 077; printf '%s' "$PASSWORD" > "$PASSWORD_FILE_OUT" )
    export CIRRUS_RSTUDIO_PASSWORD_FILE_RESOLVED="$PASSWORD_FILE_OUT"
    log "session password loaded"
fi
PASSWORD=""

[ -n "$BASE_URL" ] || BASE_URL="/"
case "$BASE_URL" in */) ;; *) BASE_URL="${BASE_URL}/" ;; esac
[ "$need_base_url" -eq 1 ] && [ "$BASE_URL" != "/" ] && log "proxy prefix: ${BASE_URL}"

PORT="${CIRRUS_RSTUDIO_PORT:-8080}"

# ===========================================================================
# bootstrap mode: everything above, then stop or hand over
# ===========================================================================
if [ "$MODE" = "bootstrap" ]; then
    if [ "$#" -gt 0 ]; then
        exec "$@"
    fi
    log "bootstrap complete"
    log "  user             : $(id -un 2>/dev/null || echo '<no passwd entry>') (uid $(id -u), gid $(id -g))"
    log "  HOME             : ${HOME}"
    log "  persist dir      : ${PERSIST_DIR}"
    log "  R_LIBS_USER      : ${R_LIBS_USER}"
    log "  R_ENVIRON_USER   : ${R_ENVIRON_USER}"
    log "  RSTUDIO_CONFIG_HOME: ${RSTUDIO_CONFIG_HOME}"
    log "  RSTUDIO_DATA_HOME  : ${RSTUDIO_DATA_HOME}"
    log "  working dir      : ${WORKDIR}"
    log "  proxy prefix     : ${BASE_URL}"
    log "  port             : ${PORT}"
    exit 0
fi

if [ "${#CONFIG_ERRORS[@]}" -gt 0 ]; then
    die "this session cannot start without its password and proxy prefix:" "${CONFIG_ERRORS[@]}"
fi

# ===========================================================================
# 4. RStudio Server, behind the gate, supervised
# ===========================================================================
RSERVER=/usr/lib/rstudio-server/bin/rserver
GATE=/usr/local/bin/cirrus-rstudio-gate
UPSTREAM_PORT="${CIRRUS_RSTUDIO_UPSTREAM_PORT:-8788}"

# --server-user takes a name and is mandatory when not root.
SERVER_USER="$(id -un 2>/dev/null || true)"
[ -n "$SERVER_USER" ] || SERVER_USER="$(id -u)"

if [ "$AUTH" = "password" ]; then
    # rserver cannot authenticate when it is not root, so it listens on
    # loopback only and the gate holds the public port.
    RSERVER_ADDRESS=127.0.0.1
    RSERVER_PORT="$UPSTREAM_PORT"
    export CIRRUS_RSTUDIO_ROOT_PATH="$BASE_URL"
    export CIRRUS_RSTUDIO_UPSTREAM_PORT="$UPSTREAM_PORT"
else
    RSERVER_ADDRESS=0.0.0.0
    RSERVER_PORT="$PORT"
    warn "CIRRUS_RSTUDIO_AUTH=none: anyone who can reach port ${PORT} gets an R session and a shell as you."
fi

args=(
    --server-daemonize=0
    --server-user="${SERVER_USER}"
    --www-address="${RSERVER_ADDRESS}"
    --www-port="${RSERVER_PORT}"
    # No --www-root-path: behind /rnode/ rserver must serve at /, or every
    # redirect gets the prefix twice.
    --server-data-dir="${STATE_DIR}/server-data"
    --secure-cookie-key-file="${STATE_DIR}/secure-cookie-key"
    --rsession-which-r=/usr/local/bin/R
    --rsession-config-file="${SESSION_CONF}"
    --rsession-path=/usr/local/bin/cirrus-rsession
)
[ "$AUTH" = "password" ] || args+=(--auth-none=1)

log "starting rserver on ${RSERVER_ADDRESS}:${RSERVER_PORT} as ${SERVER_USER} (uid $(id -u)), opening ${WORKDIR}"
"$RSERVER" "${args[@]}" &
RSERVER_PID=$!
GATE_PID=""
if [ "$AUTH" = "password" ]; then
    "$GATE" &
    GATE_PID=$!
fi

# --- ending the session -----------------------------------------------------
#
# RStudio has no idle shutdown that releases the pod, so this does it: after
# IDLE_TIMEOUT with no activity, or MAX_SECONDS in any case. An open browser
# tab is not activity: it keeps rserver, the gate and rsession polling, so
# their CPU is never counted. Activity is any of:
#
#   * console input: RStudio appends it to history_database at once
#   * R still running console code: RStudio's per-session "executing" flag
#   * anything rsession started (terminals and the commands in them,
#     background jobs, R subprocesses) reading, writing or using CPU
#   * any other CPU in the pod beyond BUSY_CPU_MS per check, which catches
#     processes that start and finish between two checks
IDLE_TIMEOUT="${CIRRUS_RSTUDIO_IDLE_TIMEOUT:-3600}"
IDLE_CHECK="${CIRRUS_RSTUDIO_IDLE_CHECK:-300}"
MAX_SECONDS="${CIRRUS_RSTUDIO_MAX_SECONDS:-43200}"
BUSY_CPU_MS="${CIRRUS_RSTUDIO_BUSY_CPU_MS:-1000}"
ENDED="${STATE_DIR}/session-ended"
rm -f -- "$ENDED"
STARTED="$(date +%s)"
CLK_TCK="$(getconf CLK_TCK 2>/dev/null || echo 100)"

# Whole-pod CPU in ms, from the cgroup; includes processes that have exited.
pod_cpu_ms() {
    if [ -r /sys/fs/cgroup/cpu.stat ]; then
        awk '/^usage_usec/ { print int($2 / 1000) }' /sys/fs/cgroup/cpu.stat
    elif [ -r /sys/fs/cgroup/cpuacct/cpuacct.usage ]; then
        awk '{ print int($1 / 1000000) }' /sys/fs/cgroup/cpuacct/cpuacct.usage
    fi
}

# CPU of the given pids (their own, not their children's), in ms.
pids_cpu_ms() {
    local p total=0 v
    for p in "$@"; do
        v="$(awk -v t="$CLK_TCK" '{ sub(/.*\) /, ""); print int(($12 + $13) * 1000 / t) }' "/proc/$p/stat" 2>/dev/null)"
        total=$((total + ${v:-0}))
    done
    printf '%s' "$total"
}

# One line per process rsession started: pid, I/O bytes and CPU. Any change
# between two checks means something ran, was typed, or printed.
session_children_state() {
    local roots p
    roots="$(pgrep -x rsession 2>/dev/null | tr '\n' ' ')"
    [ -n "$roots" ] || return 0
    ps -e -o pid=,ppid= 2>/dev/null | awk -v roots=" $roots " '
        { parent[$1] = $2 }
        END {
            for (p in parent) {
                q = parent[p]
                while (q in parent) {
                    if (index(roots, " " q " ")) { print p; break }
                    q = parent[q]
                }
            }
        }' | sort -n | while read -r p; do
            printf '%s %s %s\n' "$p" \
                "$(awk '/^(rchar|wchar):/ { s += $2 } END { print s + 0 }' "/proc/$p/io" 2>/dev/null)" \
                "$(pids_cpu_ms "$p")"
        done
}

history_mtime() {
    stat -c %Y "${RSTUDIO_DATA_HOME}/history_database" 2>/dev/null || echo 0
}

r_is_executing() {
    grep -qx 1 "${RSTUDIO_DATA_HOME}"/sessions/active/session-*/properites/executing 2>/dev/null
}

watchdog() {
    local now last_active prev_pod cur_pod prev_quiet cur_quiet
    local prev_children cur_children prev_hist cur_hist reason
    # A failed probe must never take the watchdog down with it.
    set +e +o pipefail
    last_active="$STARTED"
    prev_pod="$(pod_cpu_ms)"
    prev_quiet=0
    prev_children=""
    prev_hist="$(history_mtime)"
    [ -n "$prev_pod" ] || warn "no cgroup CPU accounting; short-lived processes will not count as activity."

    while sleep "$IDLE_CHECK"; do
        kill -0 "$RSERVER_PID" 2>/dev/null || return 0
        now="$(date +%s)"

        cur_hist="$(history_mtime)"
        [ "$cur_hist" = "$prev_hist" ] || last_active="$now"
        prev_hist="$cur_hist"

        r_is_executing && last_active="$now"

        cur_children="$(session_children_state)"
        [ -z "$cur_children" ] || [ "$cur_children" = "$prev_children" ] || last_active="$now"
        prev_children="$cur_children"

        # CPU that an open browser tab causes, to subtract from the pod's.
        cur_quiet="$(pids_cpu_ms "$RSERVER_PID" $GATE_PID $(pgrep -x rsession 2>/dev/null))"
        cur_pod="$(pod_cpu_ms)"
        if [ -n "$prev_pod" ] && [ -n "$cur_pod" ]; then
            # Restarting R starts a new rsession, whose counter begins at 0.
            [ "$cur_quiet" -ge "$prev_quiet" ] || prev_quiet="$cur_quiet"
            if [ $(( (cur_pod - prev_pod) - (cur_quiet - prev_quiet) )) -ge "$BUSY_CPU_MS" ]; then
                last_active="$now"
            fi
        fi
        prev_pod="$cur_pod"; prev_quiet="$cur_quiet"

        if [ $(( now - STARTED )) -ge "$MAX_SECONDS" ]; then
            reason="the session reached its maximum length of ${MAX_SECONDS}s."
        elif [ "$IDLE_TIMEOUT" -gt 0 ] && [ $(( now - last_active )) -ge "$IDLE_TIMEOUT" ]; then
            reason="no activity for $(( now - last_active ))s (limit ${IDLE_TIMEOUT}s)."
        else
            continue
        fi
        log "$reason"
        log "Ending this session so it stops holding its CPU and memory. Relaunch from"
        log "OnDemand when you need it; your files, R packages and RStudio settings are kept."
        printf '%s\n' "$reason" > "$ENDED"
        kill -TERM "$RSERVER_PID" 2>/dev/null
        return 0
    done
}
watchdog &
WATCHDOG_PID=$!

stop_all() {
    kill -TERM "$RSERVER_PID" ${GATE_PID:+"$GATE_PID"} "$WATCHDOG_PID" 2>/dev/null || true
}

# This shell is PID 1, so pod deletion (ending the session from the dashboard)
# signals it. Stop RStudio cleanly and report success.
on_term() {
    log "received SIGTERM; stopping RStudio"
    stop_all
    wait "$RSERVER_PID" 2>/dev/null || true
    exit 0
}
trap on_term TERM INT

# Whichever of rserver and the gate exits first ends the session.
RC=0
wait -n "$RSERVER_PID" ${GATE_PID:+"$GATE_PID"} || RC=$?
stop_all
wait "$RSERVER_PID" 2>/dev/null || true

# Ended on purpose: exit 0, so the pod is Completed rather than restarted
# (restart_policy is OnFailure) or shown as Failed.
if [ -f "$ENDED" ]; then
    log "session ended: $(cat "$ENDED")"
    exit 0
fi
log "RStudio exited unexpectedly (status ${RC})"
exit "$RC"
