# Changelog

## Unreleased

- Default initial server seeding to stable. Add `--channel stable|nightly`, installer `-Channel`, and `T3TRAY_CHANNEL`.
- Prefer an installed desktop version only when it matches the selected channel. Log ignored versions.
- Skip preview and Android releases, require the matching Windows x64 server zip, and follow release pagination.
- Keep an existing launcher `activeVersion` regardless of channel. Server updates stay in T3 Code's Update machines dialog.
- Show the selected seed channel in status JSON, the tooltip, and the menu header.
- Test release filtering and run the real Windows install and server smoke checks on stable and nightly.

## v0.1.0

- Run upstream T3 Code's service launcher in a Windows tray with sign-in startup.
- Keep server updates in T3 Code's Update machines dialog.
- Install a checked release executable without Rust, including from SSH.
- Provide status, restart, stop, start, and quit commands.
- Remove the manual launcher-runtime check command and menu item. Keep automatic seeding.
- Add reproducible GNU-target builds, Windows smoke checks, and tagged releases.
- Preserve the original crate history.

Windows handoff hard-kills the old server. Children of an old server can linger until the tray restarts. Rollback is untested. Build provenance is skipped while the repository is private because GitHub requires Enterprise Cloud for private attestations.
