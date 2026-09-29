#!/usr/bin/env bash
# Interactive picker for running Claude agents.
#
#   picker.sh           fzf picker; on enter, jumps to the chosen agent.
#   picker.sh --list    print the rows and refresh the cache (used by fzf's
#                       async initial load and by the ctrl-x reload).
#   picker.sh --copy <kind> <id> <loc>
#                       copy the row's location, or a cloud session's URL, to the
#                       clipboard (used by ctrl-y).
#   picker.sh --preview <id> <kind>
#                       capture the pane <id> without its trailing blank lines,
#                       which would otherwise leave fzf's `follow` scrolled onto
#                       padding; or describe the cloud session <id> and show its
#                       latest turns.
#
# Rows come from agents.sh, which pairs each running Claude with the tmux pane it
# occupies. Three kinds of row jump differently:
#   dedicated  a Claude in a `claude-*` session this plugin launched — resumed in
#              the popup, over the window it was launched from.
#   loose      a Claude running in any other pane — focused in place.
#   cloud      a claude.ai/code session — opened in the browser.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

cache="$(cache_path agents.cache)"

if [ "${1:-}" = '--list' ]; then
  "$DIR/agents.sh" 2>/dev/null | write_atomic "$cache"
  cat "$cache" 2>/dev/null
  exit 0
fi

if [ "${1:-}" = '--preview' ] && [ "${3:-}" = cloud ]; then
  exec "$DIR/cloud.sh" --preview "${2:-}"
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
  text="${4:-}"
  [ "${2:-}" = cloud ] && text="$(cloud_url "${3:-}")"
  copy_to_clipboard "$text" &&
    tmux display-message "tmux-claude-hatch: copied $text"
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

# On cloud rows only, the session's details and link label the preview's bottom
# border, between the conversation and the list, and the preview wraps: a
# captured pane is already laid out for its width, but a cloud transcript is not.
# `transform` needs fzf 0.45. `focus` misses the first row when the list first
# loads, so `result` runs it too.
cloud_opts=()
if [ "$(get_tmux_option @claude_cloud 'off')" = on ]; then
  on_row="transform[test {4} = cloud && echo 'change-preview-window(wrap)' || echo 'change-preview-window(nowrap)']+transform-preview-label(test {4} = cloud && $DIR/cloud.sh --label {2})"
  cloud_opts=(--preview-label-pos=2:bottom --bind "focus:$on_row" --bind "result:$on_row")
fi

# ctrl-x kills the Claude process itself: a dedicated session dies with its last
# window, while a loose pane keeps the shell that hosted it. The reload waits a
# beat so the process is gone by the time agents.sh looks for it.
# A cloud row has no pid, so nothing to kill.
# ctrl-y copies the agent's location (session:window.pane, e.g. claude-88074b0e:0.0),
# or a cloud session's URL, and closes the picker.
sel=$("${list_cmd[@]}" | fzf --ansi --delimiter='\t' --with-nth=5,6,7,8 \
  --reverse --cycle --header='Claude agents · enter: jump · ctrl-x: kill · ctrl-y: copy' \
  --preview="$self --preview {2} {4}" --preview-window='up,70%,follow' \
  --bind="ctrl-x:execute-silent([ -z {3} ] || kill {3})+reload(sleep 0.3; $self --list)" \
  --bind="ctrl-y:execute-silent($self --copy {4} {2} {7})+abort" \
  --bind='change:first' \
  ${sync_opts[@]+"${sync_opts[@]}"} \
  ${cloud_opts[@]+"${cloud_opts[@]}"} \
  ${extra_opts[@]+"${extra_opts[@]}"})

[ -z "$sel" ] && exit 0
pane=$(printf '%s' "$sel" | cut -f2)
kind=$(printf '%s' "$sel" | cut -f4)

if [ "$kind" = cloud ]; then
  url="$(cloud_url "$pane")"
  open_url "$url" || tmux display-message "tmux-claude-hatch: no open or xdg-open to open $url"
  exit 0
fi

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
