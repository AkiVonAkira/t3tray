# Changelog

## v0.1.0

- Run upstream T3 Code's service launcher in a Windows tray with sign-in startup.
- Keep server updates in T3 Code's Update machines dialog.
- Install a checked release executable without Rust, including from SSH.
- Provide status, restart, stop, start, and quit commands.
- Remove the manual launcher-runtime check command and menu item. Keep automatic seeding.
- Add reproducible GNU-target builds, Windows smoke checks, and tagged releases.
- Preserve the original crate history.

Windows handoff hard-kills the old server. Children of an old server can linger until the tray restarts. Rollback is untested. Build provenance is skipped while the repository is private because GitHub requires Enterprise Cloud for private attestations.
