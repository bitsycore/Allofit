# Allofit

A fast file-name search utility for macOS, inspired by [voidtools Everything](https://www.voidtools.com/) on Windows.

Allofit keeps an in-memory index of every file's name + metadata on configured roots, streams real-time updates via FSEvents, and answers wildcard queries instantly as you type. The index lives on disk as an LZ4-compressed binary cache so launches are sub-second even with hundreds of thousands of entries.

> Status: early. Currently at `0.0.1`. Builds and works, but expect rough edges around code signing and TCC.

## Features

- Instant name search with `*` and `?` wildcards (`Start*.pdf`, `IMG_????.heic`).
- OR-separated alternatives: `*.png | *.jpg | *.gif`.
- Real-time updates — new files appear within ~3 s of being created.
- Three index-host modes, selectable from Settings:
  - **Built-in** — the GUI process owns the index.
  - **User LaunchAgent** — runs in the background as your user.
  - **Root LaunchDaemon** — runs as `root` and can index everything on disk (Full Disk Access required).
- Sortable Table view (Name / Path / Size / Created / Modified), click headers to sort.
- Quick Look preview, Reveal in Finder, drag-and-drop out, Copy Path.
- Persistent search history with up/down arrow navigation and the magnifying-glass dropdown.
- Remembers last query, last sort order, and exclusion list across launches.
- Diagnostics tab with live daemon status, cache mtime, and service log tail.

## Requirements

- macOS 15 (Sequoia) or newer.
- Swift 6 toolchain (Xcode 16 ships with Swift 6.0; the repo uses `swift-tools-version: 6.0` with `swiftLanguageMode(.v5)`).

## Install (from a release)

Grab the latest from [Releases](https://github.com/bitsycore/Allofit/releases).

- **`.dmg`** — double-click, drag `Allofit` onto the `Applications` shortcut, eject.
- **`.zip`** — unzip, move `Allofit.app` to `/Applications` (or run from anywhere).
- **`.sha256`** — checksums for both files if you want to verify the download.

### Gatekeeper warning on first launch

Allofit ships ad-hoc signed (no Developer ID) since it's an open-source utility. macOS Gatekeeper will refuse to launch it on first open with the "unidentified developer" message. Two ways past it:

```bash
# the well-mannered way: tell macOS you've reviewed the binary
xattr -dr com.apple.quarantine /Applications/Allofit.app
open /Applications/Allofit.app
```

Or right-click `Allofit.app` in Finder → **Open** → confirm the warning dialog. Once accepted, subsequent launches don't prompt.

## Build from source

```bash
# Local dev: produces an ad-hoc-signed Allofit.app next to the repo
./build-app.sh
open Allofit.app

# Package as a drag-to-install DMG
./build-dmg.sh                 # rebuilds the .app first, then DMGs it
./build-dmg.sh --skip-build    # assumes Allofit.app already exists

# Pin a version in the Info.plist (CI does this automatically from the tag)
ALLOFIT_VERSION=1.2.3 ALLOFIT_BUILD=42 ./build-app.sh
```

Both scripts default to `ALLOFIT_VERSION=0.0.0` / `ALLOFIT_BUILD=0` when the env vars are unset.

For a one-shot run without building the bundle:

```bash
swift run -c release Allofit
```

## Search syntax

| Query | Meaning |
|---|---|
| `report` | Case-insensitive substring match against the file name |
| `Start*.pdf` | Anchored wildcard — name starts with `Start`, ends with `.pdf` |
| `IMG_????.heic` | `?` matches exactly one character |
| `*.png \| *.jpg` | OR — matches either alternative (whitespace around `\|` is optional) |
| *(empty)* | Show all indexed entries |

## Service mode (root daemon)

The root daemon runs `Allofit --service` as a LaunchDaemon and keeps the index alive even when the GUI is closed. Install/uninstall from **Settings → Service**.

Important: macOS TCC restricts even root from receiving FSEvents for `~/Documents`, `~/Desktop`, `~/Downloads`, `~/Library/Mail`, etc. After installing the daemon, grant **Full Disk Access** to its binary in **System Settings → Privacy & Security → Full Disk Access**. The Diagnostics tab shows the exact path to add.

## Reset

`./clean.sh` removes everything Allofit ever wrote: the LaunchAgent / LaunchDaemon plists, both per-user and system caches, the indexer lock, UserDefaults, log files, and (unless `--keep-build`) the build directory and `.app` bundle. Run it before reinstalling if anything gets into a weird state.

```bash
./clean.sh --help
```

## Architecture quick reference

| File | Role |
|---|---|
| `Main.swift` | `@main`; routes between GUI and `--service` daemon |
| `AllofitApp.swift` | SwiftUI `App` + `NSApplicationDelegate` for proper focus & dock behavior |
| `AllofitService.swift` | Headless daemon: initial scan + FSEvents loop + 3 s autosave |
| `FileIndexer.swift` | Filesystem walker (`FileManager.enumerator` + pre-fetched `URLResourceKey`s) |
| `FileWatcher.swift` | FSEvents wrapper, supports resuming from a saved event id |
| `IndexStore.swift` | LZ4-compressed binary cache format + system/user path resolution |
| `IndexerLock.swift` | POSIX advisory lock (fcntl `F_SETLK`) keeping only one indexer alive |
| `Preferences.swift` | UserDefaults-backed settings; daemon reads owner's plist via `ALLOFIT_OWNER_HOME` env var |
| `AppModel.swift` | `@MainActor` ObservableObject; orchestrates indexer/reader bootstrap |
| `SearchEngine.swift` | Wildcard → anchored regex + OR-alternative matcher |
| `ContentView.swift`, `SettingsView.swift` | SwiftUI views; six-tab Settings (Roots / Exclusions / Volumes / Service / Cache / Diagnostics) |
| `SearchField.swift` | `NSViewRepresentable` around `NSSearchField` for native history + ↑/↓ navigation |

## CI / releases

`.github/workflows/ci.yml` builds debug + release on every push/PR to `main`. `.github/workflows/release.yml` fires on tag pushes — builds the bundle, packages a `.zip` and a `.dmg`, computes SHA-256 checksums for both, and publishes a GitHub Release with all artifacts attached. Tag with `0.0.1` or `v0.0.1` (the leading `v` is stripped before being stamped into the Info.plist).

## Keyboard shortcuts

| Key | Action |
|---|---|
| ⌘F | Focus the search field (and select existing text) |
| ⌘R | Reindex everything |
| ⌘, | Open Preferences |
| ⌘W | Hide the window (process stays resident; ⌘Q to actually quit) |
| ↑ / ↓ in the search field | Cycle through recent search history |

## License

MIT — see [LICENSE](LICENSE).
