#!/usr/bin/env bash
#
# new.sh — scaffold a Moodle-plugin → Packagist mirror repo. Looks the plugin
# up in the directory, shows compatible versions, writes the mirror files,
# seeds the chosen version, and git-inits + tags it. See usage() for options.
# Depends only on: curl, jq, unzip, git.
set -euo pipefail

PLUGLIST_URL="${PLUGLIST_URL:-https://download.moodle.org/api/1.3/pluglist.php}"
UA="${MOODLE_UA:-MoodleBot/1.0 (+https://moodle.org)}"
TEMPLATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/template"

usage() {
  cat <<'EOF'
new.sh — scaffold a Moodle-plugin → Packagist mirror repo from a directory
URL, a frankenstyle component, or just the plugin name.

  ./new.sh <moodle-plugin-url-or-component> [target-path] [options]

  <input>   a Moodle plugins directory URL, a frankenstyle component, or just
            the plugin name: https://moodle.org/plugins/theme_boost_union,
            theme_boost_union, or boost_union (ambiguous names ask which one)
  [path]    where to create the repo (default: ./<component>, e.g.
            ./theme_boost_union) — must not exist, be empty, or be a git repo

  --vendor V    your Packagist organization — packages publish as
                <vendor>/<component> (e.g. udir-moodle/mod_adaptivequiz).
                Also from env: export MOODLE_COMPOSER_VENDOR=my-org skips the prompt.
                Asked interactively if omitted; required with --yes
  --version V   seed this published $plugin->version (default: ask / latest)
  --no-seed     scaffold only; don't download/commit any plugin files
  --yes, -y     no prompts (requires --vendor; seeds --version, or latest)
  --help
EOF
}

# MOODLE_COMPOSER_VENDOR is namespaced on purpose: a generic VENDOR is preset
# by some shells (tcsh exports VENDOR=apple), which would misname packages.
VENDOR="${MOODLE_COMPOSER_VENDOR:-}"; SEED=1; AUTO=0; PICK=""; POS=()
VFROM=""; [ -n "${VENDOR}" ] && VFROM=" (from MOODLE_COMPOSER_VENDOR)"
while [ $# -gt 0 ]; do
  case "$1" in
    --vendor) [ $# -ge 2 ] || { echo "option --vendor needs a value" >&2; exit 2; }
              VENDOR="$2"; VFROM=""; shift 2 ;;
    --vendor=*) VENDOR="${1#*=}"; VFROM=""; shift ;;
    --version) [ $# -ge 2 ] || { echo "option --version needs a value" >&2; exit 2; }
               PICK="$2"; shift 2 ;;
    --version=*) PICK="${1#*=}"; shift ;;
    --no-seed) SEED=0; shift ;;
    -y|--yes)  AUTO=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
    *) POS+=("$1"); shift ;;
  esac
done
[ "${#POS[@]}" -ge 1 ] && [ "${#POS[@]}" -le 2 ] || { usage >&2; exit 2; }
INPUT="${POS[0]}"
[ "${SEED}" -eq 0 ] && [ -n "${PICK}" ] && echo "note: --version is ignored with --no-seed (no files are downloaded)" >&2

# --- output helpers ---------------------------------------------------------
section() { printf '\n===== %s =====\n' "$*"; }
kv()      { printf '  %-13s %s\n' "${1}:" "$2"; }
die()     { kv error "$*"; exit 1; }
file_md5() { if command -v md5sum >/dev/null 2>&1; then md5sum "$1" | cut -d' ' -f1; elif command -v md5 >/dev/null 2>&1; then md5 -q "$1"; fi; }

# --- requirements -----------------------------------------------------------
section "requirements"
missing=""; have=""
for t in curl jq unzip git; do
  if command -v "$t" >/dev/null 2>&1; then have="${have}${have:+  }${t} ✓"; else missing="${missing} ${t}"; fi
done
kv tools "${have}"
if [ -n "${missing}" ]; then
  kv missing "${missing# }"
  die "install the missing tool(s) first — macOS: brew install${missing}; Debian/Ubuntu: apt install${missing}; Windows: run from Git Bash and install via winget/choco"
fi

# --- resolve input (URL, frankenstyle component, or bare plugin name) --------
case "${INPUT}" in
  *moodle.org/plugins/*) query="${INPUT#*moodle.org/plugins/}" ;;
  *)                     query="${INPUT##*/}" ;;
esac
query="${query%%[/?#]*}"
[ -n "${query}" ] || die "could not read a plugin name from: ${INPUT}"

section "lookup"
TMP="$(mktemp -d)"; trap 'rm -rf "${TMP}"' EXIT
curl -fsSL -A "${UA}" --retry 3 --retry-all-errors --retry-delay 5 --max-time 180 \
  "${PLUGLIST_URL}" -o "${TMP}/pl.json" 2>/dev/null \
  || die "could not download the plugin list from the Moodle directory — check your network connection and try again"

# Try exact component, then plugin-name, then substring matches; prompt to pick.
resolve_exact() { jq -r --arg q "$1" '[(.plugins // .)[].component | strings | select(ascii_downcase == ($q|ascii_downcase))] | first // empty' "${TMP}/pl.json"; }
pick_from() {  # prompt against list file $1; Enter = first; any existing component is accepted too
  while :; do
    printf '\n  Component [%s]: ' "$(head -1 "$1")"
    read -r ans || { printf '\n'; die "aborted — nothing created"; }
    : "${ans:=$(head -1 "$1")}"
    if grep -qxF "${ans}" "$1"; then component="${ans}"; break; fi
    component="$(resolve_exact "${ans}")"
    [ -n "${component}" ] && break
    printf '  "%s" is not in the list (or the directory) — try again\n' "${ans}"
  done
  kv resolved "'${query}' -> ${component}"
}
component="$(resolve_exact "${query}")"
if [ -z "${component}" ]; then
  jq -r --arg q "${query}" '
    [(.plugins // .)[].component | strings
     | select((split("_")[1:] | join("_") | ascii_downcase) == ($q|ascii_downcase))]
    | unique | .[]' "${TMP}/pl.json" >"${TMP}/matches"
  n="$(($(wc -l <"${TMP}/matches")))"
  if [ "${n}" -eq 1 ]; then
    component="$(cat "${TMP}/matches")"
    kv resolved "'${query}' -> ${component}"
  elif [ "${n}" -gt 1 ]; then
    kv matches "$(paste -sd, "${TMP}/matches" | sed 's/,/, /g')"
    [ "${AUTO}" -eq 1 ] && die "'${query}' is ambiguous — pass the full component (e.g. $(head -1 "${TMP}/matches"))"
    pick_from "${TMP}/matches"
  else
    # no exact or name match — offer close (substring) matches
    jq -r --arg q "${query}" '(.plugins // .)[].component | strings | select(ascii_downcase | contains($q|ascii_downcase))' \
      "${TMP}/pl.json" 2>/dev/null | sort -u | head -8 >"${TMP}/matches"
    if [ ! -s "${TMP}/matches" ]; then
      kv result "NOT FOUND — '${query}' is not in the Moodle plugins directory"
      exit 1
    fi
    kv result "'${query}' not found"
    kv "did you mean" "$(paste -sd, "${TMP}/matches" | sed 's/,/, /g')"
    [ "${AUTO}" -eq 1 ] && exit 1
    pick_from "${TMP}/matches"
  fi
fi
name="$(  jq -r --arg c "${component}" '(.plugins // .)[]|select(.component==$c)|.name'      "${TMP}/pl.json" | head -1)"
source="$(jq -r --arg c "${component}" '(.plugins // .)[]|select(.component==$c)|.source//""' "${TMP}/pl.json" | head -1)"
vcount="$(jq    --arg c "${component}" '[(.plugins // .)[]|select(.component==$c)|.versions[].version|tonumber? // 0]|unique|length' "${TMP}/pl.json")"
latest="$( jq -c --arg c "${component}" '[(.plugins // .)[]|select(.component==$c)|.versions[]]|max_by(.version|tonumber? // 0)' "${TMP}/pl.json")"
lver="$(printf '%s' "${latest}" | jq -r '.version')"
lrel="$(printf '%s' "${latest}" | jq -r '.release // ""')"

# --- derive type / install-name from the resolved component ------------------
no_prefix=0
case "${component}" in
  *_*)
    prefix="${component%%_*}"
    installer="${component#*_}"
    type="moodle-${prefix}"
    ;;
  *)
    # No type prefix (frankenstyle is normally type_name) — neutral fallback.
    no_prefix=1
    prefix=""
    installer="${component}"
    type="moodle-other"
    ;;
esac
# Types composer/installers places natively (v2.3.x). Others are valid too but
# need one installer-paths line in the consuming site (the README shows it).
# Regenerate after upgrading composer/installers from MoodleInstaller.php.
NATIVE_TYPES="mod admin_report atto tool assignment assignsubmission assignfeedback antivirus auth availability block booktool cachestore cachelock calendartype communication customfield fileconverter format coursereport contenttype customcertelement datafield dataformat datapreset editor enrol filter forumreport gradeexport gradeimport gradereport gradingform local logstore ltisource ltiservice media message mlbackend mnetservice paygw plagiarism portfolio qbank qbehaviour qformat qtype quizaccess quiz report repository scormreport search theme tiny tinymce profilefield webservice workshopallocation workshopeval workshopform"
type_native=1
case " ${NATIVE_TYPES} " in *" ${prefix} "*) : ;; *) type_native=0 ;; esac
# Absolute immediately: parts of the script cd elsewhere.
TARGET="${POS[1]:-./${component}}"; TARGET="${TARGET%/}"
case "${TARGET}" in /*) : ;; *) TARGET="$(pwd)/${TARGET#./}" ;; esac

section "plugin"
kv input     "${INPUT}"
kv component "${component}"
kv name      "${name}"
kv source    "${source:-n/a}"
kv versions  "${vcount} published"
kv latest    "${lver} (${lrel})"
kv type      "${type}"
if [ "${no_prefix}" -eq 1 ]; then
  kv note "no type prefix in the component — falling back to moodle-other; consuming sites place it via one installer-paths line"
elif [ "${type_native}" -eq 0 ]; then
  kv note "type not natively placed by composer/installers — consuming sites add one installer-paths line (see the generated README)"
fi
kv installer "${installer}"
kv target    "${TARGET}"

# --- target must be empty and not a git repo (checked BEFORE any prompting) --
section "target"
hint="pass a different path:  ./new.sh ${INPUT} <other-path>"
[ -e "${TARGET}/.git" ] && { kv hint "${hint}"; die "${TARGET} is already a git repository"; }
if [ -d "${TARGET}" ] && [ -n "$(ls -A "${TARGET}" 2>/dev/null)" ]; then
  kv hint "${hint}"; die "${TARGET} exists and is not empty"
fi
kv ok "path is usable"
# warn (don't block) when the new repo would sit inside another git work tree
outer="$(git -C "$(dirname "${TARGET}")" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "${outer}" ] && kv note "inside another git repo (${outer}) — fine for testing, but don't commit the mirror there"

# --- vendor (required, no default) -------------------------------------------
# Packagist org / package-name prefix. Format: lowercase a-z0-9 sep by - _ .
vendor_ok() { printf '%s' "$1" | grep -qE '^[a-z0-9]([_.-]?[a-z0-9]+)*$'; }
section "vendor"
if [ -z "${VENDOR}" ]; then
  [ "${AUTO}" -eq 1 ] && die "--vendor is required with --yes (or export MOODLE_COMPOSER_VENDOR=<org>) — your Packagist organization; the package publishes as <vendor>/${component}"
  printf '  Vendor = your Packagist organization / package prefix.\n'
  printf '  It becomes the package name  <vendor>/%s  on Packagist and the\n' "${component}"
  printf '  expected GitHub remote  github.com/<vendor>/%s.\n' "${component}"
  printf '\n  Tip: creating many mirrors? export MOODLE_COMPOSER_VENDOR=<org> once to skip this prompt.\n'
  while :; do
    printf '\n  Vendor: '
    read -r VENDOR || { printf '\n'; die "vendor is required — aborting"; }
    vendor_ok "${VENDOR}" && break
    printf '  invalid: use lowercase letters/digits separated by - _ . (e.g. udir-moodle)\n'
  done
fi
vendor_ok "${VENDOR}" || die "invalid vendor '${VENDOR}'${VFROM} — use lowercase letters/digits separated by - _ . (e.g. udir-moodle)"
kv vendor "${VENDOR}${VFROM}"

# --- compatibility: Moodle release -> plugin versions that support it -------
section "compatibility"
jq -r --arg c "${component}" '
  [ (.plugins // .)[] | select(.component==$c) | .versions[]
    | {v:.version, n:(.version|tonumber? // 0), ms:[.supportedmoodles[]?.release]} ]
  | [ .[] | .ms[] as $m | {m:$m, v:.v, n:.n} ]
  | group_by(.m)
  | map({m:.[0].m, vs:(unique_by(.v)|sort_by(.n)|reverse|map(.v))})
  | sort_by(.m|split(".")|map(tonumber? // 0)) | reverse | .[]
  | "Moodle \(.m)\t\(.vs[0:6]|join(", "))\(if (.vs|length)>6 then "  (+\((.vs|length)-6) more)" else "" end)"
  ' "${TMP}/pl.json" | while IFS=$'\t' read -r m vs; do kv "${m}" "${vs}"; done

# --- pick the version to mirror (Enter = latest) -----------------------------
pick_info() {  # version -> "version<TAB>release<TAB>url<TAB>md5<TAB>supported" ("" if unknown)
  jq -r --arg c "${component}" --arg v "$1" '
    [ (.plugins // .)[] | select(.component==$c) | .versions[] | select(.version==$v) ] | last // empty
    | [.version, (.release // ""), (.downloadurl // ""), (.downloadmd5 // ""),
       ([.supportedmoodles[]?.release] | join(" "))] | @tsv' "${TMP}/pl.json"
}
if [ "${SEED}" -eq 1 ]; then
  if [ -n "${PICK}" ]; then                 # --version flag: validate once, fail clearly
    picked="$(pick_info "${PICK}")"
    [ -n "${picked}" ] || die "version ${PICK} is not published for ${component} — pick one from the compatibility list above"
  elif [ "${AUTO}" -eq 1 ]; then            # --yes: latest
    picked="$(pick_info "${lver}")"
  else                                      # interactive: re-ask until a published version
    while :; do
      printf '\n  Version to mirror [%s]: ' "${lver}"
      read -r PICK || { printf '\n'; die "aborted — nothing created"; }
      : "${PICK:=${lver}}"
      picked="$(pick_info "${PICK}")"
      if [ -n "${picked}" ]; then break; fi
      printf '  "%s" is not a published version of %s — pick one from the list above\n' "${PICK}" "${component}"
      PICK=""
    done
  fi
  # cut, not tab-IFS read: read collapses EMPTY fields (e.g. a null md5 would
  # shift the columns), cut preserves them.
  pfld() { printf '%s\n' "${picked}" | cut -f"$1"; }
  pver="$(pfld 1)"; prel="$(pfld 2)"; purl="$(pfld 3)"; pmd5="$(pfld 4)"; psup="$(pfld 5)"
  kv mirror "${pver} (${prel})"

  # --- download first, before anything is created — a failure leaves no trace
  section "download"
  [ -n "${purl}" ] || die "the directory lists no download URL for ${pver} — nothing was created"
  curl -fsSL -A "${UA}" --retry 3 --retry-delay 5 --max-time 300 "${purl}" -o "${TMP}/p.zip" 2>/dev/null \
    || die "download failed (network problem, or moodle.org blocked this IP) — nothing was created; try again, or use --no-seed"
  if [ -n "${pmd5}" ]; then
    got="$(file_md5 "${TMP}/p.zip")"
    if [ -z "${got}" ]; then kv checksum "no md5 tool found — skipping verification"
    elif [ "${got}" != "${pmd5}" ]; then die "downloaded zip is corrupt (md5 mismatch) — nothing was created; try again"
    fi
  fi
  unzip -q "${TMP}/p.zip" -d "${TMP}/zip" 2>/dev/null \
    || die "could not extract the downloaded zip — nothing was created; try again"
  src="$(find "${TMP}/zip" -mindepth 1 -maxdepth 1 -type d -print -quit)"
  [ -n "${src}" ] || die "unexpected zip layout — nothing was created"
  kv ok "downloaded ${purl##*/}"
fi

# --- scaffold + seed ----------------------------------------------------------
section "scaffold"
mkdir -p "${TARGET}"
cp -a "${TEMPLATE}/." "${TARGET}/"
# Render {{PLACEHOLDER}}s. No in-place sed: BSD/macOS `sed -i` is incompatible
# with GNU's, so write to a temp file and move it back (portable everywhere).
esc() { printf '%s' "$1" | sed 's/[&|\\]/\\&/g'; }
for f in "${TARGET}/composer.json" "${TARGET}/.github/README.md"; do
  sed \
    -e "s|{{VENDOR}}|$(esc "${VENDOR}")|g" \
    -e "s|{{COMPONENT}}|$(esc "${component}")|g" \
    -e "s|{{NAME}}|$(esc "${name}")|g" \
    -e "s|{{TYPE}}|$(esc "${type}")|g" \
    -e "s|{{INSTALLER_NAME}}|$(esc "${installer}")|g" \
    "$f" >"$f.render" && mv "$f.render" "$f"
done
jq -e . "${TARGET}/composer.json" >/dev/null || die "generated composer.json is invalid JSON"
kv wrote "composer.json + .goupdate.yml + .github/{README.md, workflows/update.yml, scripts/{list-versions.sh,update.sh}}"

seeded=""
if [ "${SEED}" -eq 1 ]; then
  ( cd "${src}" && find . -mindepth 1 -maxdepth 1 \
      ! -name '.git' ! -name '.github' ! -name 'composer.json' ! -name 'composer.lock' \
      -exec cp -a {} "${TARGET}/" \; )
  # every Moodle plugin must have a version.php — if it's missing, the copy failed
  [ -f "${TARGET}/version.php" ] || die "seeding failed — plugin files were not copied into ${TARGET}"
  seeded="$(grep -oE "\\\$plugin->version[[:space:]]*=[[:space:]]*[0-9]+(\.[0-9]+)?" "${TARGET}/version.php" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)?' | tail -1 || true)"
  : "${seeded:=${pver}}"
  kv seeded "plugin files at version ${seeded}"
  # require moodle/moodle from supportedmoodles; "*" if the directory lists none.
  if [ -n "${psup}" ]; then
    constraint=""
    for r in ${psup}; do constraint="${constraint}${constraint:+ || }${r}.*"; done
    kv moodle "supports ${psup// /, } -> require moodle/moodle: ${constraint}"
  else
    constraint="*"
    kv moodle "directory lists no supported versions -> require moodle/moodle: * (edit composer.json after the next tag to narrow)"
  fi
  jq --arg c "${constraint}" '.require["moodle/moodle"] = $c' "${TARGET}/composer.json" >"${TARGET}/composer.json.tmp" \
    && mv "${TARGET}/composer.json.tmp" "${TARGET}/composer.json"
fi

# --- git init + tag ---------------------------------------------------------
section "git"
# -b needs git >= 2.28 (older macOS git lacks it) — fall back gracefully.
git -C "${TARGET}" init -q -b main 2>/dev/null \
  || { git -C "${TARGET}" init -q && git -C "${TARGET}" symbolic-ref HEAD refs/heads/main; }
git -C "${TARGET}" add -A
git -C "${TARGET}" commit -q -m "Initialize ${VENDOR}/${component} Composer mirror" >/dev/null 2>&1 \
  || die "git commit failed — usually a missing git identity; set it once with:
                git config --global user.name  'Your Name'
                git config --global user.email 'you@example.com'"
if [ -n "${seeded}" ]; then
  git -C "${TARGET}" tag "${seeded}" && kv tagged "${seeded}"
fi
kv initialized "${TARGET} (branch main)"

# --- next steps -------------------------------------------------------------
section "next steps"
# show a relative path when the repo sits under the current directory
tdisp="${TARGET}"; case "${TARGET}" in "$(pwd)"/*) tdisp="${TARGET#"$(pwd)"/}" ;; esac
if [ "${SEED}" -eq 0 ]; then
  cat <<EOF
  NOTE: scaffolded without plugin files (--no-seed). With no version.php the
  daily updater starts from the plugin's OLDEST published version — seed the
  files (e.g. run `goupdate update -r moodle --yes --incremental`) before pushing.

EOF
fi
cat <<EOF
  1. Create an EMPTY public GitHub repo named:  ${VENDOR}/${component}
  2. cd ${tdisp}
     git remote add origin https://github.com/${VENDOR}/${component}.git
     git push -u origin main --tags
  3. Submit https://github.com/${VENDOR}/${component} at
     https://packagist.org/packages/submit  and install the Packagist GitHub App
     (it auto-publishes every new tag).
  4. The daily workflow tags each newer version automatically.

  Consumers: follow the repo README (shown on the GitHub page) — it covers the
  required Moodle setup, then:  composer require '${VENDOR}/${component}:*'
EOF
