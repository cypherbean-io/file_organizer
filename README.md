# File Organizer

An interactive, offline command-line tool for reviewing and organizing the
files in a directory, one file at a time. For each file it shows detailed
information, then lets you open/view it, rename it, copy or move it to
another directory, or delete it.

Written in pure Ruby (3.0+) with **zero gem dependencies** — everything,
including the photo (EXIF) and audio (ID3, FLAC, Vorbis, …) metadata
parsers, uses only the standard library. The program never touches the
network.

## Usage

```sh
ruby bin/file_organizer [options] [DIRECTORY]
```

If `DIRECTORY` is omitted you are prompted for one.

| Option | Description |
| --- | --- |
| `-m`, `--mode MODE` | `general` (default), `photo`, or `audio` |
| `--read-only` | Inspect only: rename, copy, move, delete and open are all disabled |
| `--dry-run` | Prompt as usual, but report what each action *would* do and change nothing |
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

## Project layout

```
bin/file_organizer                     Executable entry point
lib/file_organizer.rb                  Loader
lib/file_organizer/cli.rb              Interactive loop, option parsing
lib/file_organizer/console.rb          Safe terminal I/O
lib/file_organizer/safe_file.rb        Reads that never follow a symlink
lib/file_organizer/type_detector.rb    Magic-byte type detection
lib/file_organizer/file_info.rb        Filesystem metadata
lib/file_organizer/viewer.rb           Open / preview
lib/file_organizer/actions.rb          Rename / copy / move / delete
lib/file_organizer/metadata/binary.rb        Bounds-checked binary readers
lib/file_organizer/metadata/exif_parser.rb   Pure-Ruby TIFF/EXIF parser
lib/file_organizer/metadata/photo.rb         Image metadata
lib/file_organizer/metadata/audio.rb         Audio metadata
test/                                  Test suite (ruby test/all.rb)
```
