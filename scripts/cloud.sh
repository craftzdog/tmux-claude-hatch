#!/usr/bin/env bash
# Claude Code cloud sessions (claude.ai/code), for the picker.
#
#   cloud.sh                          one record per session (used by agents.sh),
#                                     and the sessions saved for the preview
#   cloud.sh --preview <id>           the session's latest turns (used by the
#                                     picker's preview)
#   cloud.sh --label <id>             the session's details (used as the label on
#                                     the preview's bottom border)
#
# Reads the endpoints Claude Code's own `claude --teleport` lists sessions and
# their history from. They are undocumented, so every failure — no claude.ai
# login, an expired token, no network, a reshaped response — yields nothing
# rather than an error.
#
#   Rec: status \t session-id \t pid \t kind \t seen-at \t loc \t path
#   The record agents.sh formats into a row; pid is empty and kind and loc are
#   both `cloud`.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers.sh
. "$DIR/helpers.sh"

# oauth_token
# The claude.ai OAuth access token Claude Code signed in with: a file on Linux, the
# login keychain on macOS. An expired token is skipped rather than refreshed; the
# next `claude` run refreshes it.
oauth_token() {
  local creds="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/.credentials.json"
  {
    if [ -r "$creds" ]; then
      cat "$creds"
    elif command -v security >/dev/null 2>&1; then
      security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null
    fi
  } | jq -r '.claudeAiOauth // empty
    | select(.accessToken and (.expiresAt == null or .expiresAt / 1000 > now))
    | .accessToken' 2>/dev/null
}

# api_get <path>
# The token goes in on stdin, so it never shows up in `ps`.
api_get() {
  local token
  token="$(oauth_token)"
  [ -n "$token" ] || return 1
  printf 'Authorization: Bearer %s\n' "$token" |
    curl -fsS --compressed --max-time "$(get_tmux_option @claude_cloud_timeout '5')" \
      -H @- -H 'anthropic-version: 2023-06-01' \
      "https://api.anthropic.com$1" 2>/dev/null
}

# cloud.sh --label <session-id>
# The session's title, repo and link, from the last listing, on one line that
# fits the border.
if [ "${1:-}" = '--label' ]; then
  jq -r --arg id "${2:-}" --arg url "$(cloud_url "${2:-}")" --argjson width "$((${FZF_COLUMNS:-80} - 6))" '
    first(.[] | select(.id == $id))
    | ([.title, .repo] | map(select(. != "")) | join(" · ")) as $about
    | ($width - ($url | length) - 3) as $room
    | if $room < 10 then " \($url) "
      elif ($about | length) > $room then " \($about[:$room - 1])… · \($url) "
      else " \($about) · \($url) " end
    ' "$(cache_path cloud.json)" 2>/dev/null
  exit 0
fi

command -v curl >/dev/null 2>&1 || exit 0

# cloud.sh --preview <session-id>
# Prints the session's latest turns the way Claude Code draws them in a pane:
# prompts, replies, and each tool call with the first line of its result (stderr
# in red), or for an edit, its diff.
# Events are Claude Code's stream-json messages, newest first. Only the main
# thread's user and assistant messages are kept: progress, system, control and
# rate-limit frames, and subagents' messages (those with a parent_tool_use_id),
# make up most of a page, so it is fetched at 500, the largest size the API
# accepts. The result is cached for a few seconds, so moving back onto a row is
# instant.
#
# While a fetch is under way a loading line stands in for the transcript; fzf
# wipes it when the clear-screen sequence arrives.
if [ "${1:-}" = '--preview' ]; then
  case "${2:-}" in '' | */* | *[!A-Za-z0-9_-]*) exit 0 ;; esac
  out="$(cache_path "cloud-$2.txt")"
  mtime="$(file_mtime "$out")"
  if [ -z "$mtime" ] || [ $(($(date +%s) - mtime)) -ge 10 ]; then
    printf '\033[90mLoading conversation…\033[0m\n'
    # A failed fetch keeps the last transcript rather than blanking it.
    turns="$(api_get "/v1/code/sessions/$2/events?limit=500&sort_order=desc" | jq -r '
      def clip($n): if length > $n then .[:$n - 1] + "…" else . end;
      def oneline: gsub("\\s+"; " ") | ltrimstr(" ");
      def nonblank: split("\n") | map(select(test("\\S")));
      def pad: tostring | " " * (5 - length) + .;
      def plural($n; $w): "\($n) \($w)\(if $n == 1 then "" else "s" end)";
      def more($n): if $n > 0 then " \u001b[90m… +\($n) lines\u001b[0m" else "" end;
      def blocks: if type == "string" then [{ type: "text", text: . }] else . // [] end;
      def text_of: blocks | map(select(.type == "text") | .text) | join("\n");
      def args: (.command // .file_path // .notebook_path // .pattern // .path // .url
                 // .query // .skill // .description // .prompt // "") | tostring | oneline | clip(80);
      # Tags wrapped around a whole text block are harness plumbing (system
      # reminders, slash-command echoes), not something typed.
      def plumbing: test("^\\s*<[a-z_-]+>[\\s\\S]*</[a-z_-]+>\\s*$");
      # A note that opens with a "[Tag]" preamble reads as the tag and the first
      # line of the indented body it frames, e.g. "Subagent hand-back: Found 0 …".
      def note: nonblank as $lines
        | ([$lines[0] // "" | capture("^\\[(?<tag>[^]]+)\\]")] | .[0].tag) as $tag
        | if $tag then "\($tag): \(first($lines[] | select(test("^\\s")) | oneline) // "")"
          else $lines[0] // "" end;
      # result(colour): the first line of a result, and how many more there are.
      def result($c): "  ⎿  \($c)\((.[0] // "(no output)") | oneline | clip(100))\u001b[0m"
        + more(length - 1) + "\n";
      # An edit is drawn as its diff, numbered by the line it lands on, the way
      # Claude Code shows it: removals red, additions green, context dim. Long
      # diffs are cut after 20 lines.
      def patch:
        (map(reduce .lines[] as $l ({ old: .oldStart, new: .newStart, add: 0, del: 0, out: [] };
            ($l[1:]) as $t
            | if ($l | startswith("-")) then
                .out += ["\u001b[31m\(.old | pad) -\($t)\u001b[0m"] | .old += 1 | .del += 1
              elif ($l | startswith("+")) then
                .out += ["\u001b[32m\(.new | pad) +\($t)\u001b[0m"] | .new += 1 | .add += 1
              else .out += ["\u001b[90m\(.new | pad)  \($t)\u001b[0m"] | .old += 1 | .new += 1 end))) as $hunks
        | ([$hunks[] | ["\u001b[90m    ⋮\u001b[0m"] + .out] | add | .[1:]) as $lines
        | "  ⎿  \(plural([$hunks[].add] | add; "addition")) and \(plural([$hunks[].del] | add; "removal"))\n"
          + ($lines[:20] | map("     " + .) | join("\n"))
          + (if ($lines | length) > 20 then "\n    " + more(($lines | length) - 20) else "" end)
          + "\n";

      .data | reverse | .[].payload
      | select((.type == "user" or .type == "assistant") and .parent_tool_use_id == null
               and (.isMeta | not))
      | .type as $role
      | .isSynthetic as $synthetic
      | .origin.body? as $origin
      | ((.tool_use_result | objects) // {}) as $details
      | .message.content | blocks[]
      # A synthetic message is one the harness sent in, such as a subagent handing
      # back its report; it gets one dim line.
      | if $synthetic and .type == "text" then
          "\u001b[90m✉ \($origin // .text | tostring | note | clip(100))\u001b[0m\n"
        elif .type == "text" and (.text | test("\\S")) and (.text | plumbing | not) then
          if $role == "user" then "\u001b[1;36m❯\u001b[0m \(.text | sub("\\s+$"; ""))\n"
          else "● \(.text | sub("\\s+$"; ""))\n" end
        elif .type == "tool_use" then
          "\u001b[32m●\u001b[0m \u001b[1m\(.name)\u001b[0m(\(.input | args))"
        elif .type == "tool_result" then
          if .is_error then .content | text_of | nonblank | result("\u001b[31m")
          elif $details.structuredPatch | type == "array" and length > 0 then
            $details.structuredPatch | patch
          elif $details.type == "create" then
            "  ⎿  Wrote \($details.content // "" | nonblank | length) lines to \($details.filePath // "the file")\n"
          elif $details.stdout | type == "string" then
            # Bash keeps stderr apart from stdout, so it can be shown in red.
            ($details.stdout | nonblank) as $out | ($details.stderr // "" | nonblank) as $err
            | if ($err | length) == 0 then $out | result("\u001b[90m")
              elif ($out | length) == 0 then $err | result("\u001b[31m")
              else ($out | result("\u001b[90m")) + ($err | result("\u001b[31m") | sub("⎿"; " "))
              end
          else .content | text_of | nonblank | result("\u001b[90m") end
        else empty end' 2>/dev/null)" && printf '%s\n' "$turns" | write_atomic "$out"
    printf '\033[2J'
  fi
  cat "$out" 2>/dev/null
  exit 0
fi

# Timestamps arrive as ISO 8601 with fractional seconds, which fromdateiso8601
# rejects. Archived sessions, and any idle for longer than @claude_cloud_max_age
# hours, are left out. Titles and repos are settled here, once, for both the
# records and the preview.
sessions="$(api_get /v1/code/sessions | jq -c \
  --argjson max_age "$(get_tmux_option @claude_cloud_max_age '24')" '
  def epoch: try (sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601) catch null;
  [ .data[]
    | select(.status != "archived")
    | . + { seen: ((.last_event_at // .created_at) | epoch) }
    | select(.seen != null and now - .seen < $max_age * 3600)
    | . + { title: (.title // "" | if . == "" then "Untitled" else . end),
            repo: (first(.config.sources[]? | select(.type == "git_repository") | .url
                   | capture("(?<r>[^/:]+/[^/]+?)(\\.git)?/?$").r) // "") }
  ]' 2>/dev/null)" || exit 0

printf '%s\n' "$sessions" | write_atomic "$(cache_path cloud.json)"

# The API's worker statuses, in agents.sh's terms; requires_action is a
# permission prompt or question waiting on you.
printf '%s' "$sessions" | jq -r '
  .[]
  | [({ requires_action: "waiting", idle: "idle", running: "busy" }[.worker_status // ""] // "unknown"),
     .id, "", "cloud", .seen, "cloud",
     ([.repo, .title] | map(select(. != "")) | join(" · ") | gsub("[\t\n]"; " "))]
  | @tsv' 2>/dev/null
exit 0
