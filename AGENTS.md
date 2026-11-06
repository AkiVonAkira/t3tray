# Working on t3tray

t3tray is an unofficial Windows tray host for the upstream T3 Code server. Read
[README.md](README.md) for the user setup and [docs/reference.md](docs/reference.md)
for flags, paths, and update behavior.

## Set up for a user

- Use Windows 10 or 11 x64 and PowerShell 5.1 or newer, as the intended Windows
  user. Only the optional Private-network firewall rule needs administrator approval.
- Inspect the current installation with `t3tray status --json`. Exit 3 means the
  tray is absent. Do not replace a running server during active agent work.
- Prefer the unattended installer with explicit `-Channel`, `-ListenHost`, and
  `-Port`. Start with `-DryRun -NonInteractive` to inspect the plan. A command in a
  redirected shell never opens the keyboard wizard.
- Use loopback unless the user needs another machine to connect. LAN binding is
  `0.0.0.0`; firewall access belongs on Private networks. Never print credentials.
- A normal install starts through the signed-in user's desktop session. For a
  CI runner without a desktop session, use `-NoStart`. Do not claim the server is
  running until `status --json` reports `running` and HTTP returns 200.
- After setup, point the user to `t3tray status`. In the T3 desktop app, turn off
  **Local environment** and pair it with this server. Actual pairing requires the
  user's app session; an HTTP check does not prove pairing.
- Uninstall preserves `.t3` data. `-Purge` removes `.t3tray`, including its logs.

## Change the code

- `install.ps1` and `uninstall.ps1` load helpers locally or through `irm | iex`.
  Keep both paths working. Release packaging stamps the source tag into them.
- `installer/ui.ps1` owns terminal input and rendering. Keep its wizard state
  machine and reuse its controls. Successful child processes must not interrupt
  the progress output. Keep useful diagnostics on failure.
- `src/main.rs` owns the Windows tray and CLI; `src/channel.rs` selects the initial
  server release. Existing launcher state owns the active server version.
- Bare `t3tray` prints help. Every tray launch, including the sign-in entry,
  the installer's start task, and smoke scripts, uses `t3tray run`. `t3tray update`
  runs the release installer while its own executable is running, so the installer
  renames that file before replacing it and must not stop its parent process.
- Human status is the default. Scripts use `status --json`. Update every consumer
  when changing that contract. Preserve exit 3 for an absent tray.
- Non-ASCII PowerShell files need a UTF-8 BOM for PowerShell 5.1. `scripts/check.ps1`
  checks this. Use the Windows GNU toolchain in `rust-toolchain.toml`, not MSVC.
- Do not launch the tray or run the install/uninstall smoke script on the user's
  active desktop. It changes startup registration and stops real processes. Use
  an isolated Windows runner for that check.

## Verify behavior

Run `cargo fmt --check`, `cargo test --locked --lib`, and
`cargo clippy --locked --target x86_64-pc-windows-gnu -- -D warnings`.
Run `powershell.exe -NoProfile -File scripts/check.ps1` with Pester 5.7.1 and
PSScriptAnalyzer 1.24.0 available. CI runs the stable real-server journey in
`scripts/smoke.ps1`; manual CI also checks nightly. The stable journey uses a
custom T3 home and updates the installed tray from local fixture releases with a
build that has the test-only `fixture-releases` feature. Release builds never
enable it. Tagged releases build twice
to prove reproducibility.

Prefer checks that exercise the real installer, CLI, HTTP, and saved state.
Before adding a test below those paths, write down the failure it catches.
Logic or protocol fixes need a test that fails without the fix. Visual changes
need before-and-after terminal captures. Do not add unit tests to raise coverage.
Keep security, external parsing, failure paths, and navigation tests unless a
stronger journey proves the same behavior.

`scripts/check-tests.ps1` rejects sleeps and mock-call assertions in Pester tests.
Await events or use scripted input; assert the result visible to the caller.
Copy-only and static-value tests still need human review. See
[test behavior, not implementation](https://github.com/AkiVonAkira/fleet/blob/main/vendor/p3-stack/skills/principle-test-behavior-not-implementation/SKILL.md).
