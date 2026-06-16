#!/usr/bin/env bash
# Print published version integers for this mirror's component.
# Side effect: writes a component-filtered cache (~1KB) the wedge reuses,
# so the daily run hits the directory once total, not twice.
set -uo pipefail
PLUGLIST_URL="${PLUGLIST_URL:-https://download.moodle.org/api/1.3/pluglist.php}"
UA="${MOODLE_UA:-MoodleBot/1.0 (+https://moodle.org)}"
COMPONENT="$(jq -r '.extra["moodle-composer"].component // empty' composer.json 2>/dev/null)"
[ -n "$COMPONENT" ] || { echo "component-missing" >&2; exit 1; }
CACHE_FILE="${RUNNER_TEMP:-/tmp}/goupdate-pluglist-${COMPONENT}.json"

# Hard-fail on any error so the workflow goes red and notifies — silent
# success would hide real issues like a permanent Cloudflare block, a removed
# directory listing, or upstream API breakage.
fail() {
  echo "::error::$1" >&2
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && echo "> ❌ $1" >> "$GITHUB_STEP_SUMMARY"
  exit 1
}

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL -A "$UA" --retry 3 --retry-all-errors --retry-delay 5 --max-time 180 \
  "$PLUGLIST_URL" -o "$TMP/pluglist.json" 2>"$TMP/curl.err" \
  || fail "could not reach the Moodle plugins directory: $(cat "$TMP/curl.err" 2>/dev/null | head -1)"
jq -e . "$TMP/pluglist.json" >/dev/null 2>&1 \
  || fail "plugins directory response is not valid JSON (Cloudflare challenge? upstream API change?)"
jq -e --arg c "$COMPONENT" '[(.plugins // .)[] | select(.component==$c)] | length > 0' \
  "$TMP/pluglist.json" >/dev/null 2>&1 \
  || fail "${COMPONENT} is no longer listed in the plugins directory"

jq --arg c "$COMPONENT" '[(.plugins // .)[] | select(.component==$c) | .versions[]]' \
  "$TMP/pluglist.json" > "$CACHE_FILE.tmp" && mv "$CACHE_FILE.tmp" "$CACHE_FILE"
# Emit valid $plugin->version date integers only. Trim stray whitespace
# (some entries are e.g. "2012022200 "), then drop anything that isn't a
# plain integer with an optional .NN decimal (e.g. "v0.5.0", "Moodle 1.9").
jq -r '.[].version | tostring | gsub("^\\s+|\\s+$";"")' "$CACHE_FILE" \
  | grep -E '^[0-9]+(\.[0-9]+)?$' | sort -n
