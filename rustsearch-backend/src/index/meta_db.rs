use anyhow::Result;
use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;
use std::{collections::HashMap, path::Path};

#[derive(Clone, Debug)]
pub struct FileMeta {
    pub path: String,
    pub display_path: String,
    pub size: u64,
    pub mtime: u64,
    pub mtime_ns: i64,
    pub ext: String,
    pub status: i64,
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::{
        path::PathBuf,
        sync::atomic::{AtomicU64, Ordering},
    };

    static NEXT: AtomicU64 = AtomicU64::new(0);
    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "rustsearch-meta-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }
    fn file(path: &str, status: i64) -> FileMeta {
        FileMeta {
            path: path.to_owned(),
            display_path: path.to_owned(),
            size: 7,
            mtime: 1,
            mtime_ns: 1,
            ext: "txt".into(),
            status,
        }
    }

    #[test]
    fn pending_operation_survives_reopen_and_extraction_failure() {
        let fixture = Fixture::new();
        let mut db = MetaDb::open(&fixture.0).unwrap();
        let path = "c:\\docs\\contract.txt";
        db.stage_paths(&[(path.into(), path.into())]).unwrap();
        drop(db);
        let mut db = MetaDb::open(&fixture.0).unwrap();
        assert!(db.pending_paths().unwrap().contains_key(path));
        db.save_batch(&[(file(path, 1), None)], &[]).unwrap();
        assert!(db.pending_paths().unwrap().contains_key(path));
        assert!(db.is_dirty().unwrap());
        let text = zstd::encode_all("\u{5408}\u{540c}".as_bytes(), 1).unwrap();
        db.save_batch(&[(file(path, 0), Some(text))], &[]).unwrap();
        assert!(db.pending_paths().unwrap().is_empty());
        assert!(!db.is_dirty().unwrap());
        assert_eq!(db.content(path).unwrap(), "\u{5408}\u{540c}");
    }

    #[test]
    fn completing_one_root_retains_offline_operations() {
        let fixture = Fixture::new();
        let mut db = MetaDb::open(&fixture.0).unwrap();
        let local = "c:\\docs\\new.txt";
        let offline = "z:\\docs\\new.txt";
        db.stage_paths(&[
            (local.into(), local.into()),
            (offline.into(), offline.into()),
        ])
        .unwrap();
        db.save_batch(&[], &[local.into()]).unwrap();
        let pending = db.pending_paths().unwrap();
        assert_eq!(pending.len(), 1);
        assert!(pending.contains_key(offline));
        assert!(db.is_dirty().unwrap());
    }

    #[test]
    fn metadata_failure_rolls_back_journal_completion() {
        let fixture = Fixture::new();
        let mut db = MetaDb::open(&fixture.0).unwrap();
        let first = "c:\\docs\\a.txt";
        let second = "c:\\docs\\b.txt";
        db.stage_paths(&[(first.into(), first.into()), (second.into(), second.into())])
            .unwrap();
        let mut bad = file(second, 0);
        bad.size = u64::MAX;
        let text = zstd::encode_all(b"ok".as_slice(), 1).unwrap();
        assert!(db
            .save_batch(
                &[(file(first, 0), Some(text.clone())), (bad, Some(text))],
                &[]
            )
            .is_err());
        assert_eq!(db.pending_paths().unwrap().len(), 2);
        assert!(db.all_files().unwrap().is_empty());
        assert_eq!(db.content(first).unwrap(), "");
    }

    #[test]
    fn removing_root_completes_pending_orphans() {
        let fixture = Fixture::new();
        let mut db = MetaDb::open(&fixture.0).unwrap();
        let root = "c:\\docs";
        let path = "c:\\docs\\orphan.txt";
        db.add_root(root, root).unwrap();
        db.stage_paths(&[(path.into(), path.into())]).unwrap();
        db.remove_root(root, &[path.into()]).unwrap();
        assert!(db.root_paths().unwrap().is_empty());
        assert!(db.pending_paths().unwrap().is_empty());
        assert!(!db.is_dirty().unwrap());
    }

    #[test]
    fn adding_existing_root_reports_no_insert() {
        let fixture = Fixture::new();
        let db = MetaDb::open(&fixture.0).unwrap();
        let root = "c:\\docs";
        assert!(db.add_root(root, root).unwrap());
        assert!(!db.add_root(root, root).unwrap());
        assert_eq!(db.root_paths().unwrap(), vec![root]);
    }

    #[test]
    fn root_count_requires_a_committed_content_record() {
        let fixture = Fixture::new();
        let mut db = MetaDb::open(&fixture.0).unwrap();
        let root = "c:\\docs";
        let path = "c:\\docs\\contract.txt";
        db.add_root(root, root).unwrap();
        db.save_batch(&[(file(path, 1), None)], &[]).unwrap();
        assert_eq!(db.roots().unwrap()[0].total_docs, 0);
        let text = zstd::encode_all(b"contract".as_slice(), 1).unwrap();
        db.save_batch(&[(file(path, 0), Some(text))], &[]).unwrap();
        assert_eq!(db.roots().unwrap()[0].total_docs, 1);
        db.save_batch(&[(file(path, 1), None)], &[]).unwrap();
        assert_eq!(db.roots().unwrap()[0].total_docs, 1);
        db.save_batch(&[(file(path, 3), None)], &[]).unwrap();
        assert_eq!(db.roots().unwrap()[0].total_docs, 0);
        assert!(db.content(path).unwrap().is_empty());
    }
}
#[derive(Clone, Debug, Serialize)]
pub struct Root {
    pub path: String,
    pub added_at: u64,
    pub total_docs: usize,
}
pub struct MetaDb {
    conn: Connection,
}
pub fn now() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
impl MetaDb {
    pub fn open(dir: &Path) -> Result<Self> {
        let conn = Connection::open(dir.join("meta.db"))?;
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        // WAL keeps readers independent from indexing. NORMAL avoids an fsync for every
        // metadata batch while retaining atomic transactions and crash recovery.
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;
            CREATE TABLE IF NOT EXISTS files(path TEXT PRIMARY KEY,display_path TEXT NOT NULL,size INTEGER NOT NULL,mtime INTEGER NOT NULL,mtime_ns INTEGER NOT NULL,ext TEXT NOT NULL,status INTEGER NOT NULL DEFAULT 0,indexed_at INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS roots(path TEXT PRIMARY KEY,display_path TEXT NOT NULL,added_at INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS contents(path TEXT PRIMARY KEY,compressed BLOB NOT NULL);
            CREATE TABLE IF NOT EXISTS history(query TEXT PRIMARY KEY,searched_at INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS pending_index_ops(path TEXT PRIMARY KEY,display_path TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS state(key TEXT PRIMARY KEY,value TEXT NOT NULL);")?;
        Ok(Self { conn })
    }
    pub fn all_files(&self) -> Result<HashMap<String, FileMeta>> {
        let mut stmt = self
            .conn
            .prepare("SELECT path,display_path,size,mtime,mtime_ns,ext,status FROM files")?;
        let records = stmt.query_map([], |r| {
            Ok(FileMeta {
                path: r.get(0)?,
                display_path: r.get(1)?,
                size: r.get(2)?,
                mtime: r.get(3)?,
                mtime_ns: r.get(4)?,
                ext: r.get(5)?,
                status: r.get(6)?,
            })
        })?;
        Ok(records
            .collect::<std::result::Result<Vec<_>, _>>()?
            .into_iter()
            .map(|f| (f.path.clone(), f))
            .collect())
    }
    pub fn save_batch(
        &mut self,
        records: &[(FileMeta, Option<Vec<u8>>)],
        removed: &[String],
    ) -> Result<()> {
        self.complete_batch(records, removed, None)
    }
    fn complete_batch(
        &mut self,
        records: &[(FileMeta, Option<Vec<u8>>)],
        removed: &[String],
        removed_root: Option<&str>,
    ) -> Result<()> {
        let tx = self.conn.transaction()?;
        if let Some(root) = removed_root {
            tx.execute("DELETE FROM roots WHERE path=?1", params![root])?;
        }
        for path in removed {
            tx.execute("DELETE FROM files WHERE path=?1", params![path])?;
            tx.execute("DELETE FROM contents WHERE path=?1", params![path])?;
            tx.execute("DELETE FROM pending_index_ops WHERE path=?1", params![path])?;
        }
        for (m, content) in records {
            tx.execute("INSERT INTO files VALUES(?1,?2,?3,?4,?5,?6,?7,?8) ON CONFLICT(path) DO UPDATE SET display_path=excluded.display_path,size=excluded.size,mtime=excluded.mtime,mtime_ns=excluded.mtime_ns,ext=excluded.ext,status=excluded.status,indexed_at=excluded.indexed_at",
                params![m.path,m.display_path,m.size,m.mtime,m.mtime_ns,m.ext,m.status,now()])?;
            if let Some(content) = content {
                tx.execute(
                    "INSERT OR REPLACE INTO contents VALUES(?1,?2)",
                    params![m.path, content],
                )?;
            }
            if m.status == 3 {
                tx.execute("DELETE FROM contents WHERE path=?1", params![m.path])?;
            }
            if content.is_some() || m.status == 3 {
                tx.execute(
                    "DELETE FROM pending_index_ops WHERE path=?1",
                    params![m.path],
                )?;
            }
        }
        tx.execute(
            "DELETE FROM state WHERE key='dirty' AND NOT EXISTS(SELECT 1 FROM pending_index_ops)",
            [],
        )?;
        tx.commit()?;
        Ok(())
    }
    pub fn stage_paths(&mut self, paths: &[(String, String)]) -> Result<()> {
        if paths.is_empty() {
            return Ok(());
        }
        let tx = self.conn.transaction()?;
        for (path, display_path) in paths {
            tx.execute(
                "INSERT OR REPLACE INTO pending_index_ops VALUES(?1,?2)",
                params![path, display_path],
            )?;
        }
        tx.execute("INSERT OR REPLACE INTO state VALUES('dirty','1')", [])?;
        tx.commit()?;
        Ok(())
    }
    pub fn pending_paths(&self) -> Result<HashMap<String, String>> {
        let mut stmt = self
            .conn
            .prepare("SELECT path,display_path FROM pending_index_ops")?;
        let rows = stmt
            .query_map([], |row| Ok((row.get(0)?, row.get(1)?)))?
            .collect::<std::result::Result<HashMap<_, _>, _>>()?;
        Ok(rows)
    }
    pub fn content(&self, path: &str) -> Result<String> {
        let bytes: Option<Vec<u8>> = self
            .conn
            .query_row(
                "SELECT compressed FROM contents WHERE path=?1",
                params![path],
                |r| r.get(0),
            )
            .optional()?;
        match bytes {
            Some(b) => Ok(String::from_utf8(zstd::decode_all(b.as_slice())?)?),
            None => Ok(String::new()),
        }
    }
    pub fn roots(&self) -> Result<Vec<Root>> {
        let mut stmt = self
            .conn
            .prepare("SELECT path,display_path,added_at FROM roots ORDER BY display_path")?;
        let records = stmt
            .query_map([], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, u64>(2)?,
                ))
            })?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        let mut stmt = self.conn.prepare("SELECT files.path FROM files INNER JOIN contents ON files.path=contents.path WHERE files.status<>3")?;
        let files = stmt
            .query_map([], |row| row.get::<_, String>(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(records
            .into_iter()
            .map(|(key, path, added_at)| Root {
                path,
                added_at,
                total_docs: files
                    .iter()
                    .filter(|path| crate::path_utils::within(path, &key))
                    .count(),
            })
            .collect())
    }
    pub fn add_root(&self, key: &str, path: &str) -> Result<bool> {
        let inserted = self.conn.execute(
            "INSERT OR IGNORE INTO roots VALUES(?1,?2,?3)",
            params![key, path, now()],
        )?;
        Ok(inserted != 0)
    }
    pub fn root_paths(&self) -> Result<Vec<String>> {
        let mut stmt = self
            .conn
            .prepare("SELECT display_path FROM roots ORDER BY display_path")?;
        let rows = stmt
            .query_map([], |r| r.get(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }
    pub fn remove_root(&mut self, key: &str, removed: &[String]) -> Result<()> {
        self.complete_batch(&[], removed, Some(key))
    }
    pub fn failed_count(&self) -> Result<u64> {
        Ok(self.conn.query_row(
            "SELECT COUNT(*) FROM files WHERE status=1 OR status=3",
            [],
            |r| r.get(0),
        )?)
    }
    pub fn mark_dirty(&self) -> Result<()> {
        self.conn
            .execute("INSERT OR REPLACE INTO state VALUES('dirty','1')", [])?;
        Ok(())
    }
    pub fn is_dirty(&self) -> Result<bool> {
        Ok(self.conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM state WHERE key='dirty')",
            [],
            |r| r.get(0),
        )?)
    }
    pub fn history(&self) -> Result<Vec<String>> {
        let mut stmt = self
            .conn
            .prepare("SELECT query FROM history ORDER BY searched_at DESC LIMIT 50")?;
        let rows = stmt
            .query_map([], |r| r.get(0))?
            .collect::<std::result::Result<Vec<_>, _>>()?;
        Ok(rows)
    }
    pub fn record_query(&self, query: &str) -> Result<()> {
        if query.trim().is_empty() {
            return Ok(());
        }
        self.conn.execute(
            "INSERT OR REPLACE INTO history VALUES(?1,?2)",
            params![
                query,
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_millis() as i64
            ],
        )?;
        self.conn.execute("DELETE FROM history WHERE query NOT IN (SELECT query FROM history ORDER BY searched_at DESC LIMIT 50)",[])?;
        Ok(())
    }
}
