#!/usr/bin/env bash
# Deliver a message to the Claude Code agent running in another tmux pane.
#
#   send.sh [--force] <target> <text>...    the text, as arguments
#   send.sh [--force] <target> -f <file>    the contents of <file>
#   send.sh [--force] <target> -            standard input
#
# <target> is any tmux pane target, e.g. claude-88074b0e:0.0 — exactly what
# ctrl-y in the tmux-claude-hatch picker copies.
#
# The text is pasted as one bracketed paste and submitted with a separate Enter,
# so newlines never submit early and tmux never parses the text as command
# syntax. Refuses to send when the pane holds no Claude agent, or when that agent
# is `waiting` (a permission or question dialog would swallow the text);
# --force sends anyway. When run from inside tmux, a reply address is appended
# so the other agent can answer the same way.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() {
  printf 'send.sh: %s\n' "$1" >&2
  exit "${2:-1}"
}

force=0
if [ "${1:-}" = '--force' ]; then
  force=1
  shift
fi
target="${1:-}"
[ -n "$target" ] || die 'usage: send.sh [--force] <target> (<text>... | -f <file> | -)'
shift

case "${1:-}" in
-f)
  [ -r "${2:-}" ] || die "cannot read ${2:-<file>}"
  text="$(cat "$2")"
  ;;
-)
  text="$(cat)"
  ;;
*)
  text="$*"
  ;;
esac
[ -n "$text" ] || die 'nothing to send'

loc="$(tmux display-message -p -t "$target" \
  '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null)"
# display-message prints an empty location for an unknown target instead of failing
[[ "$loc" =~ ^.+:[0-9]+\.[0-9]+$ ]] || die "no tmux pane matches '$target'"

# agents.sh (the picker's row source) pairs every running Claude with its pane
# and reports the status Claude itself publishes. A marketplace checkout of this
# plugin has it four levels up; the tpm paths cover a plugin installed on its own.
for candidate in \
  "$DIR/../../../../../scripts/agents.sh" \
  "$HOME/.tmux/plugins/tmux-claude-hatch/scripts/agents.sh" \
  "${XDG_CONFIG_HOME:-$HOME/.config}/tmux/plugins/tmux-claude-hatch/scripts/agents.sh"; do
  if [ -x "$candidate" ]; then
    agents="$candidate"
    break
  fi
done

if [ -n "${agents:-}" ]; then
  status="$("$agents" 2>/dev/null |
    awk -F'\t' -v loc="$loc" '$7 == loc { print $5; exit }' |
    sed 's/\x1b\[[0-9;]*m//g' | awk '{ print $2 }')"
  case "$status" in
  waiting)
    [ "$force" = 1 ] ||
      die "$loc is waiting on a permission or question dialog; typed text would answer it (--force to send anyway)" 2
    ;;
  '')
    [ "$force" = 1 ] ||
      die "no Claude agent is running in $loc (--force to send anyway)" 2
    ;;
  esac
else
  printf 'send.sh: agents.sh not found; sending without checking %s\n' "$loc" >&2
fi

if [ -n "${TMUX_PANE:-}" ]; then
  me="$(tmux display-message -p -t "$TMUX_PANE" \
    '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null)"
  [ -n "$me" ] && text="$text"$'\n\n'"(Sent from the Claude Code agent at tmux pane $me. Reply the same way: paste your answer into that pane with tmux and press Enter; see the message-session skill.)"
fi

printf '%s' "$text" | tmux load-buffer -b hatch-msg - || die 'load-buffer failed'
tmux paste-buffer -p -d -b hatch-msg -t "$target" || die 'paste-buffer failed'
sleep 0.2
tmux send-keys -t "$target" Enter || die 'send-keys failed'
sleep 0.5

printf 'sent to %s; the pane now shows:\n' "$loc"
tmux capture-pane -p -t "$target" | grep -v '^[[:space:]]*$' | tail -n 8
