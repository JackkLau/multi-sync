# Native bridge v1

All clients use the same Rust engine and LAN protocol. Mobile clients run it in-process while active; they do not spawn a desktop CLI. Source files are never deleted. Receiver approval is always required per file.

## C / JNI boundary

Library product: `multi_sync_bridge` (`.so`, `.dll`, or static `.a`).

```c
char *multisync_call(const char *request_json);
void multisync_free(char *response_json);
```

Input is a UTF-8 NUL-terminated JSON object. Output is owned UTF-8 JSON; copy it then always call `multisync_free`. Do not call free on any other pointer. Errors are `{ "ok": false, "error": "human-readable message" }`; no exception crosses the ABI. Long transfers start asynchronously. Poll from a timer, and do filesystem calls off the UI thread.

Android JNI: `package local.multisync; object NativeBridge { init { System.loadLibrary("multi_sync_bridge") }; @JvmStatic external fun call(request: String): String }`. Build Rust with `--features android-jni`. JNI returns a managed String.

| Request | Success response |
| --- | --- |
| `{"op":"start_receive","inbox":"absolute path","host":"192.168.1.8","port":53318}` | `{"ok":true,"handle":"uuid"}` |
| `{"op":"send","source":"absolute path","journal":"absolute path","ticket":"msync1:..."}` | `{"ok":true,"handle":"uuid"}` |
| `{"op":"send","journal":"existing absolute journal path"}` | resume using persisted journal; same handle response |
| `{"op":"poll","handle":"uuid"}` | `{"ok":true,"events":[...],"finished":false}`; drains available events |
| `{"op":"stop","handle":"uuid"}` | requests receiver shutdown or pauses sender, `{"ok":true}` |
| `{"op":"release","handle":"uuid"}` | stops and removes handle; call after consuming terminal events |
| `{"op":"jobs","inbox":"absolute path"}` | `{"ok":true,"jobs":[Transfer...]}` |
| `{"op":"approve","inbox":"absolute path","id":"uuid"}` | `{"ok":true,"job":Transfer}` |
| `{"op":"reject","inbox":"absolute path","id":"uuid"}` | same response |
| `{"op":"validate_ticket","ticket":"msync1:..."}` | `{"ok":true,"host":"192.168.1.8","port":53318}`; reject invalid/private-address/TLS certificate data |

Events follow protocol-v1.md: `ready` contains `ticket`, `address`; `hashing`, `waiting`, `progress`, `verifying`, `completed`, `error`. `stopped` is a terminal event for a receiver or cancelled sender. Error event contains `message`. `finished` tells clients to stop polling and release. Transfer shape: flattened `id,name,size,sha256,offset,state,final_name`.

Select a non-loopback private IPv4 from native network interfaces; allow the user to choose if there is more than one. Never advertise 0.0.0.0. Core binds 0.0.0.0 at the requested port (0 is supported for tests).

## UI contract

- Receive page needs no invitation input. Start receiving with local storage and local address; on ready display generated QR and buttons **复制接收码**, **分享二维码** (native share or save image).
- Send page prioritizes **扫码连接** / **从二维码图片识别**; **从剪贴板粘贴** is an explicit optional fallback. Mask raw tickets. Never auto-read clipboard or auto-send after scanning.
- QR text is the complete msync1 invitation (same as copied text), black/white with at least four modules quiet zone. Validate before changing current destination, and reject multiple different invitations in one image.
- Persist outgoing job records and staged source files in app-private durable storage before starting. On restart show unfinished tasks as paused and resume existing journals. Use a UUID subfolder while keeping the original safe filename. Do not delete user's source.
- Received files live in app-owned Documents/Inbox on mobile, chosen or standard Downloads/Inbox on desktop. Provide native open/export/share. Only completed jobs may be opened/shared.
- Show actual error and waiting-for-acceptance states, honest byte progress, pause/resume, explicit accept/reject controls. Concurrent starts are guarded.
- Mobile foreground lifecycle only: stop receiving and pause outgoing work when OS/background policy requires; explain this and preserve task state. iOS must not promise permanent listening.
- Chinese UI, teal #096C74, ink #183238, pale canvas #F4F8F9, native controls, adaptive phone/tablet layout.
