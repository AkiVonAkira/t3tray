# Changelog

## v0.2.1

- Offer **Update with current settings** when the installer wizard finds an existing install. It skips configuration and the firewall step and keeps the saved channel, address, port, T3 home, and sign-in setting. **Change settings and reinstall** keeps the full wizard. A first install is unchanged.
- Read saved settings from `.t3tray\state.json` when sign-in startup is off, so the wizard no longer falls back to defaults for that install.

## v0.2.0

- Add `t3tray update`. It downloads the release installer, checks it against `SHA256SUMS`, and reinstalls with the saved channel, address, port, T3 home, and sign-in setting. `--version` pins a release from v0.2.0 on.
- Print help for `t3tray`, `t3tray help`, and `--help` instead of starting the tray. Start the tray with `t3tray run`. Sign-in entries and the installer now write `run`; flag-only entries from v0.1 still start the tray.
- Reject unknown `run` options and invalid ports, hosts, and channels with exit code 2 instead of using defaults.
- Add installer `-BaseDir` and `-NoStartAtSignIn`. The installer renames a running `t3tray.exe` before replacing it.
- Remove the win-t3service retirement option, wizard step, and detection.
- Add `baseDir` to `status --json`.

Upgrade from v0.1.1 by re-running the installer once. v0.1.1 has no `update` command.

## v0.1.1

- Make `t3tray status` readable by default. Scripts must use `t3tray status --json`.
- Clarify installer text entry, group the review, and show one result per install step with completion instructions.
- Simplify setup documentation and combine routine CI checks. Keep reproducibility in tagged releases and run nightly smoke checks manually.

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
