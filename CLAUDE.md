# File Organizer

An interactive, offline Ruby tool for reviewing and organizing files in a
directory one at a time (terminal) or all at once (browser GUI): inspect
metadata, then open/preview, rename, copy, move, or delete. Zero gem
dependencies — everything, including EXIF/audio metadata parsing and the GUI's
HTTP server, is standard library only. It must never touch the network
(outbound) and must never silently modify or delete a file without the
confirmation rules in README.md's "Safeguards" and "Security design" sections.

## Commands

| Task | Command |
| --- | --- |
| Run (terminal) | `ruby bin/file_organizer [options] [DIRECTORY]` |
| Run (GUI) | `ruby bin/file_organizer --gui [options] [DIRECTORY]` |
| Test (all) | `ruby test/all.rb` |
| Test (single file) | `ruby test/test_operations.rb` |

Prefer running a single test file over the whole suite while iterating. No
gems to install, no build/lint/typecheck step — this is pure Ruby 3.0+
standard library.

## Architecture

- Both interfaces share one core: `Operations` performs every filesystem
  change, `Directory` lists folders, `FileInfo`/`TypeDetector` describe files,
  `Metadata::*` parses photo/audio metadata. The GUI (`lib/file_organizer/gui/`)
  adds a loopback HTTP server and a page on top of that core — it never
  reimplements a file operation.
- `safe_file.rb` is the only path allowed to touch file bytes: reads use
  `O_NOFOLLOW`, writes are `O_NOFOLLOW` opens or `rename(2)`. Symlinks are
  never followed, only inspected via `lstat`.
- GUI files are addressed by opaque id (decoded server-side to one file name
  inside the active folder), never by path, and an id is bound to the folder
  it was issued for.
- See README.md's "Safeguards against accidental changes" and "Security
  design" sections for the full list of invariants (no shell interpolation,
  path traversal protection, terminal escape sanitizing, confirmation rules,
  GUI one-time key / Host+Origin checks / CSP). Those invariants are the
  product, not incidental detail — any change touching `operations.rb`,
  `safe_file.rb`, `viewer.rb`, or anything under `gui/` must preserve them.

## Conventions

- `# frozen_string_literal: true` at the top of every file.
- One class/module per file under `lib/file_organizer/`, loaded explicitly
  from `lib/file_organizer.rb` (no autoloading).
- Tests use minitest from the standard library (`test/test_*.rb`, run via
  `test/all.rb`); no mocking framework beyond what minitest provides.

## Workflow

- Work in plan mode for anything touching more than two files.
- Every change ships with a test. Run the relevant tests before calling a task
  done, and show the output rather than asserting success.
- Conventional Commits (`feat:`, `fix:`, `chore:`, ...). Branches:
  `type/short-slug`.
- Never commit directly to `main`; open a PR.

## Guardrails

- IMPORTANT: never read, print, or copy the contents of `.env*`, `secrets/**`,
  or any private key. Read `.env.example` for variable *names* only.
- Do not add a dependency (gem) without asking first — this project's zero-gem
  policy is deliberate; justify any addition and check its transitive
  footprint.
- Do not edit `.github/workflows/**` or `.claude/**` without an explicit
  request.
- Never add network code. The program must stay fully offline.
- Any change to file read/write paths, symlink handling, confirmation
  prompts, or GUI auth/CSP/origin checks needs the corresponding README.md
  section updated to match.

## Gotchas

- `bin/file_organizer` is the only entry point — it requires
  `lib/file_organizer.rb`, which requires every submodule in dependency order;
  don't add a new file without adding its `require_relative` there.
