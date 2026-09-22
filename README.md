# mac-cleanup

A safe, repeatable disk-space cleanup script for macOS.

Modern dev machines quietly fill up with cache: npm, pip, Homebrew, IDE
indices, leftover auto-updater downloads, stray crash dumps. None of it is
useful once it's stale, and none of it is easy to find by hand. This script
clears out exactly that — and nothing else — with one command.

## Why not just use a general-purpose cleaner?

Most "Mac cleaner" apps either ask for broad system access, clean things
you can't verify, or bury their behavior in a GUI. This is one ~450-line
bash file you can read start to finish in a few minutes, with no
dependencies beyond tools already on your Mac.

## What it touches

| Step | What it clears | Command used under the hood |
|---|---|---|
| npm cache | `~/.npm` | `npm cache clean --force` |
| pip cache | `~/Library/Caches/pip` | `python3 -m pip cache purge` |
| Homebrew | old cellar versions & download cache | `brew cleanup -s` |
| JetBrains cache | `~/Library/Caches/JetBrains/*` | plain delete |
| JetBrains backups | `~/Library/Application Support/JetBrains/*-backup` | plain delete |
| Sparkle leftovers | `~/Library/Caches/*/org.sparkle-project.Sparkle` | plain delete |
| Crash dumps | `~/*.hprof` | plain delete |
| Gradle scratch | `~/.gradle/.tmp/*` | plain delete |
| Trash | `~/.Trash` | via Finder (AppleScript), never touched directly |

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

It also never asks for or uses `sudo`.

## Requirements

- macOS (any Mac — Apple Silicon or Intel; nothing here is architecture-specific)
- bash (the version macOS ships with is fine)

None of the tools it cleans (npm, pip, Homebrew, JetBrains, Gradle) need to
actually be installed — anything missing is just skipped.

## Installation

```bash
git clone https://github.com/<your-username>/mac-cleanup.git
cd mac-cleanup
chmod +x mac-cleanup.sh
```

## Usage

```bash
./mac-cleanup.sh              # run everything
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
| `--skip-jetbrains-backups` | Skip JetBrains Toolbox's `*-backup` folders |
| `--skip-sparkle` | Skip leftover Sparkle auto-updater downloads |
| `--skip-crash-dumps` | Skip `*.hprof` crash dumps in `$HOME` |
| `--skip-gradle-tmp` | Skip `~/.gradle/.tmp` |
| `--skip-trash` | Skip emptying the Trash |
| `-h`, `--help` | Show full usage |
| `-v`, `--version` | Show version |

Every flag is combinable, e.g. `./mac-cleanup.sh --skip-trash --quiet`.

### Example output

```
$ ./mac-cleanup.sh --dry-run
DRY RUN — nothing below will actually be deleted.

--- npm cache ---
  would run: npm cache clean --force  (currently: 2.1 GB)
--- pip cache ---
  would run: python3 -m pip cache purge  (currently: 340 MB)
--- Homebrew ---
  would run: brew cleanup -s  (cache currently: 410 MB)
--- JetBrains IDE cache ---
  would clear: /Users/you/Library/Caches/JetBrains  (currently: 1.8 GB)
--- JetBrains Toolbox settings-backups ---
  would remove: /Users/you/Library/Application Support/JetBrains/WebStorm2024.2-backup  (610 MB)
--- Leftover Sparkle auto-updater downloads ---
  none found.
--- Crash dumps in $HOME ---
  would remove: /Users/you/java_error_in_webstorm.hprof  (2.0 GB)
--- Gradle scratch temp folder ---
  would clear: /Users/you/.gradle/.tmp  (currently: 221 MB)
--- Trash ---
  would empty the Trash via Finder. (Size can't be previewed — ~/.Trash
  is protected from direct inspection the same way it's protected from
  find/rm; not included in the dry-run total.)

Dry run complete — would free approximately 7.4 GB (Trash not included; see above).
```

## Suggested alias

```bash
echo 'alias cleanmac="~/path/to/mac-cleanup.sh"' >> ~/.zshrc
source ~/.zshrc
```

## Continuous integration

Every push and pull request touching a `.sh` file runs
[ShellCheck](https://www.shellcheck.net/) via GitHub Actions
(`.github/workflows/shellcheck.yml`). The script currently passes with zero
warnings.

## Contributing

Issues and pull requests are welcome. If you're adding a new cleanup step,
please keep the two rules the existing ones follow: it only ever removes
things that regenerate automatically or hold no unique data, and it never
requires `sudo`.

## License

[MIT](LICENSE)
