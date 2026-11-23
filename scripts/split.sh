#!/usr/bin/env bash
# Split-mode helpers, sourced by launch.sh and picker.sh.
#
# A shown agent's pane is swapped into the caller's window, leaving a
# placeholder pane in its dedicated session so that session survives. Hiding
# swaps them back. The agent pane records its placeholder in @claude_placeholder.

# split_return <pane> <placeholder>
# Swaps a shown agent pane back into its session and drops the placeholder.
split_return() {
  tmux set-option -pu -t "$1" @claude_placeholder
  if tmux swap-pane -d -s "$1" -t "$2" 2>/dev/null; then
    tmux kill-pane -t "$2"
  else
    tmux display-message "tmux-claude-hatch: agent's session is gone; leaving it here"
  fi
}

# split_hide <window>
# Sends any agent pane shown in <window> back to its session. Returns 1 when
# there was none.
split_hide() {
  local pane holder found=1
  while read -r pane holder; do
    [ -n "$holder" ] || continue
    found=0
    split_return "$pane" "$holder"
  done < <(tmux list-panes -t "$1" -F '#{pane_id} #{@claude_placeholder}' 2>/dev/null)
  return "$found"
}

# split_shown_session <window>
# Prints the dedicated session of the agent shown in <window>, if any.
split_shown_session() {
  local holder
  holder="$(tmux list-panes -t "$1" -F '#{@claude_placeholder}' 2>/dev/null | grep -m1 .)"
  [ -n "$holder" ] && tmux display-message -p -t "$holder" '#{session_name}' 2>/dev/null
}

# split_agent_pane <session>
# Prints the agent pane of <session>. If it is shown in some window (so the
# session's active pane is its placeholder), it is sent home first.
split_agent_pane() {
  local active pane holder
  active="$(tmux display-message -p -t "$1:" '#{pane_id}')"
  while read -r pane holder; do
    if [ "$holder" = "$active" ]; then
      split_return "$pane" "$holder"
      printf '%s' "$pane"
      return
    fi
  done < <(tmux list-panes -a -F '#{pane_id} #{@claude_placeholder}' 2>/dev/null)
  printf '%s' "$active"
}

# split_show <pane> <window>
# Swaps agent <pane> into <window> as a split and focuses it.
split_show() {
  local pane="$1" window="$2" dir size holder
  case "$(tmux display-message -p -t "$window" '#{session_name}' 2>/dev/null)" in
  "$(get_tmux_option @claude_session_prefix 'claude-')"*)
    tmux display-message "tmux-claude-hatch: can't show an agent inside an agent session"
    return 1
    ;;
  esac
  dir="$(get_tmux_option @claude_split_direction 'right')"
  size="$(get_tmux_option @claude_split_size '50%')"
  case "$dir" in
  left) dir=(-h -b) ;;
  up) dir=(-v -b) ;;
  down) dir=(-v) ;;
  *) dir=(-h) ;;
  esac

  # Holds the session open; exits once the agent pane is gone (Claude quit or
  # was killed), so the session dies with it.
  holder="$(tmux split-window "${dir[@]}" -l "$size" -d -P -F '#{pane_id}' -t "$window" \
    "while tmux has-session -t '$pane' 2>/dev/null; do sleep 2; done")" || {
    tmux display-message "tmux-claude-hatch: could not split window $window"
    return 1
  }

  tmux swap-pane -d -s "$pane" -t "$holder" 2>/dev/null || {
    tmux kill-pane -t "$holder"
    tmux display-message "tmux-claude-hatch: agent pane $pane is gone"
    return 1
  }
  tmux set-option -p -t "$pane" @claude_placeholder "$holder"
  tmux select-window -t "$window"
  tmux select-pane -t "$pane"
}
