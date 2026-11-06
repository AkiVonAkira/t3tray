use std::fmt;
use std::str::FromStr;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Channel {
    Stable,
    Nightly,
}

impl Channel {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Stable => "stable",
            Self::Nightly => "nightly",
        }
    }

    pub fn from_args(args: &[String]) -> Result<Self, String> {
        match args.iter().position(|arg| arg == "--channel") {
            None => Ok(Self::Stable),
            Some(index) => args
                .get(index + 1)
                .ok_or_else(|| "--channel requires stable or nightly".to_owned())?
                .parse(),
        }
    }

    pub fn of_version(version: &str) -> Option<Self> {
        let (core, nightly) = match version.split_once("-nightly.") {
            Some((core, suffix)) => (core, Some(suffix)),
            None => (version, None),
        };
        let numeric = |part: &str| !part.is_empty() && part.bytes().all(|c| c.is_ascii_digit());
        let parts: Vec<_> = core.split('.').collect();
        if parts.len() != 3 || !parts.iter().all(|part| numeric(part)) {
            return None;
        }
        match nightly {
            None => Some(Self::Stable),
            Some(suffix) => {
                let (date, build) = suffix.split_once('.')?;
                (date.len() == 8 && numeric(date) && numeric(build)).then_some(Self::Nightly)
            }
        }
    }

    pub fn release_version(self, release: &serde_json::Value) -> Option<&str> {
        if release["draft"].as_bool() == Some(true)
            || (self == Self::Stable && release["prerelease"].as_bool() == Some(true))
        {
            return None;
        }
        let version = release["tag_name"].as_str()?.strip_prefix('v')?;
        if Self::of_version(version) != Some(self) {
            return None;
        }
        let name = format!("t3-{version}-win32-x64.zip");
        release["assets"]
            .as_array()?
            .iter()
            .any(|asset| asset["name"].as_str() == Some(&name))
            .then_some(version)
    }
}

impl FromStr for Channel {
    type Err = String;

    fn from_str(value: &str) -> Result<Self, Self::Err> {
        match value {
            "stable" => Ok(Self::Stable),
            "nightly" => Ok(Self::Nightly),
            _ => Err(format!(
                "invalid channel {value:?}; expected stable or nightly"
            )),
        }
    }
}

impl fmt::Display for Channel {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.as_str())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn cli_defaults_to_stable_and_rejects_invalid_channels() {
        let args = |values: &[&str]| values.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
        assert_eq!(Channel::from_args(&[]), Ok(Channel::Stable));
        assert_eq!(
            Channel::from_args(&args(&["--channel", "nightly"])),
            Ok(Channel::Nightly)
        );
        assert_eq!(
            Channel::from_args(&args(&["--channel", "stable"])),
            Ok(Channel::Stable)
        );
        for values in [
            vec!["--channel"],
            vec!["--channel", "preview"],
            vec!["--channel", "--host"],
        ] {
            assert!(Channel::from_args(&args(&values)).is_err());
        }
    }

    #[test]
    fn only_stable_and_dated_nightly_versions_have_channels() {
        assert_eq!(Channel::of_version("0.1.7"), Some(Channel::Stable));
        assert_eq!(
            Channel::of_version("0.1.8-nightly.20261106.4247"),
            Some(Channel::Nightly)
        );
        for version in [
            "0.1.8-preview.1",
            "android-0.1.8",
            "0.1.8-nightly",
            "0.1.8-nightly.202611.1",
            "0.1.8-nightly.20261106.1.extra",
            "../0.1.7",
            "0.1",
            "0.1.7+build",
        ] {
            assert_eq!(Channel::of_version(version), None, "{version}");
        }
    }

    #[test]
    fn mixed_releases_select_only_the_requested_channel_and_exact_asset() {
        let release = |version: &str, asset: &str| {
            json!({
                "tag_name": format!("v{version}"),
                "assets": [{"name": asset}],
            })
        };
        let releases = [
            release("0.1.9-preview.1", "t3-0.1.9-preview.1-win32-x64.zip"),
            json!({"tag_name": "android-1.0.0", "assets": [{"name": "t3-1.0.0-win32-x64.zip"}]}),
            release(
                "0.1.8-nightly.20261106.9",
                "t3-0.1.8-nightly.20261106.9-win32-arm64.zip",
            ),
            release(
                "0.1.8-nightly.20261106.8",
                "t3-0.1.8-nightly.20261106.8-win32-x64.zip",
            ),
            release("0.1.8", "unrelated-win32-x64.zip"),
            release("0.1.7", "t3-0.1.7-win32-x64.zip"),
        ];
        for (channel, expected) in [
            (Channel::Stable, "0.1.7"),
            (Channel::Nightly, "0.1.8-nightly.20261106.8"),
        ] {
            assert_eq!(
                releases.iter().find_map(|r| channel.release_version(r)),
                Some(expected)
            );
        }
        let mut draft = release("0.1.8", "t3-0.1.8-win32-x64.zip");
        draft["draft"] = json!(true);
        assert_eq!(Channel::Stable.release_version(&draft), None);
        draft["draft"] = json!(false);
        draft["prerelease"] = json!(true);
        assert_eq!(Channel::Stable.release_version(&draft), None);
    }
}
