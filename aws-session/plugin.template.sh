#!/bin/bash
#
# SwiftBar plugin — AWS session indicator
#
# Shows whether an `aws login` session is currently active on this Mac:
#
#   green cloud   session active
#   red cloud     session dead — time to run `aws login` again
#   grey cloud    never logged in, or the AWS CLI isn't installed
#
#   There is deliberately no "expiring soon" state. The credentials in the
#   cache last only 15 minutes and the CLI refreshes them automatically for up
#   to 12 hours, so a countdown against that timestamp would warn every quarter
#   hour and mean nothing. Green means refresh is working; red means it isn't
#   and you are locked out until you log in again.
#
# INSTALL
#   1. Get SwiftBar if you don't have it:  brew install --cask swiftbar
#      (or https://swiftbar.app). On first launch it asks you to choose a
#      plugin folder — any folder will do, e.g. ~/.config/swiftbar/plugins
#      You can see it later under SwiftBar → Preferences → Plugin Folder.
#   2. Save this file into that folder, keeping the name aws-session.5s.sh.
#      The ".5s." is the refresh interval and SwiftBar reads it from the
#      filename, so don't let a browser rename it to .txt or strip that part.
#   3. chmod +x aws-session.5s.sh
#      (SwiftBar normally does this for you, so it may already be done.)
#   4. The cloud shows up in your menu bar within a few seconds.
#
# REQUIRES
#   awscli >= 2.36, i.e. one that has `aws login`, and you need to have run
#   `aws login` at least once. Nothing else — no Python, no Homebrew packages.
#   Works on Apple Silicon and Intel.
#
# PRIVACY
#   Reads only `expiresAt` and `accountId` from ~/.aws/login/cache/*.json.
#   The credentials and refresh token in that same file are never read,
#   printed or logged.
#
# HOW IT DECIDES
#   Every tick it reads the cached expiry — instant, offline, no API calls.
#   Only once that expiry has passed does it spend one
#   `aws sts get-caller-identity` to tell "refreshable" apart from "logged
#   out", and that probe is rate limited to once a minute.
#
#   Note that probe is also what triggers the CLI's own refresh, so leaving
#   this plugin running keeps your credentials rolling. It cannot extend the
#   12-hour session cap — nothing can — it just means the cache stays warm.
#
# <swiftbar.title>AWS Session</swiftbar.title>
# <swiftbar.version>1.0</swiftbar.version>
# <swiftbar.desc>Shows whether an `aws login` session is active locally, and lets you re-authenticate.</swiftbar.desc>
# <swiftbar.dependencies>awscli</swiftbar.dependencies>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.refreshOnOpen>true</swiftbar.refreshOnOpen>

# GUI launchers give a bare PATH. Cover Homebrew on both architectures.
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# All overridable, which is also how the test fixtures drive each state.
AWS_LOGIN_CACHE_DIR="${AWS_LOGIN_CACHE_DIR:-$HOME/.aws/login/cache}"
AWS_SESSION_CONFIG="${AWS_SESSION_CONFIG:-$HOME/.aws/config}"
PROBE_STAMP="${AWS_SESSION_PROBE_STAMP:-${TMPDIR:-/tmp}/aws-session-probe.$(id -u)}"

PROBE_TTL=60      # min seconds between live probes while the cache reads stale

# Absolute path to this file, so the dropdown can call back into it.
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# --- icons (generated; see gen-icons.sh / build.sh) --------------------------
ICON_ACTIVE="__ICON_ACTIVE__"
ICON_EXPIRED="__ICON_EXPIRED__"
ICON_NONE="__ICON_NONE__"
ICON_LOGIN="__ICON_LOGIN__"

# --- reading the login cache -------------------------------------------------

# Pulls one string field out of the newest cache file. Only ever called for
# expiresAt and accountId — never for the key material alongside them.
_cache_field() {
  local file
  file="$(ls -t "$AWS_LOGIN_CACHE_DIR"/*.json 2>/dev/null | head -1)"
  [[ -n "$file" && -r "$file" ]] || return 1
  LC_ALL=C sed -n "s/.*\"$1\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$file" | head -1
}

# Epoch seconds of the cached expiry, or non-zero if there isn't one.
_expires_epoch() {
  local raw
  raw="$(_cache_field expiresAt)" || return 1
  [[ -n "$raw" ]] || return 1
  raw="${raw%%.*}"        # drop fractional seconds, if any
  raw="${raw%Z}"          # and the zone marker: the value is always UTC
  raw="${raw%+00:00}"
  TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%S" "$raw" +%s 2>/dev/null
}

# IAM principal from `login_session = <arn>` in ~/.aws/config.
_principal() {
  local arn
  arn="$(sed -n 's/^[[:space:]]*login_session[[:space:]]*=[[:space:]]*//p' \
    "$AWS_SESSION_CONFIG" 2>/dev/null | head -1)"
  [[ -n "$arn" ]] || return 1
  echo "${arn##*/}"
}

# --- live probe (rate limited) -----------------------------------------------

# "ok" or "fail". Only reached once the cached expiry has already passed.
_probe() {
  local now ts cached result
  now="$(date +%s)"
  if [[ -r "$PROBE_STAMP" ]]; then
    read -r ts cached < "$PROBE_STAMP"
    if [[ "$ts" =~ ^[0-9]+$ ]] && (( now - ts < PROBE_TTL )); then
      echo "$cached"
      return
    fi
  fi
  if aws sts get-caller-identity >/dev/null 2>&1; then result=ok; else result=fail; fi
  printf '%s %s\n' "$now" "$result" > "$PROBE_STAMP" 2>/dev/null
  echo "$result"
}

# --- the `Log in` action ------------------------------------------------------

# `aws login` hands off to a browser and can prompt, so give it a real terminal.
# iTerm if it's installed, otherwise Terminal.app, which every Mac has.
_open_login() {
  if [[ -d "/Applications/iTerm.app" ]]; then
    /usr/bin/osascript <<'OSA'
tell application "iTerm"
  activate
  set newWindow to (create window with default profile)
  tell current session of newWindow
    write text "aws login"
  end tell
end tell
OSA
  else
    /usr/bin/osascript <<'OSA'
tell application "Terminal"
  activate
  do script "aws login"
end tell
OSA
  fi
}

if [[ "${1:-}" == "login" ]]; then
  _open_login
  # Any cached "fail" is now stale — drop it so the menu bar doesn't stay red
  # for up to a minute after a successful sign-in.
  rm -f "$PROBE_STAMP"
  echo "Opening a terminal — finish the sign-in there."
  exit 0
fi

# --- state --------------------------------------------------------------------

if ! command -v aws >/dev/null 2>&1; then
  echo "| image=$ICON_NONE"
  echo "---"
  echo "AWS CLI not found | color=red"
  echo "Install the AWS CLI (2.36+), then log in with: aws login | color=#888888"
  exit 0
fi

now="$(date +%s)"
expires="$(_expires_epoch)" || expires=""

if [[ -z "$expires" ]]; then
  state=none
elif (( expires > now )); then
  state=active
elif [[ "$(_probe)" == "ok" ]]; then
  # The CLI refreshed under us via the stored refresh token.
  state=active
  refreshed=1
else
  state=expired
fi

# --- menu bar -----------------------------------------------------------------

case "$state" in
  active)  echo "| image=$ICON_ACTIVE" ;;
  expired) echo "| image=$ICON_EXPIRED" ;;
  none)    echo "| image=$ICON_NONE" ;;
esac

echo "---"

# --- dropdown -----------------------------------------------------------------

case "$state" in
  active)  echo "AWS session active | color=green" ;;
  expired) echo "AWS session expired | color=red" ;;
  none)    echo "Not logged in to AWS | color=#888888" ;;
esac

principal="$(_principal || true)"
account="$(_cache_field accountId || true)"
[[ -n "$principal" ]] && echo "${principal} | color=#888888"
[[ -n "$account" ]]   && echo "Account ${account} | color=#888888"

echo "---"

if [[ "$state" == "active" ]]; then
  echo "Log in again… | bash=\"$SELF\" param1=login terminal=false refresh=true image=$ICON_LOGIN"
else
  echo "Log in to AWS… | bash=\"$SELF\" param1=login terminal=false refresh=true image=$ICON_LOGIN"
fi
