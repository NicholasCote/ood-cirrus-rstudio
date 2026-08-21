# CIRRUS RStudio Server image
#
# One Open OnDemand Batch Connect app: RStudio Server on the CIRRUS mlc1
# Kubernetes cluster, with the user's GLADE home mounted.
#
# ---------------------------------------------------------------------------
# Approach: (b). Build on rocker, add our own entrypoint that does the
# arbitrary-uid work, and never chown anything.
#
# rocker's own start-up path is unusable here and this was established by
# reading the scripts in the image, not from documentation:
#
#   /init                     an execlineb script that runs s6 init-stage1. s6
#                             stage1 wants to be root; it is what runs
#                             /etc/cont-init.d and then supervises
#                             /etc/services.d/rstudio.
#   /etc/cont-init.d/01_set_env
#                             rewrites ${R_HOME}/etc/Renviron.site in place and
#                             chmod 600s /var/run/s6/container_environment/*.
#                             Root-only, and it writes into the image.
#   /etc/cont-init.d/02_userconf
#                             the USERID/GROUPID/PASSWORD path. It runs
#                             userdel, useradd, usermod, groupmod, chpasswd,
#                             adduser and `chown -R` on the home directory. All
#                             of it root-only, and the chown -R would be pointed
#                             at a GLADE home over NFS.
#   /etc/services.d/rstudio/run
#                             the only thing here we actually want:
#                             `exec /usr/lib/rstudio-server/bin/rserver
#                              --server-daemonize 0`.
#
# So the entrypoint below replaces stage1 and cont-init.d, and ends with that
# same rserver exec plus the flags an unprivileged, arbitrary-uid, proxied
# session needs. Nothing in this image is chowned, and nothing is written to at
# runtime: everything the session writes goes to /tmp or to a named directory in
# the user's home.
#
# Verified against the installed rserver (2026.08.1+195), not from memory:
#
#   * `--server-user` is mandatory. Left at its default of `rstudio-server`,
#     rserver refuses to start as an arbitrary uid:
#       ERROR Attempt to run server as user 'rstudio-server' (uid 997) from
#       account '54321' (uid 54321) without privilege
#     It takes a name and resolves it with getpwnam, so it has to be the name
#     nss_wrapper hands out -- passing the uid instead fails with "Could not
#     find details for server user '54321'", because setting up nss_wrapper is
#     what removes the runtime's numeric-named entry in the first place.
#   * `--www-root-path` exists and takes the proxy prefix, which is what makes
#     OnDemand's /node/ proxy (which forwards the whole path) the right one.
#   * Unprivileged, rserver cannot read the system secure key and falls back to
#     $HOME/.cache/rstudio/session-rpc-key -- a write into the shared GLADE
#     home. XDG_CACHE_HOME in the entrypoint moves it to /tmp.
#   * Unprivileged, rserver does not authenticate at all: it signs the caller in
#     as the server user on request, never serving a login form and never
#     running the helper at --auth-pam-helper-path. So the per-session password
#     is enforced by cirrus-rstudio-gate, which holds the public port and
#     forwards to an rserver bound to loopback. It is pure-stdlib Python against
#     the python3 the base image already ships -- adding a web framework to an R
#     image to guard one password would be a poor trade, and each dependency is
#     another thing for Harbor to scan.
# ---------------------------------------------------------------------------

# Pinned, never floating. Bump deliberately and re-test; the tag published by CI
# is a date stamp, and submit.yml.erb pins one of those.
#   rocker/rstudio:4.6.1 at time of pinning:
#     R 4.6.1, RStudio Server 2026.08.1+195, Ubuntu 24.04 noble
ARG RSTUDIO_BASE=docker.io/rocker/rstudio:4.6.1
FROM ${RSTUDIO_BASE}

# Re-declared: an ARG before the first FROM is out of scope after it.
ARG RSTUDIO_BASE

ENV CIRRUS_RSTUDIO_HOME=/opt/cirrus-rstudio

# ---------------------------------------------------------------------------
# Packages.
#
# Deliberately short. The R package set is base rocker: R 4.6.1 plus the
# recommended packages and nothing else. No tidyverse, no Bioconductor, no
# geospatial stack -- compiling those dominates build time and image size, and
# the answer to "which ones" was "none". Users install their own into
# R_LIBS_USER, which the entrypoint points at a directory outside anything
# Casper or Derecho reads.
#
# libnss-wrapper  the arbitrary-uid case: the runtime uid has no passwd entry,
#                 and rserver's --auth-validate-users, RStudio's own home
#                 lookup, git and the terminal prompt all call getpwuid().
# curl            the startup probe and the websocket check in the README, and
#                 the entrypoint's own readiness wait. Not in the base image.
# procps          pgrep/pkill for the idle watchdog. Not in the base image.
# less            R's help pager. Without it `?lm` prints an error.
# ---------------------------------------------------------------------------
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        less \
        libnss-wrapper \
        procps \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# /etc/rstudio, fixed at build time rather than redirected at runtime.
#
# RSTUDIO_CONFIG_DIR would move the whole directory, and that directory also
# holds themes/ and fonts/ which we do want. Three files are edited instead, and
# each is a real blocker for an arbitrary uid:
#
#   database.conf   ships mode 0600 owned by rstudio-server, so our uid cannot
#                   read it at all, and its default sqlite directory
#                   (/var/lib/rstudio-server) is not writable either.
#   logging.conf    ships logger-type=syslog. There is no syslog in a container,
#                   so every message -- including the fatal server-user error
#                   above -- is discarded and the pod log is empty. That is
#                   exactly the failure that looks like "the image is broken".
#   rserver.conf    the settings that never vary per session. The ones that do
#                   (port, root path, server user) are flags in the entrypoint.
# ---------------------------------------------------------------------------
COPY --chmod=0644 etc/rstudio/database.conf /etc/rstudio/database.conf
COPY --chmod=0644 etc/rstudio/logging.conf  /etc/rstudio/logging.conf
COPY --chmod=0644 etc/rstudio/rserver.conf  /etc/rstudio/rserver.conf

# rsession.conf is NOT copied: the working directory in it is a launch-form
# value, so the entrypoint generates the file and passes it with
# --rsession-config-file.
#
# /etc/rstudio/env-vars is deliberately NOT used. It looks like the answer to
# rserver dropping the session environment, and it is not: rserver reads it and
# applies it to ITSELF ("Setting server environment variable ..."), while the R
# session still comes up without any of it. What does work is
# --rsession-path pointing at bin/cirrus-rsession, which puts the values back
# one exec before the session starts.
# ---------------------------------------------------------------------------
# The R site profile.
#
# The environment is not enough to set the library path, for two separate
# reasons, so it is set in R itself:
#
#   * rserver builds a filtered environment for each R session -- R_LIBS,
#     R_LIBS_USER, R_ENVIRON_USER, XDG_CACHE_HOME and LD_PRELOAD are all dropped
#     from it (bin/cirrus-rsession puts back the ones that are not about R);
#   * a user's ~/.Renviron overrides the environment anyway, and on this platform
#     it usually names a Casper or Derecho library.
#
# Rprofile.site is the one start-up file that runs after ~/.Renviron, so setting
# .libPaths() there beats both.
#
# The base image's own Rprofile.site is kept and sourced from ours rather than
# replaced: it selects the Posit Package Manager binary repository for noble,
# which is the difference between install.packages() taking seconds and taking
# minutes.
# ---------------------------------------------------------------------------
RUN mkdir -p "${CIRRUS_RSTUDIO_HOME}" \
    && mv /usr/local/lib/R/etc/Rprofile.site "${CIRRUS_RSTUDIO_HOME}/Rprofile.site.rocker" \
    && chmod 0444 "${CIRRUS_RSTUDIO_HOME}/Rprofile.site.rocker"
COPY --chmod=0444 etc/R/Rprofile.site /usr/local/lib/R/etc/Rprofile.site

# ---------------------------------------------------------------------------
# Our scripts. /usr/local/bin is on PATH for both the entrypoint and every
# terminal RStudio spawns.
# ---------------------------------------------------------------------------
COPY --chmod=0755 bin/entrypoint.sh      /usr/local/bin/entrypoint.sh
COPY --chmod=0755 bin/cirrus-rstudio-gate /usr/local/bin/cirrus-rstudio-gate
COPY --chmod=0755 bin/cirrus-rsession     /usr/local/bin/cirrus-rsession
COPY --chmod=0755 bin/cirrus-shell        /usr/local/bin/cirrus-shell
COPY --chmod=0755 bin/rstudio-versions   /usr/local/bin/rstudio-versions

# Read by RStudio's Terminal tab, which is a login shell (`bash --login
# --posix`). Fixes the prompt, which POSIX-mode bash renders from the uid.
COPY --chmod=0644 etc/profile.d/cirrus-rstudio.sh /etc/profile.d/cirrus-rstudio.sh

# ---------------------------------------------------------------------------
# Resolved versions, recorded once at build time so a bug report can name them.
# `rstudio-versions` prints this file; `rstudio-versions --check` re-runs each
# binary and diffs against it.
#
# The nss_wrapper library path is resolved here too. Finding it at runtime would
# mean running ldconfig in every session, and a miss would be discovered at the
# worst possible moment -- after the session has already started, as an
# unexplained numeric prompt.
# ---------------------------------------------------------------------------
RUN set -eu; \
    mkdir -p "${CIRRUS_RSTUDIO_HOME}"; \
    { \
      echo "# CIRRUS RStudio image -- resolved versions"; \
      echo "# name<TAB>expected version"; \
      printf 'base-image\t%s\n'      "${RSTUDIO_BASE}"; \
      printf 'R\t%s\n'               "$(R --version | head -1 | awk '{print $3}')"; \
      printf 'rstudio-server\t%s\n'  "${RSTUDIO_VERSION}"; \
      printf 'ubuntu\t%s\n'          "$(. /etc/os-release; echo "${VERSION_ID}")"; \
      printf 'pandoc\t%s\n'          "$(/usr/lib/rstudio-server/bin/quarto/bin/tools/*/pandoc --version 2>/dev/null | head -1 | awk '{print $2}' || echo unknown)"; \
    } > "${CIRRUS_RSTUDIO_HOME}/versions.txt"; \
    lib="$(ldconfig -p | awk -F'=> ' '/libnss_wrapper/ {print $2; exit}' | tr -d ' ')"; \
    if [ -z "$lib" ] || [ ! -r "$lib" ]; then \
        lib="$(find /usr/lib /lib -name 'libnss_wrapper.so*' -print -quit 2>/dev/null)"; \
    fi; \
    test -n "$lib" && test -r "$lib"; \
    echo "$lib" > "${CIRRUS_RSTUDIO_HOME}/nss_wrapper_lib"; \
    chmod -R a+rX "${CIRRUS_RSTUDIO_HOME}"

# ---------------------------------------------------------------------------
# Runtime defaults.
#
# These exist so the image runs standalone for local testing; in the OOD path
# submit.yml.erb sets them. CIRRUS_RSTUDIO_BASE_URL is deliberately NOT given a
# default: "/" from an operator and "/" because nothing was computed are
# different things, and conflating them is how a session ends up serving at the
# root behind a /node/ proxy, which renders as a blank page with no error.
# ---------------------------------------------------------------------------
ENV CIRRUS_RSTUDIO_PORT=8080 \
    CIRRUS_RSTUDIO_STATE_DIR=/tmp/cirrus-rstudio \
    CIRRUS_RSTUDIO_AUTH=password

# Matches the fixed containerPort/NodePort of the other CIRRUS OOD apps. Not
# rocker's 8787.
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["rserver"]
