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
#   red      running but logged out, or rc exited (the dead pane is kept so you
#            can read why)
#   grey     stopped, or tmux / claude isn't installed
#
# Nothing happens without a click: no auto-start, no auto-revive, no
# auto-update.
#
# REQUIRES
#   tmux (brew install tmux) and Claude Code (native install) logged in on a
#   plan that includes Remote Control. Once, in the rc folder: run `claude` to
#   trust the folder, then `claude remote-control` to answer its one-time
#   "Enable Remote Control?" question, and Ctrl-C it.
#
# SETTINGS
#   Optional, in ~/.config/claude-rc/config, which updating this file leaves
#   alone. KEY=value lines, read as text and never run:
#     RC_DIR=~/Code                                         where rc runs
#     RC_CMD=claude remote-control --permission-mode auto   what it runs
#
# Instructions, updates and design notes:
#   https://github.com/sanctibyte/swiftbar-plugins
#
# SwiftBar reads the title, version, author, description, dependencies and
# about link only with the xbar prefix; the swiftbar prefix is for its own
# options.
# <xbar.title>Claude RC</xbar.title>
# <xbar.version>1.1</xbar.version>
# <xbar.author>Sam Church</xbar.author>
# <xbar.author.github>sanctibyte</xbar.author.github>
# <xbar.desc>Runs `claude remote-control` in tmux and shows whether it is up, current and logged in.</xbar.desc>
# <xbar.dependencies>tmux,claude</xbar.dependencies>
# <xbar.about>https://github.com/sanctibyte/swiftbar-plugins</xbar.about>
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
STATE_DIR="${CLAUDE_RC_STATE_DIR:-${TMPDIR:-/tmp}}"
PREFS_DIR="${CLAUDE_RC_PREFS_DIR:-$HOME/.config/claude-rc}"
SETTINGS="${CLAUDE_RC_SETTINGS:-$HOME/.claude/settings.json}"
DIST_TAGS_URL="${CLAUDE_RC_DIST_TAGS_URL:-https://registry.npmjs.org/-/package/@anthropic-ai/claude-code/dist-tags}"
CONFIG="$PREFS_DIR/config"

# The settings file: KEY=value lines, of which only RC_DIR and RC_CMD mean
# anything. It is read as text, never sourced, so nothing in it runs when the
# menu renders. The last line for a key wins, and one pair of quotes around a
# value is dropped.
_read_config() {
  local line key val re='^[[:space:]]*(RC_DIR|RC_CMD)[[:space:]]*=(.*)$'
  [[ -r "$CONFIG" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ $re ]] || continue
    key="${BASH_REMATCH[1]}"; val="${BASH_REMATCH[2]}"
    val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
    [[ "$val" == \"*\" || "$val" == \'*\' ]] && val="${val:1:${#val}-2}"
    printf -v "cfg_$key" '%s' "$val"
  done < "$CONFIG"
}
cfg_RC_DIR=""; cfg_RC_CMD=""
_read_config

# The environment wins, then the settings file, then these defaults.
RC_DIR="${CLAUDE_RC_DIR:-${cfg_RC_DIR:-$HOME/Code}}"
[[ "$RC_DIR" == "~" || "$RC_DIR" == "~/"* ]] && RC_DIR="$HOME${RC_DIR#\~}"
RC_CMD="${CLAUDE_RC_CMD:-${cfg_RC_CMD:-claude remote-control --permission-mode auto}}"

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
ICON_GREEN="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"
ICON_AMBER="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"
ICON_RED="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"
ICON_GREY="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"

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

# The --permission-mode value in command line $1, if any.
_mode() { sed -n 's/.*--permission-mode[ =]\([A-Za-z]*\).*/\1/p' <<<"$1"; }

# $1 with a leading $HOME shown as ~, for display.
_tilde() { if [[ "$1" == "$HOME" || "$1" == "$HOME"/* ]]; then echo "~${1#"$HOME"}"; else echo "$1"; fi; }

# Shown in place of Start and Restart while RC_DIR doesn't exist. $1 = its label.
_dir_missing_lines() {
  echo "Folder not found: $1 | color=$RED"
  echo "Set RC_DIR in $(_tilde "$CONFIG") | color=$GREY"
}

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
  # Given a folder that doesn't exist, tmux would quietly start rc in $HOME
  # while the menu went on naming RC_DIR.
  [[ -d "$RC_DIR" ]] || return 1
  tmux kill-session -t "=$SESSION" 2>/dev/null   # a dead pane from last time
  # Login + interactive shell, so rc and everything it spawns get the same
  # environment as typing the command in iTerm. exec, so the pane's process is
  # rc itself. remain-on-exit goes on rc's window only, in the same tmux
  # invocation, so an exit leaves the dead pane (code + output) for the menu.
  # tmux format-expands -c (#S is the session name), hence the doubled #. The
  # window also records what rc was started with, for the menu: see
  # _started_with.
  local cmd
  cmd="$(printf '%q ' "${SHELL:-/bin/zsh}" -lic "exec $RC_CMD")"
  tmux new-session -d -s "$SESSION" -n rc -c "${RC_DIR//\#/##}" "$cmd" \; set-option -w remain-on-exit on \
    \; set-option -w @rc_dir "$RC_DIR" \; set-option -w @rc_cmd "$RC_CMD"
}

# What the running rc was started with ($1 = @rc_dir or @rc_cmd), as _start
# recorded it. Empty for an rc started by a version that didn't record it.
_started_with() { tmux show-options -wqv -t "$RC_PANE" "$1" 2>/dev/null; }

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

# Stop, then start, but only when the start can succeed: a restart that
# can't bring rc back must not stop the one that's running.
_restart() { [[ -d "$RC_DIR" ]] || return 1; _stop; _start; }

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
    [[ "$1" == 1 ]] && _rc_alive && _restart
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
  restart) _restart ;;
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

dir_label="$(_tilde "$RC_DIR" | _safe)"
dir_ok=1; [[ -d "$RC_DIR" ]] || dir_ok=""

installed="$(_installed_version)"
latest="$(_latest_version)"
update_to=""
[[ -n "$installed" && -n "$latest" ]] && _ver_lt "$installed" "$latest" && update_to="$latest"

colour=grey; auth=unknown; running_v=""; behind_installed=""
run_dir=""; run_cmd=""; settings_changed=""
case "$state" in
  running)
    running_v="$(_running_version "$pid")"
    auth="$(_logged_in)"
    run_dir="$(_started_with @rc_dir)"; run_cmd="$(_started_with @rc_cmd)"
    [[ -n "$running_v" && -n "$installed" ]] && _ver_lt "$running_v" "$installed" && behind_installed=1
    # Settings edited since the start apply on a restart. No claim for an rc
    # that didn't record them, or while a restart couldn't start it anyway.
    [[ -n "$dir_ok" && -n "$run_dir" && -n "$run_cmd" ]] \
      && [[ "$run_dir" != "$RC_DIR" || "$run_cmd" != "$RC_CMD" ]] && settings_changed=1
    colour=green
    [[ -n "$update_to" || -n "$behind_installed" || -n "$settings_changed" ]] && colour=amber
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
    # What is running, which differs from the settings until a restart.
    info="$(_tilde "${run_dir:-$RC_DIR}" | _safe)"
    mode="$(_mode "${run_cmd:-$RC_CMD}")"
    [[ -n "$mode" ]] && info+=" · $mode"
    if [[ -n "$running_v" ]]; then info+=" · v$running_v"; else info+=" · running version unknown"; fi
    echo "$info | color=$GREY"
    [[ -n "$update_to" ]]        && echo "Update available: $update_to | color=$AMBER"
    [[ -n "$behind_installed" ]] && echo "Installed $installed — restart to apply | color=$AMBER"
    [[ -n "$settings_changed" ]] && echo "Settings changed — restart to apply | color=$AMBER"
    [[ -z "$dir_ok" ]]           && _dir_missing_lines "$dir_label"
    [[ "$auth" == no ]]          && echo "Not logged in | color=$RED"
    echo "---"
    item "Attach in $(_term_app)" attach terminal
    [[ -n "$dir_ok" ]] && item "Restart" restart arrow.clockwise
    item "Stop" stop stop.fill
    echo "---"
    if [[ -n "$dir_ok" ]]; then _update_lines "Update to $update_to & restart"; else _update_lines "Update to $update_to"; fi
    _awake_line
    [[ "$auth" == no ]]   && item "Log in…" login person.crop.circle
    ;;
  exited)
    if [[ -n "$code" ]]; then why="code $code"; else why="signal ${sig:-?}"; fi
    echo "Claude RC — exited ($why) | color=$RED"
    tmux capture-pane -p -S - -t "$RC_PANE" 2>/dev/null \
      | grep -v '^[[:space:]]*$' | grep -v '^Pane is dead' | tail -3 | _safe \
      | while IFS= read -r l; do echo "$l | font=Menlo size=11 color=$GREY length=70 symbolize=false"; done
    [[ -z "$dir_ok" ]] && _dir_missing_lines "$dir_label"
    [[ "$auth" == no ]] && echo "Not logged in | color=$RED"
    echo "---"
    [[ -n "$dir_ok" ]] && item "Restart" restart arrow.clockwise
    item "Attach in $(_term_app) (full output)" attach terminal
    item "Clear" clear xmark.circle
    [[ "$auth" == no ]] && item "Log in…" login person.crop.circle
    ;;
  stopped)
    echo "Claude RC — stopped | color=$GREY"
    [[ -z "$dir_ok" ]] && _dir_missing_lines "$dir_label"
    [[ "$auth" == no ]] && echo "Not logged in | color=$RED"
    echo "---"
    if [[ -n "$dir_ok" ]]; then item "Start" start play.fill; echo "---"; fi
    _update_lines "Update to $update_to"
    _awake_line
    [[ "$auth" == no ]]   && item "Log in…" login person.crop.circle
    ;;
esac
# The branches end on `[[ … ]] && item`, which is false when the condition
# doesn't hold. SwiftBar logs any non-zero exit as a failed run.
exit 0
