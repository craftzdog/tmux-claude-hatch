#!/usr/bin/env bash
# Interactive picker for running Claude agents.
#
#   picker.sh           fzf picker; on enter, jumps to the chosen agent.
#   picker.sh --list    print the rows and refresh the cache (used by fzf's
#                       async initial load and by the ctrl-x reload).
#   picker.sh --copy <text>
#                       copy <text> to the clipboard (used by ctrl-y).
#   picker.sh --preview <pane>
#                       capture <pane> without its trailing blank lines, which
#                       would otherwise leave fzf's `follow` scrolled onto padding.
#
# Rows come from agents.sh, which pairs each running Claude with the tmux pane it
# occupies. Two kinds of row jump differently:
#   dedicated  a Claude in a `claude-*` session this plugin launched — resumed in
#              the popup over the window it was launched from (or, in split
#              mode, swapped into that window as a split).
#   loose      a Claude running in any other pane — focused in place.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"
# shellcheck source=split.sh
. "$DIR/split.sh"

cache="${TMPDIR:-/tmp}/tmux-claude-agents-$(id -u).cache"

if [ "${1:-}" = '--list' ]; then
  tmp="$cache.$$"
  "$DIR/agents.sh" >"$tmp" 2>/dev/null
  mv -f "$tmp" "$cache" 2>/dev/null || rm -f "$tmp"
  cat "$cache" 2>/dev/null
  exit 0
fi

if [ "${1:-}" = '--preview' ]; then
  # A line holding only escape codes (from -e) is still blank.
  tmux capture-pane -ept "${2:-}" 2>/dev/null |
    awk -v esc="$(printf '\033')" '
      { line = $0; gsub(esc "\\[[0-9;]*m", "", line) }
      line ~ /^[[:space:]]*$/ { held = held $0 "\n"; next }
      { printf "%s", held; held = ""; print }
    '
  exit 0
fi

if [ "${1:-}" = '--copy' ]; then
  copy_to_clipboard "${2:-}" &&
    tmux display-message "tmux-claude-hatch: copied ${2:-}"
  exit 0
fi

for tool in fzf jq "$(get_tmux_option @claude_command 'claude')"; do
  command -v "$tool" >/dev/null 2>&1 || {
    tmux display-message "tmux-claude-hatch: $tool is required for the picker"
    exit 0
  }
done

self="$DIR/picker.sh"
export FZF_DEFAULT_OPTS=''
export CLAUDE_PICKER="$self"

# Arbitrary user fzf options (e.g. custom --bind or --preview-window)
extra_opts=()
fzf_options="$(get_tmux_option @claude_fzf_options '')"
[ -n "$fzf_options" ] && eval "extra_opts=($fzf_options)"

# Load the session list asynchronously. Painting the first frame from the cache
# can be turned off with @claude_picker_cache, since a cached frame can show a
# stale status.
list_cmd=("$self" --list)
sync_opts=()
now=$(date +%s)
mtime=$(file_mtime "$cache")
if [ "$(get_tmux_option @claude_picker_cache 'on')" = on ] &&
  [ -s "$cache" ] && [ -n "$mtime" ] && [ $((now - mtime)) -lt 3600 ]; then
  list_cmd=(cat "$cache")
  sync_opts=(--bind "load:unbind(load)+reload-sync($self --list)")
fi

# ctrl-x kills the Claude process itself: a dedicated session dies with its last
# window, while a loose pane keeps the shell that hosted it. The reload waits a
# beat so the process is gone by the time agents.sh looks for it.
# ctrl-y copies the agent's location (session:window.pane, e.g. claude-88074b0e:0.0)
# and closes the picker.
sel=$("${list_cmd[@]}" | fzf --ansi --delimiter='\t' --with-nth=5,6,7,8 \
  --reverse --cycle --header='Claude agents · enter: jump · ctrl-x: kill · ctrl-y: copy' \
  --preview="$self --preview {2}" --preview-window='up,70%,follow' \
  --bind="ctrl-x:execute-silent(kill {3})+reload(sleep 0.3; $self --list)" \
  --bind="ctrl-y:execute-silent($self --copy {7})+abort" \
  --bind='change:first' \
  ${sync_opts[@]+"${sync_opts[@]}"} \
  ${extra_opts[@]+"${extra_opts[@]}"})

[ -z "$sel" ] && exit 0
pane=$(printf '%s' "$sel" | cut -f2)
kind=$(printf '%s' "$sel" | cut -f4)

parent=$(tmux show-options -gqv @claude_parent 2>/dev/null)
session=$(tmux display-message -p -t "$pane" '#{session_name}' 2>/dev/null)

if [ "$kind" = loose ]; then
  # Focus the pane in place on the outer client. This popup closes on its own
  # when the script exits.
  if [ -n "$parent" ]; then
    tmux switch-client -c "$parent" -t "$session" 2>/dev/null
  else
    tmux switch-client -t "$session" 2>/dev/null
  fi
  tmux select-window -t "$pane" 2>/dev/null
  tmux select-pane -t "$pane" 2>/dev/null
  exit 0
fi

if [ "$(get_tmux_option @claude_display 'popup')" = split ]; then
  # Show it as a split in the window it was launched from, or the client's
  # current window when that is unknown or gone.
  origin=$(tmux show-options -qv -t "$session" @claude_origin 2>/dev/null)
  [ -n "$origin" ] && ! tmux has-session -t "$origin" 2>/dev/null && origin=''
  client=(${parent:+-c "$parent"})
  [ -n "$origin" ] && tmux switch-client ${client[@]+"${client[@]}"} -t "$origin" 2>/dev/null
  window=$(tmux display-message -p ${client[@]+"${client[@]}"} '#{window_id}')
  split_hide "$window"
  split_show "$pane" "$window"
  exit 0
fi

# Move the parent client to the window the session was launched from (best-effort),
# focus the chosen Claude's own window inside that session, then resume it in THIS
# popup over the top. Falls back to resuming over the current window when
# origin/parent are unknown.
origin=$(tmux show-options -qv -t "$session" @claude_origin 2>/dev/null)
[ -n "$origin" ] && [ -n "$parent" ] &&
  tmux switch-client -c "$parent" -t "$origin" 2>/dev/null

tmux select-window -t "$pane" 2>/dev/null
tmux select-pane -t "$pane" 2>/dev/null
tmux attach-session -t "$session"
