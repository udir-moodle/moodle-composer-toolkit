#!/usr/bin/env bash
# find-dynamic-plugins.sh — list version.php files whose $plugin->component
# goupdate's scan CANNOT read, so they never appear in `goupdate outdated`:
#   - DYNAMIC: component built from a variable, e.g. "auth_{$dir}"
#   - MISSING: no $plugin->component line at all (legacy path-based plugin)
# These are the blind spots to check by hand during a migration. Run from the
# project root (or pass a path); exits 0 with a table, or "none" if all clean.
#
#   ./find-dynamic-plugins.sh [path]
set -euo pipefail

ROOT="${1:-.}"
# goupdate's literal-component regex (raw.go): a frankenstyle name in quotes.
LITERAL="plugin->component[[:space:]]*=[[:space:]]*['\"][a-z][a-z0-9]*_[a-z0-9_]+"

# Best-effort component guess from the file's path (reverse of Moodle layout).
guess() {
  local d; d="$(dirname "$1")"
  case "$d" in
    */mod/*)            echo "mod_$(basename "$d")";;
    */blocks/*)         echo "block_$(basename "$d")";;
    */question/type/*)  echo "qtype_$(basename "$d")";;
    */question/format/*)echo "qformat_$(basename "$d")";;
    */course/format/*)  echo "format_$(basename "$d")";;
    */admin/tool/*)     echo "tool_$(basename "$d")";;
    */auth/*)           echo "auth_$(basename "$d")";;
    */enrol/*)          echo "enrol_$(basename "$d")";;
    */theme/*)          echo "theme_$(basename "$d")";;
    */filter/*)         echo "filter_$(basename "$d")";;
    */local/*)          echo "local_$(basename "$d")";;
    */repository/*)     echo "repository_$(basename "$d")";;
    *)                  echo "?_$(basename "$d")";;
  esac
}

rows=""; skipped=0
while IFS= read -r -d '' f; do
  if grep -qE "$LITERAL" "$f"; then
    continue                                   # literal — goupdate reads it fine
  elif grep -qE '^[[:space:]]*\$branch[[:space:]]*=' "$f"; then
    skipped=$((skipped+1)); continue           # Moodle core root version.php — not a plugin
  elif grep -qE 'plugin->component[[:space:]]*=' "$f"; then
    raw=$(grep -m1 -E 'plugin->component[[:space:]]*=' "$f" | sed 's/^[[:space:]]*//; s/;.*$//')
    rows+="DYNAMIC|$(guess "$f")|$f|$raw"$'\n'
  else
    rows+="MISSING|$(guess "$f")|$f|(no \$plugin->component)"$'\n'
  fi
  # core test scaffolding never ships as an installable plugin
done < <(find "$ROOT" -name version.php \
           -not -path '*/vendor/*' -not -path '*/node_modules/*' \
           -not -path '*/tests/*'  -not -path '*/fixtures/*' -print0)

note="(whitelisted $skipped Moodle-core root version.php; tests/fixtures excluded)"
if [ -z "$rows" ]; then
  echo "No undetectable plugins — every version.php has a literal \$plugin->component."
  echo "$note"
  exit 0
fi

printf '%-8s  %-28s  %s\n' "REASON" "GUESSED COMPONENT" "FILE / DECLARATION"
printf '%-8s  %-28s  %s\n' "------" "----------------------------" "------------------"
printf '%s' "$rows" | sort | while IFS='|' read -r reason guess file raw; do
  printf '%-8s  %-28s  %s\n' "$reason" "$guess" "$file"
  printf '%-8s  %-28s    %s\n' "" "" "$raw"
done
n=$(printf '%s' "$rows" | grep -c .)
echo
echo "$n plugin(s) goupdate's scan will miss — verify these by hand during migration."
echo "$note" >&2
