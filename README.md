# RStudio Server on CIRRUS (Open OnDemand)

An Open OnDemand Batch Connect app that launches [RStudio Server] on the CIRRUS
`mlc1` Kubernetes cluster, in an image built on `rocker/rstudio:4.6.1`, with the
user's GLADE home mounted.

The repository root **is** the OOD app root. `image/` holds the container we
build and OOD ignores it.

```
manifest.yml  form.yml  submit.yml.erb  view.html.erb  info.md.erb
template/.keep            # required; the built-in "basic" template is used
icon.png                  # 490x490, square
image/Dockerfile          # the image; built and pushed by CI
image/bin/                # entrypoint, password gate, rsession wrapper, shell
image/etc/                # rserver config, R site profile, profile.d
image/test/acceptance.sh  # the checks below, runnable with podman
.github/workflows/build.yml
```

`manifest.yml` has to be at the root. One directory down, OOD reports
"Manifest is missing, add a title and description", which reads like a broken
manifest rather than a misplaced one.

[RStudio Server]: https://posit.co/products/open-source/rstudio-server/

## The image: approach (b)

We build on rocker and add our own entrypoint that does the arbitrary-uid work
and never chowns anything. rocker's own start-up path is unusable here, and that
was established by reading the scripts in the image:

| in the image | what it does | why it cannot be used |
| --- | --- | --- |
| `/init` | execline script, runs s6 `init-stage1` | s6 stage 1 wants to be root |
| `/etc/cont-init.d/01_set_env` | rewrites `${R_HOME}/etc/Renviron.site` in place, `chmod 600`s s6 state | root-only, and writes into the image |
| `/etc/cont-init.d/02_userconf` | the `USERID`/`GROUPID`/`PASSWORD` path: `userdel`, `useradd`, `usermod`, `groupmod`, `chpasswd`, `adduser`, `chown -R` on the home | all root-only, and the `chown -R` would be aimed at a GLADE home over NFS |
| `/etc/services.d/rstudio/run` | `exec rserver --server-daemonize 0` | the one part we keep |

So `/usr/local/bin/entrypoint.sh` replaces stage 1 and `cont-init.d`, and ends
with that same `rserver` exec plus the flags an unprivileged, arbitrary-uid,
proxied session needs.

### What running unprivileged actually requires

Every item here was verified against the installed rserver (2026.08.1+195), not
taken from documentation:

- **`--server-user` is mandatory, and it takes a name.** Left at its default
  rserver exits before binding anything:
  `Attempt to run server as user 'rstudio-server' (uid 997) from account '54321'
  (uid 54321) without privilege`. It resolves the value with `getpwnam`, so the
  uid only works by accident — when the runtime has synthesised an entry whose
  name is the uid, which setting up nss_wrapper deliberately removes:
  `Could not find details for server user '54321'`.
- **`/etc/rstudio/logging.conf` ships `logger-type=syslog`.** There is no syslog
  in a container, so the error above lands nowhere and the pod looks like it
  exited for no reason. The image ships `logger-type=stderr`.
- **`/etc/rstudio/database.conf` ships mode 0600 owned by `rstudio-server`,**
  unreadable by the session's uid, with a sqlite directory under `/var/lib`
  it cannot write either. The image ships a readable one pointing at `/tmp`.
- **`--server-data-dir` and `--secure-cookie-key-file`** default under `/var` and
  are moved to `/tmp`.
- **Unprivileged, rserver cannot read the system secure key** and falls back to
  `$HOME/.cache/rstudio/session-rpc-key` — a write into the shared GLADE home on
  every launch. `XDG_CACHE_HOME` moves it.

### RStudio does not authenticate when it is not root

This is the finding that shaped the app. With a PAM helper configured at
`--auth-pam-helper-path` and every auth option left at its default:

```
$ curl -c jar '.../auth-sign-in?appUri=%2F'
HTTP/1.1 302 Moved Temporarily
Set-Cookie: user-id=ncote|...
```

No password was sent, no login form was served, and the helper never ran — there
is no line from it anywhere in the log. Running without privilege rserver cannot
become any user other than the one it already is, so there is nothing for it to
check. Requesting the sign-in page *is* the sign-in.

The per-session password is therefore enforced by
`/usr/local/bin/cirrus-rstudio-gate`, which holds the pod's port and forwards to
an rserver bound to loopback. It is pure-stdlib Python against the `python3` the
base image already ships. It checks the password once per connection and then
relays bytes, which is what keeps websockets working: an upgraded connection is
no longer HTTP to parse, and a browser sends its cookies on the handshake like
any other request.

If you would rather not have the gate, set `CIRRUS_RSTUDIO_AUTH=none` in
`submit.yml.erb`. That is the honest spelling of what an unguarded rserver does
anyway, and the entrypoint says so in the log.

## The proxy: `/rnode/`, not `/node/`

`--www-root-path` looks like it makes OnDemand's `/node/` proxy work. It does
not: it tells rserver what prefix to **emit** in its own redirects and cookies,
not what prefix to expect on the way in. With
`--www-root-path=/node/fakenode/30123/` set:

```
GET /node/fakenode/30123/   ->  404 Not Found
GET /                       ->  302, Location: .../node/fakenode/30123/auth-sign-in
                                Set-Cookie: user-id=...; path=/node/fakenode/30123
```

So rserver serves at the root and puts the prefix back into everything it
generates — which is exactly the `/rnode/` contract, since `/rnode/` strips its
prefix before forwarding. `view.html.erb` posts to `/rnode/HOST/PORT/`.

The prefix is still needed, or every RStudio redirect and cookie would drop it
and the browser would leave the session. It is `/rnode/<nodeName>/<nodePort>/`,
and neither part exists until the pod is scheduled and its service assigned a
NodePort — so it cannot come from the pod spec. The `add-baseurl-to-cfg` init
container computes it and writes it into the ConfigMap; the entrypoint reads it
and passes it to `--www-root-path`, and the gate uses it for the login form's
action and the cookie's `Path`.

## Keeping out of the shared home

`$HOME` is GLADE, shared with Casper and Derecho. The session writes to exactly
one directory there, `$HOME/rstudio/`:

| | |
| --- | --- |
| `$HOME/rstudio/r-libs/<R minor>/` | `R_LIBS_USER` — packages you install |
| `$HOME/rstudio/config/` | `RSTUDIO_CONFIG_HOME` — editor preferences |
| `$HOME/rstudio/data/` | `RSTUDIO_DATA_HOME` — pane layout, console history |
| `/tmp/cirrus-rstudio/` | everything else: caches, XDG, sqlite, secure cookie key, session state |

**The R library is the one that matters.** `R_LIBS_USER` defaults to
`$HOME/R/x86_64-pc-linux-gnu-library/4.6`, which is where the user's Casper and
Derecho R sessions look. A package compiled in this image and installed there is
loaded by HPC R against a different glibc and a different BLAS, and it fails days
later, somewhere else.

Setting the environment variable is not enough, for two independent reasons,
both verified:

1. **A user's `~/.Renviron` overrides the environment.** With
   `R_LIBS_USER=/tmp/rlib` in the environment and
   `R_LIBS_USER=/glade/u/home/ncote/R/casper/4.4` in `~/.Renviron`, R reports the
   Casper path. Anyone who has configured R on this platform has such a line.
2. **rserver does not give the R session its environment.** It builds a filtered
   one. Reading a live session:

   ```
   $ tr '\0' '\n' < /proc/$(pgrep -x rsession)/environ
   HOME=/home/ncote
   RSTUDIO_CONFIG_HOME=...  RSTUDIO_DATA_HOME=...     <- survive
   XDG_CONFIG_HOME=... XDG_DATA_HOME=... XDG_STATE_HOME=...   <- survive
   (no R_LIBS_USER, no R_LIBS, no R_ENVIRON_USER, no XDG_CACHE_HOME,
    no TMPDIR, no LD_PRELOAD, no NSS_WRAPPER_*)
   ```

   `/etc/rstudio/env-vars` is not the fix either, though it reads like one:
   rserver logs `Setting server environment variable ...` and applies it to
   itself, and the session still comes up without any of it.

So two mechanisms, for two halves of the problem:

- `/usr/local/lib/R/etc/Rprofile.site` sources a session profile that calls
  `.libPaths()` with the user library **first**. It is the one start-up file that
  runs after `~/.Renviron`, so it wins. First and not appended, because
  `install.packages()` writes to `.libPaths()[1]` — left second, R would find the
  root-owned site library unwritable and interactively offer to create a personal
  one at `$HOME/R/...`, putting the user straight back into the shared path.
  rocker's own `Rprofile.site` is kept and sourced from ours, so the Posit
  Package Manager binary repository still applies.
- `bin/cirrus-rsession`, named to rserver with `--rsession-path`, puts back
  `LD_PRELOAD`, `NSS_WRAPPER_*`, `XDG_CACHE_HOME`, `TMPDIR` and `R_ENVIRON_USER`
  one exec before the session starts — and therefore in front of every terminal.

The user's own `~/.Renviron` settings are preserved: the session's
`R_ENVIRON_USER` file is a copy of theirs with `R_LIBS*` lines filtered out. Their
`~/.Rprofile` still runs, after ours, and can still change `.libPaths()` — that is
their code, run deliberately, and this image does not fight it.

`$HOME/rstudio/` is never derived from the working directory on the form. Those
are two different concepts, and deriving one from the other means a user who sets
their working directory to their home turns every one of these paths into a
shared dotfile. The entrypoint also refuses a persist directory that is `$HOME`
itself, any dotfile directly in `$HOME`, or `$HOME/R`, whoever set it.

## The runtime uid has no name

The pod runs as the user's real NFS uid, which has no `/etc/passwd` entry — and a
container runtime may synthesise a useless one whose **name is the uid**:

```
$ podman run --user 54321:54321 --entrypoint getent <image> passwd 54321
54321:*:54321:54321:container user:/:/bin/sh
```

So "does an entry exist" is the wrong test; an all-digits name is treated as no
name. The entrypoint writes a passwd/group pair under `/tmp` and `LD_PRELOAD`s
`libnss-wrapper`, taking the user name from `$USER`/`$NB_USER` and the group name
from `$GROUP` (OOD sets all three), with `/bin/bash` as the shell — RStudio reads
the login shell from the passwd entry. Existing entries for the uid are
**filtered out** rather than appended after: nss_wrapper returns the first match.

## The terminal

RStudio runs its POSIX terminal shell with `--posix` appended, even for a shell
configured as "custom". In POSIX mode bash expands `\u` from the uid rather than
from the passwd entry:

```
$ bash         -c 'PS1="\u"; printf %s "${PS1@P}"'   ->  ncote
$ bash --posix -c 'PS1="\u"; printf %s "${PS1@P}"'   ->  54321
```

with nss_wrapper active and `whoami` answering `ncote` in both. Every terminal
would open with a prompt showing a bare uid — a session that reads as broken
while working fine. The entrypoint seeds `posix_terminal_shell: custom` pointing
at `/usr/local/bin/cirrus-shell`, a one-line wrapper that drops the flag and
execs `bash -l`. Only keys the user has not already set are seeded, and only in
this app's own config directory.

The image ships exactly one shell for RStudio's terminal, which is why the form
has no shell field:

```
$ curl .../rpc/get_terminal_shells
{"result":[{"type":"bash","name":"Bash"},{"type":"custom","name":"Custom"}]}
```

## Idle culling and session length

RStudio has no idle shutdown that ends the process: rsession suspends itself when
nothing is connected, but rserver keeps running and the pod keeps its CPU and
memory. The entrypoint supervises instead, watching mtimes under rserver's data
directory and RStudio's session state. Measured on this image, that signal does
not advance at all across a quiet minute and advances on every use.

Default: 1 hour idle, checked every 5 minutes; 12 hours maximum. A culled session
exits 0 so the pod completes — `restart_policy: OnFailure` would otherwise bring
it straight back and never release anything. The 12-hour ceiling becomes a
`pod.kubernetes.io/lifetime` annotation, which means something only because
OSC's `job-pod-reaper` is deployed on this cluster.

## Verifying it

```
podman build -t localhost/cirrus-rstudio:dev -f image/Dockerfile image
image/test/acceptance.sh
```

Last run, 22 checks, all passing:

```
== 1. arbitrary uid, runtime-synthesised numeric passwd entry ==
  ok   the runtime does synthesise a numeric entry: 54321:*:54321:54321:container user:/:/bin/sh
  ok   id -un is ncote, not 54321
  ok   id -gn is ncar, not the image's own group
== 2. arbitrary uid with NO passwd entry at all ==
  ok   id -un is ncote with no entry to start from
== 3. the session starts and the gate holds the port ==
  ok   port answered 0s after container start (startup probe budget is 305s)
  ok   no cookie: login page, form posting to /rnode/fakenode/30123/cirrus-signin
  ok   wrong password refused (401)
  ok   correct password accepted, cookie issued
  ok   rserver answers behind the gate and emits the /rnode/fakenode/30123 prefix in its redirects
  ok   the IDE page loads through the gate (200)
  ok   client_init succeeded; an R session is running
  ok   client_init reports r_libs_user=/home/ncote/rstudio/r-libs/4.6
== 4. websocket upgrade through the gate, foreign Origin ==
  ok   no cookie: refused, no upgrade (HTTP/1.1 200 OK)
  ok   with the session cookie: HTTP/1.1 101 Switching Protocols, valid Sec-WebSocket-Accept=True
  ok   data frame relayed through the gate: b'echo-through-gate'
== 5. what the R session actually sees ==
  ok   rsession has LD_PRELOAD (terminal identity works)
  ok   install target is /home/ncote/rstudio/r-libs/4.6
  ok   no HPC library path in .libPaths()
  ok   the user own ~/.Renviron settings survive
== 6. the home directory afterwards ==
  ok   the session created $HOME/rstudio and nothing else new
  ok   no $HOME/.cache / .local / .rstudio / .config/rstudio/rstudio-desktop
  ok   every pre-existing file is byte-identical (md5)
== 7. idle watchdog ==
  ok   an idle session ends itself and exits 0 (so OnFailure does not restart it)
```

And separately, a full session driven over RStudio's own RPC — install two
packages, open a terminal, run commands in it:

```
pkg:  /home/ncote/rstudio/r-libs/4.6/praise
term: ncote@2f661f3b28d8:~/projects$ whoami; pwd; touch ~/projects/from-terminal.txt
      ncote
      /home/ncote/projects

$HOME afterwards:  .Renviron  .Rprofile  .config/  R/  projects/  rstudio/
pre-existing files: all md5-identical
$HOME/R/x86_64-pc-linux-gnu-library/4.6/: MARKER   (nothing installed there)
```

### What the websocket check does and does not cover

The 101 above is a real handshake with a foreign `Origin`, driven through the
real gate binary in this image — but against a controlled echo upstream, not
against rserver. RStudio negotiates its own transport from JavaScript after an
in-browser handshake, and `/events/get_events` answers a plain 200 to a
hand-built request, so probing rserver directly proves nothing either way. What
the check does establish is the only new risk this app introduces: that the gate
relays an upgrade rather than eating it, in both directions, and refuses one
without the session cookie. RStudio's console and terminal are covered
functionally instead — R executed in the console and a real bash terminal driven
to completion, both through the proxy chain.

### Versions

```
$ podman run --rm <image> bootstrap rstudio-versions
base-image      docker.io/rocker/rstudio:4.6.1
R               4.6.1
rstudio-server  2026.08.1+195
ubuntu          24.04
pandoc          3.8.3
```

`rstudio-versions --check` re-runs each component and diffs against the record.

## R packages

Base rocker only: R 4.6.1 plus the recommended packages. No tidyverse, no
Bioconductor, no geospatial stack — compiling those dominates build time and
image size. Users install their own, and `install.packages()` pulls prebuilt
binaries from the Posit Package Manager repository rocker configures, so it takes
seconds rather than minutes. Packages land in `~/rstudio/r-libs/` and persist
between sessions.

To add packages to the image, add a `RUN Rscript -e 'install.packages(...)'` to
`image/Dockerfile` and re-record versions.

## CI

`ubuntu-latest`, no remote buildkitd, no scan job — Harbor runs Trivy itself.
Triggers on `workflow_dispatch` and on pushes to `main` touching `image/**` or
the workflow. Tags are date stamps, `%Y-%m-%d.%H.%M`, pushed to
`hub.k8s.ucar.edu/ncote/rstudio-server`.

**`submit.yml.erb` pins one of those tags and must be updated by hand** to a tag
that has been tested. The value there now is a placeholder written before the
first CI run; set it to the tag CI publishes and re-test before announcing the
app. Never point it at something floating.

Harbor's Trivy scan cannot be run from here, so "no Criticals" is unverified —
check it after the first push. The image does `apt-get upgrade` at build time,
and adds only `ca-certificates`, `curl`, `less`, `libnss-wrapper` and `procps` on
top of the base.
