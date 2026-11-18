# Changelog

All notable changes to Allofit are documented here.

## [1.0.12] - 2026-11-18

### Fixed

- **The window froze while another program created or deleted many files** (a test suite, a build). Removing thousands of folders at once compared each indexed entry with each removed folder, on the thread that runs the window, for seconds at a time. The check is now a binary search, about 1000× less work in that case, and every index update runs in the background: typing, scrolling and clicking stay responsive whatever the file activity.
- **Slow startup with a large index:** the cleanup pass after loading took over half a minute for 2.7 million entries; it now takes about 2 s. Loading also runs at user priority, so a busy Mac no longer stretches it to over a minute.

### Added

- **Signed and notarized releases:** once the signing secrets are set up, releases are signed with a Developer ID and notarized by Apple, so they open without Gatekeeper warnings (see README → Signing).

### Changed

- **Background service:** it now runs a copy of a helper signed on its own, `Contents/Helpers/Allofit Service`, instead of a copy of the app's program, whose signature didn't hold outside the app. With signed releases, the Full Disk Access granted to the system service persists across updates. Reinstall the service once after updating.
- **Less background work during heavy file activity:**
  - The index is saved less often when a save is expensive: at least 10× its own duration apart, instead of every 30 s.
  - When macOS asks Allofit several times to re-read the same folder, one re-read covers all the requests, instead of reading the folder once per request.

## [1.0.11] - 2026-10-29

### Fixed

- **A network share or drive that wasn't mounted lost all its entries.** When a root folder such as `/Volumes/MyShare` wasn't mounted yet (for example until you open it in Finder), macOS reported it as gone and Allofit dropped everything below it. Changes and rescans of a root that can't be reached are now ignored, so its entries stay searchable. When the volume mounts, the root is read again to pick up what changed meanwhile. A leftover empty folder in `/Volumes` doesn't count as mounted.

### Added

- **Protect** option for each folder in Settings → Indexes → Folders. A protected folder refuses any single update that would remove it, or more than 90% of its entries: for example a share that mounts empty, or a read cut off by a network error. Its entries stay searchable, and the folder shows "Kept" with the time. Smaller changes apply as usual, and folders with fewer than 100 entries aren't guarded. This works in built-in mode and with the background service.

### Changed

- **Tooltips** on the settings, buttons, search field and column headers explain what each one does. In Exclusions, Return in the path field adds the path.

## [1.0.10] - 2026-10-06

### Fixed

- **Crash** when the results list changed while the pointer rested on a cut-off name or path (for example right after adding a folder): the hover overlay read a row that no longer existed.
- **Status bar details** appeared late or not at all, because the help tag restarted its delay at every refresh. They now show 0.5 s after hovering and update live.

### Added

- **Indexing progress for new folders:** while a folder is indexed for the first time, the status bar shows "Indexing <folder>… N found", and Settings → Indexes → Folders shows the progress next to it, or "Not available" when the folder can't be reached (an unmounted drive or share).

### Changed

- **Large new folders** (a network share, an external drive) show their files as they are found, every few seconds, instead of only at the end of the walk.
- **Walks no longer delay live updates:** reading a big new folder runs separately, so changes elsewhere keep appearing.
- **Interrupted walks are redone:** a new folder only counts as indexed once its walk is complete, so quitting mid-walk resumes it on the next launch instead of leaving it half indexed.

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
- **Freeze the list:** hold ⌥ Option to stop background updates from moving rows while you read or select; releasing it catches up once. The status bar shows "Frozen" meanwhile.
- **Column options:** right-click the column header to show or hide columns. Column order, width and visibility are remembered.
- **Status bar:**
  - The last search time, Allofit's memory and CPU use, and the selection count and size ("3 selected (12 MB)").
  - Hovering it shows more detail: peak memory, threads, when the index last changed, cache size and roots.
- **Settings → Performance:** how quickly file changes reach the index and the open results, separately for when Allofit is focused (default about 3 s), when another app is focused (about 20 s) and when no window is visible (1 min). Showing a window always applies pending changes at once.

### Fixed

- **High CPU use with a path search open.** An open window searching with a `/` term re-ran the whole search on every file change and could keep several CPU cores busy. Path searches are also about three times faster.
- **Dragging files into a browser** opened the file in place of the web page instead of uploading it. Dragged rows now carry real files, like Finder.
- **Roots under `/tmp`, `/var` or `/etc`** never matched their own entries.
- **Files moved to the Trash from Allofit** came back in the results a moment later; they now leave the index, and ⌘Z puts them back.
- **Interrupted rescans** (quit or crash while a folder was being re-read) could lose that folder's contents until the next full rebuild.
- **Changing roots or exclusions** could drop file changes made at the same moment.
- **Renaming a file by case only** (`Foo` → `foo`) left a ghost entry.
- **Picking a service mode in Settings** took effect before Install, which could leave the app waiting for a service that didn't exist; the mode is now saved only when Install succeeds, and a missing service falls back to the built-in indexer.
- **Long names and paths:** hovering a cut-off name or path for half a second shows the full text over the cell, and it stays while you hover, even when the list refreshes.

### Security

- The "Authorize Access" copy no longer lets root change the owner or permissions of a path the user controls (it could be redirected to take over a system file).
- The background service no longer logs to fixed file names in `/tmp`; logs go to `/Library/Logs/Allofit/` (system service) or `~/Library/Logs/Allofit/` (user service).
- The system service's index, which lists every file name it can see, is readable only by root and the user who installed the service (it was readable by every account). Your own index is now private to you too.
- Installing the system service no longer copies a plist from a temporary file a user process could swap, and always uses the real app binary.
- Corrupt or oversized cache files are rejected instead of being expanded in memory, and two saves can no longer overwrite each other's temporary file.
- The release workflow pins its publishing action to an exact commit, and the app binary no longer searches the Xcode folder for libraries.

### Changed

- **Much less background work:** file changes are batched longer and open results refresh less often while Allofit isn't focused, and the status bar stops sampling when no window is visible.
- **Faster:** sorting a large list by date or size is about 10× faster, selecting rows no longer scans every result, new folders are merged without a pass over the whole index, and the background service saves at most every 15 s instead of every 3 s.
- **First launch:** results appear while the index is being built, an empty list explains why (loading, indexing, no match, filter on), and the macOS privacy prompts explain what Allofit reads.
- **Keyboard:** ↓ moves from the search field to the results and ↑ on the first row comes back; search history moved to ↑ / ⌥↑ / ⌥↓. The right-click menu shows the shortcuts.
- **Help:** a ? button and Help > Search Syntax show the query syntax. Clear Cache and Uninstall ask for confirmation, and Move to Trash reports failures.
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
