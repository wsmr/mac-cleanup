#!/usr/bin/env bash
#
# mac-cleanup.sh — safe, repeatable disk-space cleanup for macOS
#
#### HOW TO RUN --> ./mac-cleanup.sh
####                (safe defaults, no flags required — run from wherever
####                you've cloned or saved this file)
####                Preview first, any time: ./mac-cleanup.sh --dry-run
#
# Frees space from things that are pure, regenerable cache — and nothing
# else — with two exceptions available on request (see v2.0.0 note below).
# Built from a folder-by-folder audit of a typical dev-heavy macOS setup:
# npm/pip/Homebrew caches, JetBrains' IDE cache, leftover Sparkle
# auto-updater downloads, stray JVM crash dumps sitting in $HOME, and
# Gradle's scratch temp folder.
#
# v2.0.0 — behaviour change from v1, following an independent safety
# review. Two steps that touch things which are NOT pure cache moved from
# default-on to opt-in, because they can hold real, non-regenerable data:
#   - Emptying the Trash: now off by default, enable with --empty-trash.
#     Reason: Finder's "empty trash" empties every mounted volume's trash,
#     not just ~/.Trash (an external drive plugged in at the time would
#     lose its trash contents too) — a materially bigger blast radius than
#     the original v1 docs implied, and Trash contents are exactly the
#     kind of thing someone put there as a staging area, not disposable
#     cache.
#   - JetBrains Toolbox "*-backup" folders: now off by default, enable
#     with --include-jetbrains-backups. Reason: these aren't cache —
#     they're a full snapshot of the previous IDE version's settings
#     (keymaps, saved DB connections, live templates, plugin state),
#     created specifically as a rollback point during an IDE update. That
#     contradicts this script's own "never touch unique data" rule.
# Also narrowed in v2.0.0: crash-dump matching went from a blanket
# ~/*.hprof (which could delete a heap dump you made on purpose, e.g. via
# jcmd) to only the naming patterns JVMs/JetBrains actually auto-generate
# (java_error_in_*.hprof, java_pid*.hprof).
#
# EVERY location this script can touch, and nothing else:
#   - npm's cache                                     (npm cache clean --force)
#   - pip's cache                                     (python3 -m pip cache purge)
#   - Homebrew's download cache / old cellar versions   (brew cleanup -s)
#   - ~/Library/Caches/JetBrains/*
#   - ~/Library/Caches/*/org.sparkle-project.Sparkle
#   - $HOME/java_error_in_*.hprof, $HOME/java_pid*.hprof  (JVM crash dumps)
#   - ~/.gradle/.tmp/*
#   - opt-in only — --include-jetbrains-backups:
#       ~/Library/Application Support/JetBrains/*-backup
#   - opt-in only — --empty-trash:
#       every mounted volume's Trash, via Finder's own empty-trash command
#       (AppleScript) — never touched directly; macOS blocks direct shell
#       access to Trash folders for any command, sudo included, unless
#       Terminal has Full Disk Access, so Finder is asked to do it instead
#
# Deliberately, permanently NEVER touched here, because these need a human
# decision, not a script:
#   - Android SDK / emulator images (~/Library/Android, ~/.android)
#   - Gradle's actual VERSION caches (~/.gradle/caches — may hold exactly
#     the version an active project needs; only its scratch .tmp is cleared)
#   - Docker's data, Projects/node_modules, Downloads
#   - old-but-not-backup JetBrains version folders (e.g. a prior year's
#     WebStorm) — worth reviewing by hand every so often, not automated here
#   - personal files, SSH/GPG keys, app signing keystores
#
# Every step is find-based and (other than Trash, which macOS won't let any
# shell command size up — see above) reports its own before/after size, so
# run with --dry-run any time you want to see exactly what a real run would
# touch and roughly how much it would free, without deleting anything.
#
# Before touching the JetBrains cache or Gradle's temp folder, the script
# checks for an obviously-related running process and prints a warning
# (not a block) if it finds one — it's a heuristic on process names, not a
# guarantee, so use your own judgement too.
#
# This script never uses or requests sudo, and refuses to run at all if
# $HOME isn't set to a real, non-root directory (see require_sane_home).
#
# Run as ./mac-cleanup.sh (after `chmod +x`) or as `bash mac-cleanup.sh` —
# either correctly picks up bash via the shebang above, which is what this
# is written and tested against. Avoid `zsh mac-cleanup.sh` (explicitly
# naming zsh as the interpreter skips the shebang and reads the arrays
# below as zsh instead of bash).
#
# USAGE:
#   ./mac-cleanup.sh [OPTIONS]
#
# Run with -h/--help for the full flag reference.

set -o pipefail

VERSION="2.0.0"
SCRIPT_NAME="$(basename -- "$0")"

DRY_RUN=0
QUIET=0
SKIP_NPM=0
SKIP_PIP=0
SKIP_BREW=0
SKIP_JETBRAINS_CACHE=0
SKIP_SPARKLE=0
SKIP_CRASH_DUMPS=0
SKIP_GRADLE_TMP=0
INCLUDE_JETBRAINS_BACKUPS=0
EMPTY_TRASH=0

TOTAL_FREED_KB=0

usage() {
  cat <<EOF
mac-cleanup.sh v${VERSION} — safe, repeatable disk-space cleanup

USAGE:
  ${SCRIPT_NAME} [OPTIONS]

  Run with no options for the default safe cleanup — pure cache only.

OPTIONS:
  -n, --dry-run                 Show what would be removed and roughly how
                                 much space it would free — deletes nothing
  -q, --quiet                   Suppress npm/brew/pip's own chatter; this
                                 script's own step-by-step summary still prints
      --skip-npm                Skip the npm cache
      --skip-pip                Skip the pip cache
      --skip-brew                Skip Homebrew cleanup
      --skip-jetbrains-cache     Skip ~/Library/Caches/JetBrains
      --skip-sparkle             Skip leftover Sparkle auto-updater downloads
      --skip-crash-dumps         Skip auto-generated *.hprof crash dumps
      --skip-gradle-tmp          Skip ~/.gradle/.tmp
      --include-jetbrains-backups
                                 Opt IN to removing JetBrains Toolbox's
                                 *-backup folders. These hold real settings
                                 (keymaps, saved DB connections, plugin
                                 state) kept as an IDE-update rollback
                                 point — off by default on purpose.
      --empty-trash              Opt IN to emptying the Trash via Finder.
                                 This empties every mounted volume's trash,
                                 not just this Mac's — off by default.
  -h, --help                     Show this help and exit
  -v, --version                  Show version and exit

EXAMPLES:
  ${SCRIPT_NAME}                                Run the default safe cleanup
  ${SCRIPT_NAME} --dry-run                       Preview only, changes nothing
  ${SCRIPT_NAME} --empty-trash                   Also empty the Trash this run
  ${SCRIPT_NAME} --include-jetbrains-backups     Also drop IDE settings backups
  ${SCRIPT_NAME} --skip-brew --quiet             Skip Homebrew, be quiet

SAFETY: only ever touches the exact cache/temp locations listed in this
file's header comment — see there for the full list, what's opt-in and
why, and the equally explicit list of what's permanently out of scope.
When in doubt, run --dry-run first; every step is find-based and prints
exactly what it matched before anything is (or, in dry-run, would be)
removed.
EOF
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Refuses to run if $HOME isn't a real, sane, non-root directory — guards
# against accidentally operating on system paths if $HOME is ever unset,
# empty, or "/" (e.g. a stripped or misconfigured environment).
require_sane_home() {
  if [[ -z "${HOME:-}" || "$HOME" == "/" || ! -d "$HOME" ]]; then
    echo "Error: \$HOME is not set to a real directory (got '${HOME:-<unset>}')." >&2
    echo "Refusing to run — this script only ever operates under \$HOME." >&2
    exit 1
  fi
}

# Prints a path's size in KB, or 0 if it doesn't exist or can't be read.
# Never prints an empty string, even if du itself fails. Uses -L so a
# symlinked target (e.g. a cache folder moved to an external drive) is
# measured by what it points to, not the symlink's own negligible size.
size_kb() {
  local path="$1" sz
  if [[ -e "$path" ]]; then
    sz="$(du -sLk "$path" 2>/dev/null | awk '{print $1}')"
    printf '%s' "${sz:-0}"
  else
    printf '0'
  fi
}

# Formats a KB integer as a human-readable size.
human_kb() {
  local kb="$1"
  if [[ "$kb" -ge 1048576 ]]; then
    awk -v k="$kb" 'BEGIN{printf "%.2f GB", k/1048576}'
  elif [[ "$kb" -ge 1024 ]]; then
    awk -v k="$kb" 'BEGIN{printf "%.1f MB", k/1024}'
  else
    printf '%s KB' "$kb"
  fi
}

log() {
  printf '%s\n' "$1"
}

# Runs "$@", sending its stdout (not stderr) to /dev/null when QUIET=1, so
# real warnings/errors still surface even in quiet mode.
run_quiet_unless_loud() {
  if [[ "$QUIET" -eq 1 ]]; then
    "$@" >/dev/null
  else
    "$@"
  fi
}

# $1 = label, $2 = before_kb, $3 = after_kb — logs and accumulates the delta.
report_freed() {
  local label="$1" before="$2" after="$3"
  local freed=$((before - after))
  [[ "$freed" -lt 0 ]] && freed=0
  TOTAL_FREED_KB=$((TOTAL_FREED_KB + freed))
  log "  freed: $(human_kb "$freed")  ($label)"
}

# Best-effort, advisory-only heuristic: warns (does not block) if a process
# matching one of the given patterns appears to be running. Never treat
# this as authoritative — it's a pgrep substring match, nothing more.
warn_if_running() {
  local label="$1"; shift
  local pattern
  for pattern in "$@"; do
    if pgrep -qi -f "$pattern" 2>/dev/null; then
      log "  heads up: $label looks like it might be running right now."
      log "  Proceeding anyway — deleting these files won't corrupt the app,"
      log "  but it may need to rebuild an index or you may see a hiccup."
      return
    fi
  done
}

# ---------------------------------------------------------------------------
# Cleanup steps
# ---------------------------------------------------------------------------

clean_npm() {
  log "--- npm cache ---"
  if [[ "$SKIP_NPM" -eq 1 ]]; then
    log "  skipped (--skip-npm)"
    return
  fi
  if ! command -v npm >/dev/null 2>&1; then
    log "  npm not found on PATH — skipping."
    return
  fi
  local target="$HOME/.npm" before
  before="$(size_kb "$target")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  would run: npm cache clean --force  (currently: $(human_kb "$before"))"
    TOTAL_FREED_KB=$((TOTAL_FREED_KB + before))
    return
  fi
  run_quiet_unless_loud npm cache clean --force
  local after
  after="$(size_kb "$target")"
  report_freed "npm cache" "$before" "$after"
}

clean_pip() {
  log "--- pip cache ---"
  if [[ "$SKIP_PIP" -eq 1 ]]; then
    log "  skipped (--skip-pip)"
    return
  fi
  local pip_cmd=()
  if command -v python3 >/dev/null 2>&1; then
    pip_cmd=(python3 -m pip)
  elif command -v pip3 >/dev/null 2>&1; then
    pip_cmd=(pip3)
  else
    log "  neither python3 nor pip3 found on PATH — skipping."
    return
  fi
  local target="$HOME/Library/Caches/pip" before
  before="$(size_kb "$target")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  would run: ${pip_cmd[*]} cache purge  (currently: $(human_kb "$before"))"
    TOTAL_FREED_KB=$((TOTAL_FREED_KB + before))
    return
  fi
  run_quiet_unless_loud "${pip_cmd[@]}" cache purge
  local after
  after="$(size_kb "$target")"
  report_freed "pip cache" "$before" "$after"
}

clean_brew() {
  log "--- Homebrew ---"
  if [[ "$SKIP_BREW" -eq 1 ]]; then
    log "  skipped (--skip-brew)"
    return
  fi
  if ! command -v brew >/dev/null 2>&1; then
    log "  brew not found on PATH — skipping."
    return
  fi
  # brew cleanup -s reclaims space from two places: the download cache
  # (brew --cache) and old Cellar versions (brew --cellar). Measuring only
  # the cache would understate what's actually freed, so both are tracked.
  local cache_dir cellar_dir cache_before cellar_before
  cache_dir="$(brew --cache 2>/dev/null)"
  cellar_dir="$(brew --cellar 2>/dev/null)"
  cache_before="$(size_kb "$cache_dir")"
  cellar_before="$(size_kb "$cellar_dir")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  would run: brew cleanup -s  (cache: $(human_kb "$cache_before"), cellar: $(human_kb "$cellar_before"))"
    log "  dry-run estimate is cache-only — cellar cleanup varies too much to predict"
    TOTAL_FREED_KB=$((TOTAL_FREED_KB + cache_before))
    return
  fi
  local out
  out="$(brew cleanup -s 2>&1)"
  [[ "$QUIET" -ne 1 ]] && printf '%s\n' "$out"
  if printf '%s' "$out" | grep -q 'Xcode license'; then
    log "  Homebrew is blocked on the Xcode license again — run:"
    log "    sudo xcodebuild -license accept"
    log "  then re-run this script."
  fi
  local cache_after cellar_after
  cache_after="$(size_kb "$cache_dir")"
  cellar_after="$(size_kb "$cellar_dir")"
  report_freed "Homebrew cache" "$cache_before" "$cache_after"
  report_freed "Homebrew old cellar versions" "$cellar_before" "$cellar_after"
}

clean_jetbrains_cache() {
  log "--- JetBrains IDE cache ---"
  if [[ "$SKIP_JETBRAINS_CACHE" -eq 1 ]]; then
    log "  skipped (--skip-jetbrains-cache)"
    return
  fi
  local target="$HOME/Library/Caches/JetBrains"
  if [[ ! -d "$target" ]]; then
    log "  not found — skipping."
    return
  fi
  warn_if_running "a JetBrains IDE" "IntelliJ IDEA" "WebStorm" "PyCharm" \
    "PhpStorm" "GoLand" "CLion" "Rider" "RubyMine" "DataGrip" "Android Studio"
  local before
  before="$(size_kb "$target")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  would clear: $target  (currently: $(human_kb "$before"))"
    TOTAL_FREED_KB=$((TOTAL_FREED_KB + before))
    return
  fi
  # Trailing slash matters: if $target were ever a symlink (e.g. moved to
  # an external drive to save space), find would otherwise treat it as a
  # single opaque item and never descend into its actual contents.
  find "$target/" -mindepth 1 -delete
  local after
  after="$(size_kb "$target")"
  report_freed "JetBrains cache" "$before" "$after"
}

clean_jetbrains_backups() {
  log "--- JetBrains Toolbox settings-backups (opt-in) ---"
  if [[ "$INCLUDE_JETBRAINS_BACKUPS" -ne 1 ]]; then
    log "  skipped — these hold real settings, not cache. Opt in with"
    log "  --include-jetbrains-backups if you're sure you don't need them."
    return
  fi
  local base="$HOME/Library/Application Support/JetBrains"
  if [[ ! -d "$base" ]]; then
    log "  not found — skipping."
    return
  fi
  local path before_total=0 found=0 sz
  while IFS= read -r -d '' path; do
    found=1
    sz="$(size_kb "$path")"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "  would remove: $path  ($(human_kb "$sz"))"
      before_total=$((before_total + sz))
    elif rm -rf -- "$path" 2>/dev/null; then
      log "  removed: $path  ($(human_kb "$sz"))"
      before_total=$((before_total + sz))
    else
      log "  failed to remove: $path — check permissions, not counted as freed"
    fi
  done < <(find "$base/" -mindepth 1 -maxdepth 1 -type d -name '*-backup' -print0)
  if [[ "$found" -eq 0 ]]; then
    log "  none found."
    return
  fi
  TOTAL_FREED_KB=$((TOTAL_FREED_KB + before_total))
}

clean_sparkle_leftovers() {
  log "--- Leftover Sparkle auto-updater downloads ---"
  if [[ "$SKIP_SPARKLE" -eq 1 ]]; then
    log "  skipped (--skip-sparkle)"
    return
  fi
  local base="$HOME/Library/Caches"
  if [[ ! -d "$base" ]]; then
    log "  not found — skipping."
    return
  fi
  local path before_total=0 found=0 sz
  while IFS= read -r -d '' path; do
    found=1
    sz="$(size_kb "$path")"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "  would remove: $path  ($(human_kb "$sz"))"
      before_total=$((before_total + sz))
    elif rm -rf -- "$path" 2>/dev/null; then
      log "  removed: $path  ($(human_kb "$sz"))"
      before_total=$((before_total + sz))
    else
      log "  failed to remove: $path — check permissions, not counted as freed"
    fi
  done < <(find "$base/" -mindepth 2 -maxdepth 2 -type d -name 'org.sparkle-project.Sparkle' -print0)
  if [[ "$found" -eq 0 ]]; then
    log "  none found."
    return
  fi
  TOTAL_FREED_KB=$((TOTAL_FREED_KB + before_total))
}

clean_crash_dumps() {
  log "--- Auto-generated crash dumps in \$HOME ---"
  if [[ "$SKIP_CRASH_DUMPS" -eq 1 ]]; then
    log "  skipped (--skip-crash-dumps)"
    return
  fi
  # Deliberately narrow: only the naming patterns JVMs/JetBrains actually
  # auto-generate (java_error_in_*.hprof, java_pid*.hprof) — NOT a blanket
  # *.hprof, which would also catch a heap dump you made on purpose.
  local path before_total=0 found=0 sz
  while IFS= read -r -d '' path; do
    found=1
    sz="$(size_kb "$path")"
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "  would remove: $path  ($(human_kb "$sz"))"
      before_total=$((before_total + sz))
    elif rm -f -- "$path" 2>/dev/null; then
      log "  removed: $path  ($(human_kb "$sz"))"
      before_total=$((before_total + sz))
    else
      log "  failed to remove: $path — check permissions, not counted as freed"
    fi
  done < <(find "$HOME" -mindepth 1 -maxdepth 1 -type f \
    \( -iname 'java_error_in_*.hprof' -o -iname 'java_pid*.hprof' \) -print0)
  if [[ "$found" -eq 0 ]]; then
    log "  none found."
    return
  fi
  TOTAL_FREED_KB=$((TOTAL_FREED_KB + before_total))
}

clean_gradle_tmp() {
  log "--- Gradle scratch temp folder ---"
  if [[ "$SKIP_GRADLE_TMP" -eq 1 ]]; then
    log "  skipped (--skip-gradle-tmp)"
    return
  fi
  local target="$HOME/.gradle/.tmp"
  if [[ ! -d "$target" ]]; then
    log "  not found — skipping."
    return
  fi
  warn_if_running "a Gradle build/daemon" "GradleDaemon" "gradle-launcher"
  local before
  before="$(size_kb "$target")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  would clear: $target  (currently: $(human_kb "$before"))"
    TOTAL_FREED_KB=$((TOTAL_FREED_KB + before))
    return
  fi
  find "$target/" -mindepth 1 -delete
  local after
  after="$(size_kb "$target")"
  report_freed "Gradle temp" "$before" "$after"
}

empty_trash() {
  log "--- Trash (opt-in) ---"
  if [[ "$EMPTY_TRASH" -ne 1 ]]; then
    log "  skipped — this empties every mounted volume's trash, not just"
    log "  this Mac's. Opt in with --empty-trash if that's what you want."
    return
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  would empty the Trash via Finder, on every mounted volume."
    log "  (Size can't be previewed — Trash folders are protected from"
    log "  direct inspection the same way they're protected from find/rm;"
    log "  not included in the dry-run total.)"
    return
  fi
  osascript -e 'tell application "Finder"' -e 'try' -e 'empty trash' -e 'end try' -e 'end tell' >/dev/null
  log "  done. (Bytes freed can't be measured for the same reason — not"
  log "  included in the total below.)"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

require_sane_home

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1; shift ;;
    -q|--quiet) QUIET=1; shift ;;
    --skip-npm) SKIP_NPM=1; shift ;;
    --skip-pip) SKIP_PIP=1; shift ;;
    --skip-brew) SKIP_BREW=1; shift ;;
    --skip-jetbrains-cache) SKIP_JETBRAINS_CACHE=1; shift ;;
    --skip-sparkle) SKIP_SPARKLE=1; shift ;;
    --skip-crash-dumps) SKIP_CRASH_DUMPS=1; shift ;;
    --skip-gradle-tmp) SKIP_GRADLE_TMP=1; shift ;;
    --include-jetbrains-backups) INCLUDE_JETBRAINS_BACKUPS=1; shift ;;
    --empty-trash) EMPTY_TRASH=1; shift ;;
    -h|--help) usage; exit 0 ;;
    -v|--version) echo "${SCRIPT_NAME} v${VERSION}"; exit 0 ;;
    *)
      echo "Error: unrecognized argument '$1'" >&2
      echo "Run '${SCRIPT_NAME} --help' for usage." >&2
      exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "DRY RUN — nothing below will actually be deleted."
    log ""
  fi

  clean_npm
  clean_pip
  clean_brew
  clean_jetbrains_cache
  clean_jetbrains_backups
  clean_sparkle_leftovers
  clean_crash_dumps
  clean_gradle_tmp
  empty_trash

  log ""
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "Dry run complete — would free approximately $(human_kb "$TOTAL_FREED_KB") (Trash excluded from every total; see above)."
  else
    log "Done. Freed approximately $(human_kb "$TOTAL_FREED_KB") (Trash excluded from this total; see above)."
  fi
}

main
