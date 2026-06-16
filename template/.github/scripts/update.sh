#!/usr/bin/env bash
# Apply one published version of this mirror's Moodle plugin.
# Called by goupdate as update.commands with --apply <version>.
set -euo pipefail

APPLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --apply)   APPLY="$2"; shift 2 ;;
    --apply=*) APPLY="${1#*=}"; shift ;;
    *)         echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done
[ -n "${APPLY}" ] || { echo "missing --apply <VERSION>" >&2; exit 2; }

PLUGLIST_URL="${PLUGLIST_URL:-https://download.moodle.org/api/1.3/pluglist.php}"
UA="${MOODLE_UA:-MoodleBot/1.0 (+https://moodle.org)}"
REPO_ROOT="$(pwd)"
emit() { printf '%s\n' "$*" >>"${GITHUB_OUTPUT:-/dev/null}"; }

COMPONENT="$(jq -r '.extra["moodle-composer"].component // empty' composer.json 2>/dev/null || true)"
[ -n "${COMPONENT}" ] || { echo "no component configured (extra.moodle-composer.component)" >&2; exit 1; }
emit "component=${COMPONENT}"

TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT

# Cache is single-run: list-versions.sh always overwrites it on each new
# goupdate invocation. This fallback only fires for direct manual runs.
CACHE_FILE="${RUNNER_TEMP:-/tmp}/goupdate-pluglist-${COMPONENT}.json"
if [ ! -s "${CACHE_FILE}" ]; then
  curl -fsSL -A "${UA}" --retry 3 --retry-all-errors --retry-delay 5 --max-time 180 \
    "${PLUGLIST_URL}" -o "${TMP}/pluglist.json"
  jq --arg c "${COMPONENT}" '[(.plugins // .)[] | select(.component==$c) | .versions[]]' \
    "${TMP}/pluglist.json" > "${CACHE_FILE}"
fi

row="$(jq -r --arg v "${APPLY}" '
  .[] | select((.version|tostring)==$v)
  | [(.version|tostring), (.release // ""), (.downloadurl // ""), (.downloadmd5 // ""),
     ([.supportedmoodles[]?.release] | join(" "))] | @tsv' "${CACHE_FILE}" | head -1)"
[ -n "${row}" ] || { echo "${COMPONENT} ${APPLY} not in directory" >&2; exit 1; }
fld() { printf '%s\n' "${row}" | cut -f"$1"; }
up_version="$(fld 1)"; up_release="$(fld 2)"; up_url="$(fld 3)"
up_md5="$(fld 4)";     up_supported="$(fld 5)"

curl -fsSL -A "${UA}" --retry 3 --retry-delay 5 --max-time 300 "${up_url}" -o "${TMP}/plugin.zip"
if [ -n "${up_md5}" ] && command -v md5sum >/dev/null; then
  got="$(md5sum "${TMP}/plugin.zip" | cut -d' ' -f1)"
  [ "${got}" = "${up_md5}" ] || { echo "md5 mismatch: got ${got} expected ${up_md5}" >&2; exit 1; }
fi
unzip -q "${TMP}/plugin.zip" -d "${TMP}/zip"
src="$(find "${TMP}/zip" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[ -d "${src}" ] || { echo "unexpected zip layout" >&2; exit 1; }

# Wipe & replace; only these survive (composer.lock is upstream's, drop it).
keep=( ! -name '.git' ! -name '.github' ! -name 'composer.json' ! -name '.goupdate.yml' )
find . -mindepth 1 -maxdepth 1 "${keep[@]}" -exec rm -rf {} +
( cd "${src}" && find . -mindepth 1 -maxdepth 1 "${keep[@]}" ! -name 'composer.lock' -exec cp -a {} "${REPO_ROOT}/" \; )

if [ -n "${up_supported}" ]; then
  constraint=""
  for r in ${up_supported}; do constraint="${constraint}${constraint:+ || }${r}.*"; done
else
  constraint="*"
fi
jq --arg c "${constraint}" '.require["moodle/moodle"] = $c' composer.json >composer.json.tmp \
  && mv composer.json.tmp composer.json

vp_ver() { grep -oE "\\\$plugin->version[[:space:]]*=[[:space:]]*[0-9]+(\.[0-9]+)?" "$1" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?' | tail -1; }
tag="$(vp_ver version.php)"
: "${tag:=${up_version}}"

emit "updated=true"
emit "release=${up_release}"
emit "version=${up_version}"
emit "tag=${tag}"
echo "applied ${COMPONENT} ${up_release} (${up_version}) → moodle/moodle: ${constraint}"
