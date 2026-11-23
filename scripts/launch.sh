#!/usr/bin/env bash
# Launch (or re-attach to) a Claude session for a directory, shown in a popup,
# or in split mode (@claude_display 'split') toggled as a pane in the window.
# Args: <dir> [origin-window-id]   (both expanded by run-shell in the binding)
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"
# shellcheck source=split.sh
. "$DIR/split.sh"

path="${1:-$PWD}"
window="${2:-}"

prefix="$(get_tmux_option @claude_session_prefix 'claude-')"
cmd="$(get_tmux_option @claude_command 'claude')"
args="$(get_tmux_option @claude_args '')"
[ -n "$args" ] && cmd="$cmd $args"
w="$(get_tmux_option @claude_popup_width '90%')"
h="$(get_tmux_option @claude_popup_height '90%')"

display="$(get_tmux_option @claude_display 'popup')"

session="${prefix}$(session_hash "$path")"

if [[ "$(tmux display-message -p ${window:+-t "$window"} '#S')" == "$prefix"* ]]; then
  tmux display-message '🫪 Popup window already open'
  exit 0
fi

# Split mode toggles: hide this directory's agent if it is shown here. Another
# project's agent is hidden too, to make room for this one.
if [ "$display" = split ] && [ -n "$window" ]; then
  shown="$(split_shown_session "$window")"
  if [ -n "$shown" ]; then
    split_hide "$window"
    [ "$shown" = "$session" ] && exit 0
  fi
fi

if ! tmux has-session -t "$session" 2>/dev/null; then
  [ -d "$path" ] || {
    tmux display-message "tmux-claude-hatch: $path no longer exists"
    exit 0
  }
  tmux new-session -d -s "$session" -c "$path" "$cmd"
fi

# Close the popup when Claude exits, even under a global detach-on-destroy off.
tmux set-option -t "$session" detach-on-destroy on

# Record which window launched it, so the picker can jump back here later.
[ -n "$window" ] && tmux set-option -t "$session" @claude_origin "$window"

if [ "$display" = split ] && [ -n "$window" ]; then
  split_show "$(split_agent_pane "$session")" "$window"
  exit 0
fi

title=" Agent "
tmux display-popup -w "$w" -h "$h" -b rounded -T "$title" -E "tmux attach-session -t '$session'"
