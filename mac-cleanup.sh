#!/usr/bin/env bash
#
# mac-cleanup.sh — safe, repeatable disk-space cleanup for macOS
#
#### HOW TO RUN --> ./mac-cleanup.sh
####                (safe defaults, no flags required — run from wherever
####                you've cloned or saved this file)
####                Preview first, any time: ./mac-cleanup.sh --dry-run
#
# Frees space from things that are pure, regenerable cache or already-disposed
# data — never anything that holds unique information. Built from a
# folder-by-folder audit of a typical dev-heavy macOS setup: npm/pip/Homebrew
# caches, JetBrains' IDE cache and Toolbox settings-backups, leftover Sparkle
# auto-updater downloads, stray Java/WebStorm crash dumps sitting in $HOME,
# Gradle's scratch temp folder, and the Trash.
#
# EVERY location this script can touch, and nothing else:
#   - npm's cache                                     (npm cache clean --force)
#   - pip's cache                                     (python3 -m pip cache purge)
#   - Homebrew's download cache / old cellar versions   (brew cleanup -s)
#   - ~/Library/Caches/JetBrains/*
#   - ~/Library/Application Support/JetBrains/*-backup
#   - ~/Library/Caches/*/org.sparkle-project.Sparkle
#   - $HOME/*.hprof            (Java/JetBrains crash heap dumps)
#   - ~/.gradle/.tmp/*
#   - ~/.Trash                 (via Finder's own empty-trash — this script
#                                never touches ~/.Trash directly; macOS
#                                blocks that for any shell command, sudo
#                                included, unless Terminal has Full Disk
#                                Access, so Finder is asked to do it instead)
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
# Every step below is find-based and (other than Trash, which can't be sized
# this way) reports its own before/after size, so run with --dry-run any
# time you want to see exactly what a real run would touch and roughly how
# much it would free, without deleting anything.
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

VERSION="1.0.0"
SCRIPT_NAME="$(basename -- "$0")"

DRY_RUN=0
QUIET=0
SKIP_NPM=0
SKIP_PIP=0
SKIP_BREW=0
SKIP_JETBRAINS_CACHE=0
SKIP_JETBRAINS_BACKUPS=0
SKIP_SPARKLE=0
SKIP_CRASH_DUMPS=0
SKIP_GRADLE_TMP=0
SKIP_TRASH=0

TOTAL_FREED_KB=0

usage() {
  cat <<EOF
mac-cleanup.sh v${VERSION} — safe, repeatable disk-space cleanup

USAGE:
  ${SCRIPT_NAME} [OPTIONS]

  Run with no options for the default full, safe cleanup.

OPTIONS:
  -n, --dry-run                 Show what would be removed and roughly how
                                 much space it would free — deletes nothing
  -q, --quiet                   Suppress npm/brew/pip's own chatter; this
                                 script's own step-by-step summary still prints
      --skip-npm                Skip the npm cache
      --skip-pip                Skip the pip cache
      --skip-brew                Skip Homebrew cleanup
      --skip-jetbrains-cache     Skip ~/Library/Caches/JetBrains
      --skip-jetbrains-backups   Skip JetBrains Toolbox's *-backup folders
      --skip-sparkle             Skip leftover Sparkle auto-updater downloads
      --skip-crash-dumps         Skip *.hprof crash dumps in \$HOME
      --skip-gradle-tmp          Skip ~/.gradle/.tmp
      --skip-trash               Skip emptying the Trash
  -h, --help                     Show this help and exit
  -v, --version                  Show version and exit

EXAMPLES:
  ${SCRIPT_NAME}                          Run everything
  ${SCRIPT_NAME} --dry-run                Preview only, changes nothing
  ${SCRIPT_NAME} --skip-trash --quiet     Clean caches, leave Trash, be quiet
  ${SCRIPT_NAME} --skip-brew              Skip Homebrew just this run

SAFETY: only ever touches the exact cache/backup/temp locations listed in
this file's header comment — see there for the full list, and the equally
explicit list of what's permanently out of scope. When in doubt, run
--dry-run first; every step is find-based and prints exactly what it
matched before anything is (or, in dry-run, would be) removed.
EOF
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Prints a path's size in KB, or 0 if it doesn't exist. Silent either way.
size_kb() {
  local path="$1"
  if [[ -e "$path" ]]; then
    du -sk "$path" 2>/dev/null | awk '{print $1}'
  else
    echo 0
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
  local target before
  target="$(brew --cache 2>/dev/null)"
  before="$(size_kb "$target")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  would run: brew cleanup -s  (cache currently: $(human_kb "$before"))"
    TOTAL_FREED_KB=$((TOTAL_FREED_KB + before))
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
  local after
  after="$(size_kb "$target")"
  report_freed "Homebrew cache" "$before" "$after"
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
  local before
  before="$(size_kb "$target")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  would clear: $target  (currently: $(human_kb "$before"))"
    TOTAL_FREED_KB=$((TOTAL_FREED_KB + before))
    return
  fi
  find "$target" -mindepth 1 -delete
  local after
  after="$(size_kb "$target")"
  report_freed "JetBrains cache" "$before" "$after"
}

clean_jetbrains_backups() {
  log "--- JetBrains Toolbox settings-backups ---"
  if [[ "$SKIP_JETBRAINS_BACKUPS" -eq 1 ]]; then
    log "  skipped (--skip-jetbrains-backups)"
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
    before_total=$((before_total + sz))
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "  would remove: $path  ($(human_kb "$sz"))"
    else
      rm -rf -- "$path"
      log "  removed: $path  ($(human_kb "$sz"))"
    fi
  done < <(find "$base" -mindepth 1 -maxdepth 1 -type d -name '*-backup' -print0)
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
    before_total=$((before_total + sz))
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "  would remove: $path  ($(human_kb "$sz"))"
    else
      rm -rf -- "$path"
      log "  removed: $path  ($(human_kb "$sz"))"
    fi
  done < <(find "$base" -mindepth 2 -maxdepth 2 -type d -name 'org.sparkle-project.Sparkle' -print0)
  if [[ "$found" -eq 0 ]]; then
    log "  none found."
    return
  fi
  TOTAL_FREED_KB=$((TOTAL_FREED_KB + before_total))
}

clean_crash_dumps() {
  log "--- Crash dumps in \$HOME ---"
  if [[ "$SKIP_CRASH_DUMPS" -eq 1 ]]; then
    log "  skipped (--skip-crash-dumps)"
    return
  fi
  local path before_total=0 found=0 sz
  while IFS= read -r -d '' path; do
    found=1
    sz="$(size_kb "$path")"
    before_total=$((before_total + sz))
    if [[ "$DRY_RUN" -eq 1 ]]; then
      log "  would remove: $path  ($(human_kb "$sz"))"
    else
      rm -f -- "$path"
      log "  removed: $path  ($(human_kb "$sz"))"
    fi
  done < <(find "$HOME" -mindepth 1 -maxdepth 1 -type f -iname '*.hprof' -print0)
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
  local before
  before="$(size_kb "$target")"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  would clear: $target  (currently: $(human_kb "$before"))"
    TOTAL_FREED_KB=$((TOTAL_FREED_KB + before))
    return
  fi
  find "$target" -mindepth 1 -delete
  local after
  after="$(size_kb "$target")"
  report_freed "Gradle temp" "$before" "$after"
}

empty_trash() {
  log "--- Trash ---"
  if [[ "$SKIP_TRASH" -eq 1 ]]; then
    log "  skipped (--skip-trash)"
    return
  fi
  if [[ "$DRY_RUN" -eq 1 ]]; then
    log "  would empty the Trash via Finder. (Size can't be previewed —"
    log "  ~/.Trash is protected from direct inspection the same way it's"
    log "  protected from find/rm; not included in the dry-run total.)"
    return
  fi
  osascript -e 'tell application "Finder"' -e 'try' -e 'empty trash' -e 'end try' -e 'end tell' >/dev/null
  log "  done. (Bytes freed can't be measured for the same reason — not"
  log "  included in the total below.)"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--dry-run) DRY_RUN=1; shift ;;
    -q|--quiet) QUIET=1; shift ;;
    --skip-npm) SKIP_NPM=1; shift ;;
    --skip-pip) SKIP_PIP=1; shift ;;
    --skip-brew) SKIP_BREW=1; shift ;;
    --skip-jetbrains-cache) SKIP_JETBRAINS_CACHE=1; shift ;;
    --skip-jetbrains-backups) SKIP_JETBRAINS_BACKUPS=1; shift ;;
    --skip-sparkle) SKIP_SPARKLE=1; shift ;;
    --skip-crash-dumps) SKIP_CRASH_DUMPS=1; shift ;;
    --skip-gradle-tmp) SKIP_GRADLE_TMP=1; shift ;;
    --skip-trash) SKIP_TRASH=1; shift ;;
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
    log "Dry run complete — would free approximately $(human_kb "$TOTAL_FREED_KB") (Trash not included; see above)."
  else
    log "Done. Freed approximately $(human_kb "$TOTAL_FREED_KB") (Trash not included in this total; see above)."
  fi
}

main
