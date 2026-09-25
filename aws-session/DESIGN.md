# AWS session indicator (SwiftBar)

A menu bar light for "am I currently logged in to AWS?". Sibling of the
[claude-rc](../claude-rc) plugin.

## Where the state lives

`aws login` (AWS CLI >= 2.36) caches a browser-console session at
`~/.aws/login/cache/<hash>.json`:

```
accessToken: { accessKeyId, secretAccessKey, sessionToken, accountId, expiresAt }
tokenType, refreshToken, clientId, dpopKey
```

We read **only** `expiresAt` and `accountId`. The key material and the refresh
token are never read, printed or logged. This is a hard rule, not a side effect
of what the plugin happens to need.

`~/.aws/config` holds `login_session = <IAM user ARN>`, which gives the
principal name for the dropdown.

## What the timestamps actually mean

`aws login` credentials last **15 minutes**. The CLI refreshes them
automatically, lazily (on next use), for up to a **12-hour** cap set by the IAM
principal's session duration; past that you must log in again. Nothing on disk
records when the session started — the cache file is rewritten in place, so
even its birth time survives across logins.

So `expiresAt` is a rolling implementation detail, not a deadline. An earlier
version warned at 10 minutes against it, which meant amber for two-thirds of
every 15-minute cycle: a countdown to an event that never happens.

## State machine

There is deliberately **no "expiring soon" state**. Colour reports only what
the CLI actually did, never a projection.

| State | Decided by | Colour |
|---|---|---|
| `none` | no readable file in `~/.aws/login/cache/` | grey `#8E8E93` |
| `active` | `expiresAt` in the future, **or** the probe succeeds | green `#30D158` |
| `expired` | `expiresAt` passed **and** the live probe failed | red `#FF453A` |

Hybrid detection: the offline `expiresAt` read runs every tick (instant, no
network). Only when it says expired does the plugin run one
`aws sts get-caller-identity`. Success means the CLI silently refreshed via the
`refreshToken`, so the true state is `active` — and because that refresh
rewrites the cache file with a new `expiresAt`, the next tick reaches `active`
from the offline read alone. Failure means genuinely logged out.

The probe is throttled by a stamp file (60s TTL) so the logged-out case does
not spawn `aws` every 5 seconds.

The probe is not a passive observation: calling the CLI is what triggers its
refresh. A running plugin therefore keeps credentials rolling roughly every 15
minutes. That cannot extend the 12-hour cap, but it does mean the plugin is a
participant in the refresh cycle, not just a witness to it.

## Layout

The shipped artifact is a **single self-contained file**, so it can be
downloaded and dropped into a plugin folder with no installer and no support
directory. The template is
the canonical source; the installed plugin is a build output.

```
plugin.template.sh        canonical source, __ICON_*__ placeholders
gen-icons.sh              rsvg-convert icon renderer
build.sh                  icons + template -> dist/ (--install to deploy)
dist/aws-session.5s.sh    the distributable, committed so it can be downloaded as-is
icons/…                   PNG sources for the build (generated, not committed)
```

Run `./build.sh --install` after editing the template — editing the installed
plugin directly means the next build overwrites the change.

The README's icon pictures, `../docs/aws-session-*.png`, are copies of
`icons/menubar/*.png`. Copy them again if the glyph changes.

## Portability

Everything the plugin needs is on a stock Mac plus the AWS CLI:

- No `python3`: `sed` extracts `expiresAt`, `TZ=UTC date -j -f` converts it.
  (`python3` is used only by `build.sh`, on the author's machine.)
- PATH covers `/opt/homebrew/bin` and `/usr/local/bin`, so Intel Macs work.
- `Log in` opens iTerm when installed, else Terminal.app.
- The probe stamp lives in `$TMPDIR`, not in a directory the plugin has to
  create on someone else's machine.
- `aws` missing entirely reports "AWS CLI not found" rather than a misleading
  grey "not logged in".

There is deliberately no AWS CLI version check for `aws login` (needs >= 2.36):
it would cost a ~0.25s `aws --version` on a hot path, and an older CLI reveals
itself the moment someone clicks Log in.

There is **no update path**: an installed copy stays as it is until you
replace it with a newer `dist/aws-session.5s.sh`.

## Dropdown

```
AWS session active             | expired | Not logged in to AWS
my-iam-user                    ← principal, shown in every state
Account 123456789012           ← omitted when there is no cache file
---
Log in to AWS…                 ← "Log in again…" when already active
```

Status, identity, one action. No timestamps: the only one available is the
rolling 15-minute expiry, and showing it invites reading it as a deadline. No
"Refresh now" either — the plugin re-runs every 5 seconds and `refreshOnOpen`
covers opening the menu, so the item was pure decoration.

`Log in` opens an iTerm window running `aws login` so the browser handoff and
any prompts get a real TTY.

## Testability

`AWS_LOGIN_CACHE_DIR`, `AWS_SESSION_CONFIG` and `AWS_SESSION_PROBE_STAMP` are
overridable, so every state can be driven from fixture files without touching
the real session. Seeding the stamp file forces a probe result, which is what
separates `expired` from the refreshed case; note the stamp goes stale after
`PROBE_TTL`, so write it immediately before each run.

The AWS-CLI-not-found branch can't be tested by stripping PATH from outside —
the plugin prepends the Homebrew directories itself. Test it against a copy
whose `export PATH=` line has been rewritten.
