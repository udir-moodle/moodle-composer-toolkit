# moodle-composer-toolkit

Turn any plugin from the [Moodle Plugins directory](https://moodle.org/plugins)
into a **Composer/Packagist package that auto-updates daily** — so your Moodle
site can `composer require` plugins and `composer update` delivers new versions.

Works on macOS, Linux and Windows (Git Bash). Needs `curl`, `jq`, `unzip`,
`git` — the scripts check on start and tell you exactly what's missing.

---

## Quick start

```bash
./new.sh https://moodle.org/plugins/theme_boost_union --vendor my-org
```

```
===== compatibility =====
  Moodle 5.2:   2026042006, 2026042005, …
  Moodle 4.5:   2024100791, 2024100787, …  (+35 more)

  Version to mirror [2026042006]:          # Enter = latest
```

It scaffolds `./theme_boost_union`, seeds that version's files and git-tags it.
Then publish:

```bash
cd theme_boost_union
git remote add origin https://github.com/my-org/theme_boost_union.git
git push -u origin main --tags
# submit at https://packagist.org/packages/submit + install the Packagist GitHub App
```

Done — a daily GitHub Action tags each newer version; Packagist publishes them.

---

## The scripts

| Script | Purpose |
|---|---|
| `new.sh <url\|name> [path]` | One-time: scaffold a mirror repo from a plugin URL, component, or plain name (default path `./<component>`). |
| `.goupdate.yml` + `.goupdate-core-plugins.txt` | Drop-in goupdate config + core-plugin skip-list to inventory an existing Moodle project against the directory (see [Scanning a project](#scanning-an-existing-project)). |
| `find-dynamic-plugins.sh [path]` | Migration helper: lists `version.php` files goupdate's scan can't read (dynamic or missing `$plugin->component`) — the blind spots to check by hand. |
| `.github/scripts/{list-versions.sh,update.sh}` | Inside every generated repo; called by [goupdate](https://github.com/ajxudir/goupdate) on the daily `update.yml`. `list-versions.sh` lists published versions (writes a small cache); `update.sh --apply <version>` downloads + syncs the version goupdate picked. |

```bash
./new.sh https://moodle.org/plugins/mod_adaptivequiz ./mirrors/adaptivequiz   # custom path
./new.sh mod_adaptivequiz --vendor my-org --version 2023011200 --yes          # scripted, exact version
goupdate update -r moodle --yes --incremental             # what CI runs in the generated repo
```

`new.sh` options: `--version V` (seed a specific version), `--yes` (no prompts),
`--vendor V`, `--no-seed`, `--help`. Unknown plugins print `NOT FOUND` plus
suggestions.

**Vendor (required, no default):** your Packagist organization — it becomes the
package name `<vendor>/<component>` and the GitHub remote
`github.com/<vendor>/<component>`. `new.sh` asks for it interactively — or `export MOODLE_COMPOSER_VENDOR=my-org` once to skip
the prompt across many runs; with `--yes` (CI) it must come from `--vendor` or
the env var, otherwise the script fails.

## Scanning an existing project

To plan a migration, scan a Moodle site for its plugins and check each against
the directory — using goupdate. Copy two files from this toolkit into your
project root: `.goupdate.yml` and `.goupdate-core-plugins.txt`. Then, from the
project root:

```bash
# every contributed/custom plugin, with Outdated/UpToDate status (core included):
goupdate outdated -r moodle --skip-preflight

# drop Moodle core, then your own custom plugins, leaving only the mirrorable ones:
goupdate outdated -r moodle --skip-preflight \
  | grep -vwF -f <(grep -v '^#' .goupdate-core-plugins.txt) \
  | grep -vwF -f <(grep -v '^#' .goupdate-custom-plugins.txt)
```

`Outdated` rows are the actionable ones — a newer version is published in the
directory, so they're mirrorable with `new.sh`. `UpToDate` rows are current
contributed plugins (custom ones are removed by the second pipe).

**The two skip-lists.** goupdate names a package at the extraction step (regex /
json-key) — there is no command hook *before* that, so nothing can be excluded
inside the config; two pipes do it instead:
- `.goupdate-core-plugins.txt` — the Moodle standard-plugin list, shipped here.
- `.goupdate-custom-plugins.txt` — your project's private plugins (components in
  `version.php` that the directory API doesn't have). Regenerate per project:

```bash
curl -fsSL -A 'MoodleBot/1.0 (+https://moodle.org)' \
  https://download.moodle.org/api/1.3/pluglist.php \
  | jq -r '(.plugins//.)[]|select(.component!=null)|.component' | sort -u > /tmp/dir.txt
find . -name version.php -not -path '*/vendor/*' \
  | xargs grep -hoE "plugin->component[[:space:]]*=[[:space:]]*['\"][a-z][a-z0-9]*_[a-z0-9_]+" \
  | grep -oE '[a-z][a-z0-9]*_[a-z0-9_]+$' | sort -u \
  | grep -vxF -f /tmp/dir.txt | grep -vxF -f <(grep -v '^#' .goupdate-core-plugins.txt) \
  > .goupdate-custom-plugins.txt
```

**Blind spot** (verified against goupdate source): plugins whose
`$plugin->component` is set dynamically (e.g. `"auth_{$dir}"`), or omit it
entirely, are skipped — the extraction regex only matches literal component
names, so they never appear in the scan above. List them so you can check them
by hand during the migration:

```bash
./find-dynamic-plugins.sh        # from the project root (or pass a path)
```

---

## A generated repo

```
theme_boost_union/
├── composer.json            # YOURS: name, type=moodle-theme, installer-name=boost_union
├── .goupdate.yml            # YOURS: goupdate rule (numeric strategy + incremental)
├── version.php, lang/, …    # the upstream plugin (replaced on every update)
└── .github/                 # YOURS: survives every update
    ├── workflows/update.yml      # daily cron; goupdate, then git commit/tag/push
    ├── scripts/list-versions.sh  # outdated.commands: lists published versions
    ├── scripts/update.sh         # update.commands: --apply <version> from goupdate
    └── README.md
```

Only `composer.json`, `.goupdate.yml`, and `.github/` belong to the mirror —
upstream's own `composer.json` / `.github` / `composer.lock` are dropped on sync.

---

## Versioning

* Tags = the Moodle **`$plugin->version`** integer (`2024100700`, no `v`) — same
  for every vendor, monotonic, stable in Composer.
* One version per run, **next after current** — every published version gets a
  tag. Seed an older version and the updater walks forward through the rest.
* No Moodle-version filtering — the consumer's constraint decides what installs.

Consumers **pin an exact version** (the Moodle `$plugin->version` integer) and
bump it deliberately when they want the update — `*` would silently pull every
daily release, which is not what you want in a tracked `composer.json`:

```bash
composer require 'my-org/theme_boost_union:2026042006'   # pin; bump to update
```

(`^`/`~` don't help here — date integers aren't semver, so any range wider than
an exact pin behaves like `*`.)

### Moodle version gating

Every release is stamped with the Moodle versions it supports (from the
directory), as a requirement on `moodle/moodle` — the official core package
(Packagist mirrors the github.com/moodle/moodle tags, `v4.5.12` etc.):

```jsonc
"require": { "moodle/moodle": "4.1.* || 4.2.* || 4.3.* || 4.4.* || 4.5.*" }   // written per release
```

Each consuming site therefore **declares its core version first** (and bumps it
when upgrading Moodle) — each generated repo's README walks consumers through
this. Pick one:

```jsonc
"require": { "moodle/moodle": "4.5.10" }   // core source lands unused in vendor/moodle/moodle
"replace": { "moodle/moodle": "4.5.10" }   // core already in your repo — declare without installing
```

`composer update` then **never selects a plugin version your Moodle doesn't
support**, and upgrading core pulls all plugins forward by bumping that one
line. A site that skips the declaration fails *open*: composer installs a
matching core into `vendor/` by itself — which is why the per-repo README makes
the setup step explicit. (Real-core caveats: core's `ext-*` requirements must
exist on the machine running composer — `config.platform` fakes them — and
5.x-era core (type `moodle-core`) pulls its ~45 pinned libraries into your
vendor tree, whereas 4.x core (type `project`) pulls none; `replace` avoids
both.)

The requirement is **never removed**. If a release lists no supported versions
in the directory (or the author's list is stale/unverified), it falls back to
`"moodle/moodle": "*"`. To extend support manually, edit `composer.json` on
a tag after the daily updater commits it — the next sync only rewrites
`require["moodle/moodle"]` from the API's `supportedmoodles`, and the API's
list for an already-published release does not change.

`composer/installers` puts it at the real Moodle path (`theme/boost_union/`),
not `vendor/` — gitignore that path in the consuming site.

---

## Notes

* **Exotic sub-plugin types** (`minilessonitem_*`, `watool_*`, …): mirror works;
  the consumer adds one line, e.g. `"mod/minilesson/item/{$name}/": ["type:moodle-minilessonitem"]`.
* **Downloads:** moodle.org Cloudflare-challenges some datacenter IPs (`403`).
  GitHub-hosted runners pass. Scripts send the expected `MoodleBot/…` UA
  (override: `MOODLE_UA`).
* **`--no-seed`** leaves no `version.php`, so the updater would start at the
  plugin's *oldest* version — seed before pushing.
* No Action runs in this toolkit repo — only in generated repos.

---

## License

GPL-3.0-or-later — same as Moodle and the plugins this toolkit mirrors.
See [LICENSE](./LICENSE).
