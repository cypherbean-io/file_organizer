# File Organizer

An interactive, offline tool for reviewing and organizing the files in a
directory. For each file it shows detailed information, then lets you
open/view it, rename it, copy or move it to another directory, or delete it.

There are two interfaces over the same core: a terminal one that walks the
files one at a time, and a **graphical one** that runs in your browser.

Written in pure Ruby (3.0+) with **zero gem dependencies** — everything,
including the photo (EXIF) and audio (ID3, FLAC, Vorbis, …) metadata parsers
and the web server behind the graphical interface, uses only the standard
library. The program never touches the network.

## Usage

```sh
ruby bin/file_organizer [options] [DIRECTORY]        # terminal
ruby bin/file_organizer --gui [options] [DIRECTORY]  # browser
```

In the terminal you are prompted for a directory if `DIRECTORY` is omitted;
the graphical interface starts in the current directory and lets you change
folders from the page.

| Option | Description |
| --- | --- |
| `-m`, `--mode MODE` | `general` (default), `photo`, or `audio` |
| `--read-only` | Inspect only: rename, copy, move, delete and open are all disabled |
| `--dry-run` | Prompt as usual, but report what each action *would* do and change nothing |
| `-g`, `--gui` | Open the graphical interface in your browser |
| `-p`, `--port PORT` | GUI port (default: an unused port chosen by the OS) |
| `--[no-]browser` | GUI: launch the browser automatically (default: yes) |
| `-h`, `--help` | Show help |
| `--version` | Show version |

### Modes

- **general** — cycles through every file of any type and shows general
  file information.
- **photo** — cycles through image files only (detected by content, not
  extension) and additionally shows photo metadata: dimensions, megapixels,
  color format, and EXIF data (camera make/model, timestamps, exposure,
  aperture, ISO, focal length, orientation, and GPS location when present).
  Supports JPEG, PNG, GIF, BMP, TIFF, WebP, SVG, and HEIC (detection only).
- **audio** — cycles through audio files only and additionally shows audio
  metadata: codec, duration, bitrate, sample rate, channels, bit depth, and
  tags (title, artist, album, year, genre, track, embedded artwork).
  Supports MP3 (ID3v1/v2.2/v2.3/v2.4), WAV, FLAC, Ogg Vorbis, Opus, M4A,
  and AIFF.

### Per-file actions

| Key | Action | Confirmation |
| --- | --- | --- |
| `o` | Open with the system default application | typed `yes` if the extension disagrees with the content |
| `v` | Preview in the terminal (text-based files) | — |
| `r` | Rename (same directory) | `y/N`, defaulting to no |
| `c` | Copy to another directory | `y/N`; typed `yes` to overwrite |
| `m` | Move to another directory | `y/N`; typed `yes` to overwrite |
| `d` | Delete | typed `yes` |
| `h` | Show SHA-256 checksum | — |
| `n` / Enter | Next file | — |
| `q` | Quit | — |

Each key is matched in full: `d` and `delete` both delete, but a word that
merely starts with an action letter (`done`, `move it later`) is rejected as
unrecognized rather than being run.

## Graphical interface

`--gui` starts a small web server on the loopback interface and opens the
page in your browser. The terminal prints the address, which carries a
one-time key for the session:

```
── File Organizer 1.0.0 — graphical interface ──────────────────────────
  Folder:                /home/you/Downloads
  Address:               http://127.0.0.1:53017/?t=…
```

Press Ctrl-C in the terminal, or use Quit in the page, to stop.

The page shows the whole folder at once:

- **Browse** — the file list with a type icon, detected type and size for
  every entry; filter by name, filter by category (Images, Audio, Video,
  Documents, Archives, Executables, Text, Data, Links…), and sort by name,
  size, modification time or type.
- **Preview** — images are shown (click to zoom), audio and video get a
  player, text-based files get a numbered preview. Anything else shows why
  it has no preview.
- **Inspect** — the same file information the terminal shows, plus the photo
  or audio metadata for images and audio, and SHA-256 on request.
- **Act** — open, rename, copy, move and delete, with the same rules and
  confirmations as the terminal interface.
- **Gallery view** — thumbnails of the whole folder, which makes sorting
  through a directory of images much quicker.
- **Navigate** — the path is a row of breadcrumbs; “Open folder…” takes a
  path and offers the parent and subfolders as one-click choices.
- **Keyboard** — `↑`/`↓` or `j`/`k` to move, `o` `r` `c` `m` `d` `h` for the
  actions, `/` to filter, `g` for gallery, `R` to reload, `T` for the theme,
  `?` for the list. Dark and light themes follow the system and can be
  toggled.

The page lists at most 5,000 entries of a folder — once there are more, it
says so, and which 5,000 follows the order the filesystem returns them in
(the terminal has no such cap). A file's content, and its checksum, are
examined once and remembered until the file changes, so refreshing a large
folder stays quick.

Images are sent to the browser at full size — there is no image processing
in the standard library to make thumbnails with — so a folder of very large
photos takes a moment to fill the gallery.

## Information displayed for every file

Name, location, content-detected type, extension (with a warning when it
does not match the detected content), size, permissions, owner/group,
created/modified/accessed times, hidden/executable/symlink status.

## Safeguards against accidental changes

- **Nothing is modified without being confirmed first.** Renaming, copying
  and moving take a `y/N` answer that defaults to *no* — Enter, a stray
  word, or end-of-input all decline. Deleting and overwriting take the full
  word `yes` and nothing else.
- **Menu keys are matched in full.** Typing anything that is not exactly an
  action key is refused, so a word that happens to begin with `d`, `m` or
  `r` cannot start a delete, a move or a rename.
- **`--read-only`** disables rename, copy, move, delete *and* open (handing
  a file to another application is a way to have it modified), leaving
  inspection, preview and checksums. Nothing in the directory can change.
- **`--dry-run`** prompts exactly as a real session does and reports the
  operation it would have performed, without touching the filesystem.
- **Nothing is overwritten silently.** An existing file at the destination
  has to be confirmed by name; an existing *symbolic link* or *directory* at
  that name is refused outright rather than confirmed.
- **Renames cannot clobber.** The new name is staked out with `link(2)`,
  which fails if the name is taken, before the old one is dropped — so a
  file that appears between the check and the rename is not destroyed. A
  case-only rename on a case-insensitive filesystem is recognized as a
  rename rather than reported as a collision.
- **System and home directories take an explicit `yes`** before their
  contents are offered up for renaming or deletion.
- **Subdirectories are never touched** — only regular files and symlinks in
  the directory itself are listed.

## Security design

- **Fully offline** — no network code exists anywhere in the program.
- **Content-based type detection** — file types are identified by magic
  bytes, and a warning is shown when the extension disagrees (a common
  disguise for malicious files).
- **No shell interpolation** — opening a file uses an argument vector
  (`system("open", path)`), so file names containing shell metacharacters
  cannot inject commands. On Windows, where `cmd.exe` re-parses its command
  line, a path containing characters it treats as syntax is refused rather
  than quoted and hoped for.
- **Terminal escape protection** — file names, metadata tags, and text
  previews are sanitized before display. Control characters (including ESC),
  Unicode format characters (including the bidirectional overrides that turn
  `invoice<RLO>gnp.exe` into an innocent-looking `invoice.png`), and the
  Unicode line and paragraph separators are all replaced with visible
  escapes.
- **Path traversal protection** — new names for renames must be a single
  path component (no `/`, `\`, `..`, or control characters); destination
  directories are expanded and validated before use.
- **Executables and launchers are never opened** — the open action is
  disabled for executable content, for files with the executable bit set,
  and for extensions the desktop treats as "run this" (`.desktop`, `.lnk`,
  `.exe`, `.vbs`, …) whatever their bytes look like. Opening a file whose
  extension disagrees with its content takes an explicit `yes`, because the
  system picks the application from the extension.
- **Symlinks are never followed.** They are inspected with `lstat`, clearly
  labeled, and deleting one removes only the link. Every read is made with
  `O_NOFOLLOW`, and every write is either an `O_NOFOLLOW` open or a
  `rename(2)` — so a link cannot redirect a read or a write to a file
  outside the directory in play.
- **Bounded, defensive parsing** — the metadata parsers read only capped
  header/metadata segments (never whole files), bounds-check every offset,
  cap the hunt for a marker in a corrupt file, and treat corrupt data as
  "no metadata" rather than crashing. File content is never evaluated or
  executed.

## Tests

```sh
ruby test/all.rb
```

Uses minitest from the standard library; no gems to install. The suite
covers display sanitizing, every confirmation path, the refusal to write
through a symlink, menu parsing, type detection, and the metadata parsers'
behaviour on truncated and pathological files.

### The graphical interface

The GUI is a page served to your own browser, so it comes with its own set
of rules:

- **Loopback only** — the server binds `127.0.0.1`. It is not reachable from
  the network, and there is still no outbound network code anywhere.
- **A one-time key** — every page and API request must carry the key printed
  in the terminal, so another program on the machine cannot drive the
  interface. It is new on every run and lives only in memory. The browser is
  never handed the address on its command line, which every user on the
  machine can read: it is handed a private page that redirects to it.
- **Host and Origin checks** — requests must name our own loopback address
  (which defeats DNS rebinding), and anything the browser labels as
  cross-origin or cross-site is refused even if it has the key.
- **A page that can load nothing** — the Content-Security-Policy allows no
  script, style, image, font or connection other than the ones this program
  serves; the page cannot be framed and cannot submit a form anywhere.
- **Files addressed by opaque id, never by path** — an id decodes to a
  single file name inside the folder being reviewed, so a crafted request
  cannot reach anywhere else. An id also names the folder it was handed out
  for: once another tab has moved the program to a different folder, a page
  still showing the old one cannot act on a same-named file in the new one.
  (Ids also let names that are not valid UTF-8 survive the round trip.)
- **Only media is ever served to the page** — image, audio and video bytes,
  for formats detected by content and streamed in bounded ranges. SVG and
  PDF are deliberately not rendered in the page, so nothing that could carry
  script is ever handed to the browser as a document; text files go through
  the same sanitized preview the terminal uses.
- **Names and metadata are inserted as text, never as markup** — a file
  cannot inject anything into the page, just as it cannot inject terminal
  escape sequences into the terminal.
- **The same confirmations** — deleting, overwriting, opening a file whose
  extension disagrees with its content, and switching to a system or home
  folder each require typing `yes`, exactly as in the terminal. The server
  checks it too: a request without it is refused, whatever the page does.
- **The same modes** — `--read-only` and `--dry-run` work with `--gui`. In
  read-only mode the server refuses every request that would rename, copy,
  move, delete or open a file, whatever the page sends; in a dry run each
  action reports what it would have done and changes nothing.
- **The same file operations** — the GUI calls the very `Operations` the
  terminal does, so it inherits every rule above: no write through a
  symlink, no silent overwrite, no launching of executables or launchers.
- **Bounded requests** — request lines, headers, bodies and connection
  lifetimes are all capped, and a single event loop hands sockets to workers
  only when a request is actually arriving on them.

## Project layout

```
bin/file_organizer                     Executable entry point
lib/file_organizer.rb                  Loader
lib/file_organizer/cli.rb              Interactive loop, option parsing
lib/file_organizer/console.rb          Safe terminal I/O
lib/file_organizer/safe_file.rb        Reads that never follow a symlink
lib/file_organizer/type_detector.rb    Magic-byte type detection
lib/file_organizer/file_info.rb        Filesystem metadata
lib/file_organizer/directory.rb        Listing and validating directories
lib/file_organizer/viewer.rb           Open / preview
lib/file_organizer/operations.rb       Validated rename / copy / move / delete
lib/file_organizer/actions.rb          The prompts and confirmations around them
lib/file_organizer/metadata/binary.rb        Bounds-checked binary readers
lib/file_organizer/metadata/exif_parser.rb   Pure-Ruby TIFF/EXIF parser
lib/file_organizer/metadata/photo.rb         Image metadata
lib/file_organizer/metadata/audio.rb         Audio metadata
lib/file_organizer/gui.rb              GUI entry point, opaque file ids
lib/file_organizer/gui/server.rb       Loopback HTTP server (event loop)
lib/file_organizer/gui/connection.rb   Bounded HTTP request parsing
lib/file_organizer/gui/request.rb      One parsed request
lib/file_organizer/gui/response.rb     One response (in-memory or streamed)
lib/file_organizer/gui/app.rb          Routing, guards, request handling
lib/file_organizer/gui/session.rb      Which folder is being reviewed, and how
lib/file_organizer/gui/presenter.rb    Files and metadata as plain data
lib/file_organizer/gui/web/            The page: index.html, app.css, app.js
test/                                  Test suite (ruby test/all.rb)
```

Both interfaces share the core: `Operations` performs every filesystem
change, `Directory` lists folders, `FileInfo` and `TypeDetector` describe
files, `Metadata::*` parses them. The GUI adds a server and a page; it does
not add a second implementation of anything that touches your files.
