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

| Type… | …to match |
|---|---|
| `report` | any name containing "report" |
| `Start*.pdf` | starts with "Start", ends with ".pdf" |
| `IMG_????.heic` | "IMG_" + exactly 4 chars + ".heic" |
| `*.png \| *.jpg` | OR — png or jpg |

## Shortcuts

| Key | Action |
|---|---|
| ⌘F | Focus search |
| ⌘R | Reindex |
| ⌘, | Preferences |
| ↑ ↓ | Cycle search history |

## Background service (optional)

**Settings → Service** installs a LaunchAgent (user) or LaunchDaemon (root) that keeps the index updated even when the app is closed.

Root daemon mode needs **Full Disk Access** granted to its binary in **System Settings → Privacy & Security**, otherwise it won't see new files in `~/Documents`, `~/Desktop`, `~/Downloads`. The Diagnostics tab shows the exact path to add.

## Build from source

```bash
./build-app.sh    # produces Allofit.app
./build-dmg.sh    # produces Allofit-0.0.0.dmg
```

`./clean.sh` wipes services, caches, prefs, and build artifacts for a fresh start.

## License

[MIT](LICENSE)
