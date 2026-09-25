# swiftbar-plugins

Two small [SwiftBar](https://swiftbar.app) menu bar plugins for macOS. Each one
ships as a single self-contained file with its icons inlined: download it, drop
it into your SwiftBar plugin folder, done.

| Plugin | What it shows | Actions |
|---|---|---|
| [claude-rc](claude-rc) | Whether a [Claude Code Remote Control](https://docs.claude.com/en/docs/claude-code) server is running in tmux, current, and logged in | Start, Stop, Restart, Attach in iTerm/Terminal, Log in, one-click update, keep Mac awake |
| [aws-session](aws-session) | Whether an `aws login` session is active | Log in |

## Install

1. Install SwiftBar (`brew install --cask swiftbar`) and pick a plugin folder
   on first launch. You can find it later under SwiftBar → Preferences.
2. Download the plugin you want from its `dist/` folder:
   - [`claude-rc/dist/claude-rc.5s.sh`](claude-rc/dist/claude-rc.5s.sh)
   - [`aws-session/dist/aws-session.5s.sh`](aws-session/dist/aws-session.5s.sh)
3. Save it into the plugin folder, keeping the file name. The `.5s.` is the
   refresh interval, and SwiftBar reads it from the name.
4. `chmod +x` it. SwiftBar usually does this for you.

## claude-rc

Runs one `claude remote-control` server in a tmux session named `claude-rc`,
so you can drive Claude Code sessions from claude.ai/code or the Claude app
after the terminal that started it has closed.

| Icon | Meaning |
|---|---|
| green | running, logged in, up to date |
| amber | running, but an update is available, or installed and waiting for a restart |
| red | rc exited (the menu shows its last output), or logged out |
| grey | stopped, or tmux / claude isn't installed |

Nothing happens without a click. There's no auto-start, no auto-revive and no
auto-update.

**Requires** tmux (`brew install tmux`) and the native Claude Code install,
logged in with a plan that includes Remote Control. Run `claude` once in the rc
directory to accept its workspace trust prompt.

**Configure** by editing the lines near the top of the installed file:

- `RC_DIR`: where rc runs (default `~/Code`)
- `RC_CMD`: the command (default `claude remote-control --permission-mode auto`)

**Before you use it**, a few things are worth knowing:

- rc starts through your login shell (`$SHELL -lic`), so it inherits everything
  your shell exports, including any secrets in your rc files.
- Anyone signed in to your Claude account on another device can drive it. The
  default permission mode is `auto`.
- SwiftBar starts the tmux server, so macOS privacy prompts from rc's sessions
  (Desktop, Documents, Downloads…) name SwiftBar and wait for someone at the
  Mac. Pre-grant SwiftBar in System Settings → Privacy & Security if you need
  that access remotely.

The design, state machine and reasoning are in
[claude-rc/DESIGN.md](claude-rc/DESIGN.md).

## aws-session

A green, red or grey cloud for whether `aws login` (AWS CLI ≥ 2.36) credentials
are live. It reads only `expiresAt` and `accountId` from the login cache, never
the key material. Details are in
[aws-session/DESIGN.md](aws-session/DESIGN.md).

## Building from source

Each plugin has a `plugin.template.sh` (the source), `gen-icons.sh`
(`brew install librsvg`) and `build.sh`, which renders the icons, inlines them
and writes `dist/`. `./build.sh --install` also copies the result into your
SwiftBar plugin folder. claude-rc's build runs its test suite first
(`claude-rc/test.sh`, which needs tmux and `cc`). The tests use a private tmux
server and a fake `claude`, so they never touch a real session.

## License

[MIT](LICENSE)
