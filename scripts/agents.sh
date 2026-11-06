#!/usr/bin/env bash
# Emit one picker row per running Claude that lives in a tmux pane.
#
# Claude self-reports its status: each session writes its own state to disk. We
# read those files, falling back to `claude agents --json`. So this needs no
# Claude Code hooks, and no `pane_current_command` scan — on macOS a pane reports
# its parent shell there, never the `claude` child running inside it.
#
# Identity is the Claude process, not the tmux session. Joining pid -> tty -> pane
# is what lets several Claudes in one project (same cwd, same session, different
# windows) each get a row of their own.
#
#   Row: rank \t pane_id \t pid \t kind \t name \t icon \t age \t loc \t path
#   rank/pane_id/pid/kind are hidden from the display via fzf's --with-nth; the
#   rest show as the Name, Status, Last active, Tmux session and Path columns.
#   name is the Claude session name (set with /rename, otherwise derived by
#   Claude), or '-' when there is none.
#
# The first line is a column header (kind "header") for fzf's --header-lines.
# Every column but the last is padded to its widest cell, header included, so
# the labels line up with the rows.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

# session_recs
# `procStart` lets render() tell a live agent from a stale file; `statusUpdatedAt`
# feeds the age column. The files are an internal Claude Code detail, so a missing
# directory or a file caught mid-write fails this, and the caller asks the CLI.
#
#   Rec: pid \t status \t session-id \t cwd \t seen-at \t proc-start \t name
session_recs() {
  local files
  files=("${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/sessions/*.json)
  [ -f "${files[0]}" ] || return 1
  jq -r 'select(.kind == "interactive")
    | ((.statusUpdatedAt // .updatedAt) as $t | if $t then ($t / 1000 | floor) else "" end) as $seen
    | [.pid, .status, .sessionId, .cwd, $seen, .procStart, (.name // "")] | @tsv' "${files[@]}" 2>/dev/null
}

# cli_recs
# Fallback when the session files can't be read. It has already dropped dead
# agents, so proc-start stays empty. It reports no last-activity time either; the
# transcript's mtime stands in for it.
cli_recs() {
  $(get_tmux_option @claude_command 'claude') agents --json 2>/dev/null |
    jq -r '.[] | select(.kind == "interactive") | [.pid, .status, .sessionId, .cwd, (.name // "")] | @tsv' 2>/dev/null |
    while IFS=$'\t' read -r pid status sid cwd name; do
      printf '%s\t%s\t%s\t%s\t%s\t\t%s\n' "$pid" "$status" "$sid" "$cwd" "$(claude_transcript_mtime "$sid")" "$name"
    done
}

# proc_starts <recs>
# Linux only: Claude records field 22 of /proc/<pid>/stat as proc-start there.
# Strip greedily past ") " first — field 2 is the parenthesised command name and
# may itself contain ") " — which leaves field 22 as the 20th of what remains.
proc_starts() {
  printf '%s\n' "$1" | cut -f1 | while IFS= read -r pid; do
    IFS= read -r stat 2>/dev/null <"/proc/$pid/stat" || continue
    # shellcheck disable=SC2086 # deliberate split into positional parameters
    set -- ${stat##*) }
    [ $# -ge 20 ] && printf 'S\t%s\t%s\n' "$pid" "${20}"
  done
}

# render <recs> <verify>
# Tagged streams into one awk: pid->tty+start, tty->pane, and the agents. One `ps`
# serves both joins, which matters on macOS where each call costs over 100ms.
#
# With <verify> set, the recs came from the session files and liveness is on us —
# ctrl-x kills the pid on the row. A crashed Claude leaves its file behind and the
# pid may since have been recycled, so a rec counts only while that pid still has
# the start time the file recorded: `ps lstart` in UTC, or /proc on Linux. A rec
# missing a field, or not one pid verified, means the format moved on: fail, so
# the caller falls back to the CLI.
render() {
  {
    # Rejoining the fields with single spaces undoes the padding of a
    # single-digit day ("Sep  1").
    TZ=UTC LC_ALL=C ps -o pid=,tty=,lstart= -p "$(printf '%s\n' "$1" | cut -f1 | paste -sd, -)" 2>/dev/null |
      awk '{ print "P\t" $1 "\t" $2 "\t" $3 " " $4 " " $5 " " $6 " " $7 }'
    [ -r /proc/self/stat ] && proc_starts "$1"
    tmux list-panes -a -F $'T\t#{pane_tty}\t#{pane_id}\t#{session_name}\t#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null
    printf '%s\n' "$1" | sed $'s/^/A\t/'
  } | awk -F'\t' -v verify="$2" -v now="$(date +%s)" -v home="$HOME" \
    -v prefix="$(get_tmux_option @claude_session_prefix 'claude-')" '
    $1 == "P" { tty_of[$2] = $3; start[$2] = $4; next }
    $1 == "S" { start[$2] = $3; next }
    $1 == "T" { sub(/^\/dev\//, "", $2); pane[$2] = $3; sess[$2] = $4; loc[$2] = $5; next }
    $1 == "A" && $2 != "" {
      if (verify) {
        if ($3 == "" || $4 == "" || $5 == "" || $7 == "") { bad = 1; exit }
        gsub(/ +/, " ", $7)
        if (start[$2] != $7) next             # stale file: dead, or the pid was recycled
      }
      live++

      tty = tty_of[$2]
      if (tty == "" || !(tty in pane)) next   # this Claude is not running inside tmux

      if      ($3 == "waiting") { icon = "\033[33m●\033[0m waiting"; rank = 0 }  # yellow - needs input
      else if ($3 == "idle")    { icon = "\033[32m●\033[0m idle   "; rank = 1 }  # green  - done, your turn
      else if ($3 == "busy")    { icon = "\033[31m●\033[0m working"; rank = 3 }  # red    - busy, leave it
      else                      { icon = "\033[90m●\033[0m   ?    "; rank = 2 }  # grey   - unrecognised status

      secs = ($6 != "") ? now - $6 : 1e12   # unknown activity sorts last
      mins = int(secs / 60)
      if      ($6 == "")    age = "-"
      else if (mins < 60)   age = mins "m ago"
      else if (mins < 2880) age = int(mins / 60) "h ago"
      else                  age = int(mins / 1440) "d ago"
      kind = (index(sess[tty], prefix) == 1) ? "dedicated" : "loose"

      path = $5
      if (index(path, home) == 1) path = "~" substr(path, length(home) + 1)

      n++
      key[n] = secs "\t" rank "\t" pane[tty] "\t" $2 "\t" kind
      st[n] = icon; ag[n] = age; lo[n] = loc[tty]
      nm[n] = ($8 != "") ? $8 : "-"
      pa[n] = path
    }
    END {
      if (bad || !live) exit 1
      if (!n) exit 0
      # Rows are held until here so each column can be padded to its widest cell.
      # The status cell carries colour codes but always shows 9 characters.
      wa = length("Last active"); wl = length("Tmux session"); wn = length("Name")
      for (i = 1; i <= n; i++) {
        if (length(ag[i]) > wa) wa = length(ag[i])
        if (length(lo[i]) > wl) wl = length(lo[i])
        if (length(nm[i]) > wn) wn = length(nm[i])
      }
      fmt = "%s\t%-" wn "s\t%-9s\t%-" wa "s\t%-" wl "s\t%s\n"
      # secs/rank of -1 sort the header above every row in either sort mode.
      printf fmt, "-1\t-1\t\t\theader", "Name", "Status", "Last active", "Tmux session", "Path"
      for (i = 1; i <= n; i++) printf fmt, key[i], nm[i], st[i], ag[i], lo[i], pa[i]
    }
  ' | sort -t$'\t' $sort_keys | cut -f2-
  # The age column mixes units ("5m ago", "3h ago"), so the sort runs on a leading
  # seconds column, cut off once it has served.
}

# status: rank asc (what needs you floats up), then age asc so whatever just went
# idle sits at the top of its group. recent: age asc alone.
if [ "$(get_tmux_option @claude_sort 'status')" = recent ]; then
  sort_keys='-k1,1n'
else
  sort_keys='-k2,2n -k1,1n'
fi

{ recs="$(session_recs)" && out="$(render "$recs" 1)"; } ||
  { recs="$(cli_recs)" && out="$(render "$recs" '')"; } || exit 0
[ -n "$out" ] && printf '%s\n' "$out"
exit 0
