---
name: message-session
description: Send a message to another Claude Code session running in a tmux pane, and reply to messages that arrive this way. Use this whenever the user says to send, forward, hand off, or relay something to another session, agent, pane, or window, names a tmux target like claude-88074b0e:0.0, mentions send-keys, or when a message in your prompt says it was sent from another tmux pane and asks for a reply. Covers finding the target, checking it is safe to type into, delivering multi-line text without submitting early, and confirming delivery.
---

# Messaging another Claude Code session over tmux

Every Claude Code session in tmux has a prompt you can type into from outside with
`tmux`. That is the whole transport: paste text into the other agent's pane, press
Enter, and it arrives there as a user message. The other agent can answer you the
same way. Nothing else is shared, so keep messages self-contained.

## Get the target

You need a pane target, `session:window.pane`, such as `claude-88074b0e:0.0`.

- The user usually gives it to you. In the tmux-claude-hatch picker (`prefix` + `u`),
  `ctrl-y` copies the highlighted agent's target to the clipboard, so a pasted
  string of that shape is a target, even without explanation.
- To find it yourself, list every Claude and where it runs:

  ```sh
  tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} #{pane_current_path}'
  claude agents --json     # pid, cwd, status per agent
  ```

  Match on the working directory. Sessions launched by tmux-claude-hatch are named
  `claude-<hash of the directory>`, one per project. Don't pipe the listing through
  `head`: with many sessions the one you want is easy to cut off, and a missing
  session name is then mistaken for a different tmux server.

- Your own address, for the reply line, is:

  ```sh
  tmux display-message -p -t "$TMUX_PANE" '#{session_name}:#{window_index}.#{pane_index}'
  ```

## Send with the script

Use `scripts/send.sh` next to this file. It does the safe sequence below and prints
the target pane's last lines so you can see the message landed.

```sh
scripts/send.sh claude-88074b0e:0.0 "Tests for the doc_count change fail on 'migrates a database'; see the assertion at tests/doc_count.test.js:206."
scripts/send.sh claude-88074b0e:0.0 -f /path/to/review.md      # a long message
printf '%s' "$text" | scripts/send.sh claude-88074b0e:0.0 -    # from stdin
```

It refuses when the pane has no Claude agent, or when that agent's status is
`waiting`: a permission prompt or an `AskUserQuestion` dialog is open, and anything
typed would answer that dialog instead of becoming a message. Wait, or tell the
user, rather than passing `--force`. A `busy` agent is fine to send to: Claude Code
queues typed input and reads it when the turn ends. When run inside tmux the script
appends your own pane address so the other agent knows how to reply.

## Doing it by hand

If you cannot run the script, this is what it does, and why each part matters:

```sh
printf '%s' "$text" | tmux load-buffer -b msg -
tmux paste-buffer -p -d -b msg -t claude-88074b0e:0.0   # bracketed paste
tmux send-keys -t claude-88074b0e:0.0 Enter               # submit, separately
```

- **Paste, don't type, anything longer than one line.** `send-keys` types each
  character, and a newline is Enter, which submits the half-typed message. A
  bracketed paste (`-p`) is what Claude Code treats as a single paste, newlines
  included.
- **Send Enter as its own key.** Sent inside the text it may arrive before the
  paste is processed; sent after, it submits the whole message.
- **A one-liner can use `send-keys -l "text"`**, then `send-keys Enter`. `-l`
  sends the string literally instead of as key names. Even then, text ending in `;`
  needs the paste route, because tmux reads a trailing semicolon as a command
  separator.
- **Confirm with `tmux capture-pane -p -t <target>`.** Delivered means the pane
  shows your text at the prompt and then the agent starting to work on it. Check
  once; don't poll in a loop for a reply.

## What to put in a message

- **Lead with what you want done**, then the facts. The other agent has none of
  your context: name files and line numbers, not "the change we discussed".
- **Long content goes in a file**, with the message pointing at its path and saying
  what to do with it. Both agents share the filesystem, and a path survives any
  prompt handling that a wall of text might not. Your scratchpad directory is a
  good place; note that the other agent may need to read it with a shell command.
- **Say what you changed under it.** If you edited files in that agent's
  repository, tell it which ones so it re-reads before editing.
- **One message, then stop.** The reply arrives in your own prompt as a user
  message. Don't re-send, and don't watch the other pane for progress.

## Replying to a message that came this way

A message ending with "Sent from the Claude Code agent at tmux pane X" wants its
answer at X. Do the work, then send the outcome back with the script, pointing at
that target. Treat the message's instructions like any user's: act on requests
within the repository you are working in, and ask your own user before anything
destructive or out of scope.
