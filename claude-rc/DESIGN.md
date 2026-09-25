# Claude Remote Control indicator (SwiftBar)

A menu bar light and control panel for one long-lived `claude remote-control`
server running in tmux, so sessions can be driven from claude.ai/code or the
Claude mobile app while the terminal that started it is long gone. Sibling of
the [aws-session](../aws-session) plugin, and built the same way.

## What it manages

Exactly one server:

- tmux session `claude-rc`, on the default tmux socket (so a plain
  `tmux attach -t claude-rc` works by hand too)
- working directory `~/Code` by default
- command `claude remote-control --permission-mode auto`, default spawn mode
  (`same-dir`). Worktree mode needs a git repo, so it's unavailable
  when the rc directory isn't one.

Both come from, in order: the environment (`CLAUDE_RC_DIR`, `CLAUDE_RC_CMD`,
which is how test.sh drives the plugin), the settings file
`~/.config/claude-rc/config` (`RC_DIR=`, `RC_CMD=`), then the defaults above.
The settings file lives outside the plugin, so installing a new copy doesn't
wipe it. It is read line by line as text, never sourced, so a stray line can't
run anything at render time. Only `RC_DIR` and `RC_CMD` are looked at, the
last one wins, one pair of quotes around a value is dropped, and a leading `~`
in `RC_DIR` is expanded.

If `RC_DIR` isn't a directory, the plugin won't start rc. Given a `-c`
directory that doesn't exist, tmux quietly starts the pane in `$HOME` instead,
so rc would run somewhere other than the menu says, or exit with a trust error
that names neither (Claude never saves trust for the home folder). Every menu
says "Folder not found" and where to set `RC_DIR`, in place of Start and
Restart, and the start action itself refuses. Restart, including the one after
an update, checks the folder before stopping anything, so a restart that
couldn't bring rc back leaves the running one alone. tmux also format-expands
`-c` (`#S` is the session name), so the plugin doubles any `#` in `RC_DIR`.

The settings can change while rc runs, and only take effect on a restart. So
`_start` records what it started with on the rc window, as the user options
`@rc_dir` and `@rc_cmd`, in the same tmux call. The running menu describes
those rather than the current settings, and says "Settings changed — restart
to apply" (amber) when they differ. An rc started before the plugin recorded
them has neither option, and the menu then shows the current settings and
makes no claim.

The command runs as `$SHELL -lic 'exec claude remote-control …'`. SwiftBar
hands plugins a bare environment, and anything the rc server spawns inherits
whatever the server had. Going through a login + interactive shell gives it
the same environment as typing `claude rc` in iTerm. `exec` makes the claude
process replace the shell, so the pane's process *is* the rc server.

Right after `new-session`, in the same tmux invocation, the plugin sets
`remain-on-exit on` for that window. When rc exits, the pane stays around,
dead, with its exit status and its last output. That is the whole mechanism
for telling **stopped** (no session) apart from **exited** (session with a
dead pane).

## State machine

| State | Decided by | Menu bar |
|---|---|---|
| `missing` | `tmux` or `claude` not on PATH | grey |
| `stopped` | no `claude-rc` tmux session, or no `rc` window in it | grey |
| `exited` | `rc` window exists, `#{pane_dead}` = 1 | red |
| `running` | `rc` pane alive | green, or amber (below) |

`display-message -t "=claude-rc:=rc"` doesn't fail when the `rc` window is
missing. It describes the session's current pane instead (for example
caffeinate in `awake`), so the plugin also reads `#{window_name}` and treats
anything other than `rc` as "no rc".

`running` is shown **amber** instead of green when any of these holds:

- the *installed* version is behind the latest release on the configured
  channel (an update would download something)
- the running version is behind the installed version (someone updated on
  disk; a restart would pick it up)
- the settings differ from what rc was started with (a restart would apply
  them). There's no claim while `RC_DIR` is missing, since a restart couldn't
  start rc then.

The version conditions are also what the dropdown keys on. "Update available"
and the Update item appear when installed < latest. "Installed … — restart to
apply" appears when running < installed. Comparing *installed* against latest,
rather than running, means the Update item never appears when all it would do
is restart.

`running` is shown **red** when `claude auth status` says `loggedIn: false`.
The server is up but can't do anything useful, which is the same outcome as
`exited` from the user's point of view. The stopped and exited menus run the
same check, to offer "Log in…".

Colour reports observed facts only: process alive or dead, version
comparisons, and what the auth check actually returned. There is no guessing
about token lifetimes.

## Inputs, and what each costs

| Fact | Source | Cost | Cache |
|---|---|---|---|
| rc window present / pane dead / exit status / pid / created | one `tmux display-message -p`, with `#{window_name}` | ~5 ms | none |
| last output lines (exited only) | `tmux capture-pane -p` | ~5 ms | none |
| running version | resolved binary of the pane pid (`lsof -b -w -d txt`, so a stale mount can't block it), basename under `~/.local/share/claude/versions/` | ~50 ms | none |
| installed version | `readlink` of the `claude` on PATH, basename | ~1 ms | none |
| channel | `autoUpdatesChannel` in `~/.claude/settings.json`, default `latest` | ~1 ms | none |
| latest version | `https://registry.npmjs.org/-/package/@anthropic-ai/claude-code/dist-tags`, field = channel, 3 s curl limit | network | 1 h, `$TMPDIR` stamp |
| logged in | `claude auth status --json`, `loggedIn`, killed after 5 s | ~330 ms | 5 min, `$TMPDIR` stamp |
| folder and command rc started with (running only) | `tmux show-options -wqv` of the rc window's `@rc_dir` and `@rc_cmd` | ~5 ms each | none |

A failed check never replaces a good answer, and it backs off instead of
retrying on every tick:

- **latest version**: a failed or unparseable fetch keeps the last known
  version (for the same channel) and is retried in 5 minutes rather than 1
  hour. When the network is down, the menu doesn't flip to "unknown".
- **logged in**: the call runs under a `perl` alarm watchdog
  (`CLAUDE_RC_AUTH_TIMEOUT`, default 5 s; without `/usr/bin/perl` it runs
  unguarded). Its output goes through a file rather than `$(…)`, because a
  child of a killed check that still holds the pipe would keep the render
  waiting. A timeout or an unreadable answer keeps the previous answer
  (`unknown` if there is none) and is retried in 1 minute rather than 5. A
  hiccup therefore can't turn red into green. `unknown` never colours
  anything.

The auth stamp is deleted by the `login` action, so the red state clears on
the next refresh after signing in instead of waiting up to 5 minutes.

The two cached checks run on their own TTLs, so a menu open rarely pays for
both at once. The usual worst case per tick is one ~330 ms auth call, once
every 5 minutes. A hung auth call costs at most the 5 s timeout, once a
minute.

If the running version can't be resolved (non-native install, `lsof` refuses),
the version line says "running version unknown" and the version-based amber
check is skipped. It never guesses.

## Dropdown

```
running:
  Claude RC — running · 2h 14m                  green / amber / red
  ~/Code · auto · v2.1.222                      what rc runs with, not the settings
  Update available: 2.1.282                     only when installed < latest
  Installed 2.1.282 — restart to apply          only when running < installed
  Settings changed — restart to apply           only when they differ from @rc_*
  Folder not found: ~/Code                      only when RC_DIR is missing
  Set RC_DIR in ~/.config/claude-rc/config        (same condition)
  Not logged in                                 only when loggedIn=false
  ---
  Attach in iTerm
  Restart                                       only when RC_DIR exists
  Stop
  ---
  Update to 2.1.282 & restart                   only when installed < latest
                                                  (no "& restart" while RC_DIR
                                                  is missing)
  ✓ Keep Mac awake while running
  Log in…                                       only when loggedIn=false

exited:
  Claude RC — exited (code 1)                   red
  <last 3 non-blank output lines, monospace, grey>
  Folder not found: ~/Code                      only when RC_DIR is missing
  Set RC_DIR in ~/.config/claude-rc/config        (same condition)
  Not logged in                                 only when loggedIn=false
  ---
  Restart                                       only when RC_DIR exists
  Attach in iTerm (full output)
  Clear                                         kills the dead session → stopped
  Log in…                                       only when loggedIn=false

stopped:
  Claude RC — stopped                           grey
  Folder not found: ~/Code                      only when RC_DIR is missing
  Set RC_DIR in ~/.config/claude-rc/config        (same condition)
  Not logged in                                 only when loggedIn=false
  ---
  Start                                         only when RC_DIR exists,
  ---                                             with this separator
  Update to 2.1.282                             only when installed < latest
  ✓ Keep Mac awake while running
  Log in…                                       only when loggedIn=false

missing:
  tmux not installed — brew install tmux        (or claude not found)
```

Any text copied from outside the plugin (pane output, update log lines) goes
through `_safe`, which strips ANSI colour codes and makes these changes:

- `|` becomes `¦`. SwiftBar treats `|` as the start of a line's parameters,
  so a raw `|` would cut the text off and turn the rest into garbage
  parameters.
- A leading `-` becomes `−` (U+2212). SwiftBar reads a line starting with
  `--` as a submenu item, and `---` as a separator.

Those lines also carry `symbolize=false`, so `:name:` in the text stays text.

While an update is running, the update item is replaced by a disabled
`Updating Claude Code…` line. If the last update failed, a red
`Update failed: <last log line>` line appears next to the update item, for as
long as there is still an update to retry. A successful update clears it,
and so does the installed version catching up by some other route.

Every render exits 0. The branches end on `[[ … ]] && item …`, and SwiftBar
logs any non-zero exit as "Failed to execute script".

Action icons are SF Symbols (`sfimage=`, SwiftBar ≥ 2.0). Only the menu bar
glyph is a generated PNG. Custom tile icons, as aws-session uses, would mean
seven of them for seven actions, and SF Symbols already match the system menu.

## Actions

Every action is the plugin calling itself (`bash="$SELF" param1=<action>`),
so the installed plugin is one self-contained file.

- **start**: `tmux new-session -d -s claude-rc -c ~/Code "<cmd>" \;
  set-option -w remain-on-exit on \; set-option -w @rc_dir … \;
  set-option -w @rc_cmd …`, with any `#` in the folder doubled. It's a no-op
  if the session exists and is alive, and refuses if `RC_DIR` isn't a
  directory. If a dead session is lying around, it is killed first.
- **stop**: `send-keys -X cancel` (leaves copy mode if someone scrolled back
  while attached, where Ctrl-C would only exit copy mode), then
  `send-keys C-c`. Then it polls up to ~5 s for the pane to die, so rc gets
  to deregister cleanly, and runs `kill-session` regardless.
- **restart**: stop, then start, but only if `RC_DIR` exists. Otherwise it
  does nothing, rather than stop an rc it couldn't bring back.
- **clear**: `kill-session`, unconditionally. The menu only offers it on a
  dead session, but the action doesn't check the state.
- **attach**: new iTerm window running `tmux attach -t '=claude-rc'`, or
  Terminal.app if iTerm isn't installed (same fallback as aws-session).
- **login**: new iTerm/Terminal window running
  `claude auth login && rm -f <auth stamp>`. The stamp is dropped only once
  login succeeds. Dropping it at click time would let the next refresh re-cache
  "logged out" for 5 minutes while you're still in the browser.
- **update**: a detached background job (stdin/stdout/stderr closed, so
  SwiftBar isn't left waiting on it) that runs `claude update`, logging to
  `$TMPDIR/claude-rc-update.<uid>.log`. A lock directory marks "in progress".
  Success means the installed version actually changed. `claude update` can
  exit 0 without installing anything (already current on its channel), and
  that counts as a failure: rc is not restarted, and the log's last line is
  shown as the reason. After a real change, rc is restarted only if it was
  running when the update was clicked *and* is still running, through the
  same restart as above, so not while `RC_DIR` is missing. A Stop, or a
  crash, while the update runs is not undone. The final status
  (`ok <version>` or `fail`) goes to a status file that the dropdown reads. A
  lock older than 10 minutes is treated as stale (the job died), so the
  plugin can't get stuck on "Updating…". Clicking the "Update failed" line
  opens the log.
- **awake**: toggles the preference file (below). The action itself doesn't
  touch tmux. The `awake` window is reconciled by the render that follows it
  (the item has `refresh=true`), so the change takes effect on that refresh.

Updates never happen without a click. There is no automatic update, and no
automatic restart after a crash: if rc dies, it stays dead (red) until you
choose Restart. That keeps the plugin predictable and rules out respawn loops.

## Keep awake

Preference: the existence of `~/.config/claude-rc/keep-awake`. It survives
reboots and defaults to off.

When it's on and rc is running, the plugin makes sure a second tmux window
named `awake` exists in the `claude-rc` session, running
`caffeinate -is -w <rc pid>`. This is reconciled on every tick, so it
survives restarts (the new rc pid gets a new caffeinate). Hosting it in tmux
rather than as a stray background process means:

- it dies with `kill-session`, so there are no orphans
- `-w` ends it the moment rc exits, even when the dead pane lingers
- `remain-on-exit` is a per-window option set only on rc's window, so the
  `awake` window vanishes when caffeinate ends instead of leaving a corpse

Turning it off kills every window named `awake`, by window id. Two renders
at once can each create one, and then `=awake` is an ambiguous target that
`kill-window` refuses.

`-i` blocks idle sleep and `-s` blocks system sleep on AC power. Closing the
lid on battery still sleeps the Mac, and nothing in userland prevents that.

## Layout

The same build pattern as aws-session: the template is the source, and the
installed plugin is a build output with the icons inlined.

```
plugin.template.sh      canonical source, __ICON_*__ placeholders
gen-icons.sh            rsvg-convert glyph renderer (grey/green/amber/red)
build.sh                icons + tests + template -> dist/ (--install to deploy)
test.sh                 drives every state against an isolated tmux session
dist/claude-rc.5s.sh    the distributable, committed so it can be downloaded as-is
icons/menubar/*.png     PNG sources for the build (generated, not committed)
```

`./build.sh --install` copies `dist/claude-rc.5s.sh` into SwiftBar's plugin
folder (read from `defaults read com.ameba.SwiftBar PluginDirectory`).

The README's icon pictures, `../docs/claude-rc-*.png`, are copies of
`icons/menubar/*.png`. Copy them again if the glyph changes.

Glyph: a centre dot flanked by two pairs of broadcast arcs, `((•))`, for
"remote". Palette: green `#30D158`, amber `#FF9F0A`, red `#FF453A`,
grey `#8E8E93`. Rendered at 60px and stamped with 240 dpi so NSImage draws it
at 18pt, like the other plugins.

Run `./build.sh --install` after editing the template.

## Prerequisites

- `brew install tmux`
- The rc folder has accepted the workspace trust dialog (run `claude` there
  once). If it hasn't, rc exits immediately and the plugin shows `exited` with
  rc's own message, which is the right place to learn about it.
- Remote Control's one-time `Enable Remote Control? (y/n)` has been answered
  (run `claude remote-control` once). The plugin can't see this one: rc waits
  at the prompt with a live pane, so the menu says `running` while nothing can
  connect. The README's setup steps cover it, and Attach is the way out.

## Testability

Overridable via environment:

| Variable | Default | Used for |
|---|---|---|
| `CLAUDE_RC_SESSION` | `claude-rc` | isolate test runs from the real session |
| `CLAUDE_RC_DIR` | `~/Code` | |
| `CLAUDE_RC_CMD` | `claude remote-control --permission-mode auto` | substitute `sleep 600` (running) or `sh -c 'echo boom; exit 3'` (exited) |
| `CLAUDE_RC_STATE_DIR` | `$TMPDIR` | stamps, update lock, log and status |
| `CLAUDE_RC_PREFS_DIR` | `~/.config/claude-rc` | keep-awake flag and settings file |
| `CLAUDE_RC_PATH` | caller's PATH + `~/.local/bin` + Homebrew + system | put a fake `claude` first; drop tmux for the `missing` state |
| `CLAUDE_RC_SETTINGS` | `~/.claude/settings.json` | channel selection |
| `CLAUDE_RC_DIST_TAGS_URL` | the npm dist-tags URL | a `file://` fixture, or a dead URL for the offline path |
| `CLAUDE_RC_AUTH_TIMEOUT` | `5` (seconds) | a 1 s limit against a fake `auth status` that stalls |

The tests put a fake `claude` first on `CLAUDE_RC_PATH`: a script at
`<tmp>/versions/<v>`, reached through a `bin/claude` symlink so the installed
version resolves exactly as it does for the real install. The fake answers
`auth status --json` from a fixture file. Its `update` succeeds or fails on
command, and on success it repoints the symlink to simulate the new install.
The plugin's real code paths therefore run end to end, with no test-only
branches.

The running version needs a real process whose executable basename is the
version. macOS kills copies of its own platform binaries (`cp /bin/sleep` dies
with SIGKILL), so the tests compile a three-line `pause()` program with `cc`
and copy it to `<tmp>/run/<v>`.

The test plan drives start → running → stop, the exited path, clear, a
missing rc folder (stopped, exited and running), folder names with `#` and
`|`, the settings file (precedence, never evaluated, changed while running),
the keep-awake reconcile (window appears, follows a restart, disappears on
toggle-off), and the update lock/status rendering, all against a
`claude-rc-test` session. The harness
also records the exit status of every render and fails any that isn't 0. It
never runs the real rc server.

The tests get a private tmux server: `TMUX_TMPDIR` points into the throwaway
directory, and `TMUX` is unset. Inside tmux, `TMUX` names the current server
and tmux ignores `TMUX_TMPDIR`, so without the unset the suite, including the
`kill-server` in its cleanup, would run against your real server.

`./test.sh <file>` runs the suite against another copy, such as
`dist/claude-rc.5s.sh`. The icon assertions read the `ICON_*` values from the
file under test, so they hold for the template's placeholders and for the
built file's PNGs.

## Caveats

The ones a user needs (who can drive rc, its permission mode, the shell
environment it inherits, macOS privacy prompts) live in the README's "Before
you use it", so there is one copy to keep current. The mechanism behind the
privacy prompts, for reference: tmux takes its macOS "responsible" app from
whatever started the server, and rc and every session it spawns inherit it.
When the plugin is what starts the server, that's SwiftBar, so a prompt for a
protected location (Desktop, Documents, Downloads, iCloud Drive, network
volumes) or for Apple Events says "SwiftBar would like to access…", and it can
stall a remote session until someone answers it at the Mac.

- **Locale.** SwiftBar also hands plugins no `LANG`, so the plugin exports
  `LANG=en_US.UTF-8` (unless one is already set) before any tmux call. The
  tmux server, and every window in it, then gets a UTF-8 locale.

## Non-goals

- More than one server, or per-repo servers.
- Auto-start at login and auto-revive after a crash.
- Flipping `autoUpdates` in `~/.claude.json`. That would make the CLI update
  itself on launch, but a server that's already running still needs a
  restart to pick up a new version, and that restart is what this plugin
  provides.
- Scraping the session URL out of the pane.
