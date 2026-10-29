//! Stable JSON boundary for in-process native clients. No credentials go to stdout.
use anyhow::{anyhow, ensure, Context, Result};
use multi_sync::{identity::Ticket, EventSink};
use multi_sync_core::Store;
use serde_json::{json, Value};
use std::{collections::{HashMap, VecDeque}, ffi::{c_char, CStr, CString}, net::{Ipv4Addr, SocketAddr}, path::PathBuf,
    sync::{atomic::{AtomicBool, Ordering}, Arc, Mutex, OnceLock}};
use tokio::{runtime::Runtime, sync::watch};
use uuid::Uuid;

struct Task {
    events: Mutex<VecDeque<Value>>,
    finished: AtomicBool,
    stop: watch::Sender<bool>,
}
impl Task {
    fn push(&self, event: Value) {
        if let Ok(mut events) = self.events.lock() {
            let kind = event.get("event").and_then(Value::as_str).unwrap_or("");
            if matches!(kind, "progress" | "waiting") {
                events.retain(|old| old.get("event").and_then(Value::as_str) != Some(kind));
            }
            events.push_back(event);
        }
    }
}
static TASKS: OnceLock<Mutex<HashMap<String, Arc<Task>>>> = OnceLock::new();
static RUNTIME: OnceLock<std::result::Result<Runtime, String>> = OnceLock::new();
fn tasks() -> &'static Mutex<HashMap<String, Arc<Task>>> { TASKS.get_or_init(|| Mutex::new(HashMap::new())) }
fn runtime() -> Result<&'static Runtime> {
    match RUNTIME.get_or_init(|| {
        multi_sync::initialize_crypto();
        tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().map_err(|e| e.to_string())
    }) {
        Ok(runtime) => Ok(runtime), Err(error) => Err(anyhow!(error.clone())),
    }
}
fn string(value: &Value, key: &str) -> Result<String> {
    Ok(value.get(key).and_then(Value::as_str).filter(|v| !v.is_empty()).with_context(|| format!("缺少参数：{key}"))?.to_owned())
}
fn path(value: &Value, key: &str) -> Result<PathBuf> {
    let path = PathBuf::from(string(value, key)?);
    ensure!(path.is_absolute(), "{key} 必须为绝对路径");
    Ok(path)
}

fn invoke(value: Value) -> Result<Value> {
    match string(&value, "op")?.as_str() {
        "validate_ticket" => {
            multi_sync::initialize_crypto();
            let ticket = Ticket::decode(&string(&value, "ticket")?)?;
            let _ = ticket.client()?; // validates the DER trust anchor without making a request
            Ok(json!({"ok":true,"host":ticket.host.to_string(),"port":ticket.port}))
        },
        "jobs" | "approve" | "reject" => {
            let op = string(&value, "op")?;
            let mut store = Store::open(&path(&value, "inbox")?)?;
            if op == "jobs" { return Ok(json!({"ok":true,"jobs":store.list()?})); }
            let id = Uuid::parse_str(&string(&value, "id")?)?;
            let job = if op == "approve" { store.approve(id)? } else { store.reject(id)? };
            Ok(json!({"ok":true,"job":job}))
        },
        "poll" | "stop" | "release" => {
            let op = string(&value, "op")?;
            let handle = string(&value, "handle")?;
            let mut table = tasks().lock().map_err(|_| anyhow!("任务管理器不可用"))?;
            let task = table.get(&handle).cloned().context("任务不存在，请重新开始或恢复记录")?;
            if op == "poll" {
                // Read finished before draining: if it becomes true during the drain, a later poll
                // still retrieves the terminal event before the client releases the handle.
                let finished = task.finished.load(Ordering::Acquire);
                let events: Vec<Value> = task.events.lock().map_err(|_| anyhow!("任务事件不可用"))?.drain(..).collect();
                Ok(json!({"ok":true,"events":events,"finished":finished}))
            } else {
                let _ = task.stop.send(true);
                if op == "release" { table.remove(&handle); }
                Ok(json!({"ok":true}))
            }
        },
        "start_receive" | "send" => {
            let receive = string(&value, "op")? == "start_receive";
            // Validate before allocating a task, so malformed requests never leak handles.
            let (inbox, host, port, source, journal, invitation) = if receive {
                let host: Ipv4Addr = string(&value, "host")?.parse()?;
                ensure!(multi_sync::identity::local_address(host), "请选择本机局域网 IPv4 地址");
                let port = value.get("port").map(|v| v.as_u64().context("端口无效")).transpose()?.unwrap_or(53318);
                ensure!(port <= 65535, "端口无效");
                (Some(path(&value, "inbox")?), host, port as u16, None, None, None)
            } else {
                let journal = path(&value, "journal")?;
                let source = if value.get("source").and_then(Value::as_str).is_some() { Some(path(&value, "source")?) } else { None };
                let ticket = value.get("ticket").and_then(Value::as_str).map(str::to_owned);
                if !journal.exists() {
                    ensure!(source.is_some(), "首次发送需要选择文件");
                    Ticket::decode(ticket.as_deref().context("请先扫码连接接收设备")?)?;
                }
                (None, Ipv4Addr::LOCALHOST, 0, source, Some(journal), ticket)
            };
            let rt = runtime()?;
            let (stop, mut stopped) = watch::channel(false);
            let task = Arc::new(Task { events:Mutex::new(VecDeque::new()), finished:AtomicBool::new(false), stop });
            let handle = Uuid::new_v4().to_string();
            {
                let mut table = tasks().lock().map_err(|_| anyhow!("任务管理器不可用"))?;
                ensure!(table.len() < 128, "本机活动任务过多，请先暂停或结束任务");
                table.insert(handle.clone(), task.clone());
            }
            let event_task = task.clone();
            let emit: EventSink = Arc::new(move |event| event_task.push(event));
            rt.spawn(async move {
                let result = if receive {
                    multi_sync::server::serve(inbox.unwrap(), SocketAddr::from(([0,0,0,0], port)), host, emit, stopped).await
                } else {
                    tokio::select! {
                        biased;
                        _ = async { while !*stopped.borrow() { if stopped.changed().await.is_err() { break; } } } => {
                            task.push(json!({"event":"stopped"}));
                            Ok(())
                        },
                        result = multi_sync::send::send(source, journal.unwrap(), invitation, emit) => result,
                    }
                };
                match result {
                    Err(error) => task.push(json!({"event":"error","message":format!("{error:#}")})),
                    Ok(()) if receive => task.push(json!({"event":"stopped"})),
                    _ => {},
                }
                task.finished.store(true, Ordering::Release);
            });
            Ok(json!({"ok":true,"handle":handle}))
        },
        _ => Err(anyhow!("不支持的操作")),
    }
}

/// Safe Rust entry point used by native contract tests and JNI.
pub fn call_json(request: &str) -> String {
    let result = std::panic::catch_unwind(|| -> Result<Value> {
        ensure!(request.len() <= 65536, "请求过长");
        invoke(serde_json::from_str(request)?)
    });
    let value = match result {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => json!({"ok":false,"error":format!("{error:#}")}),
        Err(_) => json!({"ok":false,"error":"引擎发生异常，任务记录已保留，请重试"}),
    };
    value.to_string()
}

/// # Safety
/// request must point to a valid NUL-terminated UTF-8 string for the duration of this call.
/// The result must be released exactly once with multisync_free.
#[no_mangle]
pub unsafe extern "C" fn multisync_call(request: *const c_char) -> *mut c_char {
    let result = if request.is_null() { json!({"ok":false,"error":"请求为空"}).to_string() }
    else { match CStr::from_ptr(request).to_str() {
        Ok(request) => call_json(request),
        Err(_) => json!({"ok":false,"error":"请求不是 UTF-8"}).to_string(),
    }};
    CString::new(result).expect("JSON encodes NUL characters").into_raw()
}
/// # Safety
/// response must be null or a live pointer returned by multisync_call, freed only once.
#[no_mangle]
pub unsafe extern "C" fn multisync_free(response: *mut c_char) {
    if !response.is_null() { drop(CString::from_raw(response)); }
}

#[cfg(feature = "android-jni")]
#[no_mangle]
pub extern "system" fn Java_local_multisync_NativeBridge_call(
    mut env: jni::JNIEnv, _class: jni::objects::JClass, request: jni::objects::JString,
) -> jni::sys::jstring {
    let result = match env.get_string(&request) {
        Ok(request) => call_json(&String::from(request)),
        Err(_) => json!({"ok":false,"error":"无法读取请求"}).to_string(),
    };
    match env.new_string(result) { Ok(value) => value.into_raw(), Err(_) => std::ptr::null_mut() }
}
