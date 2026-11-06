#!/usr/bin/env bash
# Interactive picker for running Claude agents.
#
#   picker.sh           fzf picker; on enter, jumps to the chosen agent.
#   picker.sh --list    print the rows and refresh the cache (used by fzf's
#                       async initial load and by the ctrl-x reload).
#   picker.sh --copy <text>
#                       copy <text>, minus its column padding, to the clipboard
#                       (used by ctrl-y).
#   picker.sh --fallback
#                       fzf `result` hook: when the query matches no session name,
#                       widen the search to the path (reads FZF_QUERY,
#                       FZF_MATCH_COUNT and FZF_NTH).
#   picker.sh --preview <pane>
#                       capture <pane> without its trailing blank lines, which
#                       would otherwise leave fzf's `follow` scrolled onto padding.
#
# Rows come from agents.sh, which pairs each running Claude with the tmux pane it
# occupies; its first line is the column header (fzf --header-lines). Two kinds
# of row jump differently:
#   dedicated  a Claude in a `claude-*` session this plugin launched — resumed in
#              the popup, over the window it was launched from.
#   loose      a Claude running in any other pane — focused in place.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

cache="${TMPDIR:-/tmp}/tmux-claude-agents-$(id -u).cache"

# Searchable columns, numbered within the displayed fields (--with-nth=5..9:
# name, status, last active, tmux session, path).
NTH_NAME=1
NTH_PATH=5

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

if [ "${1:-}" = '--fallback' ]; then
  [ -n "${FZF_QUERY:-}" ] && [ "${FZF_MATCH_COUNT:-1}" -eq 0 ] &&
    [ "${FZF_NTH:-}" = "$NTH_NAME" ] && printf 'change-nth(%s)' "$NTH_PATH"
  exit 0
fi

if [ "${1:-}" = '--copy' ]; then
  text="${2:-}"
  text="${text%"${text##*[![:space:]]}"}"
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

# Typing filters by session name. When nothing matches, the search falls back to
# the path; editing the query goes back to names. That needs change-nth (fzf
# 0.56+); older fzf just searches name and path together.
fzf_ver=$(fzf --version 2>/dev/null | awk '{ print $1 }')
if [ "$(printf '%s\n0.56\n' "$fzf_ver" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = 0.56 ]; then
  search_opts=(--nth="$NTH_NAME"
    --bind="change:first+change-nth($NTH_NAME)"
    --bind="result:transform($self --fallback)")
else
  search_opts=(--nth="$NTH_NAME,$NTH_PATH" --bind='change:first')
fi

# ctrl-x kills the Claude process itself: a dedicated session dies with its last
# window, while a loose pane keeps the shell that hosted it. The reload waits a
# beat so the process is gone by the time agents.sh looks for it.
# ctrl-y copies the agent's location (session:window.pane, e.g. claude-88074b0e:0.0)
# and closes the picker.
sel=$("${list_cmd[@]}" | fzf --ansi --delimiter='\t' --with-nth=5,6,7,8,9 --header-lines=1 \
  --reverse --cycle --header='Claude agents · type: name, then path · enter: jump · ctrl-x: kill · ctrl-y: copy' \
  --preview="$self --preview {2}" --preview-window='up,70%,follow' \
  --bind="ctrl-x:execute-silent(kill {3})+reload(sleep 0.3; $self --list)" \
  --bind="ctrl-y:execute-silent($self --copy {8})+abort" \
  "${search_opts[@]}" \
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
