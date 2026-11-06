use serde_json::Value;

use crate::cli::{parse_run, RunOptions};

/// Settings the installer must keep when t3tray updates itself.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Installed {
    pub run: RunOptions,
    pub start_at_sign_in: bool,
}

/// Splits a Windows command line the way t3tray's sign-in entry is written:
/// whitespace separates arguments, and double quotes group a path with spaces.
pub fn split_command_line(line: &str) -> Vec<String> {
    let mut parts = Vec::new();
    let mut current = String::new();
    let mut quoted = false;
    let mut started = false;
    for c in line.chars() {
        match c {
            '"' => {
                quoted = !quoted;
                started = true;
            }
            c if c.is_whitespace() && !quoted => {
                if started {
                    parts.push(std::mem::take(&mut current));
                    started = false;
                }
            }
            c => {
                current.push(c);
                started = true;
            }
        }
    }
    if started {
        parts.push(current);
    }
    parts
}

/// The sign-in entry is the saved configuration. Without one, startup is off and
/// the running tray's state holds the settings.
pub fn installed_settings(
    run_value: Option<&str>,
    state: Option<&Value>,
) -> Result<Installed, String> {
    if let Some(line) = run_value {
        let parts = split_command_line(line);
        let flags = match parts.get(1).map(String::as_str) {
            Some("run") => &parts[2..],
            _ => parts.get(1..).unwrap_or_default(),
        };
        let run = parse_run(flags)
            .map_err(|e| format!("the T3Tray sign-in entry is not a t3tray launch ({e})"))?;
        return Ok(Installed {
            run,
            start_at_sign_in: true,
        });
    }
    let mut flags = Vec::new();
    if let Some(state) = state {
        for (flag, key) in [
            ("--host", "host"),
            ("--port", "port"),
            ("--channel", "channel"),
            ("--base-dir", "baseDir"),
        ] {
            match &state[key] {
                Value::String(s) => flags.extend([flag.to_owned(), s.clone()]),
                Value::Number(n) => flags.extend([flag.to_owned(), n.to_string()]),
                _ => {}
            }
        }
    }
    let run = parse_run(&flags).map_err(|e| format!("the running tray state is invalid ({e})"))?;
    Ok(Installed {
        run,
        start_at_sign_in: false,
    })
}

/// Arguments for install.ps1 that reproduce the installed configuration.
pub fn installer_args(installed: &Installed, tray_running: bool) -> Vec<String> {
    let run = &installed.run;
    let mut args: Vec<String> = [
        "-NonInteractive",
        "-Channel",
        run.channel.as_str(),
        "-ListenHost",
        &run.host,
        "-Port",
        &run.port.to_string(),
    ]
    .map(str::to_owned)
    .into();
    if let Some(dir) = &run.base_dir {
        args.extend(["-BaseDir".to_owned(), dir.clone()]);
    }
    if !installed.start_at_sign_in {
        args.push("-NoStartAtSignIn".to_owned());
    }
    if !tray_running {
        args.push("-NoStart".to_owned());
    }
    args
}

pub const RELEASES: &str = "https://github.com/AkiVonAkira/t3tray/releases";

/// GitHub answers releases/latest with a redirect to releases/tag/<tag>.
pub fn release_tag(location: &str) -> Option<&str> {
    let (_, rest) = location.split_once("/releases/tag/")?;
    rest.split(['/', '?', '#'])
        .next()
        .filter(|tag| crate::cli::valid_release(tag))
}

pub fn checksum<'a>(sums: &'a str, file: &str) -> Option<&'a str> {
    sums.lines().find_map(|line| {
        let (hash, name) = line.split_once(char::is_whitespace)?;
        (name.trim().trim_start_matches('*') == file
            && hash.len() == 64
            && hash.bytes().all(|c| c.is_ascii_hexdigit()))
        .then_some(hash)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::channel::Channel;
    use serde_json::json;

    const EXE: &str = r#""C:\Users\Example\.t3tray\t3tray.exe""#;

    #[test]
    fn sign_in_entry_settings_survive_the_update() {
        let line = format!(
            r#"{EXE} run --host 0.0.0.0 --port 4000 --channel nightly --base-dir "D:\T3 Home""#
        );
        let installed = installed_settings(Some(&line), Some(&json!({"port": 1}))).unwrap();
        assert_eq!(
            installer_args(&installed, true),
            [
                "-NonInteractive",
                "-Channel",
                "nightly",
                "-ListenHost",
                "0.0.0.0",
                "-Port",
                "4000",
                "-BaseDir",
                r"D:\T3 Home"
            ]
        );
    }

    #[test]
    fn version_0_1_sign_in_entry_without_run_is_read() {
        let line = format!("{EXE} --host 127.0.0.1 --port 3999 --channel stable");
        let installed = installed_settings(Some(&line), None).unwrap();
        assert_eq!(installed.run.port, 3999);
        assert_eq!(installed.run.channel, Channel::Stable);
        assert!(installed.start_at_sign_in);
    }

    #[test]
    fn disabled_startup_and_stopped_tray_stay_that_way() {
        let state = json!({"host": "0.0.0.0", "port": 4100, "channel": "nightly", "baseDir": null});
        let installed = installed_settings(None, Some(&state)).unwrap();
        let args = installer_args(&installed, false);
        assert!(args.contains(&"-NoStartAtSignIn".to_owned()));
        assert!(args.contains(&"-NoStart".to_owned()));
        assert!(args.windows(2).any(|w| w == ["-Port", "4100"]));
        assert!(args.windows(2).any(|w| w == ["-Channel", "nightly"]));
        assert!(!args.contains(&"-BaseDir".to_owned()));
        let defaults = installer_args(&installed_settings(None, None).unwrap(), false);
        assert!(defaults.windows(2).any(|w| w == ["-Port", "3773"]));
    }

    #[test]
    fn a_foreign_sign_in_entry_stops_the_update() {
        let line = format!("{EXE} --port 4000 --unknown");
        assert!(installed_settings(Some(&line), None).is_err());
    }

    #[test]
    fn release_tag_and_checksum_come_from_the_downloaded_release() {
        assert_eq!(
            release_tag("https://github.com/AkiVonAkira/t3tray/releases/tag/v0.2.0"),
            Some("v0.2.0")
        );
        assert_eq!(release_tag("https://example.com/install.ps1"), None);
        assert_eq!(
            release_tag("https://github.com/o/r/releases/tag/..%2F"),
            None
        );
        let hash = "a".repeat(64);
        let sums = format!("{}  t3tray.exe\n{hash} *install.ps1\n", "b".repeat(64));
        assert_eq!(checksum(&sums, "install.ps1"), Some(hash.as_str()));
        assert_eq!(checksum(&sums, "uninstall.ps1"), None);
    }
}
