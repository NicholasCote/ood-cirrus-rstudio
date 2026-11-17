# RStudio Server (CIRRUS)

An Open OnDemand app that starts [RStudio Server] in a container on the
**Cirrus** Kubernetes cluster. Your GLADE storage is mounted, so you see the
same files as on a login node:

- your home directory
- `/glade/work`
- `/glade/campaign` (read-only)
- `/glade/collections` and `/gdex`

The image is R 4.6 with the base set of R packages; you install the rest
yourself, and they persist between sessions.

[RStudio Server]: https://posit.co/products/open-source/rstudio-server/

## Launching

- **Working directory**: where the Files pane and the console start. Leave it
  blank for your home directory.
- **CPUs**: 1 to 8.
- **Memory**: 1 to 32 GB.

Click **Connect to RStudio Server** on the session card. Each session has its
own password, and the button signs you in with it.

## Where your work is kept

Each launch is a fresh container. Anything you save under your home directory
or on GLADE stays; anything saved elsewhere (such as `/tmp`) is gone when the
session ends.

RStudio keeps its own things in one folder, `~/rstudio/`:

| | |
| --- | --- |
| `~/rstudio/r-libs/` | R packages you install |
| `~/rstudio/config/` | your RStudio preferences |
| `~/rstudio/data/` | pane layout and console history |

This is deliberately separate from the R setup you use on Casper and Derecho:
packages built in this container do not load there, and the other way round.
Your `~/.Renviron` is still read, except for any `R_LIBS` lines in it.

## Installing R packages

`install.packages("dplyr")` works as usual. It downloads prebuilt Linux
binaries from Posit Package Manager, so most packages install in seconds.
Packages that need system libraries the image does not have will fail to
build; ask for those to be added to the image.

## SSH to Casper and Derecho without the two-factor prompt

Run `bao-getkey` once in the **Terminal** tab. It asks for your password and a
Duo approval, then loads a short-lived SSH certificate into this session's
ssh-agent:

```bash
bao-getkey
ssh derecho.hpc.ucar.edu      # no ncar-two-factor prompt
```

The certificate is used by every terminal in the session and by the **Git**
pane (push and pull over ssh). When ssh starts prompting again, the
certificate has expired; run `bao-getkey` again. The key is kept only in the
session's memory and is never written to `~/.ssh`.

The first ssh to a host asks you to confirm its host key, as usual.

## When a session ends

- **After 1 hour with no activity.** Activity means typing in the console,
  R code still running, typing in or getting output from a terminal, or a
  background job or other process still working. An open browser tab on its
  own doesn't count, and neither does just looking at files.
- **After 12 hours**, whatever it is doing.

An ended session shows as **Completed** on the dashboard. Launch a new one
whenever you like; your files, packages and settings are where you left them.

## Troubleshooting

**`bao-getkey` says "error in libcrypto".** Your account does not have the
OpenBao `ssh-client-signer` policy yet, so no certificate was issued. This is
not a bug in the app; ask for the policy to be added to your account.

**`bao-getkey` worked, but the next terminal still prompts.** Your
`~/.bashrc` or `~/.bash_profile` probably starts its own `ssh-agent`, which
replaces the session's agent in each new terminal. Start an agent there only
when `SSH_AUTH_SOCK` is not already set.

**The page asks for a "Session password".** You opened the session's address
directly. Go back to the dashboard and click **Connect to RStudio Server**.

**My session disappeared.** It was most likely ended after an hour without
activity, or at 12 hours. The pod log records which, for the admins.

**A package from my Casper library is missing.** That library is not used
here (see above). Install the package again in RStudio.

---

## For administrators

### Files

| File | Purpose |
| --- | --- |
| `manifest.yml` | App name and description shown in OnDemand |
| `form.yml` | Launch form |
| `submit.yml.erb` | Pod spec: image, limits, mounts, init containers, input validation |
| `view.html.erb` | Connect button; posts the session password to the gate |
| `info.md.erb` | Session card text |
| `template/` | Required by `batch_connect`; the built-in `basic` template is used |
| `image/` | The container image (OnDemand ignores this directory) |
| `image/bin/entrypoint.sh` | Session setup and supervision; replaces rocker's `/init` |
| `image/bin/cirrus-rstudio-gate` | Per-session password gate in front of rserver |
| `image/bin/cirrus-rsession` | Restores the environment rserver strips from the R session |
| `image/bao-getkey` | Vendored OpenBao SSH-certificate client |
| `image/test/acceptance.sh` | Local acceptance tests (podman) |
| `.github/workflows/build.yml` | Builds, smoke-tests and pushes the image |

### How it works

**The pod runs as the user's real uid, never root.** rocker's own start-up
(`/init`, s6, `cont-init.d`) needs root and would `chown -R` the GLADE home, so
`entrypoint.sh` replaces it. The uid has no `/etc/passwd` entry in the image,
so the entrypoint supplies one through `nss_wrapper`, with the user's name,
group and full name (git's default author name).

**rserver cannot authenticate when it isn't root.** Running unprivileged, it
signs anyone in as itself on request. So rserver listens on loopback and
`cirrus-rstudio-gate` holds the public port: it checks the per-session
password once per connection, sets a cookie, and then relays bytes, which keeps
RStudio's websockets working. The password comes from the usual
`ood-k8s-utils` init containers; OnDemand reads the same Secret for the
Connect button.

**The app uses OnDemand's `/rnode/` proxy.** It strips the
`/rnode/<node>/<port>` prefix on the way in and adds it back to every
`Location` header and cookie path on the way out, so rserver runs with no
`--www-root-path` (setting one doubles the prefix). Only the gate's login form
needs the prefix, because response bodies are not rewritten; an init container
computes it once the pod has a node and NodePort.

**The entrypoint waits for both the password and the prefix** (up to 2
minutes) before starting anything, and exits with an error naming the init
container to check if either never arrives. The startup probe allows 5
minutes.

**The user's GLADE home is kept clean.** Caches and per-session state go to
container-local `/tmp`; RStudio's config, data and the R library go under
`~/rstudio/`. The R library needs two mechanisms: rserver strips `R_LIBS*`
from the R session's environment, and a user's `~/.Renviron` overrides the
environment anyway. So `Rprofile.site` sets `.libPaths()` (it runs after
`~/.Renviron`), and the session reads a copy of `~/.Renviron` without its
`R_LIBS` lines. `.RData` is never saved into the working directory.

**rserver strips the R session's environment.** `LD_PRELOAD`,
`NSS_WRAPPER_*`, `SSH_AUTH_SOCK`, `TMPDIR` and a few others don't reach
rsession. `cirrus-rsession` (rserver's `--rsession-path`) reads them back from
a file the entrypoint writes, so the console, every terminal and the Git pane
get them. `/etc/profile.d/cirrus-rstudio.sh` also sets `SSH_AUTH_SOCK` for a
login shell that lost it.

**One ssh-agent per session** is started before rserver, with its socket in
container-local `/tmp`, so it ends with the pod and is never shared. `ssh-add
-l` in the Terminal and `Sys.getenv("SSH_AUTH_SOCK")` in the console both see
it.

### How sessions end

RStudio has no idle shutdown that releases the pod (rsession suspends, rserver
keeps running), so the entrypoint stays PID 1 and supervises. Every 5 minutes
it records activity if any of these happened since the last check:

| Signal | What it catches |
| --- | --- |
| RStudio's `history_database` changed | console input, which RStudio records at once |
| a session's `properites/executing` flag is `1` | R still running code, even code that uses no CPU (`Sys.sleep`, a download) |
| I/O or CPU of any process rsession started | terminal typing and output, commands, background jobs, R subprocesses |
| pod CPU (from the cgroup) beyond 1 s, excluding rserver, the gate and rsession | processes that start and finish between checks |

An open RStudio tab keeps rserver, the gate and rsession polling (rsession
alone uses about 1 s of CPU per 5 minutes with a tab open and nothing
happening), which is why their CPU is not counted and why the activity signals
come from RStudio's own records instead. Measured with a real browser on this
image: an idle open tab writes nothing to RStudio's state and leaves every
signal above unchanged.

After `idle_timeout` (1 hour) without activity, or `max_session_hours` (12)
in any case, the entrypoint logs why, stops rserver and exits 0, so the pod
is Completed rather than Failed and `restart_policy: OnFailure` does not bring
it back. Ending the session from the dashboard sends SIGTERM, which is handled
the same way. A crash still exits nonzero and is restarted. The values are in
`submit.yml.erb`; `CIRRUS_RSTUDIO_BUSY_CPU_MS` overrides the CPU threshold.

`pod.kubernetes.io/lifetime` is also set from the 12 hours, but nothing on
Cirrus acts on it; the entrypoint's limit is the one that applies.

### Form input

ood_core writes `submit.yml.erb` values into its own pod template inside bare
double quotes, so `submit.yml.erb` validates everything before it reaches the
YAML: CPUs and memory must be whole numbers in range (the form's min/max are
only enforced by the browser), the working directory must match a strict path
pattern, and the user's GECOS has `:`, quotes, backslashes and control
characters replaced.

### The image and CI

`image/Dockerfile` is `rocker/rstudio:4.6.1` plus `nss_wrapper`,
`openssh-client`, `curl`, `jq`, `procps`, `less`, our scripts, and
`bao-getkey`. No R packages are added.

`bao-getkey` is vendored because its upstream repo
(`NCAR/hsg-openbao-scripts`) is internal to the NCAR org and an
unauthenticated build cannot fetch it. It is a verbatim copy of
`bin/bao-getkey` at commit `ef6b7a7503c911977865df50df3b4d4fc223c25b`, and CI
checks its sha256. To update it, copy the file again and update the hash in
the Dockerfile comment and the workflow.

CI runs on pushes to `main` touching `image/` and on demand. It builds, runs a
smoke test as an arbitrary uid (tools present, `bao-getkey` hash, the
session's ssh-agent reachable, the gate serving its login page, SIGTERM exiting
0), then pushes `hub.k8s.ucar.edu/ncote/rstudio-server:<date tag>`. **The tag
in `submit.yml.erb` is updated by hand**; the run's summary has the line to
paste. Harbor scans pushed images with Trivy.

`rstudio-versions` in the image prints the versions recorded at build time.

### Testing locally

```bash
podman build -t localhost/cirrus-rstudio:dev -f image/Dockerfile image
image/test/acceptance.sh
```

`acceptance.sh` runs the image as an arbitrary uid with a throwaway home and
checks: user and group names, GECOS cleaning, the gate (login page, wrong and
right password, unprefixed redirects, websocket relay), the R library path and
`~/.Renviron` handling, the ssh-agent reaching rsession, that the home has
nothing new but `~/rstudio/`, and each way a session ends (idle, maximum
length, SIGTERM, missing password) with its exit status.

### Deploy as a dev app

**Develop → My Sandbox Apps → New App**, give it a directory name and this
repo's **HTTPS** git URL. The app files are at the repo root so OnDemand finds
`manifest.yml`.
