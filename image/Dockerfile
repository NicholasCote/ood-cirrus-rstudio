# CIRRUS RStudio Server image
#
# rocker/rstudio plus our own entrypoint, so RStudio runs as the user's real
# NFS uid with no root at runtime. rocker's own start-up (/init, s6, and
# /etc/cont-init.d) needs root and would chown the GLADE home, so it is not
# used; bin/entrypoint.sh replaces it. Nothing in the image is chowned or
# written to at runtime: the session writes to /tmp and to ~/rstudio only.
#
# Running unprivileged, rserver does not authenticate anyone (it signs the
# caller in as itself), so bin/cirrus-rstudio-gate holds the public port and
# checks the per-session password in front of an rserver bound to loopback.
#
# Build: podman build -t localhost/cirrus-rstudio:dev -f image/Dockerfile image

# R 4.6.1 on Ubuntu 24.04. rocker republishes this tag as RStudio Server
# updates (2026.10.1+239 at the last build), so `rstudio-versions` in the
# image, not this line, records what a given build contains.
ARG RSTUDIO_BASE=docker.io/rocker/rstudio:4.6.1
FROM ${RSTUDIO_BASE}
ARG RSTUDIO_BASE

ENV CIRRUS_RSTUDIO_HOME=/opt/cirrus-rstudio

# Kept short on purpose: R packages are base rocker only, and users install
# their own into ~/rstudio/r-libs.
#
# libnss-wrapper   gives the runtime uid a passwd entry (rserver, git, ssh and
#                  the terminal prompt all need one)
# openssh-client   ssh/ssh-agent/ssh-add, for the Git pane and bao-getkey
# curl, jq         required by bao-getkey
# procps           pgrep, used by the idle watchdog
# less             R's help pager
RUN DEBIAN_FRONTEND=noninteractive apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get -y upgrade \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        jq \
        less \
        libnss-wrapper \
        openssh-client \
        procps \
    && rm -rf /var/lib/apt/lists/*

# Three files in /etc/rstudio block an arbitrary uid as shipped:
#   database.conf  mode 0600 owned by rstudio-server, sqlite under /var/lib
#   logging.conf   logs to syslog, which a container does not have
#   rserver.conf   settings that never vary per session
# rsession.conf is generated per session by the entrypoint instead (it holds
# the working directory from the launch form).
COPY --chmod=0644 etc/rstudio/database.conf /etc/rstudio/database.conf
COPY --chmod=0644 etc/rstudio/logging.conf  /etc/rstudio/logging.conf
COPY --chmod=0644 etc/rstudio/rserver.conf  /etc/rstudio/rserver.conf

# Our Rprofile.site sets the R library path (see the file for why it has to be
# done in R). rocker's own is kept and sourced from ours: it points
# install.packages() at Posit Package Manager's prebuilt binaries.
RUN mkdir -p "${CIRRUS_RSTUDIO_HOME}" \
    && mv /usr/local/lib/R/etc/Rprofile.site "${CIRRUS_RSTUDIO_HOME}/Rprofile.site.rocker" \
    && chmod 0444 "${CIRRUS_RSTUDIO_HOME}/Rprofile.site.rocker"
COPY --chmod=0444 etc/R/Rprofile.site /usr/local/lib/R/etc/Rprofile.site

COPY --chmod=0755 bin/entrypoint.sh       /usr/local/bin/entrypoint.sh
COPY --chmod=0755 bin/cirrus-rstudio-gate /usr/local/bin/cirrus-rstudio-gate
COPY --chmod=0755 bin/cirrus-rsession     /usr/local/bin/cirrus-rsession
COPY --chmod=0755 bin/cirrus-shell        /usr/local/bin/cirrus-shell
COPY --chmod=0755 bin/rstudio-versions    /usr/local/bin/rstudio-versions
COPY --chmod=0644 etc/profile.d/cirrus-rstudio.sh /etc/profile.d/cirrus-rstudio.sh

# --- bao-getkey -------------------------------------------------------------
# HSG's OpenBao client (NCAR/hsg-openbao-scripts, MIT). One password+Duo login
# mints a short-lived signed SSH certificate and loads it into ssh-agent, so
# ssh to Casper/Derecho stops prompting for ncar-two-factor.
#
# Vendored because the upstream repo is internal to the NCAR org and an
# unauthenticated build cannot fetch it. Verbatim copy of bin/bao-getkey at
# commit ef6b7a7503c911977865df50df3b4d4fc223c25b, sha256
# 9fee1714bd7b149dec56798304350642167cae3eb9236aecfbc44fd39dc7bf9e (CI checks
# it). The entrypoint starts the ssh-agent it loads into.
COPY bao-getkey /usr/local/bin/bao-getkey
RUN chmod 0755 /usr/local/bin/bao-getkey

# Versions recorded at build time for `rstudio-versions`, and the nss_wrapper
# library path resolved once here rather than in every session.
RUN set -eu; \
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

# Defaults for running the image standalone; submit.yml.erb sets these in OOD.
ENV CIRRUS_RSTUDIO_PORT=8080 \
    CIRRUS_RSTUDIO_STATE_DIR=/tmp/cirrus-rstudio \
    CIRRUS_RSTUDIO_AUTH=password

EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["rserver"]
