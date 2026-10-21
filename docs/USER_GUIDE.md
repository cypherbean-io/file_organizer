# File Organizer — User Guide

File Organizer helps you tidy up a folder. It goes through the files in a
directory, tells you what each one really is (by looking at its content, not
its name), and lets you open, preview, rename, copy, move, or delete it — with
a confirmation before anything changes.

You can use it two ways:

- **In the terminal**, one file at a time, answering a short prompt for each.
- **In your browser**, with the whole folder on one page: a file list, a
  thumbnail gallery, previews, and buttons for every action.

It works entirely offline. It never connects to the internet, and the browser
interface is only reachable from your own computer.

This guide covers installation and everyday use. For the full list of safety
rules and how they are enforced, see the
[Safeguards](../README.md#safeguards-against-accidental-changes) and
[Security design](../README.md#security-design) sections of the README.

---

## Contents

1. [Installation](#1-installation)
2. [Quick start](#2-quick-start)
3. [Command-line options](#3-command-line-options)
4. [Choosing a mode: general, photo, audio](#4-choosing-a-mode-general-photo-audio)
5. [Using the terminal interface](#5-using-the-terminal-interface)
6. [Using the browser interface](#6-using-the-browser-interface)
7. [Confirmations and safety features](#7-confirmations-and-safety-features)
8. [Practice safely: read-only and dry-run](#8-practice-safely-read-only-and-dry-run)
9. [Common tasks](#9-common-tasks)
10. [Troubleshooting](#10-troubleshooting)
11. [Updating and uninstalling](#11-updating-and-uninstalling)

---

## 1. Installation

File Organizer is a plain Ruby program with **no gems to install**. All you
need is Ruby itself and a copy of the program.

### Step 1 — Install Ruby 3.0 or newer

Check whether you already have it:

```sh
ruby -v
```

If that prints `ruby 3.0` or higher, skip to Step 2. Otherwise:

| System | How to install Ruby |
| --- | --- |
| **macOS** | The Ruby bundled with older macOS versions is too old. Install a current one with [Homebrew](https://brew.sh): `brew install ruby`, then follow the "add to PATH" note Homebrew prints. |
| **Debian / Ubuntu** | `sudo apt install ruby` |
| **Fedora** | `sudo dnf install ruby` |
| **Arch** | `sudo pacman -S ruby` |
| **Windows** | Download and run [RubyInstaller](https://rubyinstaller.org/) (the plain "Ruby" build is enough; the Devkit is not needed). |

The official [Installing Ruby](https://www.ruby-lang.org/en/documentation/installation/)
page lists more options, including version managers such as `rbenv` and
`asdf`.

**Linux only:** opening a file in its default application uses `xdg-open`.
Most desktop distributions include it; if not, install the `xdg-utils`
package. Everything else works without it.

### Step 2 — Get File Organizer

With git:

```sh
git clone https://github.com/cypherbean-io/file_organizer.git
cd file_organizer
```

Or download the repository as a ZIP from GitHub (**Code → Download ZIP**) and
unpack it anywhere you like.

### Step 3 — Check that it runs

From inside the `file_organizer` folder:

```sh
ruby bin/file_organizer --version
```

It should print the version number (for example `1.0.0`).

Optionally, run the test suite to confirm everything works on your machine:

```sh
ruby test/all.rb
```

### Step 4 (optional) — Run it from anywhere

So you can type `file_organizer` from any folder instead of the full path:

**macOS / Linux** — link the launcher into a folder on your `PATH`
(`~/.local/bin` is common; create it if needed):

```sh
mkdir -p ~/.local/bin
ln -s "$PWD/bin/file_organizer" ~/.local/bin/file_organizer
file_organizer --version
```

If `file_organizer` is "not found", add `~/.local/bin` to your `PATH` in your
shell's startup file (e.g. `~/.bashrc` or `~/.zshrc`):

```sh
export PATH="$HOME/.local/bin:$PATH"
```

**Windows** — run it with `ruby`, using the full path to the launcher:

```bat
ruby C:\path\to\file_organizer\bin\file_organizer --gui
```

or create a one-line `file_organizer.bat` in a folder on your `PATH`:

```bat
@ruby C:\path\to\file_organizer\bin\file_organizer %*
```

The rest of this guide writes commands as `ruby bin/file_organizer …`; if you
did Step 4, plain `file_organizer …` works the same way.

---

## 2. Quick start

**Browser interface** — review your Downloads folder on one page:

```sh
ruby bin/file_organizer --gui ~/Downloads
```

Your browser opens on the file list. Press `?` on the page for the keyboard
shortcuts, and **Quit** (or Ctrl-C in the terminal) when you're done.

**Terminal interface** — walk through the same folder one file at a time:

```sh
ruby bin/file_organizer ~/Downloads
```

**Just looking?** Add `--read-only` to either command, and nothing can be
changed:

```sh
ruby bin/file_organizer --read-only --gui ~/Downloads
```

---

## 3. Command-line options

```
ruby bin/file_organizer [options] [DIRECTORY]
```

| Option | What it does |
| --- | --- |
| `-m`, `--mode MODE` | `general` (default), `photo`, or `audio` — see [modes](#4-choosing-a-mode-general-photo-audio) |
| `--read-only` | Look only. Rename, copy, move, delete, and open are all switched off |
| `--dry-run` | Everything behaves normally, but each action only *reports* what it would have done |
| `-g`, `--gui` | Use the browser interface |
| `-p`, `--port PORT` | Browser interface: the port to listen on (default: any free port) |
| `--no-browser` | Browser interface: don't open the browser automatically; just print the address |
| `-h`, `--help` | Show the option list |
| `--version` | Show the version |

**`DIRECTORY`** is the folder to review.

- In the terminal interface, if you leave it out you'll be asked for one
  (press Enter on an empty line to quit).
- In the browser interface, if you leave it out it starts in the current
  folder, and you can switch folders from the page.

Options can be combined, for example:

```sh
ruby bin/file_organizer --gui --mode photo --dry-run ~/Pictures/Import
```

---

## 4. Choosing a mode: general, photo, audio

The mode decides which files you see and how much detail is shown.

### `general` (default)

Every file in the folder, whatever its type, with the standard file
information:

- name and location
- **type**, detected from the file's content
- extension, with a **warning if it doesn't match the content** (for
  example, a PNG image named `photo.jpg`, or a program disguised as a
  document)
- size, permissions, owner and group
- created, modified, and accessed times
- whether it is hidden, executable, or a symbolic link

### `photo`

Only image files (recognised by content, so a misnamed image still counts),
plus photo details:

- dimensions, megapixels, color format
- camera make and model, date taken
- exposure, aperture, ISO, focal length, orientation
- GPS location, when the photo has one

Supported: JPEG, PNG, GIF, BMP, TIFF, WebP, SVG; HEIC is recognised but its
details are not read.

### `audio`

Only audio files, plus audio details:

- codec, duration, bitrate, sample rate, channels, bit depth
- tags: title, artist, album, year, genre, track number, and whether there
  is embedded cover art

Supported: MP3, WAV, FLAC, Ogg Vorbis, Opus, M4A, and AIFF.

> In the browser interface the mode only picks the category filter the page
> starts on (Images for `photo`, Audio for `audio`); you can switch to any
> other category from the page. Photo and audio details are shown for every
> image and audio file, whatever the mode.

---

## 5. Using the terminal interface

```sh
ruby bin/file_organizer [--mode MODE] [DIRECTORY]
```

File Organizer says how many files it found, then shows them one at a time:

```
2 file(s) to review in /home/you/Downloads — general mode.

── File 1 of 2 ─────────────────────────────────────────────────────────
  Name:                  notes.txt
  Location:              /home/you/Downloads
  Type:                  Plain text (UTF-8)
  Extension:             .txt
  Size:                  12 bytes
  Permissions:           -rw-r--r-- (644)
  ...

  [o]pen  [v]iew  [r]ename  [c]opy  [m]ove  [d]elete  [h]ash  [n]ext  [q]uit
  Choice [n]:
```

Type a letter (or the whole word) and press Enter:

| Key | Action | What happens |
| --- | --- | --- |
| `o` | **Open** | Opens the file in your system's default app for its type |
| `v` | **View** | Shows the first 40 lines of a text file right in the terminal |
| `r` | **Rename** | Asks for a new name (same folder), then asks you to confirm |
| `c` | **Copy** | Asks for a destination folder, then asks you to confirm |
| `m` | **Move** | Asks for a destination folder, then asks you to confirm; moves on to the next file afterwards |
| `d` | **Delete** | Asks you to type `yes`; moves on to the next file afterwards |
| `h` | **Hash** | Shows the file's SHA-256 checksum (handy for spotting duplicates or verifying downloads) |
| `n` or Enter | **Next** | Leaves this file as it is and shows the next one |
| `q` | **Quit** | Stops the session (Ctrl-C and Ctrl-D also stop) |

Things to know:

- **Only the actions that make sense are offered.** View appears only for
  text files; copy, move, and hash only for regular files; open never
  appears for programs or launcher files.
- **Keys must match exactly.** `d` or `delete` deletes, but something like
  `done` is rejected as "Unrecognized option" instead of being taken as `d`.
  A typo can't trigger the wrong action.
- **Destination folders** can be typed as `~/Documents/Taxes`, a relative
  path, or an absolute path. The folder must already exist.
- **Pressing Enter on an empty prompt cancels** a rename, copy, or move.
- **Subfolders are skipped.** Only the files directly inside the folder are
  reviewed; nothing in subfolders is touched.

When you reach the end, it prints `All files reviewed.`

---

## 6. Using the browser interface

```sh
ruby bin/file_organizer --gui [--mode MODE] [DIRECTORY]
```

The terminal prints a short banner and your browser opens:

```
── File Organizer 1.0.0 — graphical interface ──────────────────────────
  Folder:                /home/you/Downloads
  Address:               http://127.0.0.1:53017/?t=…

  The address carries a one-time key for this session: it works only
  from this machine, and only until the program stops.
  Press Ctrl-C here, or use Quit in the page, to stop.
```

If the browser doesn't open (or you used `--no-browser`), copy the
**Address** line into your browser yourself. Keep the terminal window open
while you work — closing it stops the program.

### The page

- **Folder path** (top) — shown as clickable breadcrumbs; click any part to
  jump to that folder.
- **Open folder…** — type a path to switch folders. The parent folder and
  any subfolders are offered as one-click choices.
- **File list** — every file with an icon, its detected type, and size.
  - **Filter by name** — type in the search box (or press `/`).
  - **Category chips** — show only Images, Audio, Video, Documents,
    Archives, Executables, Text, Data, Links, and so on.
  - **Sort** — by name, size, modification time, or type.
- **Detail / Gallery view** — the gallery shows thumbnails of the whole
  folder, which is the quickest way to sort through photos (press `g` to
  switch).
- **Preview** — images are shown (click to zoom), audio and video get a
  player, and text files get a numbered preview. Other files show why they
  can't be previewed. (SVG and PDF files are deliberately not previewed in
  the page; use **Open** instead.)
- **Details** — the same information as the terminal, plus photo or audio
  details, and a SHA-256 checksum on request.
- **Actions** — Open, Rename, Copy, Move, and Delete buttons for the selected
  file. Each opens a dialog with the same confirmations as the terminal.
- **Reload**, **theme** (light/dark), **keyboard help**, and **Quit**
  buttons sit in the top bar.

### Keyboard shortcuts

Press `?` on the page at any time to see these.

| Key | Action |
| --- | --- |
| `↑` / `↓` or `k` / `j` | Previous / next file |
| `o` | Open with the default application |
| `r` | Rename |
| `c` | Copy to another folder |
| `m` | Move to another folder |
| `d` | Delete (needs a typed confirmation) |
| `h` | SHA-256 checksum |
| `g` | Switch between detail and gallery view |
| `/` | Filter by name |
| `R` (Shift-R) | Reload the folder |
| `T` | Switch light / dark theme |
| `Esc` | Close a dialog, or clear the filter |

### Limits

- The page lists at most **5,000 files** per folder. In a larger folder it
  tells you so, and which 5,000 you see depends on the order the system
  returns them. Use the terminal interface to review every file in a very
  large folder.
- Images are sent to the browser at full size (there are no generated
  thumbnails), so a gallery of very large photos takes a moment to fill.

### Stopping

Click **Quit** in the page, or press Ctrl-C in the terminal. The address
stops working as soon as the program stops; next time you'll get a new one.

---

## 7. Confirmations and safety features

File Organizer is designed so that you cannot change a file by accident.
These rules apply in both interfaces.

| Action | What you must do to confirm |
| --- | --- |
| Rename, copy, move | Answer `y`. The default is **No** — Enter, any other answer, or closing the input all cancel. |
| Delete | Type the whole word **`yes`**. Anything else cancels. |
| Overwrite an existing file at the destination | Type **`yes`**, after being told which file would be replaced. |
| Open a file whose extension doesn't match its content | Type **`yes`** (your system picks the app from the extension, so a disguised file could open in the wrong program). |
| Review your home folder or a system folder (`/`, `/etc`, `/usr`, `/System`, …) | Type **`yes`**. Not needed with `--read-only`. |

Other protections, always on:

- **Deletes are permanent.** Deleted files do *not* go to the Trash or
  Recycle Bin. If you're unsure, move the file to a "to delete" folder
  instead.
- **No silent overwrites.** A rename never replaces another file; if the new
  name is taken, the rename is refused. Copying or moving onto an existing
  file needs a typed `yes`, and is refused outright if the name belongs to a
  folder or a symbolic link.
- **Programs are never opened.** Open is disabled for executable files and
  for launcher types (`.exe`, `.lnk`, `.desktop`, `.vbs`, …).
- **Symbolic links are never followed.** They are clearly labelled, and
  deleting one removes only the link, not the file it points to.
- **New names must be plain names** — no `/`, `\`, or `..` — so a rename
  can't send a file somewhere else.
- **Odd characters in file names are made visible.** Hidden control
  characters, and tricks like right-to-left overrides that make
  `invoice‮gnp.exe` display as `invoice.png`, are shown as visible escapes.
- **The browser interface is private.** It only listens on your own
  computer (`127.0.0.1`) and only answers requests carrying the one-time key
  from that session.

---

## 8. Practice safely: read-only and dry-run

Two options let you explore without risk.

**`--read-only`** — inspect only. Rename, copy, move, delete, *and* open are
all switched off (opening is included because another program could change
the file). You can still browse, preview, and compute checksums.

```sh
ruby bin/file_organizer --read-only ~/Downloads
```

**`--dry-run`** — a rehearsal. You get the same prompts and confirmations as
a real session, but each action just reports what it *would* have done:

```
[dry run] would hand the file to the system default application.
```

```sh
ruby bin/file_organizer --dry-run --gui ~/Downloads
```

If you give both options, `--read-only` wins.

---

## 9. Common tasks

**Sort a camera import into folders**

```sh
ruby bin/file_organizer --gui --mode photo ~/Pictures/Import
```

Press `g` for the gallery, pick a photo, press `m`, and type the destination
folder (e.g. `~/Pictures/2026/Holiday`). Create the destination folders
beforehand — File Organizer doesn't create folders.

**Clean up Downloads**

```sh
ruby bin/file_organizer ~/Downloads
```

Step through with Enter, press `d` (then type `yes`) for anything you no
longer need, and `m` for anything worth keeping. Watch for the extension
**Warning** line — a file whose name doesn't match its content deserves a
second look before you open it.

**Fix up music tags before renaming**

```sh
ruby bin/file_organizer --mode audio ~/Music/Unsorted
```

Use the title/artist/track details shown for each file to choose a good
name, then press `r` to rename it.

**Find duplicate files**

Press `h` on two files you suspect are the same. Identical SHA-256
checksums mean identical content.

**Look at a folder you don't own or don't want to touch**

```sh
ruby bin/file_organizer --read-only --gui /some/shared/folder
```

---

## 10. Troubleshooting

| Problem | What to do |
| --- | --- |
| `ruby: command not found` | Ruby isn't installed or isn't on your `PATH`. See [Step 1](#step-1--install-ruby-30-or-newer). |
| Errors as soon as it starts | Check `ruby -v`; File Organizer needs Ruby 3.0 or newer. |
| `file_organizer: does not exist: …` / `not a directory: …` | Check the path. Quote paths containing spaces: `"~/My Files"` won't expand `~` inside quotes, so use `~/"My Files"` or the full path. |
| "No files found" | The folder has no files directly inside it (subfolders aren't scanned), or none match the chosen `--mode`. |
| Asked to type `yes` before starting | You pointed it at your home folder or a system folder. Type `yes` if that's really what you want, or pick a more specific folder, or add `--read-only`. |
| "Could not open the file (no system opener available)" | On Linux, install `xdg-utils`. Or use View (`v`) for text files, or the browser interface's preview. |
| Open isn't offered for a file | It's a program or launcher file, which File Organizer never opens, or you're in `--read-only` mode. |
| The browser didn't open | Copy the **Address** line from the terminal into your browser, including the `?t=…` part. |
| The page says "Not authorized" | The address is from an earlier run (each run gets a new key), or the `?t=…` part is missing. Use the address the terminal printed this time. |
| `could not listen on port …` | Another program is using that port. Leave out `--port` to let the system pick a free one. |
| Gallery is slow | It's showing full-size images. Use the detail view, or filter to fewer files. |
| Only 5,000 files shown in the browser | That's the page's limit. Use the terminal interface for the full folder. |

---

## 11. Updating and uninstalling

**Update** — if you installed with git:

```sh
cd file_organizer
git pull
```

If you downloaded a ZIP, download a fresh one and replace the folder.

**Uninstall** — delete the `file_organizer` folder. If you created a
link in Step 4, remove that too:

```sh
rm ~/.local/bin/file_organizer
```

File Organizer keeps no settings or data anywhere else (the browser
interface's light/dark choice is remembered by your browser only).
