use crate::channel::Channel;
use crate::status::{parse_status_args, StatusFormat};

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Signal {
    Restart,
    Stop,
    Start,
    Quit,
}

impl Signal {
    pub const ALL: [Signal; 4] = [Self::Restart, Self::Stop, Self::Start, Self::Quit];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Restart => "restart",
            Self::Stop => "stop",
            Self::Start => "start",
            Self::Quit => "quit",
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RunOptions {
    pub host: String,
    pub port: u16,
    pub base_dir: Option<String>,
    pub channel: Channel,
}

impl Default for RunOptions {
    fn default() -> Self {
        Self {
            host: "127.0.0.1".into(),
            port: 3773,
            base_dir: None,
            channel: Channel::Stable,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Command {
    Help,
    Run(RunOptions),
    Status(StatusFormat),
    Signal(Signal),
    Update { version: Option<String> },
    IconPreview(String),
}

pub fn help() -> String {
    format!(
        "t3tray {}
Run the T3 Code server from the Windows tray.

Usage: t3tray <command> [options]

Commands:
  status [--json]            Show server status, address, and logs.
  start                      Start the server and wait for readiness.
  restart                    Restart the server and wait for readiness.
  stop                       Stop the server and keep the tray open.
  quit                       Close the tray and stop its server.
  update [--version vX.Y.Z]  Update t3tray and keep its settings.
  run [options]              Run the tray. Sign-in startup uses this.
  help                       Show this help.

Run options:
  --host <address>           Listen address. Default 127.0.0.1.
  --port <port>              Port from 1 to 65535. Default 3773.
  --channel stable|nightly   Initial server channel. Default stable.
  --base-dir <path>          Server's T3 home. Default %USERPROFILE%\\.t3.

stop, restart, quit, and update end active agent turns.
Update the server from T3 Code's Update machines dialog.",
        env!("CARGO_PKG_VERSION")
    )
}

pub fn parse(args: &[String]) -> Result<Command, String> {
    let Some((first, rest)) = args.split_first() else {
        return Ok(Command::Help);
    };
    match first.as_str() {
        "help" | "--help" | "-h" if rest.is_empty() => Ok(Command::Help),
        "run" => parse_run(rest).map(Command::Run),
        // Sign-in entries written by t3tray 0.1 launch the tray with flags only.
        flag if flag.starts_with("--") => parse_run(args).map(Command::Run),
        "status" => parse_status_args(rest).map(Command::Status),
        "update" => parse_update(rest),
        "icon-preview" => match rest {
            [dir] => Ok(Command::IconPreview(dir.clone())),
            _ => Err("usage: t3tray icon-preview <directory>".into()),
        },
        name => match Signal::ALL.into_iter().find(|s| s.as_str() == name) {
            Some(signal) if rest.is_empty() => Ok(Command::Signal(signal)),
            Some(signal) => Err(format!("{} takes no arguments", signal.as_str())),
            None => Err(format!("unknown command {name:?}")),
        },
    }
}

pub fn valid_host(host: &str) -> bool {
    !host.is_empty()
        && host
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b".:_-".contains(&c))
}

pub fn parse_run(args: &[String]) -> Result<RunOptions, String> {
    let mut options = RunOptions::default();
    let mut seen: Vec<&str> = Vec::new();
    let mut rest = args.iter();
    while let Some(flag) = rest.next() {
        let flag = flag.as_str();
        if !["--host", "--port", "--channel", "--base-dir"].contains(&flag) {
            return Err(format!("unknown run option {flag:?}"));
        }
        if seen.contains(&flag) {
            return Err(format!("{flag} is set twice"));
        }
        seen.push(flag);
        let value = rest
            .next()
            .filter(|v| !v.starts_with("--"))
            .ok_or_else(|| format!("{flag} requires a value"))?;
        match flag {
            "--host" if valid_host(value) => options.host = value.clone(),
            "--host" => return Err(format!("invalid host {value:?}")),
            "--port" => {
                options.port = value
                    .parse()
                    .ok()
                    .filter(|p| *p > 0)
                    .ok_or_else(|| format!("invalid port {value:?}; use 1 to 65535"))?
            }
            "--channel" => options.channel = value.parse()?,
            _ if value.is_empty() || value.contains('"') => {
                return Err(format!("invalid base directory {value:?}"))
            }
            _ => options.base_dir = Some(value.clone()),
        }
    }
    Ok(options)
}

pub fn valid_release(version: &str) -> bool {
    let core = version.strip_prefix('v').unwrap_or(version);
    core.starts_with(|c: char| c.is_ascii_digit())
        && core
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b".+-".contains(&c))
}

// Installers before v0.2.0 cannot replace the executable that runs t3tray update.
fn self_updating(version: &str) -> bool {
    let mut parts = version.split(['.', '-', '+']).map(str::parse::<u64>);
    matches!((parts.next(), parts.next()), (Some(Ok(major)), Some(Ok(minor))) if (major, minor) >= (0, 2))
}

fn parse_update(args: &[String]) -> Result<Command, String> {
    match args {
        [] => Ok(Command::Update { version: None }),
        [flag, version] if flag == "--version" && valid_release(version) => {
            let version = version.trim_start_matches('v');
            if !self_updating(version) {
                return Err(format!(
                    "t3tray update installs v0.2.0 or newer; run the v{version} installer instead"
                ));
            }
            Ok(Command::Update {
                version: Some(format!("v{version}")),
            })
        }
        _ => Err("usage: t3tray update [--version vX.Y.Z]".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(values: &[&str]) -> Vec<String> {
        values.iter().map(|v| v.to_string()).collect()
    }

    fn parse_ok(values: &[&str]) -> Command {
        parse(&args(values)).unwrap_or_else(|e| panic!("{values:?}: {e}"))
    }

    #[test]
    fn bare_and_help_print_help_instead_of_running_the_tray() {
        for values in [&[][..], &["help"], &["--help"], &["-h"]] {
            assert_eq!(parse_ok(values), Command::Help);
        }
        assert!(help().contains("update [--version vX.Y.Z]"));
        assert!(help().contains("run [options]"));
    }

    #[test]
    fn run_and_legacy_sign_in_flags_launch_the_same_tray() {
        let expected = Command::Run(RunOptions {
            host: "0.0.0.0".into(),
            port: 4000,
            base_dir: Some(r"D:\T3 Home".into()),
            channel: Channel::Nightly,
        });
        let flags = [
            "--host",
            "0.0.0.0",
            "--port",
            "4000",
            "--channel",
            "nightly",
            "--base-dir",
            r"D:\T3 Home",
        ];
        assert_eq!(parse_ok(&flags), expected);
        assert_eq!(parse_ok(&[&["run"][..], &flags].concat()), expected);
        assert_eq!(parse_ok(&["run"]), Command::Run(RunOptions::default()));
    }

    #[test]
    fn invalid_run_options_are_rejected_instead_of_defaulted() {
        for values in [
            &["run", "--port", "0"][..],
            &["run", "--port", "70000"],
            &["run", "--port"],
            &["run", "--host", "a b"],
            &["run", "--channel", "preview"],
            &["run", "--channel", "--host"],
            &["run", "--base-dir", ""],
            &["run", "--port", "1", "--port", "2"],
            &["run", "--colour", "blue"],
            &["--json"],
        ] {
            assert!(parse(&args(values)).is_err(), "{values:?} was accepted");
        }
    }

    #[test]
    fn commands_reject_unknown_names_and_extra_arguments() {
        assert_eq!(
            parse_ok(&["status", "--json"]),
            Command::Status(StatusFormat::Json)
        );
        assert_eq!(parse_ok(&["restart"]), Command::Signal(Signal::Restart));
        assert_eq!(parse_ok(&["quit"]), Command::Signal(Signal::Quit));
        for values in [
            &["frobnicate"][..],
            &["stop", "now"],
            &["help", "update"],
            &["status", "--jsn"],
            &["update", "--version"],
            &["update", "--version", "latest"],
            &["update", "--version", "v0.2.0", "extra"],
            &["update", "--version", "v0.1.1"],
        ] {
            assert!(parse(&args(values)).is_err(), "{values:?} was accepted");
        }
    }

    #[test]
    fn update_accepts_versions_with_or_without_v() {
        assert_eq!(parse_ok(&["update"]), Command::Update { version: None });
        assert_eq!(
            parse_ok(&["update", "--version", "1.0.0-rc.1"]),
            Command::Update {
                version: Some("v1.0.0-rc.1".into())
            }
        );
        for value in ["0.2.0", "v0.2.0"] {
            assert_eq!(
                parse_ok(&["update", "--version", value]),
                Command::Update {
                    version: Some("v0.2.0".into())
                }
            );
        }
    }
}
