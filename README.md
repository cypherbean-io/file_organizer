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

| Key | Action |
| --- | --- |
| `o` | Open with the system default application |
| `v` | Preview in the terminal (text-based files) |
| `r` | Rename (same directory) |
| `c` | Copy to another directory |
| `m` | Move to another directory |
| `d` | Delete (requires typing `yes`) |
| `h` | Show SHA-256 checksum |
| `n` / Enter | Next file |
| `q` | Quit |

## Information displayed for every file

Name, location, content-detected type, extension (with a warning when it
does not match the detected content), size, permissions, owner/group,
created/modified/accessed times, hidden/executable/symlink status.

## Security design

- **Fully offline** — no network code exists anywhere in the program.
- **Content-based type detection** — file types are identified by magic
  bytes, and a warning is shown when the extension disagrees (a common
  disguise for malicious files).
- **No shell interpolation** — opening a file uses an argument vector
  (`system("open", path)`), so file names containing shell metacharacters
  cannot inject commands.
- **Terminal escape protection** — file names, metadata tags, and text
  previews are sanitized before display so embedded control characters
  cannot inject terminal escape sequences.
- **Path traversal protection** — new names for renames must be a single
  path component (no `/`, `\`, `..`, or control characters); destination
  directories are expanded and validated before use.
- **Explicit confirmation** — deleting or overwriting requires typing
  `yes`; nothing is ever overwritten silently.
- **Executables are never launched** — the open action is disabled for
  executable content and files with the executable bit set.
- **Symlinks are not followed** — links are inspected with `lstat`,
  clearly labeled, and deleting one removes only the link, never its
  target. Subdirectories are never touched.
- **Bounded, defensive parsing** — the metadata parsers read only capped
  header/metadata segments (never whole files), bounds-check every offset,
  and treat corrupt data as "no metadata" rather than crashing. File
  content is never evaluated or executed.

## Project layout

```
bin/file_organizer                     Executable entry point
lib/file_organizer.rb                  Loader
lib/file_organizer/cli.rb              Interactive loop, option parsing
lib/file_organizer/console.rb          Safe terminal I/O
lib/file_organizer/type_detector.rb    Magic-byte type detection
lib/file_organizer/file_info.rb        Filesystem metadata
lib/file_organizer/viewer.rb           Open / preview
lib/file_organizer/actions.rb          Rename / copy / move / delete
lib/file_organizer/metadata/binary.rb        Bounds-checked binary readers
lib/file_organizer/metadata/exif_parser.rb   Pure-Ruby TIFF/EXIF parser
lib/file_organizer/metadata/photo.rb         Image metadata
lib/file_organizer/metadata/audio.rb         Audio metadata
```
