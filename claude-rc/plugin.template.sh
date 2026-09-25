#!/bin/bash
#
# SwiftBar plugin — Claude Remote Control in tmux
#
# Runs one `claude remote-control` server in a tmux session so you can drive
# Claude Code sessions from claude.ai/code or the Claude app, and shows
# whether it is up, current, and logged in:
#
#   green    running, logged in, up to date
#   amber    running, but an update is available, or installed and not yet
#            applied (restart to pick it up)
#   red      rc exited (the dead pane is kept so you can read why), or logged out
#   grey     stopped, or tmux / claude isn't installed
#
# Nothing happens without a click: no auto-start, no auto-revive, no
# auto-update. The reasoning is in DESIGN.md in the source repository.
#
# REQUIRES
#   tmux (brew install tmux) and Claude Code (native install) logged in with a
#   plan that includes Remote Control. The rc directory must already have
#   accepted Claude's workspace trust dialog (run `claude` there once).
#
# <swiftbar.title>Claude RC</swiftbar.title>
# <swiftbar.version>1.0</swiftbar.version>
# <swiftbar.desc>Runs `claude remote-control` in tmux and shows whether it is up, current and logged in.</swiftbar.desc>
# <swiftbar.dependencies>tmux,claude</swiftbar.dependencies>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>

# GUI launchers give a bare PATH. Keep the caller's entries first, then the
# usual install locations for claude and Homebrew on both architectures.
export PATH="${CLAUDE_RC_PATH:-$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin}"
# ...and no locale. If this plugin is what starts the tmux server, the server
# and every window in it (rc, awake, ones opened by hand later) inherit this.
export LANG="${LANG:-en_US.UTF-8}"

# All overridable, which is also how test.sh drives each state.
SESSION="${CLAUDE_RC_SESSION:-claude-rc}"
RC_DIR="${CLAUDE_RC_DIR:-$HOME/Code}"
RC_CMD="${CLAUDE_RC_CMD:-claude remote-control --permission-mode auto}"
STATE_DIR="${CLAUDE_RC_STATE_DIR:-${TMPDIR:-/tmp}}"
PREFS_DIR="${CLAUDE_RC_PREFS_DIR:-$HOME/.config/claude-rc}"
SETTINGS="${CLAUDE_RC_SETTINGS:-$HOME/.claude/settings.json}"
DIST_TAGS_URL="${CLAUDE_RC_DIST_TAGS_URL:-https://registry.npmjs.org/-/package/@anthropic-ai/claude-code/dist-tags}"

STATE_DIR="${STATE_DIR%/}"
mkdir -p "$STATE_DIR" 2>/dev/null
U="$(id -u)"
LATEST_STAMP="$STATE_DIR/claude-rc-latest.$U"
AUTH_STAMP="$STATE_DIR/claude-rc-auth.$U"
UPDATE_LOCK="$STATE_DIR/claude-rc-update.$U.lock"
UPDATE_LOG="$STATE_DIR/claude-rc-update.$U.log"
UPDATE_STATUS="$STATE_DIR/claude-rc-update.$U.status"
AWAKE_FLAG="$PREFS_DIR/keep-awake"

LATEST_TTL=3600      # seconds between registry checks
LATEST_RETRY=300     # ...or this soon after a failed one
AUTH_TTL=300         # seconds between `claude auth status` calls
AUTH_RETRY=60        # ...or this soon after one that failed or timed out
AUTH_TIMEOUT="${CLAUDE_RC_AUTH_TIMEOUT:-5}"   # seconds `claude auth status` gets
STOP_WAIT=5          # seconds rc gets to exit after Ctrl-C before the kill
UPDATE_STALE_MIN=10  # an update lock older than this belongs to a dead job

GREEN="#30D158"; AMBER="#FF9F0A"; RED="#FF453A"; GREY="#8E8E93"

# `=` makes tmux match names exactly. Without it, `claude-rc` would also match
# a `claude-rc-test` session by prefix.
RC_PANE="=$SESSION:=rc"

# Absolute path to this file, so the dropdown can call back into it.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# --- icons (generated; see gen-icons.sh / build.sh) ----------------------------
ICON_GREEN="__ICON_GREEN__"
ICON_AMBER="__ICON_AMBER__"
ICON_RED="__ICON_RED__"
ICON_GREY="__ICON_GREY__"

# --- helpers ---------------------------------------------------------------------

# Text we didn't write ourselves: strip ANSI colour codes, neutralise |, which
# SwiftBar reads as the start of the line's parameters, and swap a leading -
# for − (U+2212), since SwiftBar reads `--` as a submenu and `---` as a
# separator. Lines carrying it also get symbolize=false, so `:name:` stays text.
_safe() { LC_ALL=C sed -e $'s/\x1b\\[[0-9;?]*[A-Za-z]//g' -e 's/|/¦/g' -e 's/^-/−/'; }

# Echoes $1 back only if it is a plain X.Y.Z version.
_semver() { [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$1"; }

# True if version $1 sorts before $2. Both must already be X.Y.Z.
_ver_lt() {
  local a1 a2 a3 b1 b2 b3
  IFS=. read -r a1 a2 a3 <<<"$1"
  IFS=. read -r b1 b2 b3 <<<"$2"
  (( a1 != b1 )) && { (( a1 < b1 )); return; }
  (( a2 != b2 )) && { (( a2 < b2 )); return; }
  (( a3 < b3 ))
}

# "2h 14m" style age for a number of seconds.
_age() {
  local s=$1
  if   (( s >= 86400 )); then echo "$(( s / 86400 ))d $(( s % 86400 / 3600 ))h"
  elif (( s >= 3600 ));  then echo "$(( s / 3600 ))h $(( s % 3600 / 60 ))m"
  elif (( s >= 60 ));    then echo "$(( s / 60 ))m"
  else echo "<1m"
  fi
}

_hex() { case "$1" in green) echo "$GREEN" ;; amber) echo "$AMBER" ;; red) echo "$RED" ;; *) echo "$GREY" ;; esac; }

# A dropdown item that calls back into this plugin.
item() { echo "$1 | bash=\"$SELF\" param1=$2 terminal=false refresh=true sfimage=$3"; }

# --- the rc pane -------------------------------------------------------------------

# One tmux round trip: "dead|exit code|signal|pid|created", or nothing when
# there is no rc window. display-message doesn't fail on a missing target: with
# no such session it prints empty fields, and with a session but no rc window
# it describes the session's current pane (e.g. caffeinate in `awake`). So the
# window name comes back too, and anything but `rc` counts as no rc.
_rc_status() {
  local st
  st="$(tmux display-message -p -t "$RC_PANE" \
    '#{window_name}|#{pane_dead}|#{pane_dead_status}|#{pane_dead_signal}|#{pane_pid}|#{session_created}' 2>/dev/null)"
  [[ "$st" == 'rc|'* ]] && echo "${st#rc|}"
}

_rc_alive() { local st; st="$(_rc_status)"; [[ -n "$st" && "${st%%|*}" == 0 ]]; }

_start() {
  _rc_alive && return 0
  tmux kill-session -t "=$SESSION" 2>/dev/null   # a dead pane from last time
  # Login + interactive shell, so rc and everything it spawns get the same
  # environment as typing the command in iTerm. exec, so the pane's process is
  # rc itself. remain-on-exit goes on rc's window only, in the same tmux
  # invocation, so an exit leaves the dead pane (code + output) for the menu.
  local cmd
  cmd="$(printf '%q ' "${SHELL:-/bin/zsh}" -lic "exec $RC_CMD")"
  tmux new-session -d -s "$SESSION" -n rc -c "$RC_DIR" "$cmd" \; set-option -w remain-on-exit on
}

# Ctrl-C first so rc can deregister cleanly; kill the session regardless.
# In copy mode (someone scrolled back while attached) Ctrl-C would only leave
# copy mode, so cancel that first; outside copy mode the cancel just errors.
_stop() {
  local i
  if _rc_alive; then
    tmux send-keys -t "$RC_PANE" -X cancel 2>/dev/null
    tmux send-keys -t "$RC_PANE" C-c
    for (( i = 0; i < STOP_WAIT * 5; i++ )); do
      _rc_alive || break
      sleep 0.2
    done
  fi
  tmux kill-session -t "=$SESSION" 2>/dev/null
  return 0
}

# --- versions & auth -----------------------------------------------------------------

# The native installer links `claude` to ~/.local/share/claude/versions/<X.Y.Z>.
_installed_version() {
  local p
  p="$(command -v claude)" || return 1
  [[ -L "$p" ]] && p="$(readlink "$p")"
  _semver "${p##*/}"
}

# What the rc process is actually executing, which stays put when an update
# lands on disk.
_running_version() {
  local p
  p="$(lsof -b -w -a -p "$1" -d txt -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
  _semver "${p##*/}"
}

_channel() {
  local c
  c="$(sed -n 's/.*"autoUpdatesChannel"[[:space:]]*:[[:space:]]*"\([a-z]*\)".*/\1/p' "$SETTINGS" 2>/dev/null | head -1)"
  echo "${c:-latest}"
}

# Latest release on the configured channel, from npm's dist-tags. Stamp is
# "<epoch> <channel> <version|->", cached an hour. A failed fetch keeps the last
# known version and retries in LATEST_RETRY instead of every tick.
_latest_version() {
  local channel now ts="" ch="" v="" fetched
  channel="$(_channel)"
  now="$(date +%s)"
  [[ -r "$LATEST_STAMP" ]] && read -r ts ch v < "$LATEST_STAMP"
  if [[ "$ts" =~ ^[0-9]+$ && "$ch" == "$channel" ]] && (( now - ts < LATEST_TTL )); then
    _semver "$v"; return
  fi
  fetched="$(curl -fsS --max-time 3 "$DIST_TAGS_URL" 2>/dev/null \
    | sed -n "s/.*\"$channel\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p")"
  if fetched="$(_semver "$fetched")"; then
    printf '%s %s %s\n' "$now" "$channel" "$fetched" > "$LATEST_STAMP"
    echo "$fetched"
  else
    [[ "$ch" == "$channel" ]] || v=""
    printf '%s %s %s\n' "$(( now - LATEST_TTL + LATEST_RETRY ))" "$channel" "${v:--}" > "$LATEST_STAMP"
    _semver "$v"
  fi
}

# `claude auth status --json`, killed after AUTH_TIMEOUT seconds so a hung
# check can't stall the render. perl's alarm survives the exec.
_auth_status() {
  if [[ -x /usr/bin/perl ]]; then
    /usr/bin/perl -e 'alarm shift; exec @ARGV' "$AUTH_TIMEOUT" claude auth status --json
  else
    claude auth status --json
  fi
}

# yes | no | unknown from `claude auth status`, cached AUTH_TTL. A check that
# times out or returns something unreadable keeps the last answer (unknown if
# there is none) and retries in AUTH_RETRY, so a hiccup can't turn red green.
# The login action's typed command deletes the stamp once login succeeds.
_logged_in() {
  local now ts="" r="" out tmp="$AUTH_STAMP.$$"
  now="$(date +%s)"
  [[ -r "$AUTH_STAMP" ]] && read -r ts r < "$AUTH_STAMP"
  if [[ "$ts" =~ ^[0-9]+$ && -n "$r" ]] && (( now - ts < AUTH_TTL )); then
    echo "$r"; return
  fi
  # Via a file, not $(…): a child of the killed check that still holds the
  # pipe would keep $(…) waiting for EOF long after the watchdog fired.
  _auth_status >"$tmp" 2>/dev/null
  out="$(cat "$tmp" 2>/dev/null)"; rm -f "$tmp"
  if   grep -Eq '"loggedIn"[[:space:]]*:[[:space:]]*true'  <<<"$out"; then r=yes
  elif grep -Eq '"loggedIn"[[:space:]]*:[[:space:]]*false' <<<"$out"; then r=no
  else
    [[ "$r" == yes || "$r" == no ]] || r=unknown
    printf '%s %s\n' "$(( now - AUTH_TTL + AUTH_RETRY ))" "$r" > "$AUTH_STAMP"
    echo "$r"; return
  fi
  printf '%s %s\n' "$now" "$r" > "$AUTH_STAMP"
  echo "$r"
}

# --- update -------------------------------------------------------------------------

# True while an update job holds the lock. A lock older than UPDATE_STALE_MIN
# belongs to a job that died, so clear it rather than show "Updating…" forever.
_updating() {
  [[ -d "$UPDATE_LOCK" ]] || return 1
  if [[ -n "$(find "$UPDATE_LOCK" -maxdepth 0 -mmin +"$UPDATE_STALE_MIN" 2>/dev/null)" ]]; then
    rmdir "$UPDATE_LOCK" 2>/dev/null
    return 1
  fi
}

_update_spawn() {
  _updating && return 0
  mkdir "$UPDATE_LOCK" 2>/dev/null || return 0     # one at a time
  local restart=0
  _rc_alive && restart=1
  # Detached with every fd closed, so SwiftBar isn't left waiting on it.
  nohup "$SELF" update-job "$restart" </dev/null >/dev/null 2>&1 &
  disown
}

# `claude update` can exit 0 without installing anything (already current on
# its channel), so success means the installed version actually moved. Then
# rc restarts only if it was running when the update was clicked and still is:
# a Stop or a crash in the meantime must not be undone.
_update_job() {  # $1 = 1 if rc was running when the update was clicked
  local before after
  before="$(_installed_version)"
  if claude update >"$UPDATE_LOG" 2>&1 && after="$(_installed_version)" && [[ "$after" != "$before" ]]; then
    echo "ok $after" > "$UPDATE_STATUS"
    [[ "$1" == 1 ]] && _rc_alive && { _stop; _start; }
  else
    echo "fail" > "$UPDATE_STATUS"
  fi
  rmdir "$UPDATE_LOCK" 2>/dev/null
}

# The update item, or the in-progress / failed line in its place. $1 = label.
# A failure is only worth showing while there is still an update to retry.
_update_lines() {
  if _updating; then
    echo "Updating Claude Code… | color=$GREY sfimage=arrow.down.circle"
    return
  fi
  local st="" last
  [[ -r "$UPDATE_STATUS" ]] && read -r st _ < "$UPDATE_STATUS"
  if [[ "$st" == fail && -n "$update_to" ]]; then
    last="$(grep -v '^[[:space:]]*$' "$UPDATE_LOG" 2>/dev/null | tail -1 | _safe)"
    echo "Update failed: ${last:-see log} | color=$RED symbolize=false length=70 bash=/usr/bin/open param1=-t param2=\"$UPDATE_LOG\" terminal=false sfimage=exclamationmark.triangle"
  fi
  [[ -n "$update_to" ]] && item "$1" update arrow.down.circle
}

# --- keep awake -----------------------------------------------------------------------

_awake_on() { [[ -e "$AWAKE_FLAG" ]]; }

# IDs of every window named exactly `awake`. Usually one, but two renders at
# once can each create one, and then `=awake` is ambiguous as a target.
_awake_windows() {
  tmux list-windows -t "=$SESSION" -F '#{window_name}|#{window_id}' 2>/dev/null | sed -n 's/^awake|//p'
}

_awake_window_up() { [[ -n "$(_awake_windows)" ]]; }

# Makes the `awake` window match the preference. $1 = rc pid when running,
# empty otherwise. caffeinate -w ends with rc, and this window has no
# remain-on-exit, so a crash cleans it up too. Living in the session means
# kill-session takes it along: no orphans.
_reconcile_awake() {
  local w
  if [[ -n "$1" ]] && _awake_on; then
    _awake_window_up || tmux new-window -d -n awake -t "=$SESSION:" "caffeinate -is -w $1"
  else
    for w in $(_awake_windows); do tmux kill-window -t "$w" 2>/dev/null; done
  fi
}

_awake_line() {
  local checked=false
  _awake_on && checked=true
  echo "Keep Mac awake while running | bash=\"$SELF\" param1=awake terminal=false refresh=true checked=$checked"
}

# --- terminal -------------------------------------------------------------------------

_term_app() { if [[ -d /Applications/iTerm.app ]]; then echo iTerm; else echo Terminal; fi; }

# Opens a new terminal window running $1: iTerm if installed, else Terminal.
# The command travels as an argv item, never spliced into AppleScript source.
_open_terminal() {
  if [[ "$(_term_app)" == iTerm ]]; then
    /usr/bin/osascript - "$1" >/dev/null <<'OSA'
on run argv
  tell application "iTerm"
    activate
    set w to (create window with default profile)
    tell current session of w to write text (item 1 of argv)
  end tell
end run
OSA
  else
    /usr/bin/osascript - "$1" >/dev/null <<'OSA'
on run argv
  tell application "Terminal"
    activate
    do script (item 1 of argv)
  end tell
end run
OSA
  fi
}

# --- actions -------------------------------------------------------------------------

case "${1:-}" in
  "")      ;;
  start)   _start ;;
  stop)    _stop ;;
  restart) _stop; _start ;;
  clear)   tmux kill-session -t "=$SESSION" 2>/dev/null ;;
  update)     _update_spawn ;;
  update-job) _update_job "${2:-0}" ;;
  awake)      mkdir -p "$PREFS_DIR"
              if _awake_on; then rm -f "$AWAKE_FLAG"; else : > "$AWAKE_FLAG"; fi ;;
  attach)     _open_terminal "$(printf '%q' "$(command -v tmux)") attach -t '=$SESSION'" ;;
  login)      _open_terminal "$(printf '%q' "$(command -v claude)") auth login && rm -f $(printf '%q' "$AUTH_STAMP")" ;;
  *)       echo "unknown action: $1" >&2; exit 2 ;;
esac
[[ -n "${1:-}" ]] && exit 0

# --- render --------------------------------------------------------------------------

if ! command -v tmux >/dev/null 2>&1; then
  echo "| image=$ICON_GREY"; echo "---"
  echo "tmux not installed | color=$RED"
  echo "Install it with: brew install tmux | color=$GREY"
  exit 0
fi
if ! command -v claude >/dev/null 2>&1; then
  echo "| image=$ICON_GREY"; echo "---"
  echo "claude not found | color=$RED"
  echo "Install Claude Code, then this menu will pick it up | color=$GREY"
  exit 0
fi

IFS='|' read -r dead code sig pid created <<<"$(_rc_status)"
if   [[ -z "$dead" ]];     then state=stopped
elif [[ "$dead" == 1 ]];   then state=exited
else                            state=running
fi

dir_label="$RC_DIR"
[[ "$RC_DIR" == "$HOME" || "$RC_DIR" == "$HOME"/* ]] && dir_label="~${RC_DIR#"$HOME"}"
mode="$(sed -n 's/.*--permission-mode[ =]\([A-Za-z]*\).*/\1/p' <<<"$RC_CMD")"

installed="$(_installed_version)"
latest="$(_latest_version)"
update_to=""
[[ -n "$installed" && -n "$latest" ]] && _ver_lt "$installed" "$latest" && update_to="$latest"

colour=grey; auth=unknown; running_v=""; behind_installed=""
case "$state" in
  running)
    running_v="$(_running_version "$pid")"
    auth="$(_logged_in)"
    [[ -n "$running_v" && -n "$installed" ]] && _ver_lt "$running_v" "$installed" && behind_installed=1
    colour=green
    [[ -n "$update_to" || -n "$behind_installed" ]] && colour=amber
    [[ "$auth" == no ]] && colour=red
    _reconcile_awake "$pid"
    ;;
  exited)
    colour=red
    auth="$(_logged_in)"
    _reconcile_awake ""
    ;;
  stopped)
    auth="$(_logged_in)"
    ;;
esac

case "$colour" in
  green) echo "| image=$ICON_GREEN" ;;
  amber) echo "| image=$ICON_AMBER" ;;
  red)   echo "| image=$ICON_RED" ;;
  *)     echo "| image=$ICON_GREY" ;;
esac
echo "---"

case "$state" in
  running)
    echo "Claude RC — running · $(_age $(( $(date +%s) - created ))) | color=$(_hex "$colour")"
    info="$dir_label"
    [[ -n "$mode" ]] && info+=" · $mode"
    if [[ -n "$running_v" ]]; then info+=" · v$running_v"; else info+=" · running version unknown"; fi
    echo "$info | color=$GREY"
    [[ -n "$update_to" ]]        && echo "Update available: $update_to | color=$AMBER"
    [[ -n "$behind_installed" ]] && echo "Installed $installed — restart to apply | color=$AMBER"
    [[ "$auth" == no ]]          && echo "Not logged in | color=$RED"
    echo "---"
    item "Attach in $(_term_app)" attach terminal
    item "Restart" restart arrow.clockwise
    item "Stop" stop stop.fill
    echo "---"
    _update_lines "Update to $update_to & restart"
    _awake_line
    [[ "$auth" == no ]]   && item "Log in…" login person.crop.circle
    ;;
  exited)
    if [[ -n "$code" ]]; then why="code $code"; else why="signal ${sig:-?}"; fi
    echo "Claude RC — exited ($why) | color=$RED"
    tmux capture-pane -p -S - -t "$RC_PANE" 2>/dev/null \
      | grep -v '^[[:space:]]*$' | grep -v '^Pane is dead' | tail -3 | _safe \
      | while IFS= read -r l; do echo "$l | font=Menlo size=11 color=$GREY length=70 symbolize=false"; done
    [[ "$auth" == no ]] && echo "Not logged in | color=$RED"
    echo "---"
    item "Restart" restart arrow.clockwise
    item "Attach in $(_term_app) (full output)" attach terminal
    item "Clear" clear xmark.circle
    [[ "$auth" == no ]] && item "Log in…" login person.crop.circle
    ;;
  stopped)
    echo "Claude RC — stopped | color=$GREY"
    [[ "$auth" == no ]] && echo "Not logged in | color=$RED"
    echo "---"
    item "Start" start play.fill
    echo "---"
    _update_lines "Update to $update_to"
    _awake_line
    [[ "$auth" == no ]]   && item "Log in…" login person.crop.circle
    ;;
esac
# The branches end on `[[ … ]] && item`, which is false when the condition
# doesn't hold. SwiftBar logs any non-zero exit as a failed run.
exit 0
