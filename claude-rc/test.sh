#!/bin/bash
# Drives every plugin state against a private tmux server and a fake `claude`,
# without touching the real rc session, tmux server, login or install.
#
#   ./test.sh                 tests plugin.template.sh
#   ./test.sh path/to/plugin  tests another copy
set -uo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
PLUGIN="${1:-$SRC/plugin.template.sh}"
TMUX_BIN="$(PATH="/opt/homebrew/bin:/usr/local/bin:$PATH" command -v tmux)" || { echo "tmux required"; exit 1; }
SYS="/usr/bin:/bin:/usr/sbin:/sbin"

# Short path: the tmux socket lives under it and unix sockets cap at 104 chars.
W="$(mktemp -d "${TMPDIR:-/tmp}/crt.XXXXXX")"
W="$(cd "$W" && pwd -P)"

# A private tmux server. If the tests were first to start the default server,
# every real session started later would inherit this throwaway environment.
export TMUX_TMPDIR="$W/tmux"
# A throwaway HOME keeps ~/.bash_profile out of `bash -lic` and makes the ~
# label testable.
export HOME="$W"
export SHELL=/bin/bash
export BASH_SILENCE_DEPRECATION_WARNING=1   # else macOS bash -l prints a zsh nag into the pane
export CLAUDE_RC_SESSION="claude-rc-test"
export CLAUDE_RC_DIR="$W/code"
export CLAUDE_RC_STATE_DIR="$W/state"
export CLAUDE_RC_PREFS_DIR="$W/prefs"
export CLAUDE_RC_SETTINGS="$W/settings.json"
export CLAUDE_RC_DIST_TAGS_URL="file://$W/dist-tags.json"
export CLAUDE_RC_PATH="$W/bin:$(dirname "$TMUX_BIN"):$SYS"
mkdir -p "$TMUX_TMPDIR" "$W/code" "$W/state" "$W/prefs" "$W/bin" "$W/versions" "$W/run" "$W/empty"

cleanup() { "$TMUX_BIN" kill-server 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT

# --- fixtures ------------------------------------------------------------------

# Fake Claude Code: versions/<v> scripts behind a bin/claude symlink, exactly
# the shape of the native install. `update` fails if $W/update-fails exists,
# dawdles if $W/update-slow exists, succeeds without installing anything if
# $W/update-noop exists, otherwise repoints the symlink to the version named
# in $W/update-to. `auth status` answers from $W/auth.json, after a 5 s stall
# if $W/auth-slow exists.
make_claude() { # $1 = version
  cat > "$W/versions/$1" <<EOF
#!/bin/bash
case "\$1 \${2:-}" in
  "auth status") [[ -e "$W/auth-slow" ]] && sleep 5; cat "$W/auth.json" ;;
  "update "*)
    echo "Checking for updates..."
    [[ -e "$W/update-slow" ]] && sleep 3
    if [[ -e "$W/update-fails" ]]; then printf '\033[31mError: boom|pipe\033[0m\n'; exit 1; fi
    if [[ -e "$W/update-noop" ]]; then echo "Claude Code is up to date"; exit 0; fi
    ln -sfn "$W/versions/\$(cat "$W/update-to")" "$W/bin/claude"
    echo "Updated"; exit 0 ;;
esac
EOF
  chmod +x "$W/versions/$1"
}
install_claude() { make_claude "$1"; ln -sfn "$W/versions/$1" "$W/bin/claude"; }

# The running version is read from the rc process's executable basename, so
# the stand-in must be a real binary named <v>. macOS SIGKILLs copies of its
# own platform binaries (cp /bin/sleep), hence a compiled pause() loop.
printf '#include <unistd.h>\nint main(void){for(;;)pause();}\n' | cc -x c -o "$W/pause" - \
  || { echo "cc required"; exit 1; }
rc_at() { cp "$W/pause" "$W/run/$1"; export CLAUDE_RC_CMD="$W/run/$1 --permission-mode auto"; }

logged_in()  { echo '{"loggedIn": true, "authMethod": "claude.ai"}' > "$W/auth.json"; rm -f "$W"/state/claude-rc-auth.*; }
logged_out() { echo '{"loggedIn": false}' > "$W/auth.json"; rm -f "$W"/state/claude-rc-auth.*; }
tags() { echo "{\"stable\":\"$1\",\"latest\":\"$2\",\"next\":\"$2\"}" > "$W/dist-tags.json"; rm -f "$W"/state/claude-rc-latest.*; }

# --- helpers -------------------------------------------------------------------

# Every render (a call with no action) must exit 0: SwiftBar logs anything else
# as "Failed to execute script". `run` mostly runs inside $(…), where counters
# can't reach the parent, so it appends "<status> <section>" to a file that
# renders_exit_0 turns into assertions at each section boundary.
run() {
  local rc
  "$PLUGIN" "$@" 2>&1; rc=$?
  (( $# == 0 )) && echo "$rc ${CUR_SECTION:-?}" >> "$W/renders"
  return $rc
}
tm()   { "$TMUX_BIN" "$@"; }
pane() { tm display-message -p -t "=$CLAUDE_RC_SESSION:=rc" "$1" 2>/dev/null; }
wait_until() { local i; for (( i = 0; i < 60; i++ )); do eval "$1" && return 0; sleep 0.1; done; return 1; }
alive() { [[ "$(pane '#{pane_dead}')" == 0 ]]; }
dead()  { [[ "$(pane '#{pane_dead}')" == 1 ]]; }
gone()  { ! tm has-session -t "=$CLAUDE_RC_SESSION" 2>/dev/null; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/    | /'; return 0; }
has()   { if grep -qF -- "$2" <<<"$3"; then ok; else bad "$1 — expected: $2" "$3"; fi; }
lacks() { if grep -qF -- "$2" <<<"$3"; then bad "$1 — unexpected: $2" "$3"; else ok; fi; }
check() { if eval "$2"; then ok; else bad "$1 — $2"; fi; }

RENDERS=0
renders_exit_0() {
  local rc s n=0 failed=0
  [[ -s "$W/renders" ]] || return 0
  while read -r rc s; do
    n=$((n + 1))
    [[ "$rc" == 0 ]] || { failed=1; bad "render exits 0 ($s) — exited $rc"; }
  done < "$W/renders"
  : > "$W/renders"
  RENDERS=$((RENDERS + n))
  (( failed )) || ok
}
section() { renders_exit_0; CUR_SECTION="$1"; printf '== %s\n' "$1"; }

# Baseline: logged in, installed = latest = running = 2.1.200.
install_claude 2.1.200; logged_in; tags 2.1.100 2.1.200; rc_at 2.1.200

# --- missing / stopped ---------------------------------------------------------------

section "missing"
out="$(CLAUDE_RC_PATH="$W/bin:$SYS" run)"
has "no tmux: grey"        "| image=__ICON_GREY__" "$out"
has "no tmux: message"     "tmux not installed" "$out"
out="$(CLAUDE_RC_PATH="$W/empty:$(dirname "$TMUX_BIN"):$SYS" run)"
has "no claude: grey"      "| image=__ICON_GREY__" "$out"
has "no claude: message"   "claude not found" "$out"

section "stopped"
out="$(run)"
has   "grey icon"          "| image=__ICON_GREY__" "$out"
has   "header"             "Claude RC — stopped" "$out"
has   "start item"         "param1=start" "$out"
lacks "no stop item"       "param1=stop" "$out"

# --- lifecycle -------------------------------------------------------------------

section "start → running"
run start >/dev/null
check "pane alive"            "wait_until alive"
out="$(run)"
has   "header"                "Claude RC — running · <1m" "$out"
has   "dir · mode"            "~/code · auto · v2.1.200 |" "$out"
has   "attach item"           "param1=attach" "$out"
has   "restart item"          "param1=restart" "$out"
has   "stop item"             "param1=stop" "$out"
lacks "no start item"         "param1=start" "$out"
check "runs in RC_DIR"        '[[ "$(pane "#{pane_current_path}")" == "$W/code" ]]'
pid1="$(pane '#{pane_pid}')"
run start >/dev/null
check "start is idempotent"   '[[ "$(pane "#{pane_pid}")" == "$pid1" ]]'

section "restart"
run restart >/dev/null
check "new pid"               'wait_until alive && [[ "$(pane "#{pane_pid}")" != "$pid1" ]]'

section "stop"
t0=$SECONDS
run stop >/dev/null
check "session gone"          gone
check "Ctrl-C path, not the 5s timeout" '(( SECONDS - t0 < 3 ))'
has   "back to stopped"       "Claude RC — stopped" "$(run)"
run stop >/dev/null
check "stop with no session is harmless" gone

section "stop while the pane is in copy mode"
run start >/dev/null; wait_until alive
tm copy-mode -t "=$CLAUDE_RC_SESSION:=rc"
check "pane in copy mode"     '[[ "$(pane "#{pane_in_mode}")" == 1 ]]'
t0=$SECONDS
run stop >/dev/null
check "session gone"          gone
check "Ctrl-C reached rc, not the 5s timeout" '(( SECONDS - t0 < 3 ))'

section "exited"
CLAUDE_RC_CMD='sh -c "echo first; echo \"a|b\"; printf \"\\033[31mboom\\033[0m\\n\"; exit 3"' run start >/dev/null
check "pane dead"             "wait_until dead"
out="$(run)"
has   "red icon"              "| image=__ICON_RED__" "$out"
has   "exit code"             "Claude RC — exited (code 3)" "$out"
has   "earlier line kept"     "first | font=Menlo" "$out"
has   "pipe neutralised"      "a¦b | font=Menlo" "$out"
has   "ansi stripped"         "boom | font=Menlo" "$out"
lacks "tmux banner dropped"   "Pane is dead" "$out"
has   "restart item"          "param1=restart" "$out"
has   "clear item"            "param1=clear" "$out"
lacks "no stop item"          "param1=stop" "$out"
lacks "logged in: no login item" "param1=login" "$out"

section "exited: output that looks like SwiftBar syntax"
CLAUDE_RC_CMD='sh -c "echo \"--- separator? ---\"; echo \"-- submenu?\"; echo \"a :bolt: symbol?\"; exit 4"' run start >/dev/null
check "pane dead"             "wait_until dead"
out="$(run)"
paned="$(grep -F 'font=Menlo' <<<"$out")"
has   "separator text kept"   "−-- separator? --- |" "$paned"
has   "submenu text kept"     "−- submenu? |" "$paned"
check "no pane line starts with -"  '! grep -q "^-" <<<"$paned"'
check "all 3 pane lines unsymbolized" '[[ "$(grep -c "symbolize=false" <<<"$paned")" == 3 ]]'
run clear >/dev/null

section "start over a dead pane"
run start >/dev/null
check "replaced by a live rc" "wait_until alive"
run stop >/dev/null

section "clear"
CLAUDE_RC_CMD='sh -c "exit 1"' run start >/dev/null
check "pane dead"             "wait_until dead"
run clear >/dev/null
check "session gone"          gone

# --- versions & auth ------------------------------------------------------------------

section "running, current"
run start >/dev/null; wait_until alive
out="$(run)"
has   "green icon"            "| image=__ICON_GREEN__" "$out"
has   "dir · mode · version"  "~/code · auto · v2.1.200" "$out"
lacks "no update line"        "Update available" "$out"
lacks "no update item"        "param1=update" "$out"
run stop >/dev/null

section "installed behind latest"
tags 2.1.100 2.1.300; rc_at 2.1.200; run start >/dev/null; wait_until alive
out="$(run)"
has   "amber icon"            "| image=__ICON_AMBER__" "$out"
has   "update line"           "Update available: 2.1.300" "$out"
has   "update item"           "Update to 2.1.300 & restart" "$out"
lacks "no restart-to-apply"   "restart to apply" "$out"
run stop >/dev/null
has   "stopped: plain update" "Update to 2.1.300 |" "$(run)"

section "running behind installed"
tags 2.1.100 2.1.200; rc_at 2.1.150; run start >/dev/null; wait_until alive
out="$(run)"
has   "amber icon"            "| image=__ICON_AMBER__" "$out"
has   "running version"       "· v2.1.150" "$out"
has   "restart to apply"      "Installed 2.1.200 — restart to apply" "$out"
lacks "no update item"        "param1=update" "$out"
run stop >/dev/null

section "running version unknown"
CLAUDE_RC_CMD="sleep 600" run start >/dev/null; wait_until alive
out="$(run)"
has   "says unknown"          "running version unknown" "$out"
has   "no guessing: green"    "| image=__ICON_GREEN__" "$out"
run stop >/dev/null
rc_at 2.1.200

section "channel"
echo '{ "autoUpdatesChannel": "stable" }' > "$W/settings.json"
tags 2.1.250 2.1.300
has   "stable tag used"       "Update to 2.1.250" "$(run)"
rm -f "$W/settings.json"; tags 2.1.100 2.1.200

section "latest: cache and offline"
lat="$W/state/claude-rc-latest.$(id -u)"
tags 2.1.100 2.1.300; run >/dev/null                                   # caches 2.1.300
echo '{"stable":"2.1.100","latest":"2.1.400"}' > "$W/dist-tags.json"   # registry moves on…
has   "fresh cache used"      "Update to 2.1.300" "$(run)"             # …but the hour isn't up
echo "1 latest 2.1.300" > "$lat"                                       # stale stamp
CLAUDE_RC_DIST_TAGS_URL="file://$W/nope.json" run >/dev/null           # registry down
has   "last known kept"       "latest 2.1.300" "$(cat "$lat")"
check "retry in ~5 min, not 1 h" '(( $(cut -d" " -f1 "$lat") < $(date +%s) - 3000 ))'
tags 2.1.100 2.1.200

section "auth"
logged_out
out="$(run)"
has   "stopped: not logged in" "Not logged in" "$out"
has   "login item"             "param1=login" "$out"
run start >/dev/null; wait_until alive
has   "running + logged out: red" "| image=__ICON_RED__" "$(run)"
echo '{"loggedIn": true}' > "$W/auth.json"                    # no stamp reset: still cached
has   "cached for 5 min"       "| image=__ICON_RED__" "$(run)"
logged_in
out="$(run)"
has   "green again"            "| image=__ICON_GREEN__" "$out"
lacks "no login item"          "param1=login" "$out"
echo 'garbage' > "$W/auth.json"; rm -f "$W"/state/claude-rc-auth.*
has   "unknown is not red"     "| image=__ICON_GREEN__" "$(run)"
logged_in

section "auth: a failed check keeps the last answer"
auth_f="$W/state/claude-rc-auth.$(id -u)"
echo "1 no" > "$auth_f"                                        # expired "no"
echo 'garbage' > "$W/auth.json"
has   "garbage: still red"     "| image=__ICON_RED__" "$(run)"
check "garbage: stamp still no" '[[ "$(cut -d" " -f2 "$auth_f")" == no ]]'
check "retry in ~1 min, not 5"  'ts=$(cut -d" " -f1 "$auth_f"); now=$(date +%s); (( ts < now - 200 && ts > now - 300 ))'
echo '{"loggedIn": true}' > "$W/auth.json"; touch "$W/auth-slow"
echo "1 no" > "$auth_f"
t0=$SECONDS
out="$(CLAUDE_RC_AUTH_TIMEOUT=1 run)"
check "slow check cut off"      '(( SECONDS - t0 < 3 ))'
has   "timeout: still red"     "| image=__ICON_RED__" "$out"
check "timeout: stamp still no" '[[ "$(cut -d" " -f2 "$auth_f")" == no ]]'
rm -f "$W/auth-slow"; logged_in
run stop >/dev/null

section "exited + logged out → Log in"
logged_out
CLAUDE_RC_CMD='sh -c "echo auth expired; exit 1"' run start >/dev/null
check "pane dead"             "wait_until dead"
out="$(run)"
has   "red icon"              "| image=__ICON_RED__" "$out"
has   "not logged in line"    "Not logged in | color=" "$out"
has   "login item"            "param1=login" "$out"
run clear >/dev/null
logged_in

# --- update ---------------------------------------------------------------------

lock="$W/state/claude-rc-update.$(id -u).lock"
status_f="$W/state/claude-rc-update.$(id -u).status"
updated() { [[ ! -d "$lock" ]]; }

section "update while running → restarts on the new version"
make_claude 2.1.300; echo 2.1.300 > "$W/update-to"
tags 2.1.100 2.1.300; rc_at 2.1.200; run start >/dev/null; wait_until alive
pid1="$(pane '#{pane_pid}')"
touch "$W/update-slow"
run update >/dev/null
has   "in progress line"      "Updating Claude Code…" "$(run)"
lacks "no second update item" "param1=update" "$(run)"
rm -f "$W/update-slow"
check "job finished"          "wait_until updated || { sleep 3; updated; }"
has   "status ok"             "ok 2.1.300" "$(cat "$status_f")"
check "symlink moved"         '[[ "$(readlink "$W/bin/claude")" == *2.1.300 ]]'
check "rc restarted"          'wait_until alive && [[ "$(pane "#{pane_pid}")" != "$pid1" ]]'
lacks "update item gone"      "param1=update" "$(run)"
run stop >/dev/null

section "update while stopped → stays stopped"
install_claude 2.1.200; tags 2.1.100 2.1.300
run update >/dev/null
check "job finished"          "wait_until updated"
check "still stopped"         gone

section "update that installs nothing → fail, no restart"
install_claude 2.1.200; tags 2.1.100 2.1.300; rc_at 2.1.200; run start >/dev/null; wait_until alive
pid1="$(pane '#{pane_pid}')"
touch "$W/update-noop"
run update >/dev/null
check "job finished"          "wait_until updated"
check "status fail"           '[[ "$(cat "$status_f")" == fail ]]'
check "rc not restarted"      'alive && [[ "$(pane "#{pane_pid}")" == "$pid1" ]]'
out="$(run)"
has   "reason shown"          "Update failed: Claude Code is up to date" "$out"
has   "can retry"             "param1=update" "$out"
rm -f "$W/update-noop" "$status_f"
run stop >/dev/null

section "stopped during an update → not revived"
install_claude 2.1.200; echo 2.1.300 > "$W/update-to"; tags 2.1.100 2.1.300
run start >/dev/null; wait_until alive
touch "$W/update-slow"
run update >/dev/null
run stop >/dev/null
rm -f "$W/update-slow"
check "job finished"          "wait_until updated || { sleep 3; updated; }"
has   "update itself worked"  "ok 2.1.300" "$(cat "$status_f")"
check "still stopped"         gone

section "update failure"
install_claude 2.1.200; tags 2.1.100 2.1.300; touch "$W/update-fails"
run update >/dev/null
check "job finished"          "wait_until updated"
out="$(run)"
has   "failure line"          "Update failed: Error: boom¦pipe" "$out"
has   "opens the log"         "bash=/usr/bin/open param1=-t" "$out"
has   "failure line unsymbolized" "symbolize=false" "$(grep -F 'Update failed' <<<"$out")"
has   "can retry"             "param1=update" "$out"
rm -f "$W/update-fails"
tags 2.1.100 2.1.200                                          # nothing left to update to
check "status still fail"     '[[ "$(cat "$status_f")" == fail ]]'
lacks "no stale failure line" "Update failed" "$(run)"

section "stale lock"
mkdir -p "$lock"; touch -t 202001010000 "$lock"
out="$(run)"
lacks "stale lock ignored"    "Updating Claude Code…" "$out"
check "stale lock removed"    '[[ ! -d "$lock" ]]'
rm -f "$status_f"; tags 2.1.100 2.1.200

# --- keep awake -------------------------------------------------------------------------

awake_up() { tm list-windows -t "=$CLAUDE_RC_SESSION" -F '#{window_name}' 2>/dev/null | grep -qx awake; }
awake_cmd() { tm display-message -p -t "=$CLAUDE_RC_SESSION:=awake" '#{pane_start_command}' 2>/dev/null; }

section "keep awake"
has   "stopped: toggle off"   "param1=awake terminal=false refresh=true checked=false" "$(run)"
run awake >/dev/null
check "flag written"          '[[ -e "$W/prefs/keep-awake" ]]'
has   "toggle shows on"       "checked=true" "$(run)"
run start >/dev/null; wait_until alive; run >/dev/null
check "awake window up"       awake_up
check "caffeinate bound to rc" '[[ "$(awake_cmd)" == *"caffeinate -is -w $(pane "#{pane_pid}")"* ]]'
run restart >/dev/null; wait_until alive; run >/dev/null
check "follows the new pid"   '[[ "$(awake_cmd)" == *"-w $(pane "#{pane_pid}")"* ]]'
kill "$(pane '#{pane_pid}')"; wait_until dead
check "exits with rc"         "wait_until '! awake_up'"
run start >/dev/null; wait_until alive; run >/dev/null
run awake >/dev/null; run >/dev/null
check "toggle off kills it"   '! awake_up'
check "flag removed"          '[[ ! -e "$W/prefs/keep-awake" ]]'
run stop >/dev/null

# tmux resolves a missing `:=rc` window to the session's current pane, which
# must not pass for rc. The stand-in window isn't tied to rc's pid, so it
# outlives the rc window deterministically.
section "rc window gone, awake window left → stopped"
: > "$W/prefs/keep-awake"
run start >/dev/null; wait_until alive
tm new-window -d -n awake -t "=$CLAUDE_RC_SESSION:" "sleep 600"
tm kill-window -t "=$CLAUDE_RC_SESSION:=rc"
out="$(run)"
has   "says stopped"          "Claude RC — stopped" "$out"
lacks "not running"           "Claude RC — running" "$out"
lacks "no stop item"          "param1=stop" "$out"
run stop >/dev/null
check "stop clears the leftover" gone
rm -f "$W/prefs/keep-awake"

# Two renders at once can each create an `awake` window; `=awake` is then
# ambiguous and a kill by name removes neither.
section "duplicate awake windows → toggle off kills both"
: > "$W/prefs/keep-awake"
run start >/dev/null; wait_until alive
tm new-window -d -n awake -t "=$CLAUDE_RC_SESSION:" "sleep 600"
tm new-window -d -n awake -t "=$CLAUDE_RC_SESSION:" "sleep 600"
run awake >/dev/null; run >/dev/null
check "flag removed"          '[[ ! -e "$W/prefs/keep-awake" ]]'
check "no awake window left"  '! awake_up'
check "rc untouched"          alive
run stop >/dev/null

# --- terminal -------------------------------------------------------------------------------

section "attach label follows the terminal app"
run start >/dev/null; wait_until alive
if [[ -d /Applications/iTerm.app ]]; then want="Attach in iTerm"; else want="Attach in Terminal"; fi
has   "label"                 "$want |" "$(run)"
run stop >/dev/null

# --- summary ---------------------------------------------------------------------

renders_exit_0
check "every render's exit status was checked" '(( RENDERS >= 30 ))'
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
