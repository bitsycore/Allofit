# Changelog

All notable changes to Allofit are documented here.

## [1.0.9] - 2026-10-02

### Added

- **Unlimited results.** Every match is listed, with no 2,000-row cap. The results list is a native macOS table that only builds the rows on screen, so scrolling through hundreds of thousands of entries stays smooth. For broad searches the first rows appear in milliseconds and the complete sorted list follows a fraction of a second later.
- **Filter menu** next to the search box, like Everything: Everything, Folders, Documents, Pictures, Audio, Video, Archives, Applications, Code.
- **Match highlighting:** the matched parts of names, and of folder paths for path terms, are shown in bold. It can be turned off in Settings.
- **Global shortcut** (default ⌥Space) to show or hide Allofit from any app, with a choice of shortcuts in Settings and a warning when one is already taken.
- **Menu bar icon** with Show Allofit, Settings… and Quit, which can be hidden.
- **Start at login** option.
- **"Search in Allofit" in Finder:** right-click a folder → Quick Actions (or Services). Dropping a folder on the Dock icon, or `open -a Allofit <folder>`, also searches inside it.
- **Keyboard shortcuts** in the results:

  | Key | Action |
  |---|---|
  | Return | Open, or Reveal (choice in Settings) |
  | ⌘Return | Reveal in Finder |
  | ⌘C | Copy the files |
  | ⌥⌘C | Copy the paths |
  | ⌘Y or Space | Quick Look |
  | ⌘⌫ | Move to Trash |

- **Context menu:** Open With (default app first), Copy, Copy Name, Copy Path, Move to Trash, and Authorize Access… for files you can't read.
- **Column options:** right-click the column header to show or hide columns. Column order, width and visibility are remembered.
- **Status bar:**
  - The last search time, Allofit's memory and CPU use, and the selection count and size ("3 selected (12 MB)").
  - Hovering it shows more detail: peak memory, threads, when the index last changed, cache size and roots.
- **Settings → Performance:** how quickly file changes reach the index and the open results, separately for when Allofit is focused (default about 3 s), when another app is focused (about 20 s) and when no window is visible (1 min). Showing a window always applies pending changes at once.

### Fixed

- **High CPU use with a path search open.** An open window searching with a `/` term re-ran the whole search on every file change and could keep several CPU cores busy. Path searches are also about three times faster.
- **Dragging files into a browser** opened the file in place of the web page instead of uploading it. Dragged rows now carry real files, like Finder.
- **Roots under `/tmp`, `/var` or `/etc`** never matched their own entries.
- **Long names and paths:** hovering a cut-off name or path now shows the full text immediately.

### Changed

- **Much less background work:** file changes are batched longer and open results refresh less often while Allofit isn't focused, and the status bar stops sampling when no window is visible.
- **Lower memory use:** the index is stored in chunks, so search results take 4 bytes per row and a file change copies only a small part of the index.
- **Settings** are regrouped into four tabs: General, Indexes (folders, exclusions, volumes), Performance and Advanced (service, cache, diagnostics).
- **Rebuild Index** moved from ⌘R to ⇧⌘R, so it's harder to trigger by accident.

## [1.0.6] - 2026-10-01

### Fixed

- **Memory blow-up on relaunch.** After the app had been closed for a while, reopening it (or opening its window while it ran in the background) could fill RAM and swap with many gigabytes within seconds. Catching up on file changes made while the app was closed no longer copies the whole index once per changed file. Memory now peaks under 1 GB during a multi-day catch-up and settles around 300 MB for 600k files.
- **Endless catch-up.** The index is now saved as soon as Allofit has caught up on file changes, and again on quit (⌘Q). Before, a launch that never got as far as saving had to replay an ever-growing backlog on every relaunch.
- **Ghost results.** Moving a folder to the Trash, or renaming it, left its whole contents searchable. Now the folder's contents are removed with it, and a folder moved or renamed into an indexed location is scanned.
- **Duplicate results** for files whose names contain accents (for example `Envoyés`).
- **Selection jumping** when a file changed or after a relaunch: each file's identity is now derived from its path, so it stays stable.
- **Flicker during file activity.** The results table and the Quick Look preview no longer redraw every time the index updates.
- **Hidden-folder content** (dot-folders such as `.git` or `.gradle`, and hidden folders at the top of a root) is no longer added by live updates when the initial scan skipped it. Existing entries are cleaned up on the next launch.
- **Excluded or removed paths** are dropped from the index on launch instead of lingering until a full reindex.
- Overlapping roots (one root inside another) are no longer indexed twice.
- A saved cache that can't be resumed (for example after the disk was erased or the cache was copied from another Mac) now triggers a background rescan instead of silently going stale.
- Minor memory leaks in the file-watching code.

### Added

- **Everything-style search syntax:**

  | Query | Meaning |
  |---|---|
  | `annual report` | AND: both words in the name |
  | `*.png \| *.jpg` | OR (binds tighter than AND) |
  | `report !draft` | NOT |
  | `"my file"` | quotes keep spaces inside one term |
  | `ext:pdf;docx` | by extension |
  | `file:` / `folder:` | files or folders only, alone or as a prefix (`folder:build`) |
  | `src/main` | a term with `/` is matched against the full path |
  | `"some/folder/**/path" IMG_????.heic` | folder-aware path wildcards: `*` within one folder name, `**` across any number of folders |
  | `photos/**/` | a trailing `/` means anything inside that folder |

- Searches ignore case and accents.
- The status bar shows the total number of results, not only the rows listed.
- Changes to roots, exclusions and volume options take effect immediately in built-in mode: new roots are scanned and removed ones dropped, with no reindex needed.
- Command-line service control: `Allofit install|uninstall|start|stop [user|root]`, `Allofit mode <none|user|root>`, `Allofit status`.
- Unit tests for the search syntax and the index logic, run in CI.

### Changed

- **Much faster search.** Results appear almost as you type: the delay after a keystroke dropped from 0.5 s to 0.04 s. Matching is spread across all CPU cores, and only the 2,000 rows shown are sorted instead of every match. A 600k-file index answers typical queries in a few milliseconds.
- Sorting by name is now a fast, case-insensitive alphabetical order. Number-aware ordering (`file2` before `file10`) is no longer used.
- The background service resumes from its saved index on start instead of rescanning every root, and can no longer mistake an interrupted first scan for a complete one.
- The index uses less memory: files in the same folder share one copy of the folder path.
- Build scripts moved to `scripts/`, and build output goes to `outputs/`.
- Added the MIT license.

## [1.0.5] - 2026-06-18

Previous release.
