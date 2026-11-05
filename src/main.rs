// t3tray: run the T3 Code server on Windows from a tray icon.
//
// It runs the standalone server build from the nightly release (t3-<ver>-win32-x64.zip),
// not the CLI inside the desktop app, so the desktop app's own updater can replace its
// install folder while the server runs. The server version follows the installed desktop
// app: after an in-app update, the tray downloads the matching zip and offers a restart.
//
//   t3tray.exe [--host H] [--port P] [--base-dir D]  run the tray (one per user session)
//   t3tray.exe status                         print the running tray's state
//   t3tray.exe restart|stop|start|update|quit signal the running tray
//
// Files live in %USERPROFILE%\.t3tray: versions\<ver>\, logs\, state.json.
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
const COMMANDS: [&str; 5] = ["restart", "stop", "start", "update", "quit"];
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
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0)
}

fn log(msg: &str) {
    let dir = root().join("logs");
    let _ = fs::create_dir_all(&dir);
    if let Ok(mut f) = OpenOptions::new().create(true).append(true).open(dir.join("t3tray.log")) {
        let _ = writeln!(f, "{} {}", now_unix(), msg);
    }
}

// Global, not Local: Local names are per session, and SSH runs in a different session
// from the desktop where the tray lives. The user name keeps two users apart.
fn object_name(what: &str) -> Vec<u16> {
    let user = std::env::var("USERNAME").unwrap_or_default();
    wide(&format!("Global\\t3tray-{user}-{what}"))
}

fn event_name(cmd: &str) -> Vec<u16> {
    object_name(cmd)
}

// ---------- CLI side ----------

fn cli(cmd: &str) -> i32 {
    unsafe { AttachConsole(ATTACH_PARENT_PROCESS) };
    if cmd == "status" {
        return match fs::read_to_string(root().join("state.json")) {
            Ok(s) if tray_running() => {
                println!("{s}");
                0
            }
            _ => {
                println!("t3tray is not running");
                3
            }
        };
    }
    if !COMMANDS.contains(&cmd) {
        println!("usage: t3tray [--host H] [--port P] [--base-dir D] | status | {}", COMMANDS.join(" | "));
        return 2;
    }
    let name = event_name(cmd);
    let h = unsafe { OpenEventW(EVENT_MODIFY_STATE, 0, name.as_ptr()) };
    if h.is_null() {
        println!("t3tray is not running");
        return 3;
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
            if after != before && read_state_field("status").as_deref() == Some("running") {
                println!("running {}", read_state_field("version").unwrap_or_default());
                return 0;
            }
        }
        println!("signalled, but the server did not report running within 60 s; see {}", root().join("logs").display());
        return 1;
    }
    println!("signalled {cmd}");
    0
}

fn read_state_field(key: &str) -> Option<String> {
    let s = fs::read_to_string(root().join("state.json")).ok()?;
    let v: serde_json::Value = serde_json::from_str(&s).ok()?;
    v.get(key).map(|x| x.as_str().map(str::to_owned).unwrap_or_else(|| x.to_string()))
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
    let dir = PathBuf::from(std::env::var("LOCALAPPDATA").ok()?).join("Programs").join("t3code");
    let exe = fs::read_dir(&dir).ok()?.flatten().map(|e| e.path()).find(|p| {
        p.file_name().and_then(|n| n.to_str()).is_some_and(|n| n.starts_with("Uninstall") && n.ends_with(".exe"))
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
        let lang = if VerQueryValueW(buf.as_ptr().cast(), q.as_ptr(), &mut ptr, &mut len) != 0 && len >= 4 {
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
        let v = String::from_utf16_lossy(s).trim_end_matches('\0').trim().to_owned();
        (!v.is_empty()).then_some(v)
    }
}

fn latest_release_version() -> Result<String, String> {
    let url = format!("https://api.github.com/repos/{REPO}/releases?per_page=10");
    let body = ureq::get(&url).set("User-Agent", "t3tray").call().map_err(|e| e.to_string())?.into_string().map_err(|e| e.to_string())?;
    let v: serde_json::Value = serde_json::from_str(&body).map_err(|e| e.to_string())?;
    for r in v.as_array().into_iter().flatten() {
        let has_zip = r["assets"].as_array().into_iter().flatten().any(|a| a["name"].as_str().is_some_and(|n| n.ends_with("-win32-x64.zip")));
        if let (true, Some(tag)) = (has_zip, r["tag_name"].as_str()) {
            return Ok(tag.trim_start_matches('v').to_owned());
        }
    }
    Err("no release with a win32-x64 server zip".into())
}

fn target_version() -> Result<String, String> {
    match desktop_version() {
        Some(v) => Ok(v),
        None => latest_release_version(),
    }
}

fn version_dir(v: &str) -> PathBuf {
    root().join("versions").join(v)
}

fn installed(v: &str) -> bool {
    version_dir(v).join("t3.exe").is_file()
}

fn newest_installed() -> Option<String> {
    let mut dirs: Vec<(SystemTime, String)> = fs::read_dir(root().join("versions"))
        .ok()?
        .flatten()
        .filter(|e| e.path().join("t3.exe").is_file())
        .filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.file_name().to_string_lossy().into_owned())))
        .collect();
    dirs.sort();
    dirs.pop().map(|(_, v)| v)
}

// Keep the running version and the two newest others.
fn prune(keep: &str) {
    let Ok(rd) = fs::read_dir(root().join("versions")) else { return };
    let mut dirs: Vec<(SystemTime, PathBuf)> = rd
        .flatten()
        .filter(|e| e.file_name().to_string_lossy() != keep)
        .filter_map(|e| Some((e.metadata().ok()?.modified().ok()?, e.path())))
        .collect();
    dirs.sort();
    dirs.reverse();
    for (_, p) in dirs.into_iter().skip(2) {
        let _ = fs::remove_dir_all(p);
    }
}

fn download(v: &str) -> Result<(), String> {
    if installed(v) {
        return Ok(());
    }
    let name = format!("t3-{v}-win32-x64");
    let base = format!("https://github.com/{REPO}/releases/download/v{v}");
    let sums = ureq::get(&format!("{base}/SHA256SUMS")).call().map_err(|e| format!("SHA256SUMS: {e}"))?.into_string().map_err(|e| e.to_string())?;
    let want = sums
        .lines()
        .find(|l| l.ends_with(&format!("{name}.zip")))
        .and_then(|l| l.split_whitespace().next())
        .ok_or(format!("{name}.zip not in SHA256SUMS"))?
        .to_lowercase();
    let tmp = root().join("versions").join(format!("{v}.partial"));
    let _ = fs::remove_dir_all(&tmp);
    fs::create_dir_all(&tmp).map_err(|e| e.to_string())?;
    let zip_path = tmp.join("server.zip");
    let mut reader = ureq::get(&format!("{base}/{name}.zip")).call().map_err(|e| format!("{name}.zip: {e}"))?.into_reader();
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
    let got: String = hasher.finalize().iter().map(|b| format!("{b:02x}")).collect();
    if got != want {
        return Err(format!("{name}.zip sha256 {got} does not match SHA256SUMS {want}"));
    }
    let mut zip = zip::ZipArchive::new(File::open(&zip_path).map_err(|e| e.to_string())?).map_err(|e| e.to_string())?;
    zip.extract(&tmp).map_err(|e| e.to_string())?;
    let inner = tmp.join(&name);
    if !inner.join("t3.exe").is_file() {
        return Err(format!("{name}.zip has no {name}\\t3.exe"));
    }
    fs::rename(&inner, version_dir(v)).map_err(|e| e.to_string())?;
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
        if OpenProcessToken(GetCurrentProcess(), windows_sys::Win32::Security::TOKEN_QUERY | windows_sys::Win32::Security::TOKEN_DUPLICATE, &mut token) == 0 {
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
    if fs::metadata(&path).map(|m| m.len() > MAX_LOG_BYTES).unwrap_or(false) {
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

fn start_server(version: &str, host: &str, port: u16, base_dir: Option<&str>) -> Result<Server, String> {
    let dir = version_dir(version);
    let mut log_file = open_server_log().map_err(|e| e.to_string())?;
    let _ = writeln!(log_file, "\n=== {} t3tray starting {version} on {host}:{port}", now_unix());
    let err_file = log_file.try_clone().map_err(|e| e.to_string())?;
    let mut cmd = Command::new(dir.join("t3.exe"));
    cmd.args(["serve", "--host", host, "--port", &port.to_string(), "--no-browser"])
        .args(base_dir.map(|d| ["--base-dir", d]).into_iter().flatten())
        .current_dir(home())
        .stdin(Stdio::null())
        .stdout(log_file)
        .stderr(err_file)
        // Suspended so the job holds the whole tree before the server can spawn anything.
        .creation_flags(CREATE_NO_WINDOW | CREATE_SUSPENDED);
    if let Some(vars) = fresh_env() {
        cmd.env_clear().envs(vars);
    }
    let child = cmd.spawn().map_err(|e| format!("spawn {}: {e}", dir.join("t3.exe").display()))?;
    unsafe {
        let job = CreateJobObjectW(std::ptr::null(), std::ptr::null());
        let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
        // Killing the job ends the server and everything it started. If the tray dies,
        // the job handle closes and the server goes with it, so nothing is left holding the port.
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | JOB_OBJECT_LIMIT_BREAKAWAY_OK;
        SetInformationJobObject(job, JobObjectExtendedLimitInformation, (&info as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(), std::mem::size_of_val(&info) as u32);
        if AssignProcessToJobObject(job, child.as_raw_handle()) == 0 {
            log(&format!("AssignProcessToJobObject failed: {}", GetLastError()));
        }
        resume_threads(child.id());
        Ok(Server { child, job, version: version.to_owned() })
    }
}

// ---------- tray ----------

#[derive(Clone, Copy, PartialEq)]
enum Light {
    Green,
    Amber,
    Red,
}

fn icon(light: Light) -> Icon {
    let (r, g, b) = match light {
        Light::Green => (0x3f, 0xb9, 0x50),
        Light::Amber => (0xe3, 0xa0, 0x08),
        Light::Red => (0xe0, 0x4f, 0x4f),
    };
    let n = 32u32;
    let mut px = Vec::with_capacity((n * n * 4) as usize);
    for y in 0..n {
        for x in 0..n {
            let (dx, dy) = (x as f32 - 15.5, y as f32 - 15.5);
            let d = (dx * dx + dy * dy).sqrt();
            let a = (14.5 - d).clamp(0.0, 1.0);
            // Dark ring so the dot reads on light and dark taskbars.
            let ring = d > 11.5;
            let (cr, cg, cb) = if ring { (r / 2, g / 2, b / 2) } else { (r, g, b) };
            px.extend_from_slice(&[cr, cg, cb, (a * 255.0) as u8]);
        }
    }
    Icon::from_rgba(px, n, n).expect("icon")
}

enum Msg {
    Target(Result<String, String>),
    // The server answered HTTP 200; carries the startedAt it belongs to.
    Ready(u64),
}

// Poll the server until it answers 200, so "running" means clients can connect.
fn probe_ready(host: &str, port: u16, started_at: u64, tx: mpsc::Sender<Msg>) {
    let host = if host == "0.0.0.0" { "127.0.0.1".to_owned() } else { host.to_owned() };
    std::thread::spawn(move || {
        let url = format!("http://{host}:{port}/");
        let agent = ureq::AgentBuilder::new().timeout(Duration::from_secs(2)).build();
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
    host: String,
    port: u16,
    base_dir: Option<String>,
    server: Option<Server>,
    want_running: bool,
    next_start: Instant,
    started_at: u64,
    ready: bool,
    last_exit: Option<i32>,
    target: Option<String>,
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

    fn update_ready(&self) -> Option<&str> {
        let t = self.target.as_deref()?;
        let s = self.server.as_ref()?;
        (s.version != t && installed(t)).then_some(t)
    }

    fn pick_version(&self) -> Option<String> {
        match &self.target {
            Some(t) if installed(t) => Some(t.clone()),
            _ => newest_installed(),
        }
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
                prune(&v);
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
        std::thread::spawn(move || {
            let r = target_version().and_then(|v| download(&v).map(|_| v));
            let _ = tx.send(Msg::Target(r));
        });
    }

    fn tick(&mut self) {
        if let Some(s) = &mut self.server {
            if let Ok(Some(st)) = s.child.try_wait() {
                let code = st.code();
                log(&format!("server {} exited with {:?}", s.version, code));
                let s = self.server.take().unwrap();
                unsafe { CloseHandle(s.job) };
                self.last_exit = code;
                let wait = if code == Some(EXIT_STATE_DIR_OWNED) { 60 } else { 10 };
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
            Msg::Target(Ok(v)) => {
                self.checking = false;
                if self.target.as_deref() != Some(&v) {
                    log(&format!("target version {v}"));
                }
                self.target = Some(v);
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
            Msg::Target(Err(e)) => {
                self.checking = false;
                log(&format!("update check failed: {e}"));
                self.message = format!("update check failed: {e}");
            }
        }
    }

    fn state_json(&self) -> String {
        serde_json::json!({
            "status": self.status(),
            "version": self.server.as_ref().map(|s| s.version.clone()),
            "serverPid": self.server.as_ref().map(|s| s.child.id()),
            "trayPid": std::process::id(),
            "host": self.host,
            "port": self.port,
            "startedAt": self.started_at,
            "lastExit": self.last_exit,
            "targetVersion": self.target,
            "updateReady": self.update_ready(),
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
    update: MenuItem,
    logs: MenuItem,
    quit: MenuItem,
    light: Option<Light>,
    last_state: String,
}

impl Ui {
    fn refresh(&mut self, app: &App) {
        let light = match (app.server.is_some() && app.ready, app.update_ready().is_some() || !app.message.is_empty()) {
            (true, false) => Light::Green,
            (true, true) => Light::Amber,
            (false, _) if app.want_running => Light::Amber,
            _ => Light::Red,
        };
        if self.light != Some(light) {
            let _ = self.tray.set_icon(Some(icon(light)));
            self.light = Some(light);
        }
        let head = match &app.server {
            Some(s) if app.ready => format!("T3 server {} on {}:{}", s.version, app.host, app.port),
            Some(s) => format!("T3 server starting {}", s.version),
            None => format!("T3 server {}", app.status()),
        };
        let tip = if app.message.is_empty() { head.clone() } else { format!("{head}\n{}", app.message) };
        let tip: String = tip.chars().take(120).collect();
        self.status.set_text(&head);
        let _ = self.tray.set_tooltip(Some(&tip));
        self.restart.set_text(match app.update_ready() {
            Some(v) => format!("Restart onto {v}"),
            None => "Restart server".into(),
        });
        self.toggle.set_text(if app.want_running { "Stop server" } else { "Start server" });
        self.update.set_enabled(!app.checking);
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
    args.iter().position(|a| a == flag).and_then(|i| args.get(i + 1)).cloned()
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if let Some(cmd) = args.first().filter(|a| !a.starts_with("--")) {
        std::process::exit(cli(cmd));
    }
    let host = arg_value(&args, "--host").unwrap_or_else(|| "127.0.0.1".into());
    let port: u16 = arg_value(&args, "--port").and_then(|p| p.parse().ok()).unwrap_or(3773);

    let mutex_name = object_name("instance");
    let _mutex = unsafe { CreateMutexW(std::ptr::null(), 1, mutex_name.as_ptr()) };
    if unsafe { GetLastError() } == ERROR_ALREADY_EXISTS {
        return;
    }
    let events: Vec<(&str, HANDLE)> = COMMANDS
        .iter()
        .map(|c| (*c, unsafe { CreateEventW(std::ptr::null(), 0, 0, event_name(c).as_ptr()) }))
        .collect();

    log(&format!("tray starting, host {host} port {port}"));
    let (tx, rx) = mpsc::channel();
    let mut app = App {
        host,
        port,
        base_dir: arg_value(&args, "--base-dir"),
        server: None,
        want_running: true,
        next_start: Instant::now(),
        started_at: 0,
        ready: false,
        last_exit: None,
        target: None,
        message: String::new(),
        checking: false,
        last_check: None,
        tx,
    };

    let menu = Menu::new();
    let status = MenuItem::new("T3 server", false, None);
    let restart = MenuItem::new("Restart server", true, None);
    let toggle = MenuItem::new("Stop server", true, None);
    let update = MenuItem::new("Check for update", true, None);
    let logs = MenuItem::new("Open logs", true, None);
    let quit = MenuItem::new("Quit", true, None);
    let sep1 = PredefinedMenuItem::separator();
    let sep2 = PredefinedMenuItem::separator();
    menu.append_items(&[&status, &sep1, &restart, &toggle, &update, &logs, &sep2, &quit]).expect("menu");
    let tray = TrayIconBuilder::new().with_menu(Box::new(menu)).with_tooltip("T3 server").with_icon(icon(Light::Amber)).build().expect("tray");
    let mut ui = Ui { tray, status, restart, toggle, update, logs, quit, light: None, last_state: String::new() };

    // Start on the newest local version right away; the first check may move it later.
    app.target = desktop_version();
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
        let mut cmds: Vec<&str> = events.iter().filter(|(_, h)| unsafe { WaitForSingleObject(*h, 0) } == WAIT_OBJECT_0).map(|(c, _)| *c).collect();
        while let Ok(e) = MenuEvent::receiver().try_recv() {
            let id = e.id();
            if id == ui.restart.id() {
                cmds.push("restart");
            } else if id == ui.toggle.id() {
                cmds.push(if app.want_running { "stop" } else { "start" });
            } else if id == ui.update.id() {
                cmds.push("update");
            } else if id == ui.logs.id() {
                let _ = Command::new("explorer.exe").arg(root().join("logs")).spawn();
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
                "update" => app.check(),
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
