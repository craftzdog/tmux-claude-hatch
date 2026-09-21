# tmux-claude-hatch

[![screenshot](./docs/screenshot.jpg)](https://youtu.be/NnTV6r4l5D0)

A tmux plugin (plus an optional Claude Code plugin) that runs a Claude Code
session in a popup for each project directory. Open the hatch, hand Claude the
work, close it and get back to your editor. Each session lives in its own nested
tmux session, so closing the hatch never interrupts it. When you want to check
in, an `fzf` picker lists every running session, shows what each one is doing,
and jumps you straight to it. And when a session finishes or needs your
attention, it rings a bell that highlights the window you launched it from — so
you know where to go without even opening the picker.

Simple by design: it's just a few shell scripts.

## Why / philosophy

- **Who it's for**
  - People who want to stay in their editor — (Neo)vim, Emacs — in the main tmux
    session
  - People who still read, write, and review the code themselves
  - People who'd rather have a small tool than a full-blown one just to manage
    agent sessions
- **Who it's not for**
  - People whose focus is the agent's chat interface rather than the code
  - People who want one tool for sessions across several AI providers — this one
    is Claude Code only
  - People who run a swarm of agents and don't read or write code themselves

## Features

- **A central picker** (`prefix` + `u`) listing every running Claude agent —
  several in one project, and any running loose in an ordinary pane.
- **Live status** per agent — `working` / `waiting` / `idle` — read straight
  from `claude agents --json`, so you instantly see which need you. No setup.
- **A live preview** of each agent's screen right in the picker.
- **Smart jump** — selecting an agent switches your client to the window it
  was launched from, then resumes it in a popup over it.
- **A launcher** (`prefix` + `y`) that opens/attaches a Claude session for the
  current directory.
- **Quick kill** (`ctrl-x`) of a finished agent from the picker.
- **Copy location** (`ctrl-y`) — puts an agent's `session:window.pane` target
  on the clipboard, ready for `tmux send-keys -t` and friends.
- **Agent-to-agent messages** — the Claude Code plugin adds a `message-session`
  skill: paste a target into an agent's prompt and it can send a message to that
  session and read the reply, with no MCP server in between.
- **Bell forwarding** — a bell in a dedicated session highlights the window
  you launched it from, so you notice even without opening the picker
  ([one-time Claude Code setup](#making-claude-ring-the-bell)).
  ![bell-forwarding](./docs/bell-forwarding.png)

## Prerequisites

- **tmux ≥ 3.2** (for `display-popup`)
- **[fzf](https://github.com/junegunn/fzf)** — the picker UI
- **[jq](https://jqlang.org/)** — parses `claude agents --json`
- **[Claude Code](https://claude.com/claude-code)** ≥ 2.1.139 — for the
  `claude agents` command (`claude --version` to check)
- bash; macOS or Linux

## Installation

### tpm

Add to `~/.tmux.conf` (or `~/.config/tmux/tmux.conf`):

```tmux
set -g @plugin 'craftzdog/tmux-claude-hatch'
```

Then hit `prefix` + <kbd>I</kbd> to install.

> **Keybinding note:** by default the plugin binds `prefix` + `y` (launch) and
> `prefix` + `u` (list). If your config binds those elsewhere, either change the
> [options](#options), or make sure the plugin loads **after** your own bindings
> (put `run '~/.tmux/plugins/tpm/tpm'` _after_ them) so the one you want wins.

### (Optional) Claude Code plugin

Independent of the tmux plugin above. It ships the Claude Code hook
configuration this plugin wants, so you don't have to hand-edit
`~/.claude/settings.json`:

- **Rings the terminal bell** when an agent ends a turn, asks for permission, or
  asks you a question — the moments the picker calls `idle` and `waiting`. That
  is what [bell forwarding](#making-claude-ring-the-bell) needs in order to
  highlight the window you launched the agent from.
- **Refreshes the picker's agent cache** on those same events, plus session
  start/end and prompt submit. The picker paints from cache for a fast startup,
  so without this the first frame can be stale — showing `working` for an agent
  that has been waiting on you.
- **Adds a `message-session` skill** — an agent can message another Claude Code
  session by its `ctrl-y` target and reply to messages sent that way, without
  hitting a permission or question dialog by accident.

```
/plugin marketplace add craftzdog/tmux-claude-hatch
/plugin install tmux-claude-hatch@tmux-claude-hatch
```

See [`plugins/tmux-claude-hatch`](./plugins/tmux-claude-hatch) for exactly what
it registers.

## Usage

| Key            | Action                                                                          |
| -------------- | ------------------------------------------------------------------------------- |
| `prefix` + `y` | Launch (or re-attach to) a Claude session for the current directory, in a popup |
| `prefix` + `d` | Close the popup and go back to your window; the Claude session keeps running    |
| `prefix` + `u` | Open the agent picker                                                           |

Inside the picker:

| Key                       | Action                                                                       |
| ------------------------- | ---------------------------------------------------------------------------- |
| `enter`                   | Jump to the agent                                                            |
| `ctrl-x`                  | Kill the highlighted agent                                                   |
| `ctrl-y`                  | Copy the highlighted agent's location (e.g. `claude-88074b0e:0.0`) and close |
| `↑` / `↓`, type to filter | fzf navigation                                                               |

Agents needing your attention (`waiting`, `idle`) sort to the top.

Every running Claude gets its own row — the picker identifies each by its
process, not by its tmux session. So several agents in one project all show up
separately, as does a Claude you started by hand in an ordinary pane.

## Options

Set any of these before the plugin loads (defaults shown):

```tmux
set -g @claude_launch_key     'y'        # prefix key: launch/open for current dir
set -g @claude_list_key       'u'        # prefix key: open the picker
set -g @claude_command        'claude'   # command run in new sessions
set -g @claude_args           ''         # extra args appended to the command
set -g @claude_session_prefix 'claude-'  # tmux session name prefix
set -g @claude_popup_width     '90%'     # popup width
set -g @claude_popup_height    '90%'     # popup height
set -g @claude_fzf_options    ''         # extra options passed to the fzf picker
set -g @claude_forward_bell   'on'       # highlight the origin window on a bell
```

For example, to skip permission prompts in launched sessions:

```tmux
set -g @claude_args '--dangerously-skip-permissions'
```

## Manual installation

If you don't use tpm:

```sh
git clone https://github.com/craftzdog/tmux-claude-hatch ~/clone/path
```

Add to `~/.tmux.conf`, then reload (`prefix` + <kbd>r</kbd> or
`tmux source ~/.tmux.conf`):

```tmux
run-shell ~/clone/path/claude_hatch.tmux
```

## Customizations

### Making Claude ring the bell

Forwarding relays a bell; it cannot create one. Claude Code has to emit it. The
[Claude Code plugin](#optional-claude-code-plugin) takes care of that; the
alternatives below do the same job by hand.

#### Via Claude's own notification settings

Two settings decide this — and they live in **different files**.

**How** it notifies — `~/.claude/settings.json`:

```json
{
  "preferredNotifChannel": "terminal_bell"
}
```

Only `terminal_bell` and `iterm2_with_bell` write a real `\a`. `iterm2`, `kitty`
and `ghostty` send escape sequences that tmux does not count as a bell,
`notifications_disabled` sends nothing, and the default `auto` picks by terminal —
so pin it.

**When** it notifies — `~/.claude.json`, the global config (`settings.json`
ignores this key and drops it silently):

```json
{
  "messageIdleNotifThresholdMs": 0
}
```

Claude rings once it has sat idle this long. The default is 60000, long enough
that you'd normally have gone back to look before it fires; `0` rings the moment a
turn ends.

#### Via a hook

A hook is the way to keep the bell while pointing `preferredNotifChannel` at an
OS-notification channel instead. This is what the Claude Code plugin registers;
to wire it by hand, in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "printf '\\a' 2>/dev/null > /dev/tty || { [ -n \"$TMUX_PANE\" ] && printf '\\a' 2>/dev/null > \"$(tmux display-message -p -t \"$TMUX_PANE\" '#{pane_tty}' 2>/dev/null)\"; } || true"
          }
        ]
      }
    ]
  }
}
```

`Stop` fires the moment a turn ends, with no idle timer involved. The bell goes to
`/dev/tty` — the hook's controlling terminal, which inside tmux is the pane's own
pty, exactly where Claude's built-in bell would land. The `$TMUX_PANE` branch
covers a hook running without a controlling terminal, resolving the pane's tty
through tmux instead; the trailing `|| true` keeps a failed bell from failing the
hook.

Note that `2>/dev/null` comes **before** the `/dev/tty` redirection. A failed
redirection is reported by the shell itself, so a trailing `2>/dev/null` is
applied too late to suppress it — with the operands the other way round, a hook
running without a controlling terminal prints
`bash: /dev/tty: Device not configured` on every turn.

Use the same command under `Notification` with the `permission_prompt` matcher to
ring when Claude asks for permission, or under `PreToolUse` matching
`AskUserQuestion` to ring when it asks you a question.

Set `@claude_forward_bell 'off'` to disable forwarding altogether.

### Customizing the fzf picker

`@claude_fzf_options` is passed straight to `fzf`, so you can add your own
bindings. Here is a vim-style example:

```tmux
set -g @claude_fzf_options "\
  --prompt 'nav> ' \
  --bind 'j:down' \
  --bind 'k:up' \
  --bind 'q:abort' \
  --bind 'x:execute-silent(kill {3})+reload(sleep 0.3; \$CLAUDE_PICKER --list)' \
  --bind 'i:unbind(j,k,q,i,a,x)+change-prompt(filter> )' \
  --bind 'a:unbind(j,k,q,i,a,x)+change-prompt(filter> )' \
  --bind 'esc:rebind(j,k,q,i,a,x)+change-prompt(nav> )'"
```

The picker opens in **nav** mode:

| Key       | Action                                                  |
| --------- | ------------------------------------------------------- |
| `j` / `k` | move down / up                                          |
| `i` / `a` | switch to **filter** mode — type to fuzzy-match         |
| `x`       | kill the highlighted agent (like the built-in `ctrl-x`) |
| `q`       | close the picker                                        |
| `enter`   | jump to the agent (both modes)                          |
| `esc`     | filter mode → back to nav                               |

Only the bound keys are special in nav mode; any other key still filters as you
type. `x` reloads the list through `$CLAUDE_PICKER`, a path the picker exports
for exactly this — write it as `\$CLAUDE_PICKER` inside the double-quoted value
above so tmux stores a literal `$` (in a single-quoted value, use a bare
`$CLAUDE_PICKER`).

## License

[MIT](LICENSE) © Takuya Matsuyama
