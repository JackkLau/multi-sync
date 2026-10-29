use multi_sync_core::{hash_bytes, Manifest, Store, validate_name};
use std::{fs, io::Write};
use tempfile::tempdir;
use uuid::Uuid;

fn manifest(bytes: &[u8]) -> Manifest {
    Manifest { id: Uuid::new_v4(), name: "照片.jpg".into(), size: bytes.len() as u64, sha256: hash_bytes(bytes) }
}

#[test]
fn explicit_acceptance_restart_and_atomic_no_overwrite() {
    let root = tempdir().unwrap();
    let bytes = b"hello reliable world";
    let m = manifest(bytes);
    fs::write(root.path().join(&m.name), b"existing content").unwrap();
    {
        let mut store = Store::open(root.path()).unwrap();
        assert_eq!(store.offer(&m).unwrap().state, "pending");
        assert!(store.chunk(m.id, 0, &bytes[..5], &hash_bytes(&bytes[..5])).is_err());
        store.approve(m.id).unwrap();
        assert_eq!(store.chunk(m.id, 0, &bytes[..5], &hash_bytes(&bytes[..5])).unwrap().offset, 5);
    }
    // Model power loss after disk write but before checkpoint commit.
    let part = root.path().join(".multisync").join(format!("{}.part", m.id));
    fs::OpenOptions::new().append(true).open(part).unwrap().write_all(b"uncommitted").unwrap();
    let mut store = Store::open(root.path()).unwrap();
    assert_eq!(store.get(m.id).unwrap().offset, 5);
    // A lost ACK is a duplicate, never an append of the same bytes.
    assert_eq!(store.chunk(m.id, 0, &bytes[..5], &hash_bytes(&bytes[..5])).unwrap().offset, 5);
    store.chunk(m.id, 5, &bytes[5..], &hash_bytes(&bytes[5..])).unwrap();
    let result = store.complete(m.id).unwrap();
    assert_eq!(result.state, "completed");
    assert_eq!(fs::read(root.path().join(result.final_name.unwrap())).unwrap(), bytes);
    assert_eq!(fs::read(root.path().join(&m.name)).unwrap(), b"existing content");
    assert_eq!(store.complete(m.id).unwrap().state, "completed");
}

#[test]
fn corrupt_chunk_wrong_offset_and_full_digest_never_publish() {
    let root = tempdir().unwrap();
    let mut store = Store::open(root.path()).unwrap();
    let m = manifest(b"hello");
    store.offer(&m).unwrap(); store.approve(m.id).unwrap();
    assert!(store.chunk(m.id, 0, b"bad!!", &hash_bytes(b"hello")).is_err());
    assert!(store.chunk(m.id, 1, b"hello", &hash_bytes(b"hello")).is_err());
    assert_eq!(store.get(m.id).unwrap().offset, 0);
    store.chunk(m.id, 0, b"wrong", &hash_bytes(b"wrong")).unwrap();
    assert!(store.complete(m.id).is_err());
    assert!(!root.path().join(&m.name).exists());
    assert_eq!(store.get(m.id).unwrap().offset, 0); // ready to retransmit
}

#[test]
fn zero_bytes_idempotency_and_manifest_collision() {
    let root = tempdir().unwrap();
    let mut store = Store::open(root.path()).unwrap();
    let m = manifest(b"");
    store.offer(&m).unwrap();
    let mut different = m.clone(); different.name = "different".into();
    assert!(store.offer(&different).is_err());
    store.approve(m.id).unwrap();
    assert_eq!(store.complete(m.id).unwrap().state, "completed");
    assert_eq!(store.offer(&m).unwrap().state, "completed");
}

#[test]
fn cancellation_and_unapproved_jobs_survive_restart() {
    let root = tempdir().unwrap();
    let m = manifest(b"abc");
    let mut store = Store::open(root.path()).unwrap();
    store.offer(&m).unwrap(); store.reject(m.id).unwrap(); drop(store);
    let mut store = Store::open(root.path()).unwrap();
    assert_eq!(store.get(m.id).unwrap().state, "cancelled");
    assert!(store.approve(m.id).is_err());
    assert!(store.chunk(m.id, 0, b"abc", &hash_bytes(b"abc")).is_err());
    assert!(!root.path().join(&m.name).exists());
}

#[test]
fn unsafe_names_are_rejected() {
    for name in ["../escape", "a/b", "a\\b", ".", "..", "CON.txt", "lpt1", "NUL", "COM¹.txt", "a:", "foo.", "foo ", ".multisync", "a\0b"] {
        assert!(validate_name(name).is_err(), "accepted {name:?}");
    }
    assert!(validate_name("家庭照片 2026.jpg").is_ok());
}

#[cfg(unix)]
#[test]
fn symlink_state_directory_is_rejected() {
    let root = tempdir().unwrap(); let outside = tempdir().unwrap();
    std::os::unix::fs::symlink(outside.path(), root.path().join(".multisync")).unwrap();
    assert!(Store::open(root.path()).is_err());
}

#[test]
fn crash_after_publication_before_final_checkpoint_recovers() {
    let root = tempdir().unwrap();
    let bytes = b"published but not acknowledged";
    let m = manifest(bytes);
    let mut store = Store::open(root.path()).unwrap();
    store.offer(&m).unwrap(); store.approve(m.id).unwrap();
    store.chunk(m.id, 0, bytes, &hash_bytes(bytes)).unwrap();
    drop(store);
    let db = rusqlite::Connection::open(root.path().join(".multisync/tasks.sqlite3")).unwrap();
    db.execute("UPDATE transfers SET state='committing',final_name=?2 WHERE id=?1", rusqlite::params![m.id.to_string(), m.name]).unwrap();
    fs::hard_link(root.path().join(format!(".multisync/{}.part", m.id)), root.path().join(&m.name)).unwrap();
    drop(db);
    let mut store = Store::open(root.path()).unwrap();
    assert_eq!(store.complete(m.id).unwrap().state, "completed");
    assert_eq!(fs::read(root.path().join(&m.name)).unwrap(), bytes);
}

#[test]
fn missing_checkpoint_bytes_are_never_silently_replaced() {
    let root = tempdir().unwrap();
    let mut store = Store::open(root.path()).unwrap();
    let m = manifest(b"hello world");
    store.offer(&m).unwrap(); store.approve(m.id).unwrap();
    store.chunk(m.id, 0, b"hello", &hash_bytes(b"hello")).unwrap();
    fs::write(root.path().join(format!(".multisync/{}.part", m.id)), b"he").unwrap();
    assert!(store.chunk(m.id, 5, b" world", &hash_bytes(b" world")).is_err());
    assert_eq!(store.get(m.id).unwrap().offset, 5);
}
