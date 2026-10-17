# Security guidance for this repository

<!-- Read by the security-guidance plugin's model-backed reviews. Combined cap
     across all locations is 8 KB. Keep it to rules specific to THIS repo — the
     plugin already carries a general vulnerability checklist. -->

## Data handling
- Never log request bodies, `email`, `password`, `token`, or any `*_secret` field at any
  level.
- The sensitive data here is the user's own files and their metadata (EXIF GPS
  coordinates, camera/device identifiers, audio tags) and the GUI's one-time session
  key. Never log file contents, EXIF/ID3 field values, or the session key; see
  README.md's "Security design" section for the full handling rules.

## Authorization
- There are no user accounts or roles — the GUI's only authorization boundary is the
  one-time key plus the Host/Origin checks described in README.md. Every GUI route that
  reads or mutates a file must require that key, bind to the loopback address, and
  resolve file ids only within the active session's folder (see
  `lib/file_organizer/gui/session.rb` and `gui/app.rb`).

## Cryptography
- Token and signature comparison uses a constant-time function, never `===` or `==`.
- No homemade crypto. Use the platform library.

## Dependencies
- A new runtime dependency is a finding unless the diff includes a justification comment.
- Any package with a postinstall script is a finding.
