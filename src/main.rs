// t3tray: run the T3 Code server on Windows from a tray icon.
//
// It runs the standalone server build from the selected release channel (t3-<ver>-win32-x64.zip),
// not the CLI inside the desktop app, so the desktop app's own updater can replace its
// install folder while the server runs. Upstream's service launcher owns server updates.
//
//   t3tray.exe [--host H] [--port P] [--base-dir D] [--channel stable|nightly]  run the tray (one per user session)
//   t3tray.exe status [--json]                print the running tray's state
//   t3tray.exe restart|stop|start|quit signal the running tray
//
// Logs and tray state live in %USERPROFILE%\.t3tray; runtimes live in .t3\runtime.
#![windows_subsystem = "windows"]

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::os::windows::io::AsRawHandle;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use sha2::{Digest, Sha256};
use t3tray::channel::Channel;
use t3tray::status::{
    format_status, local_host, not_running_json, parse_status_args, StatusFormat,
};
use tray_icon::menu::{Menu, MenuEvent, MenuItem, PredefinedMenuItem};
use tray_icon::{Icon, TrayIcon, TrayIconBuilder};
use windows_sys::Win32::Foundation::*;
use windows_sys::Win32::Storage::FileSystem::*;
use windows_sys::Win32::System::Console::*;
use windows_sys::Win32::System::Diagnostics::ToolHelp::*;
use windows_sys::Win32::System::Environment::*;
use windows_sys::Win32::System::JobObjects::*;
use windows_sys::Win32::System::Threading::*;
use windows_sys::Win32::UI::WindowsAndMessaging::*;

const REPO: &str = "pingdotgg/t3code";
const COMMANDS: [&str; 4] = ["restart", "stop", "start", "quit"];
// `t3 serve` exits 78 while the desktop app owns the T3 home; retry slowly then.
const EXIT_STATE_DIR_OWNED: i32 = 78;
const UPDATE_EVERY: Duration = Duration::from_secs(600);
const MAX_LOG_BYTES: u64 = 20 * 1024 * 1024;

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(Some(0)).collect()
}

fn home() -> PathBuf {
    PathBuf::from(std::env::var("USERPROFILE").expect("USERPROFILE"))
}

fn root() -> PathBuf {
    home().join(".t3tray")
}

fn now_unix() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn log(msg: &str) {
    let dir = root().join("logs");
    let _ = fs::create_dir_all(&dir);
    if let Ok(mut f) = OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("t3tray.log"))
    {
        let _ = writeln!(f, "{} {}", now_unix(), msg);
    }
}

// Global, not Local: Local names are per session, and SSH runs in a different session
// from the desktop where the tray lives. The user name keeps two users apart.
fn object_name(what: &str) -> Vec<u16> {
    let user = std::env::var("USERNAME").unwrap_or_default().to_lowercase();
    wide(&format!("Global\\t3tray-{user}-{what}"))
}

fn event_name(cmd: &str) -> Vec<u16> {
    object_name(cmd)
}

// ---------- CLI side ----------

fn status(args: &[String]) -> i32 {
    let format = match parse_status_args(args) {
        Ok(format) => format,
        Err(usage) => {
            eprintln!("{usage}");
            return 2;
        }
    };
    let state = fs::read_to_string(root().join("state.json"))
        .ok()
        .filter(|_| tray_running())
        .and_then(|s| serde_json::from_str::<serde_json::Value>(&s).ok());
    match (state, format) {
        (Some(state), StatusFormat::Json) => println!("{state}"),
        (Some(state), StatusFormat::Human) => println!("{}", format_status(&state)),
        (None, StatusFormat::Json) => {
            println!("{}", not_running_json());
            return 3;
        }
        (None, StatusFormat::Human) => {
            println!("t3tray is not running");
            return 3;
        }
    }
    0
}

fn cli(cmd: &str, args: &[String]) -> i32 {
    unsafe { AttachConsole(ATTACH_PARENT_PROCESS) };
    if cmd == "status" {
        return status(args);
    }
    if !COMMANDS.contains(&cmd) || !args.is_empty() {
        println!(
            "usage: t3tray [--host H] [--port P] [--base-dir D] [--channel stable|nightly] | status [--json] | {}",
            COMMANDS.join(" | ")
        );
        return 2;
    }
    let name = event_name(cmd);
    let h = unsafe { OpenEventW(EVENT_MODIFY_STATE, 0, name.as_ptr()) };
    if h.is_null() {
        println!("t3tray is not running");
        return 3;
    }
    if cmd == "start" && tray_running() && read_state_field("status").as_deref() == Some("running")
    {
        println!(
            "running {}",
            read_state_field("version").unwrap_or_default()
        );
        return 0;
    }
    let before = read_state_field("startedAt");
    unsafe {
        SetEvent(h);
        CloseHandle(h);
    }
    if cmd == "restart" || cmd == "start" {
        // Wait for the new server process so scripts can run right after.
        for _ in 0..60 {
            std::thread::sleep(Duration::from_secs(1));
            let after = read_state_field("startedAt");
            // start does not replace a starting server, so it only waits for ready.
            if (cmd == "start" || after != before)
                && read_state_field("status").as_deref() == Some("running")
            {
                println!(
                    "running {}",
                    read_state_field("version").unwrap_or_default()
                );
                return 0;
            }
        }
        println!(
            "signalled, but the server did not report running within 60 s; see {}",
            root().join("logs").display()
        );
        return 1;
    }
    println!("signalled {cmd}");
    0
}

fn read_state_field(key: &str) -> Option<String> {
    let s = fs::read_to_string(root().join("state.json")).ok()?;
    let v: serde_json::Value = serde_json::from_str(&s).ok()?;
    v.get(key).map(|x| {
        x.as_str()
            .map(str::to_owned)
            .unwrap_or_else(|| x.to_string())
    })
}

fn tray_running() -> bool {
    let name = object_name("instance");
    let h = unsafe { OpenMutexW(SYNCHRONIZE, 0, name.as_ptr()) };
    if h.is_null() {
        return false;
    }
    unsafe { CloseHandle(h) };
    true
}

// ---------- versions ----------

// The uninstaller carries the full nightly version; the app exe only has 0.1.8.0.
fn desktop_version() -> Option<String> {
    let dir = PathBuf::from(std::env::var("LOCALAPPDATA").ok()?)
        .join("Programs")
        .join("t3code");
    let exe = fs::read_dir(&dir)
        .ok()?
        .flatten()
        .map(|e| e.path())
        .find(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .is_some_and(|n| n.starts_with("Uninstall") && n.ends_with(".exe"))
        })?;
    file_product_version(&exe)
}

fn file_product_version(path: &Path) -> Option<String> {
    let p = wide(&path.to_string_lossy());
    unsafe {
        let size = GetFileVersionInfoSizeW(p.as_ptr(), std::ptr::null_mut());
        if size == 0 {
            return None;
        }
        let mut buf = vec![0u8; size as usize];
        if GetFileVersionInfoW(p.as_ptr(), 0, size, buf.as_mut_ptr().cast()) == 0 {
            return None;
        }
        let mut ptr: *mut core::ffi::c_void = std::ptr::null_mut();
        let mut len = 0u32;
        let q = wide("\\VarFileInfo\\Translation");
        let lang = if VerQueryValueW(buf.as_ptr().cast(), q.as_ptr(), &mut ptr, &mut len) != 0
            && len >= 4
        {
            let t = ptr as *const u16;
            format!("{:04x}{:04x}", *t, *t.add(1))
        } else {
            "040904b0".into()
        };
        let q = wide(&format!("\\StringFileInfo\\{lang}\\ProductVersion"));
        if VerQueryValueW(buf.as_ptr().cast(), q.as_ptr(), &mut ptr, &mut len) == 0 || len == 0 {
            return None;
        }
        let s = std::slice::from_raw_parts(ptr as *const u16, len as usize);
        let v = String::from_utf16_lossy(s)
            .trim_end_matches('\0')
            .trim()
            .to_owned();
        (!v.is_empty()).then_some(v)
    }
}

fn release_json(url: &str) -> Result<serde_json::Value, String> {
    let body = ureq::get(url)
        .set("User-Agent", "t3tray")
        .call()
        .map_err(|e| e.to_string())?
        .into_string()
        .map_err(|e| e.to_string())?;
    serde_json::from_str(&body).map_err(|e| e.to_string())
}

fn latest_release_version(channel: Channel) -> Result<String, String> {
    let base = format!("https://api.github.com/repos/{REPO}/releases");
    if channel == Channel::Stable {
        let release = release_json(&format!("{base}/latest"))?;
        if let Some(version) = channel.release_version(&release) {
            return Ok(version.into());
        }
    }
    for page in 1.. {
        let releases = release_json(&format!("{base}?per_page=100&page={page}"))?;
        let releases = releases.as_array().ok_or("invalid release list")?;
        for release in releases {
            if let Some(version) = channel.release_version(release) {
                return Ok(version.into());
            }
        }
        if releases.len() < 100 {
            break;
        }
    }
    Err(format!("no {channel} release with a win32-x64 server zip"))
}

fn target_version(channel: Channel) -> Result<String, String> {
    if let Some(version) = desktop_version() {
        if Channel::of_version(&version) == Some(channel) {
            return Ok(version);
        }
        log(&format!(
            "ignoring installed desktop version {version}: it is not on the selected {channel} channel"
        ));
    }
    latest_release_version(channel)
}

fn service_home(base_dir: Option<&str>) -> PathBuf {
    base_dir
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join(".t3"))
}

fn version_dir_at(base: &Path, v: &str) -> PathBuf {
    base.join("runtime").join("versions").join(v)
}

fn version_dir(v: &str) -> PathBuf {
    version_dir_at(&service_home(None), v)
}

fn installed(base: &Path, v: &str) -> bool {
    let dir = version_dir_at(base, v);
    dir.join("t3.exe").is_file()
        && fs::read_to_string(dir.join(".install-complete")).is_ok_and(|s| s.trim() == v)
}

struct ServiceState {
    active_version: String,
    update: Option<serde_json::Value>,
}

fn read_service_state(base: &Path) -> Result<Option<ServiceState>, String> {
    let path = base.join("runtime").join("service-state.json");
    let text = match fs::read_to_string(&path) {
        Ok(text) => text,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("{}: {e}", path.display())),
    };
    let state: serde_json::Value = serde_json::from_str(&text).map_err(|e| e.to_string())?;
    let version = state["activeVersion"]
        .as_str()
        .ok_or("service state has no activeVersion")?;
    if state["protocol"] != 3
        || version.is_empty()
        || !version
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b".-+".contains(&c))
        || !version.starts_with(|c: char| c.is_ascii_digit())
    {
        return Err("invalid or unsupported service state; leaving it untouched".into());
    }
    Ok(Some(ServiceState {
        active_version: version.into(),
        update: state.get("update").cloned(),
    }))
}

fn seed_service(base: &Path, channel: Channel) -> Result<String, String> {
    if let Some(state) = read_service_state(base)? {
        download(base, &state.active_version)?;
        return Ok(state.active_version);
    }
    let version = target_version(channel)?;
    download(base, &version)?;
    // Publish a complete initial state without replacing a state another launcher created.
    let runtime = base.join("runtime");
    let tmp = runtime.join(format!(
        ".t3tray-state-{}-{}",
        std::process::id(),
        now_unix()
    ));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&tmp)
        .map_err(|e| e.to_string())?;
    let state = serde_json::json!({ "protocol": 3, "activeVersion": version });
    file.write_all(state.to_string().as_bytes())
        .and_then(|_| file.sync_all())
        .map_err(|e| e.to_string())?;
    drop(file);
    let result = fs::hard_link(&tmp, runtime.join("service-state.json"));
    let _ = fs::remove_file(&tmp);
    if let Err(e) = result {
        if e.kind() != std::io::ErrorKind::AlreadyExists {
            return Err(e.to_string());
        }
    }
    read_service_state(base)?
        .map(|s| s.active_version)
        .ok_or("service state disappeared".into())
}

fn newest_installed() -> Option<String> {
    read_service_state(&service_home(None))
        .ok()
        .flatten()
        .map(|s| s.active_version)
}

fn download(base_dir: &Path, v: &str) -> Result<(), String> {
    if installed(base_dir, v) {
        return Ok(());
    }
    if version_dir_at(base_dir, v).exists() {
        return Err(format!(
            "runtime {v} is incomplete; refusing to overwrite it"
        ));
    }
    let name = format!("t3-{v}-win32-x64");
    let base = format!("https://github.com/{REPO}/releases/download/v{v}");
    let sums = ureq::get(&format!("{base}/SHA256SUMS"))
        .call()
        .map_err(|e| format!("SHA256SUMS: {e}"))?
        .into_string()
        .map_err(|e| e.to_string())?;
    let want = sums
        .lines()
        .find(|l| l.ends_with(&format!("{name}.zip")))
        .and_then(|l| l.split_whitespace().next())
        .ok_or(format!("{name}.zip not in SHA256SUMS"))?
        .to_lowercase();
    let tmp = root().join(format!("seed-{v}-{}-{}", std::process::id(), now_unix()));
    fs::create_dir_all(&tmp).map_err(|e| e.to_string())?;
    let zip_path = tmp.join("server.zip");
    let mut reader = ureq::get(&format!("{base}/{name}.zip"))
        .call()
        .map_err(|e| format!("{name}.zip: {e}"))?
        .into_reader();
    let mut out = File::create(&zip_path).map_err(|e| e.to_string())?;
    let mut hasher = Sha256::new();
    let mut buf = vec![0u8; 1 << 16];
    loop {
        let n = reader.read(&mut buf).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        hasher.update(&buf[..n]);
        out.write_all(&buf[..n]).map_err(|e| e.to_string())?;
    }
    drop(out);
    let got: String = hasher
        .finalize()
        .iter()
        .map(|b| format!("{b:02x}"))
        .collect();
    if got != want {
        return Err(format!(
            "{name}.zip sha256 {got} does not match SHA256SUMS {want}"
        ));
    }
    let mut zip = zip::ZipArchive::new(File::open(&zip_path).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    zip.extract(&tmp).map_err(|e| e.to_string())?;
    let inner = tmp.join(&name);
    if !inner.join("t3.exe").is_file() {
        return Err(format!("{name}.zip has no {name}\\t3.exe"));
    }
    fs::write(inner.join(".install-complete"), format!("{v}\n")).map_err(|e| e.to_string())?;
    fs::create_dir_all(base_dir.join("runtime").join("versions")).map_err(|e| e.to_string())?;
    fs::rename(&inner, version_dir_at(base_dir, v)).map_err(|e| e.to_string())?;
    let _ = fs::remove_dir_all(&tmp);
    Ok(())
}

// ---------- process ----------

struct Server {
    child: Child,
    job: HANDLE,
    version: String,
}

impl Server {
    fn kill(mut self) {
        unsafe {
            TerminateJobObject(self.job, 1);
            CloseHandle(self.job);
        }
        let _ = self.child.wait();
    }
}

// A fresh environment from the registry, like a new logon, so a restart picks up
// user variables set since the tray started.
fn fresh_env() -> Option<Vec<(String, String)>> {
    unsafe {
        let mut token: HANDLE = std::ptr::null_mut();
        if OpenProcessToken(
            GetCurrentProcess(),
            windows_sys::Win32::Security::TOKEN_QUERY
                | windows_sys::Win32::Security::TOKEN_DUPLICATE,
            &mut token,
        ) == 0
        {
            return None;
        }
        let mut block: *mut core::ffi::c_void = std::ptr::null_mut();
        let ok = CreateEnvironmentBlock(&mut block, token, 0);
        CloseHandle(token);
        if ok == 0 {
            return None;
        }
        let mut vars = Vec::new();
        let mut p = block as *const u16;
        loop {
            let mut len = 0;
            while *p.add(len) != 0 {
                len += 1;
            }
            if len == 0 {
                break;
            }
            let s = String::from_utf16_lossy(std::slice::from_raw_parts(p, len));
            // Entries like "=C:=C:\" start with '='.
            if let Some(i) = s[1..].find('=') {
                vars.push((s[..i + 1].to_owned(), s[i + 2..].to_owned()));
            }
            p = p.add(len + 1);
        }
        DestroyEnvironmentBlock(block);
        Some(vars)
    }
}

fn open_server_log() -> std::io::Result<File> {
    let dir = root().join("logs");
    fs::create_dir_all(&dir)?;
    let path = dir.join("server.log");
    if fs::metadata(&path)
        .map(|m| m.len() > MAX_LOG_BYTES)
        .unwrap_or(false)
    {
        let _ = fs::rename(&path, dir.join("server.log.1"));
    }
    OpenOptions::new().create(true).append(true).open(path)
}

fn resume_threads(pid: u32) {
    unsafe {
        let snap = CreateToolhelp32Snapshot(TH32CS_SNAPTHREAD, 0);
        if snap == INVALID_HANDLE_VALUE {
            return;
        }
        let mut te: THREADENTRY32 = std::mem::zeroed();
        te.dwSize = std::mem::size_of::<THREADENTRY32>() as u32;
        let mut ok = Thread32First(snap, &mut te);
        while ok != 0 {
            if te.th32OwnerProcessID == pid {
                let th = OpenThread(THREAD_SUSPEND_RESUME, 0, te.th32ThreadID);
                if !th.is_null() {
                    ResumeThread(th);
                    CloseHandle(th);
                }
            }
            ok = Thread32Next(snap, &mut te);
        }
        CloseHandle(snap);
    }
}

fn start_server(
    version: &str,
    host: &str,
    port: u16,
    base_dir: Option<&str>,
) -> Result<Server, String> {
    let base = service_home(base_dir);
    let dir = version_dir_at(&base, version);
    let mut log_file = open_server_log().map_err(|e| e.to_string())?;
    let _ = writeln!(
        log_file,
        "\n=== {} t3tray starting {version} on {host}:{port}",
        now_unix()
    );
    let err_file = log_file.try_clone().map_err(|e| e.to_string())?;
    let mut cmd = Command::new(dir.join("t3.exe"));
    cmd.arg("__service-launcher")
        .current_dir(home())
        .stdin(Stdio::null())
        .stdout(log_file)
        .stderr(err_file)
        // Suspended so the job holds the whole tree before the server can spawn anything.
        .creation_flags(CREATE_NO_WINDOW | CREATE_SUSPENDED);
    if let Some(vars) = fresh_env() {
        cmd.env_clear().envs(vars);
    }
    cmd.env("T3CODE_HOME", &base)
        .env("T3CODE_HOST", host)
        .env("T3CODE_PORT", port.to_string())
        .env("T3CODE_NO_BROWSER", "1");
    let child = cmd
        .spawn()
        .map_err(|e| format!("spawn {}: {e}", dir.join("t3.exe").display()))?;
    unsafe {
        let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
        let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
        // Killing the job ends the server and everything it started. If the tray dies,
        // the job handle closes and the server goes with it, so nothing is left holding the port.
        info.BasicLimitInformation.LimitFlags =
            JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_BREAKAWAY_OK;
        SetInformationJobObject(
            job,
            JobObjectExtendedLimitInformation,
            (&info as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
            std::mem::size_of_val(&info) as u32,
        );
        if job.is_null() || AssignProcessToJobObject(job, child.as_raw_handle()) == 0 {
            // Outside the job, stop could not end the server's tree; do not run it.
            let err = GetLastError();
            let mut child = child;
            let _ = child.kill();
            let _ = child.wait();
            if !job.is_null() {
                CloseHandle(job);
            }
            return Err(format!(
                "could not put the server in a job object: error {err}"
            ));
        }
        resume_threads(child.id());
        Ok(Server {
            child,
            job,
            version: version.to_owned(),
        })
    }
}

// ---------- tray ----------

#[derive(Clone, Copy, PartialEq)]
enum Light {
    Green,
    Amber,
    Red,
}

fn area_resize(src: &[u8], width: usize, height: usize, size: usize) -> Vec<u8> {
    let mut out = vec![0; size * size * 4];
    for y in 0..size {
        for x in 0..size {
            let (left, right) = (
                x as f64 * width as f64 / size as f64,
                (x + 1) as f64 * width as f64 / size as f64,
            );
            let (top, bottom) = (
                y as f64 * height as f64 / size as f64,
                (y + 1) as f64 * height as f64 / size as f64,
            );
            let mut sum = [0.0; 4];
            for sy in top.floor() as usize..bottom.ceil() as usize {
                for sx in left.floor() as usize..right.ceil() as usize {
                    let weight = (right.min((sx + 1) as f64) - left.max(sx as f64))
                        * (bottom.min((sy + 1) as f64) - top.max(sy as f64));
                    let i = (sy.min(height - 1) * width + sx.min(width - 1)) * 4;
                    let alpha = src[i + 3] as f64 / 255.0;
                    for c in 0..3 {
                        sum[c] += src[i + c] as f64 * alpha * weight;
                    }
                    sum[3] += alpha * weight;
                }
            }
            let i = (y * size + x) * 4;
            if sum[3] > 0.0 {
                for c in 0..3 {
                    out[i + c] = (sum[c] / sum[3]).round() as u8;
                }
                out[i + 3] = (sum[3] / ((right - left) * (bottom - top)) * 255.0).round() as u8;
            }
        }
    }
    out
}

fn icon_pixels(light: Light, favicon: Option<&[u8]>) -> Vec<u8> {
    let color = match light {
        Light::Green => [0x3f, 0xb9, 0x50],
        Light::Amber => [0xe3, 0xa0, 0x08],
        Light::Red => [0xe0, 0x4f, 0x4f],
    };
    let mut px = vec![0; 32 * 32 * 4];
    if let Some(logo) = favicon {
        for y in 0..26 {
            px[y * 32 * 4..(y * 32 + 26) * 4].copy_from_slice(&logo[y * 26 * 4..(y + 1) * 26 * 4]);
        }
    }
    for y in 0..32 {
        for x in 0..32 {
            let composed = favicon.is_some();
            let center = if composed { 23.0 } else { 16.0 };
            let radius = if composed { 9.0 } else { 14.0 };
            let (dx, dy) = (x as f64 + 0.5 - center, y as f64 + 0.5 - center);
            let d = (dx * dx + dy * dy).sqrt();
            let a = (radius + 0.5 - d).clamp(0.0, 1.0);
            let i = (y * 32 + x) * 4;
            let gap = if composed {
                (d - radius - 1.5).clamp(0.0, 1.0)
            } else {
                1.0
            };
            let old_a = px[i + 3] as f64 / 255.0 * gap;
            let out_a = a + old_a * (1.0 - a);
            if out_a > 0.0 {
                for c in 0..3 {
                    px[i + c] = ((color[c] as f64 * a + px[i + c] as f64 * old_a * (1.0 - a))
                        / out_a)
                        .round() as u8;
                }
            }
            px[i + 3] = (out_a * 255.0).round() as u8;
        }
    }
    px
}

fn read_png(path: &Path) -> Option<(Vec<u8>, usize, usize)> {
    let mut decoder = png::Decoder::new(std::io::BufReader::new(File::open(path).ok()?));
    decoder.set_transformations(png::Transformations::EXPAND | png::Transformations::STRIP_16);
    let mut reader = decoder.read_info().ok()?;
    let mut buffer = vec![0; reader.output_buffer_size()?];
    let info = reader.next_frame(&mut buffer).ok()?;
    let channels = match info.color_type {
        png::ColorType::Rgba => 4,
        png::ColorType::Rgb => 3,
        png::ColorType::GrayscaleAlpha => 2,
        png::ColorType::Grayscale => 1,
        png::ColorType::Indexed => return None,
    };
    let mut rgba = Vec::with_capacity(info.width as usize * info.height as usize * 4);
    for pixel in buffer[..info.buffer_size()].chunks_exact(channels) {
        match channels {
            4 => rgba.extend_from_slice(pixel),
            3 => rgba.extend_from_slice(&[pixel[0], pixel[1], pixel[2], 255]),
            2 => rgba.extend_from_slice(&[pixel[0], pixel[0], pixel[0], pixel[1]]),
            _ => rgba.extend_from_slice(&[pixel[0], pixel[0], pixel[0], 255]),
        }
    }
    Some((rgba, info.width as usize, info.height as usize))
}

fn load_favicon(dir: &Path) -> Option<Vec<u8>> {
    let client = dir.join("client");
    let mut folders = vec![client.clone()];
    let mut best = None;
    while let Some(folder) = folders.pop() {
        let Ok(entries) = fs::read_dir(folder) else {
            continue;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                folders.push(path);
                continue;
            }
            if path.extension().is_none_or(|ext| ext != "png") {
                continue;
            }
            let Some((rgba, w, h)) = read_png(&path) else {
                continue;
            };
            if w != h || w <= 32 {
                continue;
            }
            let corners = [0, w - 1, (h - 1) * w, h * w - 1];
            if corners.iter().all(|i| rgba[i * 4 + 3] == 0)
                && best.as_ref().is_none_or(|(_, size)| w > *size)
            {
                best = Some((rgba, w));
            }
        }
    }
    if let Some((rgba, size)) = best {
        return Some(area_resize(&rgba, size, size, 26));
    }
    let (rgba, w, h) = read_png(&client.join("favicon-32x32.png"))?;
    Some(area_resize(&rgba, w, h, 26))
}

fn write_icon_png(
    path: &Path,
    pixels: &[u8],
    width: usize,
    height: usize,
    scale: usize,
) -> Result<(), Box<dyn std::error::Error>> {
    let mut scaled = Vec::with_capacity(width * height * scale * scale * 4);
    for y in 0..height * scale {
        for x in 0..width * scale {
            let i = ((y / scale) * width + x / scale) * 4;
            scaled.extend_from_slice(&pixels[i..i + 4]);
        }
    }
    let mut encoder = png::Encoder::new(
        File::create(path)?,
        (width * scale) as u32,
        (height * scale) as u32,
    );
    encoder.set_color(png::ColorType::Rgba);
    encoder.set_depth(png::BitDepth::Eight);
    encoder.write_header()?.write_image_data(&scaled)?;
    Ok(())
}

fn icon_preview(out: &Path) -> Result<(), Box<dyn std::error::Error>> {
    fs::create_dir_all(out)?;
    let favicon = newest_installed().and_then(|v| load_favicon(&version_dir(&v)));
    let mut sheet = vec![0; 176 * 80 * 4];
    for (row, background) in [0x20, 0xf3].into_iter().enumerate() {
        for pixel in sheet[row * 40 * 176 * 4..(row + 1) * 40 * 176 * 4]
            .as_chunks_mut::<4>()
            .0
        {
            pixel.copy_from_slice(&[background, background, background, 255]);
        }
    }
    for (column, (name, light, base)) in [
        ("green", Light::Green, favicon.as_deref()),
        ("amber", Light::Amber, favicon.as_deref()),
        ("red", Light::Red, favicon.as_deref()),
        ("fallback", Light::Green, None),
    ]
    .into_iter()
    .enumerate()
    {
        let pixels = icon_pixels(light, base);
        write_icon_png(&out.join(format!("{name}.png")), &pixels, 32, 32, 8)?;
        for (row, background) in [0x20, 0xf3].into_iter().enumerate() {
            for (size, offset) in [(16, 2), (24, 18)] {
                let small = area_resize(&pixels, 32, 32, size);
                for y in 0..size {
                    for x in 0..size {
                        let src = (y * size + x) * 4;
                        let dst =
                            ((row * 40 + (40 - size) / 2 + y) * 176 + column * 44 + offset + x) * 4;
                        let alpha = small[src + 3] as f64 / 255.0;
                        for c in 0..3 {
                            sheet[dst + c] = (small[src + c] as f64 * alpha
                                + background as f64 * (1.0 - alpha))
                                .round() as u8;
                        }
                    }
                }
            }
        }
    }
    write_icon_png(&out.join("sheet.png"), &sheet, 176, 80, 4)
}

enum Msg {
    Seed(Result<String, String>),
    // The server answered HTTP 200; carries the startedAt it belongs to.
    Ready(u64),
}

// Poll the server until it answers 200, so "running" means clients can connect.
fn probe_ready(host: &str, port: u16, started_at: u64, tx: mpsc::Sender<Msg>) {
    let host = local_host(host);
    std::thread::spawn(move || {
        let url = format!("http://{host}:{port}/");
        let agent = ureq::AgentBuilder::new()
            .timeout(Duration::from_secs(2))
            .build();
        for _ in 0..240 {
            if agent.get(&url).call().is_ok_and(|r| r.status() == 200) {
                let _ = tx.send(Msg::Ready(started_at));
                return;
            }
            std::thread::sleep(Duration::from_millis(500));
        }
    });
}

struct App {
    channel: Channel,
    host: String,
    port: u16,
    base_dir: Option<String>,
    server: Option<Server>,
    want_running: bool,
    next_start: Instant,
    started_at: u64,
    ready: bool,
    last_exit: Option<i32>,
    service_state: Option<ServiceState>,
    message: String,
    checking: bool,
    last_check: Option<Instant>,
    tx: mpsc::Sender<Msg>,
}

impl App {
    fn status(&self) -> &'static str {
        if self.server.is_some() && self.ready {
            "running"
        } else if self.server.is_some() {
            "starting"
        } else if self.want_running {
            "waiting"
        } else {
            "stopped"
        }
    }

    fn pick_version(&self) -> Option<String> {
        let state = self.service_state.as_ref()?;
        installed(
            &service_home(self.base_dir.as_deref()),
            &state.active_version,
        )
        .then(|| state.active_version.clone())
    }

    fn start(&mut self) {
        let Some(v) = self.pick_version() else {
            self.message = "downloading the server".into();
            self.check();
            self.next_start = Instant::now() + Duration::from_secs(5);
            return;
        };
        match start_server(&v, &self.host, self.port, self.base_dir.as_deref()) {
            Ok(s) => {
                log(&format!("started {v} pid {}", s.child.id()));
                self.server = Some(s);
                self.started_at = now_unix();
                self.ready = false;
                probe_ready(&self.host, self.port, self.started_at, self.tx.clone());
                self.message.clear();
            }
            Err(e) => {
                log(&format!("start failed: {e}"));
                self.message = e;
                self.next_start = Instant::now() + Duration::from_secs(30);
            }
        }
    }

    fn stop(&mut self) {
        if let Some(s) = self.server.take() {
            log(&format!("stopping {}", s.version));
            s.kill();
        }
    }

    fn check(&mut self) {
        if self.checking {
            return;
        }
        self.checking = true;
        self.last_check = Some(Instant::now());
        let tx = self.tx.clone();
        let base = service_home(self.base_dir.as_deref());
        let channel = self.channel;
        std::thread::spawn(move || {
            let r = seed_service(&base, channel);
            let _ = tx.send(Msg::Seed(r));
        });
    }

    fn tick(&mut self) {
        match read_service_state(&service_home(self.base_dir.as_deref())) {
            Ok(state) => {
                self.service_state = state;
                if let (Some(server), Some(state)) = (&mut self.server, &self.service_state) {
                    server.version = state.active_version.clone();
                }
            }
            Err(e) => self.message = e,
        }
        if let Some(s) = &mut self.server {
            if let Ok(Some(st)) = s.child.try_wait() {
                let code = st.code();
                log(&format!("server {} exited with {:?}", s.version, code));
                let s = self.server.take().unwrap();
                unsafe { CloseHandle(s.job) };
                self.last_exit = code;
                let wait = if code == Some(EXIT_STATE_DIR_OWNED) {
                    60
                } else {
                    10
                };
                self.message = if code == Some(EXIT_STATE_DIR_OWNED) {
                    "the desktop app owns the T3 home; turn its Local environment off".into()
                } else {
                    format!("server exited with {code:?}; restarting in {wait} s")
                };
                self.next_start = Instant::now() + Duration::from_secs(wait);
            }
        }
        if self.server.is_none() && self.want_running && Instant::now() >= self.next_start {
            self.start();
        }
        if self.last_check.is_none_or(|t| t.elapsed() >= UPDATE_EVERY) {
            self.check();
        }
    }

    fn on_msg(&mut self, m: Msg) {
        match m {
            Msg::Seed(Ok(v)) => {
                self.checking = false;
                log(&format!("launcher runtime ready {v}"));
                if self.message.starts_with("update") || self.message.starts_with("downloading") {
                    self.message.clear();
                }
            }
            Msg::Ready(at) => {
                if at == self.started_at && self.server.is_some() {
                    self.ready = true;
                    log("server answered HTTP 200");
                }
            }
            Msg::Seed(Err(e)) => {
                self.checking = false;
                log(&format!("update check failed: {e}"));
                self.message = format!("update check failed: {e}");
            }
        }
    }

    fn state_json(&self) -> String {
        serde_json::json!({
            "status": self.status(),
            "channel": self.channel.as_str(),
            "version": self.service_state.as_ref().map(|s| &s.active_version),
            "serviceUpdate": self.service_state.as_ref().and_then(|s| s.update.as_ref()),
            "serverPid": self.server.as_ref().map(|s| s.child.id()),
            "trayPid": std::process::id(),
            "host": self.host,
            "port": self.port,
            "startedAt": self.started_at,
            "lastExit": self.last_exit,
            "serviceState": service_home(self.base_dir.as_deref()).join("runtime").join("service-state.json"),
            "message": self.message,
            "logs": root().join("logs").to_string_lossy(),
        })
        .to_string()
    }
}

struct Ui {
    tray: TrayIcon,
    status: MenuItem,
    restart: MenuItem,
    toggle: MenuItem,
    logs: MenuItem,
    quit: MenuItem,
    light: Option<Light>,
    last_state: String,
    icon_dir: Option<PathBuf>,
    favicon: Option<Vec<u8>>,
}

impl Ui {
    fn refresh(&mut self, app: &App) {
        let light = match (
            app.server.is_some() && app.ready,
            app.service_state
                .as_ref()
                .and_then(|s| s.update.as_ref())
                .is_some_and(|u| u["status"] == "pending")
                || !app.message.is_empty(),
        ) {
            (true, false) => Light::Green,
            (true, true) => Light::Amber,
            (false, _) if app.want_running => Light::Amber,
            _ => Light::Red,
        };
        let dir = app
            .server
            .as_ref()
            .map(|s| s.version.clone())
            .or_else(newest_installed)
            .map(|v| version_dir(&v));
        let changed = self.icon_dir != dir;
        if changed {
            self.favicon = dir.as_deref().and_then(load_favicon);
            self.icon_dir = dir;
        }
        if self.light != Some(light) || changed {
            let pixels = icon_pixels(light, self.favicon.as_deref());
            let _ = self
                .tray
                .set_icon(Some(Icon::from_rgba(pixels, 32, 32).expect("icon")));
            self.light = Some(light);
        }
        let head = match &app.server {
            Some(s) if app.ready => format!("{} on {}:{}", s.version, app.host, app.port),
            Some(s) => format!("starting {}", s.version),
            None => app.status().to_owned(),
        };
        let head = format!("T3 server ({}) {head}", app.channel);
        let head = match app.service_state.as_ref().and_then(|s| s.update.as_ref()) {
            Some(u) => format!("{head} [{}]", u["status"].as_str().unwrap_or("unknown")),
            None => head,
        };
        let tip = if app.message.is_empty() {
            head.clone()
        } else {
            format!("{head}\n{}", app.message)
        };
        let tip: String = tip.chars().take(120).collect();
        self.status.set_text(&head);
        let _ = self.tray.set_tooltip(Some(&tip));
        self.restart.set_text("Restart server");
        self.toggle.set_text(if app.want_running {
            "Stop server"
        } else {
            "Start server"
        });
        let state = app.state_json();
        if state != self.last_state {
            let path = root().join("state.json");
            let tmp = root().join("state.json.tmp");
            if fs::write(&tmp, &state).is_ok() {
                let _ = fs::rename(&tmp, &path);
            }
            self.last_state = state;
        }
    }
}

fn arg_value(args: &[String], flag: &str) -> Option<String> {
    args.iter()
        .position(|a| a == flag)
        .and_then(|i| args.get(i + 1))
        .cloned()
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().is_some_and(|a| a == "icon-preview") {
        let result = args
            .get(1)
            .ok_or("usage: t3tray icon-preview <outdir>")
            .map_err(|e| e.into())
            .and_then(|out| icon_preview(Path::new(out)));
        if let Err(e) = result {
            eprintln!("{e}");
            std::process::exit(1);
        }
        return;
    }
    if let Some(cmd) = args.first().filter(|a| !a.starts_with("--")) {
        std::process::exit(cli(cmd, &args[1..]));
    }
    let channel = match Channel::from_args(&args) {
        Ok(channel) => channel,
        Err(error) => {
            unsafe { AttachConsole(ATTACH_PARENT_PROCESS) };
            eprintln!("{error}");
            log(&error);
            std::process::exit(2);
        }
    };
    let host = arg_value(&args, "--host").unwrap_or_else(|| "127.0.0.1".into());
    let port: u16 = arg_value(&args, "--port")
        .and_then(|p| p.parse().ok())
        .unwrap_or(3773);

    let mutex_name = object_name("instance");
    let _mutex = unsafe { CreateMutexW(std::ptr::null(), 1, mutex_name.as_ptr()) };
    if unsafe { GetLastError() } == ERROR_ALREADY_EXISTS {
        return;
    }
    let events: Vec<(&str, HANDLE)> = COMMANDS
        .iter()
        .map(|c| {
            (*c, unsafe {
                CreateEventW(std::ptr::null(), 0, 0, event_name(c).as_ptr())
            })
        })
        .collect();

    log(&format!(
        "tray starting, channel {channel} host {host} port {port}"
    ));
    let (tx, rx) = mpsc::channel();
    let mut app = App {
        channel,
        host,
        port,
        base_dir: arg_value(&args, "--base-dir"),
        server: None,
        want_running: true,
        next_start: Instant::now(),
        started_at: 0,
        ready: false,
        last_exit: None,
        service_state: None,
        message: String::new(),
        checking: false,
        last_check: None,
        tx,
    };

    let menu = Menu::new();
    let heading = format!("T3 server ({channel})");
    let status = MenuItem::new(&heading, false, None);
    let restart = MenuItem::new("Restart server", true, None);
    let toggle = MenuItem::new("Stop server", true, None);
    let logs = MenuItem::new("Open logs", true, None);
    let quit = MenuItem::new("Quit", true, None);
    let sep1 = PredefinedMenuItem::separator();
    let sep2 = PredefinedMenuItem::separator();
    menu.append_items(&[&status, &sep1, &restart, &toggle, &logs, &sep2, &quit])
        .expect("menu");
    let tray = TrayIconBuilder::new()
        .with_menu(Box::new(menu))
        .with_tooltip(&heading)
        .with_icon(Icon::from_rgba(icon_pixels(Light::Amber, None), 32, 32).expect("icon"))
        .build()
        .expect("tray");
    let mut ui = Ui {
        tray,
        status,
        restart,
        toggle,
        logs,
        quit,
        light: None,
        last_state: String::new(),
        icon_dir: None,
        favicon: None,
    };

    app.service_state = read_service_state(&service_home(app.base_dir.as_deref()))
        .ok()
        .flatten();
    let mut quitting = false;
    while !quitting {
        unsafe {
            MsgWaitForMultipleObjects(0, std::ptr::null(), 0, 500, QS_ALLINPUT);
            let mut msg: MSG = std::mem::zeroed();
            while PeekMessageW(&mut msg, std::ptr::null_mut(), 0, 0, PM_REMOVE) != 0 {
                if msg.message == WM_QUIT {
                    quitting = true;
                }
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
        let mut cmds: Vec<&str> = events
            .iter()
            .filter(|(_, h)| unsafe { WaitForSingleObject(*h, 0) } == WAIT_OBJECT_0)
            .map(|(c, _)| *c)
            .collect();
        while let Ok(e) = MenuEvent::receiver().try_recv() {
            let id = e.id();
            if id == ui.restart.id() {
                cmds.push("restart");
            } else if id == ui.toggle.id() {
                cmds.push(if app.want_running { "stop" } else { "start" });
            } else if id == ui.logs.id() {
                let _ = Command::new("explorer.exe")
                    .arg(root().join("logs"))
                    .spawn();
            } else if id == ui.quit.id() {
                cmds.push("quit");
            }
        }
        for c in cmds {
            log(&format!("command {c}"));
            match c {
                "restart" => {
                    app.stop();
                    app.want_running = true;
                    app.next_start = Instant::now();
                }
                "stop" => {
                    app.want_running = false;
                    app.stop();
                }
                "start" => {
                    app.want_running = true;
                    app.next_start = Instant::now();
                }
                "quit" => quitting = true,
                _ => {}
            }
        }
        while let Ok(m) = rx.try_recv() {
            app.on_msg(m);
        }
        if !quitting {
            app.tick();
            ui.refresh(&app);
        }
    }
    app.stop();
    let _ = fs::remove_file(root().join("state.json"));
    log("tray quit");
}
