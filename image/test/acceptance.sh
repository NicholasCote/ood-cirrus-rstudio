#!/usr/bin/env bash
#
# Acceptance checks for the CIRRUS RStudio image, run with podman against a
# throwaway home. Everything here is reproducible in about two minutes and
# covers the failures that are expensive to find in OnDemand:
#
#   1. an arbitrary uid with a runtime-synthesised numeric passwd entry
#   2. an arbitrary uid with NO passwd entry at all (the Kubernetes case)
#   3. the per-session password gate, including a websocket upgrade with a
#      foreign Origin
#   4. home isolation: the R library path, RStudio's state, and a pre-existing
#      HPC configuration left byte-identical
#   5. the session's ssh-agent reaching the R session
#   6. session endings: idle, the maximum length, SIGTERM, and a missing
#      password, each with the exit status OnDemand needs
#
# Usage: image/test/acceptance.sh [image-ref]
set -uo pipefail

IMAGE="${1:-localhost/cirrus-rstudio:dev}"
WORK="$(mktemp -d)"
PORT=18080
NAME="rstudio-acceptance-$$"
PASSWORD="TestPass123"
PREFIX="/rnode/fakenode/30123"
UA="Mozilla/5.0 (X11; Linux x86_64) Chrome/140"

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$*"; pass=$((pass+1)); }
bad()  { printf '  FAIL %s\n' "$*"; fail=$((fail+1)); }
head_() { printf '\n== %s ==\n' "$*"; }

cleanup() {
    podman rm -f "$NAME" "${NAME}-idle" "${NAME}-max" "${NAME}-term" "${NAME}-nopw" >/dev/null 2>&1
    # The throwaway home is written by a uid inside the container's user
    # namespace, so the host user cannot remove it directly.
    podman unshare rm -rf "$WORK" 2>/dev/null || rm -rf "$WORK" 2>/dev/null
}
trap cleanup EXIT

# --- a home that already looks like a real GLADE home ----------------------
mkdir -p "$WORK/home/.config/rstudio" "$WORK/home/R/x86_64-pc-linux-gnu-library/4.6" \
         "$WORK/home/projects" "$WORK/ood"
# The line every R user on this platform has, and the one that makes setting
# R_LIBS_USER in the environment insufficient.
printf 'R_LIBS_USER=/glade/u/home/jdoe/R/casper/4.4\nMY_API_KEY=keepme\n' > "$WORK/home/.Renviron"
printf 'options(repos=c(CRAN="https://cloud.r-project.org"))\n' > "$WORK/home/.Rprofile"
printf '{"font_size_points":14}\n' > "$WORK/home/.config/rstudio/rstudio-prefs.json"
printf 'hpc marker\n' > "$WORK/home/R/x86_64-pc-linux-gnu-library/4.6/MARKER"
printf 'x <- 1\n' > "$WORK/home/projects/demo.R"
chmod -R 777 "$WORK/home"
( cd "$WORK/home" && find . -type f | sort | xargs md5sum ) > "$WORK/home-before.md5"

printf '# seeded\npassword=%s\n' "$PASSWORD" > "$WORK/ood/csenv"
printf '%s/\n' "$PREFIX" > "$WORK/ood/base_url"
chmod -R 755 "$WORK/ood"

head_ "1. arbitrary uid, runtime-synthesised numeric passwd entry"
# podman appends an entry whose NAME IS THE UID -- 54321:*:54321:54321:container
# user:/:/bin/sh -- which is why "does an entry exist" is the wrong test.
# --entrypoint, so this reads /etc/passwd as the runtime left it. Through the
# normal entrypoint the answer would be nss_wrapper's, which is what the next
# check is for.
synth="$(podman run --rm --user 54321:54321 --entrypoint getent "$IMAGE" passwd 54321 2>/dev/null)"
case "$synth" in
    54321:*) ok "the runtime does synthesise a numeric entry: ${synth}" ;;
    *)       printf '  note the runtime did not synthesise an entry (%s)\n' "${synth:-none}" ;;
esac
out="$(podman run --rm --user 54321:54321 -e HOME=/tmp/h -e USER=jdoe -e GROUP=ncar \
        "$IMAGE" bootstrap id -un 2>/dev/null)"
[ "$out" = "jdoe" ] && ok "id -un is jdoe, not 54321" || bad "id -un is '${out}', expected jdoe"
out="$(podman run --rm --user 54321:54321 -e HOME=/tmp/h -e USER=jdoe -e GROUP=ncar \
        "$IMAGE" bootstrap id -gn 2>/dev/null)"
[ "$out" = "ncar" ] && ok "id -gn is ncar, not the image's own group" || bad "id -gn is '${out}', expected ncar"

head_ "2. arbitrary uid with NO passwd entry at all"
# /etc/passwd mounted read-only without the uid, so the runtime cannot add one.
# This is the Kubernetes case, and it is the one where a `getent` under `set -e`
# with `pipefail` kills the entrypoint before it logs anything.
podman run --rm --user 54321:54321 "$IMAGE" bootstrap cat /etc/passwd 2>/dev/null \
    | grep -v '^[^:]*:[^:]*:54321:' > "$WORK/passwd-noentry"
chmod 644 "$WORK/passwd-noentry"
out="$(podman run --rm --user 54321:54321 -v "$WORK/passwd-noentry:/etc/passwd:ro,z" \
        -e HOME=/tmp/h -e USER=jdoe -e GROUP=ncar "$IMAGE" bootstrap id -un 2>/dev/null)"
[ "$out" = "jdoe" ] && ok "id -un is jdoe with no entry to start from" || bad "id -un is '${out}'"

out="$(podman run --rm --user 54321:54321 -e HOME=/tmp/h -e USER=jdoe -e GROUP=ncar \
        -e CIRRUS_RSTUDIO_GECOS="$(printf 'Jane: Doe\nx:0:0')" "$IMAGE" bootstrap getent passwd jdoe 2>/dev/null)"
fields=$(printf '%s\n' "$out" | awk -F: '{print NF}')
[ "$(printf '%s\n' "$out" | wc -l)" = 1 ] && [ "$fields" = 7 ] \
    && ok "GECOS with ':' and a newline gives one 7-field passwd line (${out})" \
    || bad "GECOS broke the passwd entry: ${out}"

head_ "3. the session starts and the gate holds the port"
podman rm -f "$NAME" >/dev/null 2>&1
podman run -d --name "$NAME" --user 54321:54321 -p "${PORT}:8080" \
  -v "$WORK/home:/home/jdoe:z" -v "$WORK/ood:/ood:z" \
  -e HOME=/home/jdoe -e USER=jdoe -e NB_USER=jdoe -e GROUP=ncar \
  -e CIRRUS_RSTUDIO_PASSWORD_FILE=/ood/csenv \
  -e CIRRUS_RSTUDIO_BASE_URL_FILE=/ood/base_url \
  -e CIRRUS_RSTUDIO_WORKDIR=/home/jdoe/projects \
  "$IMAGE" rserver >/dev/null || { bad "container did not start"; exit 1; }

start=$(date +%s)
for _ in $(seq 1 120); do
    curl -s -o /dev/null -m 1 "http://127.0.0.1:${PORT}/" 2>/dev/null && break
    sleep 0.5
done
ok "port answered $(( $(date +%s) - start ))s after container start (startup probe budget is 305s)"

code=$(curl -s -o "$WORK/login.html" -w '%{http_code}' -A "$UA" "http://127.0.0.1:${PORT}/")
[ "$code" = "200" ] && grep -q "${PREFIX}/cirrus-signin" "$WORK/login.html" \
    && ok "no cookie: login page, form posting to ${PREFIX}/cirrus-signin" \
    || bad "no cookie: got ${code} and an unexpected page"

code=$(curl -s -o /dev/null -w '%{http_code}' -A "$UA" -X POST -d "password=WRONG" \
        "http://127.0.0.1:${PORT}/cirrus-signin")
[ "$code" = "401" ] && ok "wrong password refused (401)" || bad "wrong password gave ${code}, expected 401"

cookie=$(curl -s -D - -o /dev/null -A "$UA" -X POST -d "password=${PASSWORD}" \
        "http://127.0.0.1:${PORT}/cirrus-signin" | grep -i '^set-cookie:' | sed 's/.*: //; s/;.*//')
[ -n "$cookie" ] && ok "correct password accepted, cookie issued" || bad "correct password issued no cookie"

# The 302 the gate sends after a correct password. It must NOT carry the prefix:
# OnDemand's /rnode/ block prepends the prefix to every Location it forwards, so
# a prefixed one arrives at the browser doubled --
# /rnode/<node>/<port>/rnode/<node>/<port>/ -- which is a 404 on the dashboard,
# and was what the first live session did.
loc=$(curl -s -D - -o /dev/null -A "$UA" -X POST -d "password=${PASSWORD}" \
        "http://127.0.0.1:${PORT}/cirrus-signin" | grep -i '^location:' | tr -d '\r' | sed 's/.*: //')
[ "$loc" = "/" ] \
    && ok "sign-in redirects to '/', unprefixed, so the proxy's rewrite lands on ${PREFIX}/" \
    || bad "sign-in redirect is '${loc}', expected '/' (a prefix here gets applied twice)"

# Past the gate, requests reach rserver. Note the paths below carry NO prefix:
# that is what OnDemand's /rnode/ proxy delivers, having stripped it -- and for
# the same reason rserver runs with no --www-root-path, so what it emits must be
# unprefixed too. Its Location is a full URL built from the Host header; the
# proxy's rule replaces the scheme and authority with the prefix.
loc=$(curl -s -D - -o /dev/null -A "$UA" -H "Cookie: ${cookie}" "http://127.0.0.1:${PORT}/" \
      | grep -i '^location:' | tr -d '\r' | sed 's/.*: //')
case "$loc" in
    *"${PREFIX}"*)
        bad "rserver emitted the ${PREFIX} prefix ('${loc}'); the proxy would double it" ;;
    */auth-sign-in*)
        ok "rserver redirects to an unprefixed /auth-sign-in ('${loc}')" ;;
    *)  bad "expected an unprefixed /auth-sign-in redirect, got '${loc}'" ;;
esac

# The IDE page references every asset by relative path -- css/icons.css,
# js/diff.min.js, rstudio/rstudio.nocache.js -- which is what makes serving at
# the root safe behind a prefix-stripping proxy that rewrites headers only. A
# root-absolute reference here would be requested from the OnDemand host itself.

# Sign in to RStudio itself and load the IDE. rserver signs the caller in on
# request -- that is why the gate exists -- so this needs no password.
rsjar="$WORK/rsjar.txt"
curl -s -o /dev/null -A "$UA" -H "Cookie: ${cookie}" -c "$rsjar" \
     "http://127.0.0.1:${PORT}/auth-sign-in?appUri=%2F"
# Cookies are sent as an explicit header rather than with -b, because the jar
# curl writes here is not the jar a browser would hold behind the proxy: the
# proxy rewrites every Set-Cookie Path to /rnode/<node>/<port>, and this test
# sees the unrewritten ones.
allcookies=$(sed 's/^#HttpOnly_//' "$rsjar" | grep -v '^#' | awk 'NF>=7{printf "%s=%s; ", $6, $7}')
allcookies="${cookie}; ${allcookies}"
code=$(curl -s -o "$WORK/ide.html" -w '%{http_code}' -A "$UA" -H "Cookie: ${allcookies}" \
        "http://127.0.0.1:${PORT}/")
grep -qi "rstudio" "$WORK/ide.html" && [ "$code" = "200" ] \
    && ok "the IDE page loads through the gate (${code})" \
    || bad "IDE page: got ${code} and no RStudio markup"

abs=$(grep -oE '(src|href)="/[^"]*"' "$WORK/ide.html" | sort -u | tr '\n' ' ')
[ -z "$abs" ] \
    && ok "the IDE page references no root-absolute asset (safe to serve at /)" \
    || bad "the IDE page has root-absolute references the proxy will not rewrite: ${abs}"

# client_init is what makes rserver start an R session, so it has to happen
# before anything below can look at one.
csrf=$(grep 'rs-csrf-token' "$rsjar" | awk '{print $NF}')
curl -s -A "$UA" -H "Cookie: ${allcookies}" \
     -H "Content-Type: application/json" -H "X-CSRF-Token: ${csrf}" \
     -d '{"method":"client_init","params":[{"scope":{"project":"","id":""}}],"clientId":"","clientVersion":""}' \
     "http://127.0.0.1:${PORT}/rpc/client_init" -o "$WORK/client_init.json"
if grep -q '"clientId"' "$WORK/client_init.json" 2>/dev/null; then
    ok "client_init succeeded; an R session is running"
    # RStudio reports this from its own read of ~/.Renviron. Before the site
    # profile was in place it said /glade/u/home/jdoe/R/casper/4.4 -- which was
    # the only visible sign that the R session was ignoring everything the
    # entrypoint had set.
    reported=$(python3 -c "import json;print(json.load(open('$WORK/client_init.json'))['result'].get('r_libs_user',''))" 2>/dev/null)
    case "$reported" in
        */rstudio/r-libs/*) ok "client_init reports r_libs_user=${reported}" ;;
        *)                  bad "client_init reports r_libs_user=${reported}" ;;
    esac
else
    bad "client_init failed: $(head -c 120 "$WORK/client_init.json")"
fi

head_ "4. websocket upgrade through the gate, foreign Origin"
# Tested against a controlled echo upstream rather than against rserver, and
# that is deliberate. RStudio negotiates its own transport: its client opens the
# websocket from JavaScript after an in-browser handshake, and /events/get_events
# answers a plain 200 to anything else, so a hand-built request to rserver proves
# nothing either way. What CAN be proved -- and is the only new risk this app
# introduces -- is that the gate relays an upgrade rather than eating it. So the
# real gate binary, in this image, is put in front of a websocket server and
# driven with a foreign Origin.
podman exec -d "$NAME" bash -c 'python3 - 8899 > /tmp/wsecho.log 2>&1 <<"ECHO"
import base64, hashlib, socket, struct, sys, threading
GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
def handle(c):
    buf = b""
    while b"\r\n\r\n" not in buf:
        d = c.recv(4096)
        if not d: return
        buf += d
    head = buf.split(b"\r\n\r\n")[0].decode("latin-1")
    key = next(l.split(":",1)[1].strip() for l in head.split("\r\n")[1:]
               if l.lower().startswith("sec-websocket-key:"))
    acc = base64.b64encode(hashlib.sha1((key+GUID).encode()).digest()).decode()
    c.sendall(("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n"
               "Connection: Upgrade\r\n"
               "Sec-WebSocket-Accept: " + acc + "\r\n\r\n").encode())
    payload = b"echo-through-gate"
    c.sendall(b"\x81" + struct.pack("!B", len(payload)) + payload)
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", int(sys.argv[1]))); srv.listen(8)
while True:
    c, _ = srv.accept()
    threading.Thread(target=handle, args=(c,), daemon=True).start()
ECHO' >/dev/null 2>&1
podman exec -d "$NAME" bash -c 'CIRRUS_RSTUDIO_PORT=8081 CIRRUS_RSTUDIO_UPSTREAM_PORT=8899 \
  CIRRUS_RSTUDIO_ROOT_PATH='"$PREFIX"'/ \
  CIRRUS_RSTUDIO_PASSWORD_FILE_RESOLVED=/tmp/cirrus-rstudio/session-password \
  /usr/local/bin/cirrus-rstudio-gate > /tmp/gate-ws.log 2>&1' >/dev/null 2>&1
sleep 3
if podman exec -i "$NAME" python3 - <<'WS'
import base64, hashlib, http.client, os, socket, sys, urllib.parse

def probe(cookie):
    key = base64.b64encode(os.urandom(16)).decode()
    req = ("GET /events/get_events HTTP/1.1\r\nHost: 127.0.0.1:8081\r\n"
           "Upgrade: websocket\r\nConnection: Upgrade\r\n"
           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n"
           # Foreign on purpose: behind a proxy every request carries one.
           "Origin: https://ondemand.ucar.edu\r\n"
           "User-Agent: Mozilla/5.0 Chrome/140\r\n"
           + (f"Cookie: {cookie}\r\n" if cookie else "") + "\r\n")
    s = socket.create_connection(("127.0.0.1", 8081), timeout=10)
    s.sendall(req.encode())
    buf = b""
    while b"\r\n\r\n" not in buf and len(buf) < 8192:
        d = s.recv(4096)
        if not d:
            break
        buf += d
    head, _, rest = buf.partition(b"\r\n\r\n")
    text = head.decode("latin-1")
    acc = next((l.split(":", 1)[1].strip() for l in text.split("\r\n")[1:]
                if l.lower().startswith("sec-websocket-accept:")), None)
    exp = base64.b64encode(
        hashlib.sha1((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
    if acc != exp:
        return text.split("\r\n")[0], False, b""
    while len(rest) < 2:
        rest += s.recv(4096)
    length = rest[1] & 0x7F
    payload = rest[2:2 + length]
    while len(payload) < length:
        payload += s.recv(4096)
    return text.split("\r\n")[0], True, payload

status, upgraded, _ = probe("")
print(("  ok   " if not upgraded else "  FAIL ") + f"no cookie: refused, no upgrade ({status})")

password = open("/tmp/cirrus-rstudio/session-password").read().strip()
conn = http.client.HTTPConnection("127.0.0.1", 8081, timeout=10)
conn.request("POST", "/cirrus-signin", urllib.parse.urlencode({"password": password}),
             {"Content-Type": "application/x-www-form-urlencoded"})
resp = conn.getresponse()
token = resp.getheader("Set-Cookie", "").split(";")[0]
status, upgraded, payload = probe(token)
print(("  ok   " if upgraded else "  FAIL ") +
      f"with the session cookie: {status}, valid Sec-WebSocket-Accept={upgraded}")
if upgraded:
    print(("  ok   " if payload == b"echo-through-gate" else "  FAIL ") +
          f"data frame relayed through the gate: {payload!r}")
sys.exit(0 if upgraded and payload == b"echo-through-gate" else 1)
WS
then pass=$((pass+3)); else fail=$((fail+1)); fi

head_ "5. what the R session actually sees"
# Read from the live rsession's own environment and from R started under it.
podman exec "$NAME" bash -c '
  pid=$(pgrep -x rsession | head -1)
  [ -n "$pid" ] || exit 9
  tr "\0" "\n" < /proc/$pid/environ | grep -qE "^LD_PRELOAD=" && echo "  ok   rsession has LD_PRELOAD (terminal identity works)" || echo "  FAIL rsession has no LD_PRELOAD"
' 2>/dev/null || printf '  note no rsession yet (nobody has opened the IDE in this run)\n'

# rsession's log goes to the user's Console, not the pod log, so its level is set
# per process rather than in logging.conf. At info the Console opens with three
# INFO lines about keybinding files nobody installed.
if podman exec "$NAME" bash -c '
      pid=$(pgrep -x rsession | head -1); [ -n "$pid" ] || exit 9
      tr "\0" "\n" < /proc/$pid/environ | grep -qx "RS_LOG_LEVEL=warn"' 2>/dev/null; then
    ok "rsession runs at RS_LOG_LEVEL=warn (no INFO lines in the user's Console)"
else
    bad "rsession has no RS_LOG_LEVEL=warn; the Console will open with log lines"
fi

# The session's ssh-agent has to survive rserver's environment filtering, or
# bao-getkey and ssh in the Terminal and the Git pane cannot use it.
if podman exec "$NAME" bash -c '
      pid=$(pgrep -x rsession | head -1); [ -n "$pid" ] || exit 9
      sock=$(tr "\0" "\n" < /proc/$pid/environ | sed -n "s/^SSH_AUTH_SOCK=//p")
      [ -S "$sock" ] && SSH_AUTH_SOCK=$sock ssh-add -l >/dev/null 2>&1; [ $? -eq 1 ]' 2>/dev/null; then
    ok "rsession has SSH_AUTH_SOCK and the agent answers (no identities yet)"
else
    bad "rsession has no working SSH_AUTH_SOCK"
fi
missing=""
for b in ssh ssh-agent ssh-add jq curl bao-getkey; do
    podman exec "$NAME" sh -c "command -v $b" >/dev/null 2>&1 || missing="$missing $b"
done
[ -z "$missing" ] && ok "ssh, ssh-agent, ssh-add, jq, curl and bao-getkey are installed" \
                  || bad "missing from the image:${missing}"

podman exec "$NAME" bash -c 'R -s -e "
  lib <- .libPaths()[1]
  cat(if (grepl(\"/home/jdoe/rstudio/r-libs\", lib)) \"  ok   \" else \"  FAIL \", \"install target is \", lib, \"\n\", sep=\"\")
  cat(if (any(grepl(\"casper|derecho\", .libPaths()))) \"  FAIL \" else \"  ok   \", \"no HPC library path in .libPaths()\n\", sep=\"\")
  cat(if (nzchar(Sys.getenv(\"MY_API_KEY\"))) \"  ok   \" else \"  FAIL \", \"the user own ~/.Renviron settings survive\n\", sep=\"\")
"' 2>/dev/null | grep -E "ok|FAIL"

head_ "6. the home directory afterwards"
extra=$(podman exec "$NAME" bash -c 'find /home/jdoe -maxdepth 1 -mindepth 1 -printf "%f\n" | sort | tr "\n" " "')
printf '  contents: %s\n' "$extra"
case " $extra " in
    *" rstudio "*) ok "the session created \$HOME/rstudio and nothing else new" ;;
    *)             bad "\$HOME/rstudio was not created" ;;
esac
for d in .cache .local .config/rstudio/rstudio-desktop .rstudio; do
    if podman exec "$NAME" test -e "/home/jdoe/$d" 2>/dev/null; then
        case "$d" in
            .config/rstudio/*) bad "the session wrote $d" ;;
            .cache|.local|.rstudio) bad "the session created \$HOME/$d" ;;
        esac
    else
        ok "no \$HOME/$d"
    fi
done
if ( cd "$WORK/home" && md5sum -c "$WORK/home-before.md5" >/dev/null 2>&1 ); then
    ok "every pre-existing file is byte-identical (md5)"
else
    bad "a pre-existing file changed:"
    ( cd "$WORK/home" && md5sum -c "$WORK/home-before.md5" 2>&1 | grep -v ': OK' | sed 's/^/       /' )
fi

head_ "7. how sessions end"
# Each ending must exit 0 when it was intended (OnDemand shows Completed, and
# restart_policy OnFailure leaves it alone) and nonzero when it was not.
run_session() {   # name, extra podman args...
    local n="$1"; shift
    podman rm -f "$n" >/dev/null 2>&1
    podman run -d --name "$n" --user 54321:54321 -v "$WORK/ood:/ood:z" \
        -e HOME=/tmp/h -e USER=jdoe -e GROUP=ncar \
        -e CIRRUS_RSTUDIO_PASSWORD_FILE=/ood/csenv "$@" "$IMAGE" rserver >/dev/null
}
wait_exit() {     # name, max seconds -> sets state and rc
    local i
    for i in $(seq 1 "$2"); do
        state=$(podman inspect "$1" --format '{{.State.Status}}' 2>/dev/null)
        [ "$state" = "exited" ] && break
        sleep 1
    done
    rc=$(podman inspect "$1" --format '{{.State.ExitCode}}' 2>/dev/null)
}

run_session "${NAME}-idle" -e CIRRUS_RSTUDIO_IDLE_TIMEOUT=20 -e CIRRUS_RSTUDIO_IDLE_CHECK=5
wait_exit "${NAME}-idle" 90
if [ "$state" = exited ] && [ "$rc" = 0 ] && podman logs "${NAME}-idle" 2>&1 | grep -c 'no activity for' >/dev/null; then
    ok "an idle session ends itself, says why, and exits 0"
else
    bad "idle session: state=${state} exit=${rc}"
fi

run_session "${NAME}-max" -e CIRRUS_RSTUDIO_IDLE_TIMEOUT=0 -e CIRRUS_RSTUDIO_IDLE_CHECK=5 \
    -e CIRRUS_RSTUDIO_MAX_SECONDS=15
wait_exit "${NAME}-max" 60
if [ "$state" = exited ] && [ "$rc" = 0 ] && podman logs "${NAME}-max" 2>&1 | grep -c 'maximum length' >/dev/null; then
    ok "a session at its maximum length ends and exits 0"
else
    bad "maximum length: state=${state} exit=${rc}"
fi

run_session "${NAME}-term"
sleep 8
podman stop -t 20 "${NAME}-term" >/dev/null 2>&1
wait_exit "${NAME}-term" 30
if [ "$rc" = 0 ] && podman logs "${NAME}-term" 2>&1 | grep -c 'received SIGTERM' >/dev/null; then
    ok "SIGTERM (ending it from the dashboard) stops RStudio and exits 0"
else
    bad "SIGTERM: exit=${rc}"
fi

mkdir -p "$WORK/ood-empty" && : > "$WORK/ood-empty/csenv" && chmod -R 755 "$WORK/ood-empty"
podman rm -f "${NAME}-nopw" >/dev/null 2>&1
podman run -d --name "${NAME}-nopw" --user 54321:54321 -v "$WORK/ood-empty:/ood:z" \
    -e HOME=/tmp/h -e USER=jdoe -e CIRRUS_RSTUDIO_PASSWORD_FILE=/ood/csenv \
    -e CIRRUS_RSTUDIO_CONFIG_WAIT=5 "$IMAGE" rserver >/dev/null
wait_exit "${NAME}-nopw" 30
if [ "$rc" != 0 ] && podman logs "${NAME}-nopw" 2>&1 | grep -c 'ERROR: this session cannot start' >/dev/null; then
    ok "no password after the wait: a clear error and a nonzero exit (${rc})"
else
    bad "missing password: exit=${rc}"
fi
podman logs "${NAME}-nopw" 2>&1 | grep 'cirrus-rstudio: ' | tail -4 | sed 's/^/       /'

head_ "versions recorded in the image"
podman run --rm "$IMAGE" bootstrap rstudio-versions 2>/dev/null | grep -v '^#' | sed 's/^/  /'

printf '\n== %d passed, %d failed ==\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
