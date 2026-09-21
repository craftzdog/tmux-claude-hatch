# tmux-claude-hatch

A [Claude Code plugin](https://docs.claude.com/en/docs/claude-code/plugins) that
ships the hook configuration
[tmux-claude-hatch](https://github.com/craftzdog/tmux-claude-hatch)
wants, so you don't have to paste JSON into `~/.claude/settings.json`.

It does three things:

- **Rings the terminal bell** when an agent ends a turn, asks for permission, or
  asks you a question — the three moments the picker calls `idle` and `waiting`.
  tmux only raises an alert for a real `\a` written to a pane's pty, which is what
  makes window-status alerts and this plugin's bell forwarding fire.
- **Refreshes the picker's agent cache** on those same events, plus session
  start/end and prompt submit. The picker paints from cache for a fast startup,
  so without this the first frame can be stale — showing `working` for an agent
  that has been waiting on you.
- **Adds a `message-session` skill** so an agent can send a message to another
  Claude Code session in a tmux pane — the target `ctrl-y` copies in the picker —
  and reply to messages that arrive that way. The skill's `send.sh` pastes the
  text as one bracketed paste, submits with a separate Enter, and refuses to type
  into an agent that is `waiting` on a permission or question dialog.

## Install

```
/plugin marketplace add craftzdog/tmux-claude-hatch
/plugin install tmux-claude-hatch@tmux-claude-hatch
```

## Notes

- Both hooks are silent, always exit `0`, and run the cache refresh detached, so
  a failure never fails a turn and nothing lands in the transcript.
- The cache refresh is skipped entirely when the agent is not inside tmux — it
  would otherwise overwrite a good cache with an empty one.
- This covers the hook route only. `preferredNotifChannel` and
  `messageIdleNotifThresholdMs` are user settings a plugin cannot set; see
  [Making Claude ring the bell](../../README.md#making-claude-ring-the-bell) if
  you'd rather use Claude's built-in bell than a hook.
