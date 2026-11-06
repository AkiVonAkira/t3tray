# t3tray

t3tray runs the T3 Code server in your Windows desktop session, with a tray icon and sign-in startup. It is unofficial and is not affiliated with T3 Code or Ping Labs.

Windows has no upstream `t3 service` command yet. t3tray runs upstream's `t3.exe __service-launcher` so the in-app updater and **Update machines** dialog can manage the Windows server as a `boot-service`. The standalone server stays outside the desktop app's install directory, so the desktop updater can replace that directory while the server runs.

## Install

Use Windows 10 or 11 on x64, Windows PowerShell 5.1 or newer, and an internet connection. Rust and administrator rights are not required. ARM64 is not tested. Turn off **Local environment** in the T3 desktop app before starting t3tray, then pair the desktop app with this server.

Run in PowerShell as the Windows user who will run T3:

```powershell
irm https://raw.githubusercontent.com/AkiVonAkira/t3tray/main/install.ps1 | iex
```

The installer downloads the latest t3tray release and verifies `t3tray.exe` against its release `SHA256SUMS`. It installs `%USERPROFILE%\.t3tray\t3tray.exe`, writes `%USERPROFILE%\.t3\bin\t3tray.cmd`, and sets the current user's `T3Tray` Run value. Add `%USERPROFILE%\.t3\bin` to your user `PATH`, or call the wrapper by its full path.

The tray starts through a one-shot interactive scheduled task, including when you install over SSH. You must already be signed in to the Windows desktop. The installer waits up to 10 minutes for the real server to answer HTTP 200.

For explicit parameters, invoke the downloaded text as a scriptblock:

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/AkiVonAkira/t3tray/main/install.ps1))) -Version v0.1.0 -ListenHost 127.0.0.1 -Port 3773
```

The pipe form also accepts `T3TRAY_VERSION`, `T3TRAY_HOST`, `T3TRAY_PORT`, and `T3TRAY_CHANNEL` environment variables. Parameters override them. Download and inspect the script before running it if you prefer.

| Parameter | Default | Effect |
| --- | --- | --- |
| `-Version` | Latest release | Selects a release such as `v0.1.0`. |
| `-ListenHost` | `127.0.0.1` | Sets the server's listen address. |
| `-Port` | `3773` | Sets the TCP port, from 1 to 65535. |
| `-Channel` | `stable` | Seeds the T3 server from `stable` or `nightly`. Saves `--channel` in the Run value. |
| `-ExePath` | Download | Uses a local executable with `SHA256SUMS` beside it. |
| `-AssetDir` | Download | Uses `t3tray.exe` and `SHA256SUMS` in a local directory. Mutually exclusive with `-ExePath`. |
| `-NoStart` | Off | Registers sign-in startup without starting now. Useful on CI runners without an interactive logon. |
| `-RetireWinT3Service` | Off | Stops the old user service, disables its `T3 Code Server (User Logon)` task, and removes `t3service.cmd`. Its data stays in place. |

While this repository is private, anonymous downloads and the one-liner cannot work. Download release assets with an authenticated GitHub client, then use `-AssetDir`. No token belongs in the installer or tray.

## Commands and menu

```powershell
t3tray status
t3tray restart
t3tray stop
t3tray start
t3tray quit
```

`status` prints JSON while the tray runs and exits with code 3 otherwise. `restart` and `start` wait up to 60 seconds for HTTP readiness. `stop` keeps the tray open. `quit` closes the tray and its server tree. Wait for agent turns to finish before stopping, restarting, quitting, or reinstalling.

Launch the executable without a command to open the tray. Its flags are `--host`, `--port`, `--base-dir`, and `--channel stable|nightly`. The channel defaults to `stable` and appears in status JSON, the tooltip, and the menu header. `--base-dir` selects the server's T3 home, while tray state and logs stay in `.t3tray`. The default T3 home is `%USERPROFILE%\.t3`.

The menu shows server status, **Restart server**, **Stop server** or **Start server**, **Open logs**, and **Quit**. The icon is green after HTTP readiness, amber while starting, waiting, or reporting a pending update, and red while stopped. `icon-preview <directory>` writes PNG previews for maintainers.

## Updates and logs

On first start, t3tray downloads the standalone Windows server zip from the selected upstream channel and checks its SHA-256. `stable` selects releases tagged `vX.Y.Z`, preferring upstream's latest release. `nightly` selects releases tagged `vX.Y.Z-nightly.YYYYMMDD.N`. Both require the matching `t3-<version>-win32-x64.zip` asset. Preview and `android-*` tags are skipped. Release lookup follows pagination when needed.

If the installed T3 desktop app has a version on the selected channel, t3tray prefers that exact version. It ignores a desktop version on another channel and logs why. An existing `.t3\runtime\service-state.json` always keeps its `activeVersion`, even if you change `--channel`. The channel selects only the initial runtime. The tray checks that seed at startup and every 10 minutes without selecting a newer version.

To seed nightly on a new installation, pass `-Channel nightly` to the installer or set the environment variable before the pipe form:

```powershell
$env:T3TRAY_CHANNEL = 'nightly'
irm https://raw.githubusercontent.com/AkiVonAkira/t3tray/main/install.ps1 | iex
```

`-Version` selects the t3tray executable release. `-Channel` selects the initial upstream T3 server release. They are independent.

Use T3 Code's **Update machines** dialog for server updates. Upstream's launcher owns the update trial, database backups, rollback, and runtime pruning. Updating the desktop app does not select a new server version. Re-run this installer to update t3tray itself. The desktop app uses its own updater; this repo does not provide a desktop updater script.

Tray state is `%USERPROFILE%\.t3tray\state.json`. Logs are `.t3tray\logs\t3tray.log` and `.t3tray\logs\server.log`. The server log rotates at 20 MiB when the server starts. A new server process reads user environment variables from the registry. The tray retries after an unexpected exit in 10 seconds, or in 60 seconds on exit 78 when another process owns the T3 home.

## Uninstall

Download `uninstall.ps1` from a release and run:

```powershell
& .\uninstall.ps1
```

This quits the tray, stops its server tree, and removes the Run value, wrapper, and executable. Logs stay in `.t3tray`. `-Purge` also removes `.t3tray`. Both forms keep `.t3`, including projects, sessions, runtimes, and credentials.

## Limits and security

- The tray runs after desktop sign-in and stops at sign-out. It does not run before sign-in after a reboot.
- The server and its children belong to a Windows Job Object. Quitting or restarting the tray can terminate active agent work.
- Windows handoff hard-kills the old server because Windows has no graceful SIGTERM. Children of an old server can linger until the tray restarts. Rollback is untested.
- The executable is unsigned. Windows SmartScreen may warn about it.
- `--host 0.0.0.0` exposes the server on every network interface. Restrict access with a Windows firewall rule and T3 authentication. The installer does not create a firewall rule.
- Release checksums detect corruption. They do not protect against a compromised release account. See [SECURITY.md](SECURITY.md).

## Build and verify

Install Rust with rustup and MinGW-w64. The exact stable toolchain and Windows GNU target are in `rust-toolchain.toml`. On Ubuntu:

```bash
sudo apt-get install mingw-w64
cargo fmt --check
cargo test --locked --lib
cargo clippy --locked --target x86_64-pc-windows-gnu -- -D warnings
bash scripts/build-reproducible.sh
```

Commit your changes before running the build script. It builds the committed tree twice in separate clean directories, sets `SOURCE_DATE_EPOCH` to the commit timestamp, remaps build paths, disables the PE timestamp, and fails unless both executables are byte-identical. Outputs and checksums go in `dist/`. Reproducing a release requires the same Rust, MinGW, and system tool versions used by its workflow. Runner image updates can change the output.

CI checks formatting, Clippy, reproducibility, and PowerShell scripts. Windows jobs for stable and nightly install the artifact, download the real upstream server, check status and HTTP 200, exercise stop/start, and check that uninstall removes every tray and T3 process while preserving T3 data. Each job also changes the channel and checks that the existing active version stays unchanged. Each starts the executable directly after installing with `-NoStart` because hosted runners lack an interactive desktop logon.

Tags matching `v*` run the release workflow. The tag must match `Cargo.toml`. The workflow publishes the executable, checksums, installer, and uninstaller. It attests build provenance for public repositories. GitHub requires Enterprise Cloud for private-repository attestations, so that step is skipped while this repo is private.

The crate's Git history was extracted with `git subtree split` before adding standalone packaging.
