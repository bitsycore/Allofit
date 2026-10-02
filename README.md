# Allofit

Fast file-name search for macOS, inspired by [voidtools Everything](https://www.voidtools.com/).

Keeps an in-memory index of file names + metadata, updates in real time via FSEvents, and filters instantly as you type. Optional background service so the index stays warm between launches.

## Install

Grab the latest `.dmg` from [Releases](https://github.com/bitsycore/Allofit/releases). Open it, drag `Allofit` onto `Applications`.

First launch will be blocked by Gatekeeper (ad-hoc signed). Right-click → **Open**, or:

```bash
xattr -dr com.apple.quarantine /Applications/Allofit.app
```

Requires macOS 15 (Sequoia) or newer.

## Search

Same syntax as Everything:

| Type… | …to match |
|---|---|
| `report` | any name containing "report" (case-insensitive) |
| `annual report` | names containing "annual" **and** "report" |
| `Start*.pdf` | starts with "Start", ends with ".pdf" |
| `IMG_????.heic` | "IMG_" + exactly 4 chars + ".heic" |
| `*.png \| *.jpg` | OR - png or jpg (OR binds tighter than the space AND) |
| `report !draft` | NOT - names with "report" but without "draft" |
| `"my file"` | quotes keep spaces inside one term |
| `ext:pdf;docx` | by extension |
| `file:` / `folder:` | files only / folders only, alone or as a prefix (`folder:build`) |
| `src/main` | a term with `/` matches against the full path |
| `"some/folder/**/path" IMG_????.heic` | path wildcards: `*` stays inside one folder name, `**` spans any number of folders (zero too) |
| `photos/**/` | a trailing `/` means anything inside that folder |

The list shows the first 2,000 results in the chosen order; the status bar shows the total count.

## Shortcuts

| Key | Action |
|---|---|
| ⌥Space | Show / hide Allofit from any app (changeable in Settings) |
| ⌘F | Focus search |
| ↑ ↓ (in the search field) | Cycle search history |
| Return | Open the selection (or reveal it, see Settings) |
| ⌘Return | Reveal in Finder |
| Space / ⌘Y | Quick Look |
| ⌘C / ⌥⌘C | Copy the files / their paths |
| ⌘⌫ | Move to Trash |
| Hold ⌥ | Freeze the list: no background updates until released |
| ⇧⌘R | Rebuild the index |
| ⌘, | Settings |

Hovering a cut-off name or path for half a second shows it in full. In Finder, right-click a folder → Quick Actions → **Search in Allofit** to search inside it.

## Background service (optional)

**Settings → Service** installs a LaunchAgent (user) or LaunchDaemon (root) that keeps the index updated even when the app is closed.

Root daemon mode needs **Full Disk Access** granted to its binary in **System Settings → Privacy & Security**, otherwise it won't see new files in `~/Documents`, `~/Desktop`, `~/Downloads`. The Diagnostics tab shows the exact path to add.

## Build from source

```bash
./scripts/build-app.sh    # produces outputs/Allofit-0.0.0.app
./scripts/build-dmg.sh    # produces outputs/Allofit-0.0.0.dmg
```

(The version is stamped into both the filename and the bundle's Info.plist. Pass `--version 1.2.3` or set `ALLOFIT_VERSION=1.2.3` to override.)

`./scripts/clean.sh` wipes services, caches, prefs, and build artifacts (including `outputs/`) for a fresh start.

## License

[MIT](LICENSE)
