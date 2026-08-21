#!/usr/bin/env bash
#
# CIRRUS RStudio Server entrypoint.  Usage: entrypoint.sh {rserver|bootstrap}
#
# Replaces rocker's /init entirely. See the header in the Dockerfile for why:
# s6 stage1 and both /etc/cont-init.d scripts require root, and 02_userconf's
# useradd/chown -R path would be pointed at a GLADE home over NFS.
#
# What this does instead, in order:
#   1. give the runtime uid a name (nss_wrapper)
#   2. keep everything this session writes out of the user's shared dotfiles
#   3. resolve the session password and the proxy root path
#   4. exec rserver with the flags an unprivileged session needs
#
# Nothing here chowns anything, and nothing writes into the image.

set -euo pipefail

PROG="cirrus-rstudio"
# stderr, always. `entrypoint.sh bootstrap <cmd>` has to leave stdout clean for
# <cmd>, and in the OOD path both streams land in the pod log anyway.
log()  { printf '%s: %s\n' "$PROG" "$*" >&2; }
warn() { printf '%s: WARNING: %s\n' "$PROG" "$*" >&2; }

usage() {
    cat >&2 <<USAGE
usage: entrypoint.sh rserver
       entrypoint.sh bootstrap [command...]

  rserver     Start RStudio Server (the OOD app path).

  bootstrap   Run the common bootstrap only -- runtime uid, home isolation,
              password, proxy path -- then exec command... if one was given, or
              print a summary and exit. This is what the tests drive, and it is
              the way to reproduce a session's environment by hand without
              starting a server.
USAGE
}

MODE="${1:-rserver}"
case "$MODE" in
    rserver|bootstrap) shift || true ;;
    -h|--help) usage; exit 2 ;;
    *) printf '%s: ERROR: unknown mode: %s\n' "$PROG" "$MODE" >&2; usage; exit 2 ;;
esac

# ===========================================================================
# 1. Session-local state
# ===========================================================================

STATE_DIR="${CIRRUS_RSTUDIO_STATE_DIR:-/tmp/cirrus-rstudio}"
export CIRRUS_RSTUDIO_STATE_DIR="$STATE_DIR"

# $HOME is the user's GLADE home in the OOD path. Standalone (podman run --user
# 54321:54321) there may be no usable $HOME at all, so give it somewhere
# writable rather than letting every ~-relative path expand to "/".
if [ -n "${HOME:-}" ] && [ ! -d "$HOME" ]; then
    mkdir -p -- "$HOME" 2>/dev/null || true
fi
if [ -z "${HOME:-}" ] || [ ! -d "${HOME:-}" ]; then
    warn "\$HOME is unset or unusable (${HOME:-<unset>}); using ${STATE_DIR}/home"
    HOME="${STATE_DIR}/home"
    export HOME
fi

mkdir -p \
    "${STATE_DIR}" \
    "${STATE_DIR}/database" \
    "${STATE_DIR}/server-data" \
    "${STATE_DIR}/cache" \
    "${STATE_DIR}/xdg-data" \
    "${STATE_DIR}/xdg-config" \
    "${STATE_DIR}/xdg-state" \
    "${STATE_DIR}/tmp" \
    "${STATE_DIR}/run" 2>/dev/null || true

# ===========================================================================
# 2. Runtime uid
#
# OOD sets runAsUser/runAsGroup to the user's real NFS uid/gid, which has no
# entry in this image's /etc/passwd. rserver's --auth-validate-users calls
# getpwnam on the name being logged in; RStudio resolves the session home from
# the passwd entry; git, ssh and the terminal prompt all call getpwuid(). So the
# uid needs a name, and we cannot write to /etc.
# ===========================================================================

setup_nss_wrapper() {
    local uid gid lib want_name want_group cur_name cur_group
    local passwd_file group_file need_passwd=0 need_group=0
    uid="$(id -u)"
    gid="$(id -g)"

    # OOD sets USER, NB_USER and GROUP in the pod spec, and it is the authority:
    # the container has no way to know any of them.
    want_name="${USER:-${NB_USER:-}}"
    case "${want_name}" in ''|*[!a-zA-Z0-9._-]*) want_name="" ;; esac
    [ -n "$want_name" ] || want_name="rstudio-${uid}"
    want_group="${GROUP:-}"
    case "${want_group}" in *[!a-zA-Z0-9._-]*) want_group="" ;; esac

    # `|| true` on both, and it is load-bearing. With no entry getent exits 2;
    # under `set -e` with `pipefail` that kills this script here -- before it has
    # logged a single line, so the session dies with an empty pod log and no
    # clue. That is precisely the Kubernetes case, where nothing has synthesised
    # an entry.
    cur_name="$(getent passwd "$uid" 2>/dev/null | cut -d: -f1 || true)"
    cur_group="$(getent group "$gid" 2>/dev/null | cut -d: -f1 || true)"

    # "Does an entry exist" is the wrong test. Container runtimes synthesise one
    # whose *name is the uid* -- verified here under podman:
    #   54321:*:54321:54321:container user:/:/bin/sh
    # It satisfies an existence check while being useless: getpwuid returns
    # "54321", so the prompt, whoami, git and RStudio's own user display all show
    # a number, and the login shell is /bin/sh. Treat an all-digits name as no
    # name at all.
    if [ -z "$cur_name" ] || [ "$cur_name" = "$uid" ]; then
        need_passwd=1
    else
        case "$cur_name" in
            *[!0-9]*) : ;;          # has a non-digit: a real name, leave it alone
            *) need_passwd=1 ;;     # all digits: the uid wearing a name's clothes
        esac
    fi

    # Likewise the group: gid 1000 resolves to the image's own "ubuntu" group,
    # so without this a user whose group is ncar reports gid=1000(ubuntu).
    if [ -n "$want_group" ] && [ "$cur_group" != "$want_group" ]; then
        need_group=1
    fi

    if [ "$need_passwd" -eq 0 ] && [ "$need_group" -eq 0 ]; then
        CIRRUS_RSTUDIO_USER="$cur_name"
        return 0
    fi

    lib="$(cat /opt/cirrus-rstudio/nss_wrapper_lib 2>/dev/null || true)"
    if [ -z "$lib" ] || [ ! -r "$lib" ]; then
        warn "libnss_wrapper.so was not found; uid ${uid} will resolve as"
        warn "'${cur_name:-<unresolved>}' and RStudio's login will almost certainly"
        warn "fail --auth-validate-users. This is an image bug, not a site problem."
        CIRRUS_RSTUDIO_USER="${cur_name:-$want_name}"
        return 0
    fi

    passwd_file="${STATE_DIR}/passwd"
    group_file="${STATE_DIR}/group"

    # Existing entries for this uid/gid are filtered out rather than appended
    # after: nss_wrapper returns the FIRST match, so leaving the runtime's
    # numeric line in place would win over ours and nothing would change.
    #
    # `|| true` again: grep exits 1 when it filters everything out, which under
    # pipefail would end the script.
    grep -v "^[^:]*:[^:]*:${uid}:" /etc/passwd > "$passwd_file" 2>/dev/null || true
    # /bin/bash, not the synthesised /bin/sh. RStudio reads the login shell from
    # the passwd entry and uses it for the Terminal tab; /bin/sh here is dash,
    # which has no readline, so the arrow keys emit ^[[A instead of walking
    # history -- a terminal that looks broken to anyone who has used one before.
    printf '%s:x:%s:%s:CIRRUS RStudio user:%s:/bin/bash\n' \
        "$want_name" "$uid" "$gid" "$HOME" >> "$passwd_file"

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
    log "uid ${uid} resolves as '${want_name}'${want_group:+, gid ${gid} as '${want_group}'} (via nss_wrapper)"
}
CIRRUS_RSTUDIO_USER=""
setup_nss_wrapper
export CIRRUS_RSTUDIO_USER

# ===========================================================================
# 3. Home isolation
#
# $HOME is GLADE, shared with Casper and Derecho. Anything written to a shared
# dotfile here can break the user's sessions on those machines, and the worst
# offender is the R library: packages compiled in this image link against this
# image's glibc and BLAS, and R on Casper will happily try to load them.
#
# So: caches and per-session state go to /tmp, and the few things genuinely
# worth keeping go under one named directory, $HOME/rstudio.
# ===========================================================================

# Where state persists. Deliberately NOT derived from the working directory --
# that is a launch-form choice, and deriving this from it means a user who sets
# their working directory to their home turns every one of these paths into a
# shared dotfile. Two concepts, two variables.
PERSIST_DIR="${CIRRUS_RSTUDIO_PERSIST_DIR:-${HOME}/rstudio}"

# Backstop, whoever set it and however. The failure this prevents is silent:
# $HOME/.config/rstudio and $HOME/.local/share/rstudio are read by RStudio
# anywhere else the user runs it, and $HOME itself would scatter everything.
persist_dir_is_safe() {
    local d="${1%/}"
    case "$d" in
        ""|"/"|"${HOME%/}") return 1 ;;   # home itself, or the root
        "${HOME%/}"/.*)     return 1 ;;   # any dotfile directly in home
        */.config|*/.config/*|*/.local|*/.local/*|*/.cache|*/.cache/*) return 1 ;;
        "${HOME%/}"/R|"${HOME%/}"/R/*)    return 1 ;;   # R's own default user library
    esac
    return 0
}
if ! persist_dir_is_safe "$PERSIST_DIR"; then
    warn "persist directory ${PERSIST_DIR} is a path your Casper and Derecho sessions"
    warn "also read. Using ${HOME}/rstudio instead, which is this app's own directory."
    PERSIST_DIR="${HOME}/rstudio"
fi
if ! mkdir -p -- "$PERSIST_DIR" 2>/dev/null; then
    warn "could not create ${PERSIST_DIR}; nothing will persist past this session."
    warn "Your home directory is not writable here -- usually a failed NFS mount."
    PERSIST_DIR="${STATE_DIR}/persist"
    mkdir -p -- "$PERSIST_DIR"
fi
export CIRRUS_RSTUDIO_PERSIST_DIR="$PERSIST_DIR"

# --- caches and XDG: /tmp, never the home ---------------------------------
#
# XDG_CACHE_HOME is not cosmetic here. Running without privilege, rserver cannot
# read the system secure key and falls back to $HOME/.cache/rstudio/
# session-rpc-key -- verified in the log:
#   WARNING Running without privilege; system secure key at
#   /var/lib/rstudio-server/session-rpc-key is not readable, falling back to
#   user cache
# That is a write into the shared home on every single launch.
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-${STATE_DIR}/cache}"
export XDG_STATE_HOME="${XDG_STATE_HOME:-${STATE_DIR}/xdg-state}"
export XDG_DATA_HOME="${XDG_DATA_HOME:-${STATE_DIR}/xdg-data}"
export XDG_CONFIG_HOME="${XDG_CONFIG_HOME:-${STATE_DIR}/xdg-config}"
export TMPDIR="${TMPDIR:-${STATE_DIR}/tmp}"

# --- RStudio's own state --------------------------------------------------
#
# RStudio reads these two before it reads XDG, which is why they are set
# explicitly rather than left to inherit: RSTUDIO_CONFIG_HOME defaults to
# $HOME/.config/rstudio and RSTUDIO_DATA_HOME to $HOME/.local/share/rstudio,
# both of which are shared dotfiles. Pointed at the app's own directory they
# keep doing their job -- editor preferences, pane layout, console history --
# without any other RStudio the user runs ever seeing them.
export RSTUDIO_CONFIG_HOME="${RSTUDIO_CONFIG_HOME:-${PERSIST_DIR}/config}"
export RSTUDIO_DATA_HOME="${RSTUDIO_DATA_HOME:-${PERSIST_DIR}/data}"
mkdir -p -- "$RSTUDIO_CONFIG_HOME" "$RSTUDIO_DATA_HOME" 2>/dev/null || \
    warn "could not create RStudio state under ${PERSIST_DIR}; settings will not persist"

# --- the R library --------------------------------------------------------
#
# The big one. R_LIBS_USER defaults to $HOME/R/x86_64-pc-linux-gnu-library/4.6,
# which is exactly where the user's Casper and Derecho R sessions look. A package
# compiled in this image and installed there is loaded by HPC R against a
# different glibc and a different BLAS, and the failure surfaces days later,
# somewhere else, as a segfault or an undefined symbol.
#
# Two things are required to keep out of it, and setting the environment variable
# is only the first:
#
#   1. R_LIBS_USER here, pointing inside $HOME/rstudio.
#   2. R_ENVIRON_USER below -- because a user's ~/.Renviron OVERRIDES the
#      environment. Verified: with R_LIBS_USER=/tmp/rlib in the environment and
#      `R_LIBS_USER=/glade/u/home/ncote/R/casper/4.4` in ~/.Renviron, R reports
#      the Casper path. Anyone who has ever configured R on this platform has
#      that line in their home directory.
R_VERSION_MM="$(R --version 2>/dev/null | head -1 | awk '{print $3}' | cut -d. -f1,2 || true)"
[ -n "$R_VERSION_MM" ] || R_VERSION_MM="4.6"
R_LIBS_USER_DIR="${PERSIST_DIR}/r-libs/${R_VERSION_MM}"
if ! mkdir -p -- "$R_LIBS_USER_DIR" 2>/dev/null; then
    warn "could not create ${R_LIBS_USER_DIR}; installed packages will not persist"
    R_LIBS_USER_DIR="${STATE_DIR}/r-libs"
    mkdir -p -- "$R_LIBS_USER_DIR"
fi

# The site library, in the order R itself would put it. Reproduced rather than
# inherited because R_LIBS is written below and an unset value would drop it.
R_SITE_LIBS="/usr/local/lib/R/site-library:/usr/local/lib/R/library"

# The session's Renviron, generated fresh each launch.
#
# It is the user's ~/.Renviron with every R_LIBS* assignment filtered out and
# ours appended, rather than a file of our own: their other settings (API keys,
# proxies, options) are theirs and should still work. Only the library path is
# taken away from them, and only because it is the one that reaches off this
# machine.
#
# R_LIBS is set as well as R_LIBS_USER so the user library comes FIRST in
# .libPaths(). Verified: with only R_LIBS_USER set, .libPaths()[1] is
# /usr/local/lib/R/site-library, which is root-owned -- so install.packages()
# finds its default library unwritable and interactively offers to create a
# personal one at $HOME/R/..., putting the user straight back into the shared
# path this whole section exists to avoid.
SESSION_RENVIRON="${STATE_DIR}/Renviron.session"
: > "$SESSION_RENVIRON"
if [ -r "${HOME}/.Renviron" ]; then
    # `|| true`: a ~/.Renviron consisting only of R_LIBS lines filters to nothing
    # and grep exits 1, which under set -e ends the session with no explanation.
    grep -v '^[[:space:]]*R_LIBS' "${HOME}/.Renviron" >> "$SESSION_RENVIRON" 2>/dev/null || true
    log "carried your ~/.Renviron into this session, minus its R_LIBS settings"
fi
{
    printf '\n# --- set by the CIRRUS RStudio session; see entrypoint.sh ---\n'
    printf 'R_LIBS_USER=%s\n' "$R_LIBS_USER_DIR"
    printf 'R_LIBS=%s:%s\n'   "$R_LIBS_USER_DIR" "$R_SITE_LIBS"
} >> "$SESSION_RENVIRON"
export R_ENVIRON_USER="$SESSION_RENVIRON"
export R_LIBS_USER="$R_LIBS_USER_DIR"
export R_LIBS="${R_LIBS_USER_DIR}:${R_SITE_LIBS}"

# ===========================================================================
# 4. Working directory -- where the editor opens, and nothing else
# ===========================================================================
WORKDIR="${CIRRUS_RSTUDIO_WORKDIR:-$HOME}"
if [ ! -d "$WORKDIR" ]; then
    warn "'${WORKDIR}' is not a directory in this session; opening ${HOME} instead."
    warn "Only your home directory is mounted here."
    WORKDIR="$HOME"
fi
export CIRRUS_RSTUDIO_WORKDIR="$WORKDIR"

# ===========================================================================
# 4b. Handing all of that to the R session
#
# None of the environment above reaches rsession on its own, and that is not a
# detail -- it is the difference between this app isolating the home directory
# and only appearing to. rserver does not fork the R session with its own
# environment; it builds a filtered one. Verified by reading the live process:
#
#   $ tr '\0' '\n' < /proc/$(pgrep -x rsession)/environ
#   HOME=/home/ncote
#   RSTUDIO_CONFIG_HOME=/home/ncote/rstudio/config     <- survives
#   RSTUDIO_DATA_HOME=/home/ncote/rstudio/data         <- survives
#   XDG_CONFIG_HOME=... XDG_DATA_HOME=... XDG_STATE_HOME=...   <- survive
#   (no R_LIBS_USER, no R_LIBS, no R_ENVIRON_USER, no XDG_CACHE_HOME,
#    no TMPDIR, no LD_PRELOAD, no NSS_WRAPPER_*)
#
# So the R session was reading the user's own ~/.Renviron and installing into
# their Casper library, with .libPaths()[1] back to the read-only site library,
# while everything in this script looked correct. The one giveaway was
# client_init reporting r_libs_user as the Casper path.
#
# /etc/rstudio/env-vars is not the fix, though it reads like it: rserver applies
# that file to itself and the session still comes up without it. Two mechanisms
# are needed instead, for two different halves of the problem:
#
#   * this file, read back by bin/cirrus-rsession (rserver's --rsession-path),
#     which puts the process environment back one exec before the session
#     starts -- and therefore in front of every terminal the user opens;
#   * Rprofile.session below, for the R library path specifically, because the
#     environment is not enough there even when it survives: a user's
#     ~/.Renviron overrides it.
# ===========================================================================
SESSION_ENV_FILE="${STATE_DIR}/session-env"
{
    printf '# Written by entrypoint.sh; read by cirrus-rsession.\n'
    printf 'XDG_CACHE_HOME=%s\n' "$XDG_CACHE_HOME"
    printf 'TMPDIR=%s\n'         "$TMPDIR"
    printf 'R_ENVIRON_USER=%s\n' "$R_ENVIRON_USER"
    printf 'USER=%s\n'           "${USER:-}"
    printf 'LOGNAME=%s\n'        "${LOGNAME:-${USER:-}}"
} > "$SESSION_ENV_FILE"

# nss_wrapper has to be re-established for the session too. Without it the
# Terminal tab runs as a uid with no name: the prompt shows a number, `whoami`
# prints the uid, and git refuses to commit with
#   fatal: unable to look up current user in the passwd file
if [ -n "${NSS_WRAPPER_PASSWD:-}" ] && [ -n "${LD_PRELOAD:-}" ]; then
    {
        printf 'LD_PRELOAD=%s\n'          "$LD_PRELOAD"
        printf 'NSS_WRAPPER_PASSWD=%s\n'  "$NSS_WRAPPER_PASSWD"
        printf 'NSS_WRAPPER_GROUP=%s\n'   "$NSS_WRAPPER_GROUP"
    } >> "$SESSION_ENV_FILE"
fi

# The R session profile.
#
# The library path is established in R itself -- see
# /usr/local/lib/R/etc/Rprofile.site, which sources this file. It runs after the
# user's ~/.Renviron, which is what makes it win: setting R_LIBS_USER in the
# environment does not, because ~/.Renviron overrides it, and the session
# environment is filtered on top of that.
#
# Written with dput()-safe quoting rather than interpolation: $HOME comes from
# the pod spec and a quote or a backslash in it would otherwise be R syntax.
RPROFILE_SESSION="${STATE_DIR}/Rprofile.session"
r_string() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"; }
{
    printf '## Written by entrypoint.sh at session start.\n'
    printf 'local({\n'
    printf '  user_lib <- %s\n'  "$(r_string "$R_LIBS_USER_DIR")"
    printf '  site <- %s\n'      "$(r_string "$R_SITE_LIBS")"
    printf '  dir.create(user_lib, recursive = TRUE, showWarnings = FALSE)\n'
    # First, not appended: install.packages() writes to .libPaths()[1], and the
    # site library is root-owned. Left second, R would find its default library
    # unwritable and interactively offer to create a personal one at
    # ~/R/x86_64-pc-linux-gnu-library/4.6 -- the shared path all of this exists
    # to stay out of.
    printf '  .libPaths(c(user_lib, unlist(strsplit(site, ":", fixed = TRUE))))\n'
    printf '  Sys.setenv(R_LIBS_USER = user_lib)\n'
    # XDG_CACHE_HOME is dropped from the session environment too, and R hands it
    # to tools::R_user_dir(), which packages use for downloads and caches. Left
    # unset it is ~/.cache, which is on GLADE and shared with Casper.
    printf '  Sys.setenv(XDG_CACHE_HOME = %s)\n' "$(r_string "$XDG_CACHE_HOME")"
    printf '})\n'
} > "$RPROFILE_SESSION"

if [ ! -L /usr/local/lib/R/etc/Rprofile.site ] && ! grep -q 'Rprofile.session' /usr/local/lib/R/etc/Rprofile.site 2>/dev/null; then
    warn "/usr/local/lib/R/etc/Rprofile.site does not source ${RPROFILE_SESSION}."
    warn "The R session will fall back to your ~/.Renviron, which on this platform"
    warn "usually points R_LIBS_USER at a Casper or Derecho library. This is an"
    warn "image bug."
fi

# RStudio user preferences.
#
# Only the terminal shell, and only keys the user has not already set. RStudio's
# default POSIX terminal is `bash --login --posix`, and POSIX-mode bash renders
# \u from the uid rather than the passwd entry -- verified:
#
#   $ bash         -c 'PS1="\u"; printf %s "${PS1@P}"'   ->  ncote
#   $ bash --posix -c 'PS1="\u"; printf %s "${PS1@P}"'   ->  54321
#
# with nss_wrapper active and whoami answering ncote in both. So every terminal
# opens with a prompt that reads as a broken session while everything in it
# works. A custom shell of `/bin/bash -l` is the same login shell without POSIX
# mode.
#
# Written into RSTUDIO_CONFIG_HOME, which is this app's own directory under
# $HOME/rstudio -- not $HOME/.config/rstudio, which the user's other RStudio
# installations read.
seed_user_prefs() {
    local prefs="${RSTUDIO_CONFIG_HOME}/rstudio-prefs.json"
    mkdir -p -- "$(dirname -- "$prefs")" 2>/dev/null || return 0
    python3 - "$prefs" <<'PYPREFS' || warn "could not seed RStudio preferences at ${prefs}"
import json, os, sys

path = sys.argv[1]
# Existing preferences win, always. This runs on every launch, and a user who
# changed their terminal shell in the IDE should not have it changed back.
try:
    with open(path) as fh:
        prefs = json.load(fh)
    if not isinstance(prefs, dict):
        raise ValueError("not an object")
except FileNotFoundError:
    prefs = {}
except Exception as exc:
    # A file we cannot parse is left exactly as it is. Overwriting it would
    # throw away every preference the user has set.
    print("cirrus-rstudio: WARNING: %s is not readable as JSON (%s);" % (path, exc), file=sys.stderr)
    print("cirrus-rstudio: WARNING: leaving it alone. The terminal prompt may show your uid.", file=sys.stderr)
    sys.exit(0)

defaults = {
    "posix_terminal_shell": "custom",
    "custom_shell_command": "/usr/local/bin/cirrus-shell",
    "custom_shell_options": "",
}
changed = False
for key, value in defaults.items():
    if key not in prefs:
        prefs[key] = value
        changed = True

if changed:
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(prefs, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)
PYPREFS
}
seed_user_prefs

# rsession's own configuration, generated for the same reason: the working
# directory is a launch-form value and cannot be baked into the image.
SESSION_CONF="${STATE_DIR}/rsession.conf"
{
    printf '# Written by entrypoint.sh at session start.\n'
    # Where the Files pane and a new console start. Not a persistence path --
    # see the note on PERSIST_DIR above for why those are two different things.
    printf 'session-default-working-dir=%s\n' "$WORKDIR"
    # Do not write .RData into the working directory on exit. That directory is
    # in the GLADE home, which Casper and Derecho also see, and a stray .RData
    # is silently reloaded by every later R start on any of the three.
    printf 'session-save-action-default=no\n'
} > "$SESSION_CONF"

# ===========================================================================
# 5. Session password
#
# Generated by the init-secret container into <pod>-secret, copied into a
# configmap by add-passwd-to-cfg, and projected here as a file. OnDemand reads
# the same Secret to build the Connect button, so both ends agree without the
# password ever being rendered into an app template.
# ===========================================================================

PASSWORD_FILE_OUT="${STATE_DIR}/session-password"
resolve_password() {
    local src="${CIRRUS_RSTUDIO_PASSWORD_FILE:-}" i pw=""

    if [ "${CIRRUS_RSTUDIO_AUTH:-password}" = "none" ]; then
        return 0
    fi
    if [ -z "$src" ]; then
        warn "CIRRUS_RSTUDIO_AUTH=password but CIRRUS_RSTUDIO_PASSWORD_FILE is unset."
        warn "Nobody can sign in to this session. Starting anyway so the log is readable."
        return 1
    fi

    # The wait is what makes this race-free. Volumes are mounted before init
    # containers run, so the file is already projected -- empty -- by the time
    # add-passwd-to-cfg edits the underlying ConfigMap. Kubelet re-projects
    # within a second or two, but "usually fast enough" is not a guarantee, and
    # losing that race silently produces a session whose Connect button is
    # rejected with no clue why. The startup probe in submit.yml.erb is sized to
    # cover this wait.
    for i in $(seq 1 120); do
        # `|| true` twice over: the file may not exist yet (grep exits 2) and may
        # exist with no password line (grep exits 1). Both are the normal state
        # of this loop, and both would end the script under set -e + pipefail.
        pw="$(grep -m1 '^password=' "$src" 2>/dev/null | cut -d= -f2- || true)"
        [ -n "$pw" ] && break
        [ "$i" -eq 1 ] && log "waiting for the session password at ${src}"
        sleep 1
    done

    if [ -z "$pw" ]; then
        warn "no password appeared at ${src} after 120s."
        warn "The add-passwd-to-cfg init container did not write one. Check:"
        warn "    kubectl logs \$POD -c add-passwd-to-cfg"
        return 1
    fi

    # 0600 and in /tmp, never in the home. cirrus-rstudio-gate reads it; nothing
    # else in this pod runs as anyone else.
    ( umask 077; printf '%s' "$pw" > "$PASSWORD_FILE_OUT" )
    export CIRRUS_RSTUDIO_PASSWORD_FILE_RESOLVED="$PASSWORD_FILE_OUT"
    log "session password loaded (${#pw} characters)"
    return 0
}
PASSWORD_OK=1
resolve_password || PASSWORD_OK=0

# ===========================================================================
# 6. Proxy root path
#
# OnDemand ships two proxies and they are not interchangeable:
#
#   /node/HOST/PORT/...   forwards the whole path, prefix included.
#   /rnode/HOST/PORT/...  strips the prefix.
#
# rserver has --www-root-path, so /node/ is the right one -- and the prefix is
# /node/<nodeName>/<nodePort>/, neither of which exists until the pod is
# scheduled and its service is assigned a NodePort. So it cannot come from the
# pod spec: an init container computes it and writes it into a configmap file,
# and this reads it.
# ===========================================================================

BASE_URL="${CIRRUS_RSTUDIO_BASE_URL:-}"
if [ -z "$BASE_URL" ] && [ -n "${CIRRUS_RSTUDIO_BASE_URL_FILE:-}" ]; then
    # Waited for, like the password, and for the same reason: the volume is
    # projected before the init containers run, so the file is already here and
    # empty when they start editing the underlying ConfigMap, and kubelet
    # re-projects a second or two later. Both keys live in the same ConfigMap and
    # a projection is atomic, so in practice the password wait above has already
    # covered this -- but the cost of losing the race is a session that renders
    # without stylesheets and whose sign-in posts to the wrong URL, which is a
    # miserable thing to debug from a browser, and the cost of the loop is a few
    # seconds in the case that never happens.
    for i in $(seq 1 30); do
        # Last path-looking line, not the whole file: the init container writes a
        # ConfigMap key, and a seeded comment or a second write would otherwise
        # be concatenated into a nonsense prefix.
        #
        # `|| true`: an empty file -- exactly what a failed init container leaves
        # behind -- makes grep exit 1, which under pipefail + set -e kills the
        # session before the warning below can be printed.
        BASE_URL="$(grep -oE '^[[:space:]]*/[^[:space:]]*' "$CIRRUS_RSTUDIO_BASE_URL_FILE" 2>/dev/null | tr -d '[:space:]' | tail -1 || true)"
        [ -n "$BASE_URL" ] && break
        sleep 1
    done
    if [ -n "$BASE_URL" ]; then
        log "root path read from ${CIRRUS_RSTUDIO_BASE_URL_FILE}: ${BASE_URL}"
    else
        warn "no root path appeared at ${CIRRUS_RSTUDIO_BASE_URL_FILE}."
        warn "The init container that computes it did not write one. Check:"
        warn "    kubectl logs \$POD -c add-baseurl-to-cfg"
        warn "Serving at / instead. Behind the OnDemand proxy that means RStudio's"
        warn "own redirects and cookies drop the /rnode/<node>/<port>/ prefix, so"
        warn "the session lands on the dashboard's 404 page instead of the IDE."
    fi
fi
[ -n "$BASE_URL" ] || BASE_URL="/"
# rserver wants a trailing slash on a non-root path; without it the assets it
# emits are one path segment short.
case "$BASE_URL" in */) ;; *) BASE_URL="${BASE_URL}/" ;; esac

PORT="${CIRRUS_RSTUDIO_PORT:-8080}"

# ===========================================================================
# 7. bootstrap mode -- everything above, then stop or hand over
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
    log "  XDG_CACHE_HOME   : ${XDG_CACHE_HOME}"
    log "  working dir      : ${WORKDIR}"
    log "  session env      : ${SESSION_ENV_FILE}"
    log "  R site profile   : ${RPROFILE_SESSION}"
    log "  rsession.conf    : ${SESSION_CONF}"
    log "  root path        : ${BASE_URL}"
    log "  port             : ${PORT}"
    exit 0
fi

# ===========================================================================
# 8. RStudio Server
# ===========================================================================

RSERVER=/usr/lib/rstudio-server/bin/rserver
UID_NOW="$(id -u)"

# --server-user is mandatory. Left at its default of rstudio-server, rserver
# exits 1 before binding anything:
#   Attempt to run server as user 'rstudio-server' (uid 997) from account
#   '54321' (uid 54321) without privilege
#
# It takes a NAME, not a uid, and resolves it with getpwnam. The numeric uid
# works only by accident, when the container runtime has synthesised an entry
# whose name is the uid -- and setting up nss_wrapper deliberately removes that
# entry, so passing the uid here fails with:
#   ERROR Could not find details for server user '54321'
#   Failed password entry database lookup for user, user-value: 54321
#
# So ask the same resolver rserver will use, under the same environment
# (nss_wrapper is already exported at this point), and fall back to the uid for
# the case where nothing resolved at all -- where it is at least the value the
# runtime's synthesised entry would answer to.
SERVER_USER="$(id -un 2>/dev/null || true)"
[ -n "$SERVER_USER" ] || SERVER_USER="$UID_NOW"

# ---------------------------------------------------------------------------
# Who holds the port.
#
# RStudio Server cannot authenticate anybody when it is not running as root, and
# it does not pretend to: it signs the caller in as the server user on request.
# Verified against this image, with a PAM helper configured and every auth
# option left at its default:
#
#   $ curl -c jar '.../auth-sign-in?appUri=%2F'
#   HTTP/1.1 302 Moved Temporarily
#   Set-Cookie: user-id=ncote|...
#
# No password sent, no login form served, and the configured helper never
# executed. Running unprivileged, rserver cannot become any user other than the
# one it already is, so there is nothing for it to check.
#
# With CIRRUS_RSTUDIO_AUTH=password (the default), the gate holds the public
# port and rserver binds loopback behind it. With CIRRUS_RSTUDIO_AUTH=none there
# is no gate and rserver holds the port itself -- which is the honest spelling
# of what an unguarded rserver does anyway.
# ---------------------------------------------------------------------------
GATE=/usr/local/bin/cirrus-rstudio-gate
UPSTREAM_PORT="${CIRRUS_RSTUDIO_UPSTREAM_PORT:-8788}"
USE_GATE=0
if [ "${CIRRUS_RSTUDIO_AUTH:-password}" = "password" ]; then
    if [ "$PASSWORD_OK" -eq 1 ]; then
        USE_GATE=1
    else
        # Refuse rather than fall back to no auth. A session that silently drops
        # its password check is worse than one that does not start: the pod looks
        # healthy and the exposure is invisible.
        warn "CIRRUS_RSTUDIO_AUTH=password but no session password is available."
        warn "Refusing to start an unauthenticated session. The reason is above;"
        warn "set CIRRUS_RSTUDIO_AUTH=none deliberately if that is really wanted."
        exit 1
    fi
fi

# The port rserver itself binds: the public one when it is alone, the loopback
# one when the gate is in front. Decided before the argument list is built --
# rserver rejects a repeated flag outright ("option '--www-port' cannot be
# specified more than once on command line") rather than taking the last value,
# so it cannot be appended as an override.
if [ "$USE_GATE" -eq 1 ]; then
    RSERVER_ADDRESS=127.0.0.1
    RSERVER_PORT="$UPSTREAM_PORT"
    export CIRRUS_RSTUDIO_ROOT_PATH="$BASE_URL"
    export CIRRUS_RSTUDIO_UPSTREAM_PORT="$UPSTREAM_PORT"
else
    RSERVER_ADDRESS=0.0.0.0
    RSERVER_PORT="$PORT"
    warn "CIRRUS_RSTUDIO_AUTH=none: anyone who can reach this port gets a shell"
    warn "and an R session as you. Only appropriate behind something else that"
    warn "authenticates."
fi

args=(
    --server-daemonize=0
    --server-user="${SERVER_USER}"
    # Loopback when the gate is in front. Binding 0.0.0.0 as well would leave an
    # unauthenticated door open on the same pod, on a port the OnDemand proxy
    # does not use but anything else in the cluster could.
    --www-address="${RSERVER_ADDRESS}"
    --www-port="${RSERVER_PORT}"
    --www-root-path="${BASE_URL}"
    # Both of these default to paths under /var, owned by rstudio-server and not
    # writable by the session's uid.
    --server-data-dir="${STATE_DIR}/server-data"
    --secure-cookie-key-file="${STATE_DIR}/secure-cookie-key"
    --rsession-which-r=/usr/local/bin/R
    --rsession-config-file="${SESSION_CONF}"
    # Not rsession itself: the wrapper puts back the environment rserver drops
    # when it builds the session's. See bin/cirrus-rsession.
    --rsession-path=/usr/local/bin/cirrus-rsession
)
[ "$USE_GATE" -eq 1 ] || args+=(--auth-none=1)

log "starting rserver: ${RSERVER_ADDRESS}:${RSERVER_PORT} root-path=${BASE_URL} user=${SERVER_USER} (uid ${UID_NOW}) workdir=${WORKDIR}"

# Not exec'd. This shell stays as PID 1 so it can supervise both processes, cull
# an idle session, and decide what exit status to report -- see below.
"$RSERVER" "${args[@]}" &
RSERVER_PID=$!
GATE_PID=""

if [ "$USE_GATE" -eq 1 ]; then
    # Started after rserver so that a connection accepted by the gate has
    # somewhere to go. It does not wait for rserver to be listening: the startup
    # probe hits the gate, and a gate that is up while rserver is still starting
    # answers with the login page, which is a correct answer.
    "$GATE" &
    GATE_PID=$!
    log "password gate on :${PORT}, rserver on 127.0.0.1:${UPSTREAM_PORT}"
fi

# --- idle culling ---------------------------------------------------------
#
# RStudio Server has no idle shutdown that ends the process: rsession suspends
# itself when nothing is connected, but rserver keeps running and the pod keeps
# its CPU and memory. So the supervision lives here.
#
# The signal is rsession's own state directory. rserver writes a per-session
# directory under its data dir while a client is connected and touches it as
# requests arrive; when the browser goes away the mtimes stop advancing. Falls
# back to this session's start time until one exists, so a session nobody ever
# opens is still reclaimed rather than living out its full 12 hours.
IDLE_TIMEOUT="${CIRRUS_RSTUDIO_IDLE_TIMEOUT:-3600}"
IDLE_CHECK="${CIRRUS_RSTUDIO_IDLE_CHECK:-300}"
CULLED="${STATE_DIR}/idle-culled"
rm -f "$CULLED"
STARTED="$(date +%s)"

newest_activity() {
    local newest
    # -printf over -exec stat: one process, and it copes with an empty tree.
    # `|| true` on the pipeline: find exits nonzero the moment a directory it is
    # walking disappears -- rsession deletes its own state on suspend -- and
    # under pipefail that would take the watchdog down with it.
    newest="$(find "${STATE_DIR}/server-data" "${RSTUDIO_DATA_HOME}" \
                   -mindepth 1 -printf '%T@\n' 2>/dev/null \
              | sort -n | tail -1 | cut -d. -f1 || true)"
    [ -n "$newest" ] || newest="$STARTED"
    printf '%s' "$newest"
}

if [ "$IDLE_TIMEOUT" -gt 0 ]; then
    (
        while sleep "$IDLE_CHECK"; do
            kill -0 "$RSERVER_PID" 2>/dev/null || exit 0
            IDLE=$(( $(date +%s) - $(newest_activity) ))
            if [ "$IDLE" -ge "$IDLE_TIMEOUT" ]; then
                warn "no activity for ${IDLE}s (limit ${IDLE_TIMEOUT}s)."
                warn "Ending this session so it stops holding its CPU and memory."
                warn "Relaunch from OnDemand when you need it; your files, your"
                warn "installed R packages and your RStudio settings are in ${PERSIST_DIR}."
                : > "$CULLED"
                kill -TERM "$RSERVER_PID" 2>/dev/null || true
                exit 0
            fi
        done
    ) &
fi

# Pod deletion sends SIGTERM to this shell, since this shell is PID 1. Forward
# it, so ending a session from the OnDemand dashboard shuts RStudio down instead
# of leaving it to be SIGKILLed when the grace period expires.
trap 'kill -TERM "$RSERVER_PID" ${GATE_PID:+"$GATE_PID"} 2>/dev/null || true; exit 0' TERM INT

# `wait -n` rather than `wait "$RSERVER_PID"`: with the gate running, rserver
# exiting is not the only way this session can end, and a gate that has died
# leaves a pod that is listening on nothing while still holding its resources.
# Whichever goes first ends the session.
RC=0
wait -n "$RSERVER_PID" ${GATE_PID:+"$GATE_PID"} || RC=$?
for pid in "$RSERVER_PID" ${GATE_PID:+"$GATE_PID"}; do
    kill -TERM "$pid" 2>/dev/null || true
done

# Exit 0 after a cull. restart_policy is OnFailure, so a nonzero exit restarts
# the container and the session comes straight back -- which for an idle cull
# would mean never releasing anything and the pod cycling forever. Exiting 0
# leaves the pod Completed. A genuine crash still exits nonzero and still gets
# its restart.
if [ -f "$CULLED" ]; then
    log "session ended by the idle timeout (exit 0 so the pod completes rather than restarting)"
    exit 0
fi
exit "$RC"
