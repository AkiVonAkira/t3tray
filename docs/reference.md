# Installer and runtime reference

## Installer options

Download the installer to pass parameters, or invoke its text as a scriptblock:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AkiVonAkira/t3tray/main/install.ps1))) -Channel nightly -ListenHost 127.0.0.1 -Port 3773
```

| Parameter | Default | Effect |
| --- | --- | --- |
| `-Version` | Latest t3tray release | Selects a release such as `v0.1.0`. |
| `-Channel` | `stable` | Selects the initial upstream server channel, `stable` or `nightly`. |
| `-ListenHost` | `127.0.0.1` | Selects the listen address. `0.0.0.0` listens on every interface. |
| `-Port` | `3773` | Selects a TCP port from 1 to 65535. |
| `-ExePath` | Download | Uses a local executable with `SHA256SUMS` beside it. |
| `-AssetDir` | Download | Uses `t3tray.exe` and `SHA256SUMS` in a local directory. Cannot be combined with `-ExePath`. |
| `-BaseDir` | `%USERPROFILE%\.t3` | Selects the server's T3 home. Use a folder, not a drive root. |
| `-NoStart` | Off | Installs and configures startup without starting the tray now. |
| `-NoStartAtSignIn` | Off | Removes the sign-in entry instead of setting it. |
| `-NonInteractive` | Off | Skips the keyboard wizard. |
| `-DryRun` | Off | Shows the plan without installing or verifying a running server. |

The pipe form accepts `T3TRAY_VERSION`, `T3TRAY_CHANNEL`, `T3TRAY_HOST`, and
`T3TRAY_PORT`. Parameters override those variables. `T3TRAY_REF` selects the
branch or tag used to fetch installer helpers; releases pin their own tag.

The wizard opens only with no configuration arguments or variables in an
interactive console. `-DryRun` alone preserves the wizard. Explicit configuration,
redirected input/output, or `CI` selects unattended mode.

Interactive installs offer a firewall rule for the chosen TCP port on Private
networks when binding to `0.0.0.0`. That step requests UAC; other steps run as the
current user. Unattended installs leave firewall configuration to the caller.

The installer starts the tray with a temporary interactive scheduled task. This
also works over SSH when the user already has a signed-in desktop session. It
waits up to ten minutes for server readiness. Interactive verification checks
the tray process, status, HTTP 200, and `server.getConfig` with
`serverSelfUpdate=boot-service`. The RPC check issues a one-minute local auth
session and revokes it afterward.

## CLI options and exit codes

| Command | Result |
| --- | --- |
| `t3tray` or `t3tray help` | Lists the commands and run options. Does not start the tray. |
| `t3tray status` | Readable status, connection address, and diagnostic paths. |
| `t3tray status --json` | Machine-readable tray state. |
| `t3tray start` | Starts the server and waits up to 60 seconds for readiness. |
| `t3tray restart` | Restarts the server and waits up to 60 seconds for readiness. |
| `t3tray stop` | Stops the server and leaves the tray open. |
| `t3tray quit` | Closes the tray and its server tree. |
| `t3tray update [--version vX.Y.Z]` | Updates t3tray through the release installer and keeps its settings. |
| `t3tray run [options]` | Runs the tray. The sign-in entry uses this. |

An absent tray exits with code 3. Invalid command usage exits with code 2.
Wait for active agent turns to finish before stop, restart, quit, or update.

`run` takes `--host`, `--port`, `--base-dir`, and `--channel stable|nightly`.
It rejects unknown options and invalid values instead of using defaults.
`--base-dir` selects the server's T3 home; tray state and logs stay in `.t3tray`.
A command line that starts with one of these flags also runs the tray, so sign-in
entries written by v0.1 keep working.
`icon-preview <directory>` writes icon PNGs for maintainers.

## Files and startup

| Path | Contents |
| --- | --- |
| `%USERPROFILE%\.t3tray\t3tray.exe` | Tray executable. |
| `%USERPROFILE%\.t3\bin\t3tray.cmd` | Command wrapper. Add its directory to your user `PATH`. |
| `%USERPROFILE%\.t3tray\state.json` | Current tray and server state. |
| `%USERPROFILE%\.t3tray\logs\t3tray.log` | Tray diagnostics. |
| `%USERPROFILE%\.t3tray\logs\server.log` | Server output, rotated at 20 MiB on server start. |
| `%USERPROFILE%\.t3\runtime\service-state.json` | Upstream launcher's active runtime and update state. |
| `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\T3Tray` | Current user's sign-in startup command. |

The server and its children belong to a Windows Job Object. The tray retries an
unexpected exit after ten seconds, or after sixty seconds for exit 78 when
another process owns the T3 home. New server processes read user environment
variables from the registry.

## Server selection and updates

On first start, t3tray downloads the standalone Windows x64 server zip and checks
its SHA-256. Stable selects `vX.Y.Z` releases. Nightly selects
`vX.Y.Z-nightly.YYYYMMDD.N`. Preview and Android tags are skipped.

A matching desktop channel prefers that desktop version. A different desktop
channel does not affect the seed. Once `.t3/runtime/service-state.json` has an
`activeVersion`, changing the channel keeps that version. The tray checks the
seed at startup and every ten minutes without selecting a newer version.

T3 Code's **Update machines** dialog owns server updates through upstream's
launcher, including update trials, database backups, rollback, and runtime
pruning. Updating the desktop app does not select a new server version.

`t3tray update` updates t3tray itself:

1. It reads the settings from the `T3Tray` sign-in entry. Without that entry it
   uses the running tray's state and keeps sign-in startup off.
2. It resolves the latest release, or the `--version` release, which must be
   v0.2.0 or newer. If the latest release is already installed, it stops.
3. It downloads `install.ps1`, `SHA256SUMS`, and `t3tray.exe` from that release
   and checks `install.ps1` against `SHA256SUMS`. The installer checks `t3tray.exe`.
4. It runs the installer unattended with the saved channel, address, port, T3 home,
   and sign-in setting. A stopped tray stays stopped.

The installer renames the running `t3tray.exe` to `t3tray.<id>.old` before copying
the new one, and removes old copies on the next install or uninstall. It does not
stop the `t3tray update` process that started it. The command exits with the
installer's exit code. Errors before the installer starts change nothing.

Re-running the installer also updates t3tray. `-Version` selects t3tray;
`-Channel` selects the initial upstream server. They are independent.

When t3tray is installed, the wizard's check screen offers two choices:

- **Update with current settings** goes straight to review. It keeps the
  channel, address, port, T3 home, and sign-in setting, and makes no firewall
  change. Go back returns to the check screen.
- **Change settings and reinstall** runs the usual steps with the saved settings
  suggested, and ends on **Reinstall**.

The wizard reads saved settings from the `T3Tray` sign-in entry. Without that
entry it reads `.t3tray\state.json` and keeps sign-in startup off. Unattended
runs use the parameters they are given; use `t3tray update` to keep saved
settings from a script.

## Build and release

Use Rust and MinGW-w64. `rust-toolchain.toml` pins Rust and the Windows GNU target.

```bash
cargo fmt --check
cargo test --locked --lib
cargo clippy --locked --target x86_64-pc-windows-gnu -- -D warnings
cargo build --locked --release --target x86_64-pc-windows-gnu
```

On an isolated Windows runner, `scripts/smoke.ps1` installs the binary from `dist`,
rejects corrupt assets, starts the real upstream server, checks status and HTTP,
exercises stop/start, preserves the active version across channel changes, and
uninstalls while retaining T3 data. It modifies startup registration and stops
processes. Do not run it on your working desktop.

Tagged `v*` releases require the tag to match `Cargo.toml`. The release workflow
builds the committed tree twice with `scripts/build-reproducible.sh`, compares
the executables, and publishes the binary, checksums, installer, and uninstaller.
Reproduction requires matching Rust, MinGW, and system tools. Public releases
include build provenance; private attestations require GitHub Enterprise Cloud.
