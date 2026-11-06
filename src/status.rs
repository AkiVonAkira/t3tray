use serde_json::Value;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StatusFormat {
    Human,
    Json,
}

pub const STATUS_USAGE: &str = "usage: t3tray status [--json]";

pub fn parse_status_args(args: &[String]) -> Result<StatusFormat, String> {
    match args {
        [] => Ok(StatusFormat::Human),
        [flag] if flag == "--json" => Ok(StatusFormat::Json),
        _ => Err(STATUS_USAGE.to_owned()),
    }
}

/// Host a local client should use: wildcard listen addresses are not connectable.
pub fn local_host(listen: &str) -> String {
    match listen.trim_matches(['[', ']']) {
        "" | "0.0.0.0" | "::" | "*" => "127.0.0.1".to_owned(),
        host if host.contains(':') => format!("[{host}]"),
        host => host.to_owned(),
    }
}

pub fn local_url(listen: &str, port: u16) -> String {
    format!("http://{}:{port}/", local_host(listen))
}

pub fn not_running_json() -> String {
    serde_json::json!({ "status": "not running" }).to_string()
}

fn text(state: &Value, key: &str) -> Option<String> {
    match state.get(key)? {
        Value::Null => None,
        Value::String(s) if s.is_empty() => None,
        Value::String(s) => Some(s.clone()),
        other => Some(other.to_string()),
    }
}

fn update_text(update: &Value) -> Option<String> {
    let status = update.get("status").and_then(Value::as_str)?;
    let field = |key| update.get(key).and_then(Value::as_str);
    Some(match (field("targetVersion"), field("fromVersion")) {
        (Some(to), Some(from)) => format!("{status} {to} (from {from})"),
        (Some(to), None) => format!("{status} {to}"),
        _ => status.to_owned(),
    })
}

/// Human-readable lines for `t3tray status`. Missing optional fields are left out.
pub fn format_status(state: &Value) -> String {
    let status = text(state, "status").unwrap_or_else(|| "unknown".into());
    let port = state
        .get("port")
        .and_then(Value::as_u64)
        .and_then(|p| u16::try_from(p).ok());
    let host = text(state, "host").unwrap_or_else(|| "127.0.0.1".into());
    let mut rows: Vec<(&str, String)> = vec![("Status", status)];
    if let Some(channel) = text(state, "channel") {
        rows.push(("Channel", channel));
    }
    rows.push((
        "Server",
        text(state, "version").unwrap_or_else(|| "not installed yet".into()),
    ));
    if let Some(port) = port {
        rows.push(("Local URL", local_url(&host, port)));
        rows.push(("Listen", format!("{host}:{port}")));
    }
    if let Some(update) = state.get("serviceUpdate").and_then(update_text) {
        rows.push(("Update", update));
    }
    let pids: Vec<String> = [("tray", "trayPid"), ("server", "serverPid")]
        .iter()
        .filter_map(|(name, key)| text(state, key).map(|pid| format!("{name} {pid}")))
        .collect();
    if !pids.is_empty() {
        rows.push(("PIDs", pids.join(", ")));
    }
    if let Some(code) = text(state, "lastExit") {
        rows.push(("Last exit", code));
    }
    if let Some(message) = text(state, "message") {
        rows.push(("Message", message));
    }
    if let Some(logs) = text(state, "logs") {
        rows.push(("Logs", logs));
    }
    let width = rows.iter().map(|(label, _)| label.len()).max().unwrap_or(0);
    rows.iter()
        .map(|(label, value)| format!("{label:<width$}  {value}"))
        .collect::<Vec<_>>()
        .join("\n")
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn row<'a>(out: &'a str, label: &str) -> Option<&'a str> {
        out.lines()
            .find_map(|line| {
                line.strip_prefix(label)
                    .filter(|rest| rest.starts_with("  "))
            })
            .map(str::trim)
    }

    #[test]
    fn wildcard_listen_addresses_map_to_loopback() {
        assert_eq!(local_url("0.0.0.0", 3773), "http://127.0.0.1:3773/");
        assert_eq!(local_url("::", 80), "http://127.0.0.1:80/");
        assert_eq!(local_url("[::]", 80), "http://127.0.0.1:80/");
        assert_eq!(local_url("", 1), "http://127.0.0.1:1/");
        assert_eq!(local_url("192.168.1.5", 4000), "http://192.168.1.5:4000/");
        assert_eq!(local_url("localhost", 4000), "http://localhost:4000/");
        assert_eq!(local_url("::1", 4000), "http://[::1]:4000/");
    }

    #[test]
    fn missing_and_null_values_are_omitted_or_explained() {
        let out = format_status(&json!({
            "status": "waiting", "version": null, "serverPid": null, "trayPid": 7,
            "serviceUpdate": null, "lastExit": 78, "message": "the desktop app owns the T3 home"
        }));
        assert_eq!(row(&out, "Status"), Some("waiting"));
        assert_eq!(row(&out, "Server"), Some("not installed yet"));
        assert_eq!(row(&out, "PIDs"), Some("tray 7"));
        assert_eq!(row(&out, "Last exit"), Some("78"));
        assert_eq!(
            row(&out, "Message"),
            Some("the desktop app owns the T3 home")
        );
        assert_eq!(row(&out, "Local URL"), None);
        assert_eq!(row(&out, "Update"), None);
        assert_eq!(row(&format_status(&json!({})), "Status"), Some("unknown"));
    }
}
