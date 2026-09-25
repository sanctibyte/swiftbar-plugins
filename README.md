# swiftbar-plugins

Two menu bar plugins for [SwiftBar](https://swiftbar.app), for macOS. Each one
is a single file with its icons built in: put it in your SwiftBar plugin
folder and it shows up in the menu bar.

| Plugin | Shows | Lets you |
|---|---|---|
| [claude-rc](#claude-rc) | whether your Claude Code [Remote Control](https://code.claude.com/docs/en/remote-control) server is running, up to date and logged in | start, stop, restart and update it, open it in a terminal, log in, keep the Mac awake |
| [aws-session](#aws-session) | whether you're signed in with `aws login` | log in |

## Set up SwiftBar

Do this once, before installing either plugin:

1. Install SwiftBar with `brew install --cask swiftbar`, or download it from
   [swiftbar.app](https://swiftbar.app).
2. Make a folder for plugins, such as `mkdir ~/SwiftBar`, then open SwiftBar
   and choose that folder when it asks. Avoid Documents, Desktop and iCloud
   Drive: macOS makes apps ask permission before reading those.
3. Optional: turn on **Launch at Login** in SwiftBar's settings, so your menu
   bar icons come back after a restart.

## claude-rc

Keeps one `claude remote-control` server running in a tmux session, so you
can work in Claude Code on this Mac from [claude.ai/code](https://claude.ai/code)
or the Claude app on your phone, long after you've closed the terminal.

| Icon | Meaning |
|---|---|
| <img src="docs/claude-rc-green.png" width="22" alt="green"> | Running, logged in and up to date |
| <img src="docs/claude-rc-amber.png" width="22" alt="amber"> | Running, but a Claude Code update is available, or an update or a settings change is waiting for a restart |
| <img src="docs/claude-rc-red.png" width="22" alt="red"> | Running but logged out, or the server quit (the menu shows its last lines of output) |
| <img src="docs/claude-rc-grey.png" width="22" alt="grey"> | Stopped, or tmux or Claude Code isn't installed |

Nothing happens until you click. The plugin never starts, restarts or updates
anything on its own.

### Before you use it

- **Every device signed in to your Claude account can use it.** Sessions
  opened from claude.ai or the Claude app run on this Mac, in your project
  folder.
- **Sessions start in `auto` permission mode**, where Claude acts without
  asking and relies on background safety checks. To have sessions ask first,
  change the mode in [Settings](#settings). The
  [permission modes](https://code.claude.com/docs/en/permission-modes) page
  explains each one.
- **The server gets your whole shell environment.** It starts through your
  login shell, so it and every session it runs see everything your shell
  startup files export, API keys included.
- **macOS privacy prompts can hold up remote work.** When the plugin is what
  starts tmux, a request to use Desktop, Documents, Downloads or a similar
  folder says "SwiftBar would like to access…" and waits for someone at the
  Mac to answer it. If you'll be away, answer each prompt once while you're at
  the Mac, or give SwiftBar Full Disk Access in System Settings → Privacy &
  Security. If tmux was already running, the prompts name the app that
  started it instead.

### What you need

- **Claude Code**, installed with the
  [native installer](https://code.claude.com/docs/en/setup) and signed in on
  a Pro, Max, Team or Enterprise plan. On Team and Enterprise, an Owner has
  to turn Remote Control on first. Other installs work if `claude` ends up in
  `~/.local/bin`, `/opt/homebrew/bin` or `/usr/local/bin`, where the plugin
  looks for it, but then the menu can't show versions or offer updates.
- **tmux**: `brew install tmux`
- **A project folder** for the server to run in. The plugin uses `~/Code`
  unless you [change it](#settings). Use a project folder rather than your
  home folder, which Claude never saves as trusted.
- **Two one-time answers in that folder.** Remote Control only runs in a
  folder you've trusted, and it asks once before it turns on. Both questions
  need a terminal, so answer them before your first Start:
  1. In that folder (`cd ~/Code` for the default), run `claude`, accept the
     trust prompt, then type `/exit`.
  2. Still there, run `claude remote-control`, answer `y`, then press Ctrl-C
     once it's running.

### Install

```bash
d="$(defaults read com.ameba.SwiftBar PluginDirectory)" && t="$(mktemp)" && curl -fsSL -o "$t" https://raw.githubusercontent.com/sanctibyte/swiftbar-plugins/main/claude-rc/dist/claude-rc.5s.sh && chmod +x "$t" && mv "$t" "$d/claude-rc.5s.sh"
```

That downloads the plugin and moves it into your SwiftBar plugin folder in one
step. The icon appears within a few seconds. To do it by hand instead, open
[`claude-rc/dist/claude-rc.5s.sh`](claude-rc/dist/claude-rc.5s.sh), use the
download button, and move the file into the plugin folder. Keep its name: the
`.5s.` tells SwiftBar to refresh it every 5 seconds.

### First run

1. Click the icon, then **Start**. It turns green, or amber or red if the
   menu has something to tell you.
2. Open [claude.ai/code](https://claude.ai/code), or **Code** in the Claude
   app. Your Mac's session is in the list, with a name like
   `yourmac-graceful-unicorn` and a green dot while it's online.
3. **Attach in iTerm** (or Terminal) shows the server itself. Closing that
   window leaves the server running.

When your Mac restarts, the server stays stopped until you click **Start**.

### The menu

- **Stop** ends the sessions the server was hosting, so they stop responding
  on your phone and in the browser. Starting it again within about four hours
  brings them back. **Restart** and **Update** stop and start it, so sessions
  drop out briefly and come back.
- **Update to …** appears when a newer Claude Code is out on your update
  channel: `autoUpdatesChannel` in `~/.claude/settings.json`, which is
  `latest` unless you've changed it. It runs `claude update`, then restarts
  the server if it was running.
- **Keep Mac awake while running** stops the Mac from sleeping while the
  server runs. Closing the lid on battery still puts it to sleep.
- **Log in…** appears when Claude Code is logged out, and opens a terminal
  running `claude auth login`.
- **Clear** appears after the server quits, and removes what's left of it.

### Settings

Settings go in `~/.config/claude-rc/config`, which updating the plugin leaves
alone. Both settings are optional. This creates the file with the defaults,
ready to edit:

```bash
mkdir -p ~/.config/claude-rc
cat > ~/.config/claude-rc/config <<'EOF'
# The folder the server runs in
RC_DIR=~/Code
# The command it runs there
RC_CMD=claude remote-control --permission-mode auto
EOF
```

- Write one `KEY=value` per line, with no `export`. Lines starting with `#`
  are ignored. The plugin reads the file as text and never runs it.
- `RC_DIR` takes a full path, or one starting with `~/`.
- In `RC_CMD`, `--permission-mode` can be `default` (asks before anything
  other than reading), `acceptEdits`, `plan`, `auto`, `dontAsk` or
  `bypassPermissions`. Other
  [`claude remote-control` options](https://code.claude.com/docs/en/remote-control)
  work too.
- Changes apply the next time the server starts. Until then the menu goes on
  showing the folder and mode the server is running with, and says **Settings
  changed — restart to apply**. Click **Restart**.

### Updating the plugin

Run the install command again. Your settings stay put.

If you changed `RC_DIR` or `RC_CMD` the old way, by editing the lines at the
top of the plugin file, copy them into the settings file first: updating
replaces the plugin file.

### Removing it

1. Click **Stop** first. Deleting the plugin or quitting SwiftBar doesn't stop
   the server: it keeps running in tmux, where your account can still reach
   it. If you've already deleted the plugin, run
   `tmux kill-session -t claude-rc`.
2. Delete `claude-rc.5s.sh` from your plugin folder.
3. Optionally, delete its settings and caches:

   ```bash
   rm -rf ~/.config/claude-rc
   find "$TMPDIR" -maxdepth 1 -name 'claude-rc-*' -exec rm -rf {} +
   ```

### Troubleshooting

| What you see | What to do |
|---|---|
| Red, **exited**, with a few lines of output | The server quit, and those lines are the end of its output; **Attach** shows the rest. See [why the server quits](#why-the-server-quits), below. |
| Green, but no session on claude.ai | The server is probably waiting for its one-time `Enable Remote Control? (y/n)` answer. Click **Attach**, type `y`, then close the window. |
| **Folder not found** | `RC_DIR` names a folder that doesn't exist. Create it and give it the [one-time answers](#what-you-need), or change `RC_DIR` in `~/.config/claude-rc/config`. If the folder does exist inside Documents, Desktop or Downloads, check that SwiftBar may access it in System Settings → Privacy & Security → Files and Folders. |
| **Settings changed — restart to apply** | You've edited the settings file since the server started. Click **Restart** to use the new settings. |
| **Not logged in** | Click **Log in…** and finish in the browser. |
| **Update failed: …** | Click it for the full log. If the log says Claude Code is up to date, Claude's own updater doesn't offer that version yet; try again later. |
| **tmux not installed** or **claude not found** | Install it. The menu notices within a few seconds. |
| No icon at all | Check that SwiftBar is running and that `claude-rc.5s.sh` is in its plugin folder. Running the file in Terminal prints what SwiftBar would show. |

#### Why the server quits

The usual causes:

- The [one-time answers](#what-you-need) haven't been given in that folder.
- Claude Code is logged out, or your shell exports `ANTHROPIC_API_KEY` or
  `ANTHROPIC_AUTH_TOKEN`. Remote Control needs your claude.ai login, not an
  API key, and the server starts through your login shell, so it sees
  whatever your shell exports.
- Your shell exports a variable that switches Remote Control off:
  `DO_NOT_TRACK`, `DISABLE_TELEMETRY`,
  `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_GROWTHBOOK`, or an
  `ANTHROPIC_BASE_URL` that isn't Anthropic's.
- The Mac was awake but offline for more than about 10 minutes, and Remote
  Control gave up.

Fix the cause, then click **Restart**.

How it works, and why: [claude-rc/DESIGN.md](claude-rc/DESIGN.md).

## aws-session

A cloud in the menu bar that shows whether you're signed in to the AWS CLI
with `aws login`.

| Icon | Meaning |
|---|---|
| <img src="docs/aws-session-active.png" width="22" alt="green"> | Signed in. The CLI keeps your credentials refreshed for up to 12 hours. |
| <img src="docs/aws-session-expired.png" width="22" alt="red"> | The session has ended. Log in again. |
| <img src="docs/aws-session-none.png" width="22" alt="grey"> | No `aws login` session on this Mac, or the AWS CLI isn't installed |

**Is it for you?** Only if you sign in with `aws login` (AWS CLI 2.36 or
later), which signs the CLI in with your AWS console credentials. It doesn't
follow IAM Identity Center (`aws sso login`) or access keys in
`~/.aws/credentials`, and stays grey for those.

### Install

```bash
d="$(defaults read com.ameba.SwiftBar PluginDirectory)" && t="$(mktemp)" && curl -fsSL -o "$t" https://raw.githubusercontent.com/sanctibyte/swiftbar-plugins/main/aws-session/dist/aws-session.5s.sh && chmod +x "$t" && mv "$t" "$d/aws-session.5s.sh"
```

Or download [`aws-session/dist/aws-session.5s.sh`](aws-session/dist/aws-session.5s.sh)
into the plugin folder by hand. To update it later, run the same command again.

### Using it

**Log in…** in the menu opens iTerm (or Terminal) running `aws login`.

The plugin reads only `expiresAt` and `accountId` from the login cache in
`~/.aws/login/cache/`, never your keys. Once the cached credentials have
expired, it runs `aws sts get-caller-identity`, at most once a minute, to tell
a session the CLI can still refresh from one that has ended. That call is also
what makes the CLI refresh, so leaving the plugin running keeps your
credentials fresh, within the 12-hour limit.

To remove it, delete `aws-session.5s.sh` from your plugin folder. How it
works, and why: [aws-session/DESIGN.md](aws-session/DESIGN.md).

## Building from source

You only need this to change the plugins.

Each plugin folder has a `plugin.template.sh`, which is the source (edit this,
not the file in `dist/`), a `gen-icons.sh` that draws the icons, and a
`build.sh` that draws them, builds them into the template and writes `dist/`.
`./build.sh --install` also copies the result into your SwiftBar plugin
folder.

Building needs librsvg (`brew install librsvg`), and `cc` and `python3` from
the Xcode Command Line Tools (`xcode-select --install`). claude-rc's build
runs its tests first (`claude-rc/test.sh`, which also needs tmux). They use a
private tmux server and a fake `claude`, so they never touch your real
sessions, even when you run them from inside tmux. To run them against a
built copy: `./test.sh dist/claude-rc.5s.sh`.

## License

[MIT](LICENSE)
