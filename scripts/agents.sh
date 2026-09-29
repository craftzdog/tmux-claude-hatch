#!/usr/bin/env bash
# Emit one picker row per running Claude that lives in a tmux pane, plus one per
# cloud session when @claude_cloud is on (see cloud.sh).
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
#   Row: rank \t target \t pid \t kind \t icon \t age \t loc \t path
#   rank/target/pid/kind are hidden from the display via fzf's --with-nth. The
#   target is a tmux pane id, or a cloud session id; pid is empty for the cloud.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

# session_recs
# `procStart` lets render() tell a live agent from a stale file; `statusUpdatedAt`
# feeds the age column. The files are an internal Claude Code detail, so a missing
# directory or a file caught mid-write fails this, and the caller asks the CLI.
#
#   Rec: pid \t status \t session-id \t cwd \t seen-at \t proc-start
session_recs() {
  local files
  files=("${CLAUDE_CONFIG_DIR:-$HOME/.claude}"/sessions/*.json)
  [ -f "${files[0]}" ] || return 1
  jq -r 'select(.kind == "interactive")
    | ((.statusUpdatedAt // .updatedAt) as $t | if $t then ($t / 1000 | floor) else "" end) as $seen
    | [.pid, .status, .sessionId, .cwd, $seen, .procStart] | @tsv' "${files[@]}" 2>/dev/null
}

# cli_recs
# Fallback when the session files can't be read. It has already dropped dead
# agents, so proc-start stays empty. It reports no last-activity time either; the
# transcript's mtime stands in for it.
cli_recs() {
  $(get_tmux_option @claude_command 'claude') agents --json 2>/dev/null |
    jq -r '.[] | select(.kind == "interactive") | [.pid, .status, .sessionId, .cwd] | @tsv' 2>/dev/null |
    while IFS=$'\t' read -r pid status sid cwd; do
      printf '%s\t%s\t%s\t%s\t%s\t\n' "$pid" "$status" "$sid" "$cwd" "$(claude_transcript_mtime "$sid")"
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
# the caller falls back to the CLI. Emits the records format() takes.
render() {
  {
    # Rejoining the fields with single spaces undoes the padding of a
    # single-digit day ("Sep  1").
    TZ=UTC LC_ALL=C ps -o pid=,tty=,lstart= -p "$(printf '%s\n' "$1" | cut -f1 | paste -sd, -)" 2>/dev/null |
      awk '{ print "P\t" $1 "\t" $2 "\t" $3 " " $4 " " $5 " " $6 " " $7 }'
    [ -r /proc/self/stat ] && proc_starts "$1"
    tmux list-panes -a -F $'T\t#{pane_tty}\t#{pane_id}\t#{session_name}\t#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null
    printf '%s\n' "$1" | sed $'s/^/A\t/'
  } | awk -F'\t' -v OFS='\t' -v verify="$2" -v home="$HOME" \
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

      kind = (index(sess[tty], prefix) == 1) ? "dedicated" : "loose"

      path = $5
      if (index(path, home) == 1) path = "~" substr(path, length(home) + 1)

      print $3, pane[tty], $2, kind, $6, loc[tty], path
    }
    END { exit (bad || !live) }
  '
}

# format
# Turns records from both sources into rows.
#
#   Rec: status \t target \t pid \t kind \t seen-at \t loc \t path
#
# The age column mixes units ("5m", "3h", "2d"), so each row leads with a seconds
# column for the sort, cut off by pad().
format() {
  awk -F'\t' -v OFS='\t' -v now="$(date +%s)" '{
    if      ($1 == "waiting") { icon = "\033[33m●\033[0m waiting"; rank = 0 }  # yellow - needs input
    else if ($1 == "idle")    { icon = "\033[32m●\033[0m idle   "; rank = 1 }  # green  - done, your turn
    else if ($1 == "busy")    { icon = "\033[31m●\033[0m working"; rank = 3 }  # red    - busy, leave it
    else                      { icon = "\033[90m●\033[0m   ?    "; rank = 2 }  # grey   - unrecognised status

    secs = ($5 != "") ? now - $5 : 1e12   # unknown activity sorts last
    mins = int(secs / 60)
    if      ($5 == "")    age = "-"
    else if (mins < 60)   age = mins "m"
    else if (mins < 2880) age = int(mins / 60) "h"
    else                  age = int(mins / 1440) "d"

    printf "%d\t%s\t%s\t%s\t%s\t%s\t%5s\t%s\t%s\n", secs, rank, $2, $3, $4, icon, age, $6, $7
  }'
}

# pad
# Drops the sort column. fzf expands tabs to 8-column stops, so locations of
# different lengths (`main:1.2` beside `claude-88074b0e:0.0`, or `cloud`) would
# push the path out of line; each is padded to the widest one instead. fzf strips
# the padding from {7}.
pad() {
  awk -F'\t' -v OFS='\t' '
    { sub(/^[^\t]*\t/, ""); row[NR] = $0; if (length($7) > w) w = length($7) }
    END { for (i = 1; i <= NR; i++) { $0 = row[i]; $7 = sprintf("%-" w "s", $7); print } }'
}

# status: rank asc (what needs you floats up), then age asc so whatever just went
# idle sits at the top of its group. recent: age asc alone.
if [ "$(get_tmux_option @claude_sort 'status')" = recent ]; then
  sort_keys='-k1,1n'
else
  sort_keys='-k2,2n -k1,1n'
fi

# Cloud sessions are fetched over the network, alongside the local lookup.
exec 3</dev/null
[ "$(get_tmux_option @claude_cloud 'off')" = on ] && exec 3< <("$DIR/cloud.sh" 2>/dev/null)

{ recs="$(session_recs)" && out="$(render "$recs" 1)"; } ||
  { recs="$(cli_recs)" && out="$(render "$recs" '')"; } || out=''

{
  [ -n "$out" ] && printf '%s\n' "$out"
  cat <&3
} | format | sort -t$'\t' $sort_keys | pad
exit 0
