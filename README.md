# mac-cleanup

A safe, repeatable disk-space cleanup script for macOS.

Modern dev machines quietly fill up with cache: npm, pip, Homebrew, IDE
indices, leftover auto-updater downloads, stray crash dumps. None of it is
useful once it's stale, and none of it is easy to find by hand. This script
clears out exactly that — and nothing else — with one command.

## Why not just use a general-purpose cleaner?

Most "Mac cleaner" apps either ask for broad system access, clean things
you can't verify, or bury their behavior in a GUI. This is one ~550-line
bash file you can read start to finish in a few minutes, with no
dependencies beyond tools already on your Mac.

## v2.0.0: what changed, and why

This script went through an independent second-opinion review after the
first release. That review found real issues — the kind you want a second
pair of eyes to catch on a tool that deletes files. v2.0.0 fixes all of
them:

- **Trash emptying is now opt-in** (`--empty-trash`, off by default).
  Finder's "empty trash" clears every *mounted volume's* trash, not just
  this Mac's — an external drive plugged in at the time would lose its
  trash too. That's a bigger blast radius than "regenerable cache," so it
  no longer runs by default.
- **JetBrains Toolbox `*-backup` folders are now opt-in**
  (`--include-jetbrains-backups`, off by default). These aren't cache —
  they're a full snapshot of your previous IDE settings (keymaps, saved
  database connections, live templates) kept specifically as a rollback
  point during an IDE update.
- **Crash-dump matching is narrower.** Previously any `~/*.hprof` file was
  removed; now only the patterns JVMs/JetBrains actually auto-generate
  (`java_error_in_*.hprof`, `java_pid*.hprof`) are touched, so a heap dump
  you made on purpose for debugging is left alone.
- **Deletion failures are no longer misreported as successes.** Every
  per-file removal now checks `rm`'s exit status before logging "removed"
  or counting it toward the freed-space total.
- **A malformed `$HOME` is refused outright**, rather than silently
  falling back to a system-wide path.
- **Symlinked cache folders are handled correctly** — if you've moved a
  cache directory to an external drive and symlinked it back, the script
  now measures and cleans what it actually points to, not just the
  symlink itself.
- Before touching the JetBrains cache or Gradle's temp folder, it now
  prints an advisory (not a block) if a related process looks like it
  might be running.

If you're on v1, the practical difference is: run `--empty-trash` and
`--include-jetbrains-backups` explicitly if you want the old default
behavior back for those two specifically.

## What it touches

| Step | What it clears | Default |
|---|---|---|
| npm cache | `~/.npm` | on |
| pip cache | `~/Library/Caches/pip` | on |
| Homebrew | old cellar versions & download cache | on |
| JetBrains cache | `~/Library/Caches/JetBrains/*` | on |
| Sparkle leftovers | `~/Library/Caches/*/org.sparkle-project.Sparkle` | on |
| Crash dumps | `~/java_error_in_*.hprof`, `~/java_pid*.hprof` | on |
| Gradle scratch | `~/.gradle/.tmp/*` | on |
| JetBrains settings-backups | `~/Library/Application Support/JetBrains/*-backup` | **opt-in** |
| Trash | every mounted volume's trash, via Finder | **opt-in** |

Every step is skipped gracefully (not an error) if the relevant tool or
folder isn't present on your machine.

## What it never touches

On purpose, because these need a human decision, not a script:

- Android SDK / emulator images (`~/Library/Android`, `~/.android`)
- Gradle's actual **version** caches (`~/.gradle/caches`) — only the
  disposable `.tmp` scratch folder is cleared; a version cache might be
  exactly what an active project needs
- Docker's data, your `Projects`/`node_modules`, `Downloads`
- Older-but-not-a-backup IDE version folders (e.g. last year's WebStorm) —
  worth reviewing by hand occasionally, not something to automate
- Personal files, SSH/GPG keys, app signing keystores

It also never asks for or uses `sudo`, and refuses to run at all if
`$HOME` isn't set to a real, sane directory.

## Requirements

- macOS (any Mac — Apple Silicon or Intel; nothing here is architecture-specific)
- bash (the version macOS ships with is fine)

None of the tools it cleans (npm, pip, Homebrew, JetBrains, Gradle) need to
actually be installed — anything missing is just skipped.

## Installation

```bash
git clone https://github.com/wsmr/mac-cleanup.git
cd mac-cleanup
chmod +x mac-cleanup.sh
```

## Usage

```bash
./mac-cleanup.sh              # run the default safe cleanup
./mac-cleanup.sh --dry-run    # preview only — deletes nothing
```

Run with `--dry-run` the first time. It reports exactly what it would
remove and roughly how much space it would free, with zero side effects.

### Options

| Flag | Description |
|---|---|
| `-n`, `--dry-run` | Preview only — nothing is deleted |
| `-q`, `--quiet` | Suppress npm/brew/pip's own output; this script's summary still prints |
| `--skip-npm` | Skip the npm cache |
| `--skip-pip` | Skip the pip cache |
| `--skip-brew` | Skip Homebrew cleanup |
| `--skip-jetbrains-cache` | Skip `~/Library/Caches/JetBrains` |
| `--skip-sparkle` | Skip leftover Sparkle auto-updater downloads |
| `--skip-crash-dumps` | Skip auto-generated `.hprof` crash dumps |
| `--skip-gradle-tmp` | Skip `~/.gradle/.tmp` |
| `--include-jetbrains-backups` | Opt in to removing JetBrains's `*-backup` folders |
| `--empty-trash` | Opt in to emptying the Trash (every mounted volume) |
| `-h`, `--help` | Show full usage |
| `-v`, `--version` | Show version |

Every flag is combinable, e.g. `./mac-cleanup.sh --empty-trash --quiet`.

### Example output

```
$ ./mac-cleanup.sh --dry-run
DRY RUN — nothing below will actually be deleted.

--- npm cache ---
  would run: npm cache clean --force  (currently: 2.1 GB)
--- pip cache ---
  would run: python3 -m pip cache purge  (currently: 340 MB)
--- Homebrew ---
  would run: brew cleanup -s  (cache: 410 MB, cellar: 1.2 GB)
  dry-run estimate is cache-only — cellar cleanup varies too much to predict
--- JetBrains IDE cache ---
  would clear: /Users/you/Library/Caches/JetBrains  (currently: 1.8 GB)
--- JetBrains Toolbox settings-backups (opt-in) ---
  skipped — these hold real settings, not cache. Opt in with
  --include-jetbrains-backups if you're sure you don't need them.
--- Leftover Sparkle auto-updater downloads ---
  none found.
--- Auto-generated crash dumps in $HOME ---
  would remove: /Users/you/java_error_in_webstorm.hprof  (2.0 GB)
--- Gradle scratch temp folder ---
  would clear: /Users/you/.gradle/.tmp  (currently: 221 MB)
--- Trash (opt-in) ---
  skipped — this empties every mounted volume's trash, not just
  this Mac's. Opt in with --empty-trash if that's what you want.

Dry run complete — would free approximately 6.5 GB (Trash excluded from every total; see above).
```

## Suggested alias

```bash
echo 'alias cleanmac="~/path/to/mac-cleanup.sh"' >> ~/.zshrc
source ~/.zshrc
```

## Continuous integration

Every push and pull request touching a `.sh` file, or the workflow file
itself, runs [ShellCheck](https://www.shellcheck.net/) via GitHub Actions
(`.github/workflows/shellcheck.yml`). The script currently passes with zero
warnings.

## Contributing

Issues and pull requests are welcome. If you're adding a new cleanup step,
please keep the rules the existing ones follow: default-on only for things
that are pure cache with zero unique data; anything that could hold real
user data is opt-in; every deletion checks its own exit status before
being reported as freed; and it never requires `sudo`.

## License

[MIT](LICENSE)
