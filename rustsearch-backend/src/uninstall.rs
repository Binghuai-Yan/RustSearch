use anyhow::{ensure, Context, Result};
use rusqlite::{Connection, OpenFlags};
use serde::Deserialize;
use std::{
    env, fs, io,
    path::{Path, PathBuf},
};

#[derive(Deserialize)]
struct UiSettings {
    data_directory: PathBuf,
}

fn selected_data_directory() -> Result<PathBuf> {
    let default = PathBuf::from(env::var_os("LOCALAPPDATA").context("LOCALAPPDATA is not set")?)
        .join("RustSearch");
    if let Some(override_path) = env::var_os("RUSTSEARCH_DATA_DIR") {
        return Ok(PathBuf::from(override_path));
    }
    let preferences = env::var_os("RUSTSEARCH_PREFERENCES_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| default.clone());
    let settings_path = preferences.join("ui-settings.json");
    if !path_exists(&settings_path)? {
        return Ok(default);
    }
    let settings: UiSettings = serde_json::from_slice(&fs::read(&settings_path)?)
        .with_context(|| format!("Invalid {}", settings_path.display()))?;
    ensure!(
        !settings.data_directory.as_os_str().is_empty(),
        "Empty data directory"
    );
    ensure!(
        settings.data_directory.is_absolute(),
        "Data directory must be absolute"
    );
    Ok(settings.data_directory)
}

pub fn remove_user_index() -> Result<()> {
    remove_index_in(&selected_data_directory()?)
}

pub fn remove_user_data() -> Result<()> {
    let data_directory = selected_data_directory()?;
    let preferences = env::var_os("RUSTSEARCH_PREFERENCES_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            PathBuf::from(env::var_os("LOCALAPPDATA").unwrap_or_default()).join("RustSearch")
        });
    remove_user_data_in(&data_directory, &preferences)
}

fn remove_user_data_in(data_directory: &Path, preferences: &Path) -> Result<()> {
    remove_index_in(data_directory)?;
    for name in [
        "config.json",
        "user_dict.txt",
        "ui-preferences.json",
        "ui-theme.txt",
        "winui-layout.json",
    ] {
        remove_managed_file(&data_directory.join(name))?;
    }
    remove_managed_file(&preferences.join("ui-settings.json"))?;
    Ok(())
}

fn remove_managed_file(path: &Path) -> Result<()> {
    if !path_exists(path)? {
        return Ok(());
    }
    ensure!(
        fs::symlink_metadata(path)?.file_type().is_file(),
        "Not a regular RustSearch file: {}",
        path.display()
    );
    fs::remove_file(path).with_context(|| format!("Cannot remove {}", path.display()))
}

fn remove_index_in(data_directory: &Path) -> Result<()> {
    if !path_exists(data_directory)? {
        return Ok(());
    }
    let data_directory = fs::canonicalize(data_directory)
        .with_context(|| format!("Cannot resolve {}", data_directory.display()))?;
    ensure!(data_directory.is_dir(), "Data directory is not a folder");

    let index = data_directory.join("index");
    let database = data_directory.join("meta.db");
    let has_index = path_exists(&index)?;
    let has_database = path_exists(&database)?;

    // Validate both stores before removing either one. A custom data directory may
    // contain unrelated files with the same names.
    if has_index {
        ensure!(
            fs::symlink_metadata(&index)?.file_type().is_dir(),
            "Index is not a regular directory"
        );
        let resolved = fs::canonicalize(&index)?;
        ensure!(
            crate::path_utils::key(&resolved) == crate::path_utils::key(&index),
            "Index directory redirects outside its expected location"
        );
        ensure!(
            index.join("meta.json").is_file() && index.join(".managed.json").is_file(),
            "Index directory is not a Tantivy index"
        );
        ensure!(
            tantivy::Index::open_in_dir(&index)?.schema()
                == crate::index::schema::AppSchema::build().0,
            "Index schema is not a RustSearch schema"
        );
    }
    if has_database {
        ensure!(
            fs::symlink_metadata(&database)?.file_type().is_file(),
            "Metadata database is not a regular file"
        );
        let connection = Connection::open_with_flags(&database, OpenFlags::SQLITE_OPEN_READ_ONLY)?;
        let tables: i64 = connection.query_row(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND name IN ('files', 'roots')",
            [],
            |row| row.get(0),
        )?;
        ensure!(
            tables == 2,
            "Metadata database is not a RustSearch database"
        );
    }
    let sidecars = ["-wal", "-shm"].map(|suffix| data_directory.join(format!("meta.db{suffix}")));
    if has_database {
        for sidecar in &sidecars {
            if path_exists(sidecar)? {
                ensure!(
                    fs::symlink_metadata(sidecar)?.file_type().is_file(),
                    "SQLite sidecar is not a regular file: {}",
                    sidecar.display()
                );
            }
        }
    }
    if !has_index && !has_database {
        return Ok(());
    }
    if has_index {
        fs::remove_dir_all(&index).with_context(|| format!("Cannot remove {}", index.display()))?;
    }
    if has_database {
        fs::remove_file(&database)
            .with_context(|| format!("Cannot remove {}", database.display()))?;
        for sidecar in sidecars {
            if path_exists(&sidecar)? {
                fs::remove_file(&sidecar)
                    .with_context(|| format!("Cannot remove {}", sidecar.display()))?;
            }
        }
    }
    Ok(())
}

fn path_exists(path: &Path) -> Result<bool> {
    match fs::symlink_metadata(path) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error).with_context(|| format!("Cannot inspect {}", path.display())),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::index::meta_db::MetaDb;
    use tempfile::tempdir;

    #[test]
    fn removes_application_settings_but_keeps_unrelated_files() {
        let temp = tempdir().unwrap();
        let data = temp.path().join("data");
        let preferences = temp.path().join("preferences");
        fs::create_dir_all(&data).unwrap();
        fs::create_dir_all(&preferences).unwrap();
        let index = data.join("index");
        fs::create_dir(&index).unwrap();
        tantivy::Index::create_in_dir(&index, crate::index::schema::AppSchema::build().0).unwrap();
        drop(MetaDb::open(&data).unwrap());
        for name in [
            "config.json",
            "user_dict.txt",
            "ui-preferences.json",
            "ui-theme.txt",
            "winui-layout.json",
        ] {
            fs::write(data.join(name), b"managed").unwrap();
        }
        fs::write(preferences.join("ui-settings.json"), b"managed").unwrap();
        fs::write(data.join("personal.txt"), b"keep").unwrap();

        remove_user_data_in(&data, &preferences).unwrap();

        assert!(!index.exists());
        assert!(!data.join("meta.db").exists());
        assert!(!data.join("config.json").exists());
        assert!(!data.join("user_dict.txt").exists());
        assert!(!data.join("ui-preferences.json").exists());
        assert!(!data.join("ui-theme.txt").exists());
        assert!(!data.join("winui-layout.json").exists());
        assert!(!preferences.join("ui-settings.json").exists());
        assert_eq!(fs::read(data.join("personal.txt")).unwrap(), b"keep");
    }

    #[test]
    fn removes_only_rustsearch_index_files() {
        let temp = tempdir().unwrap();
        let data = temp.path();
        let index = data.join("index");
        fs::create_dir(&index).unwrap();
        tantivy::Index::create_in_dir(&index, crate::index::schema::AppSchema::build().0).unwrap();
        drop(MetaDb::open(data).unwrap());
        fs::write(data.join("keep.txt"), b"keep").unwrap();
        fs::write(data.join("meta.db-wal"), b"wal").unwrap();
        fs::write(data.join("meta.db-shm"), b"shm").unwrap();

        remove_index_in(data).unwrap();

        assert!(!index.exists());
        assert!(!data.join("meta.db").exists());
        assert!(!data.join("meta.db-wal").exists());
        assert!(!data.join("meta.db-shm").exists());
        assert_eq!(fs::read(data.join("keep.txt")).unwrap(), b"keep");
    }

    #[test]
    fn refuses_unrelated_index_directory() {
        let temp = tempdir().unwrap();
        let index = temp.path().join("index");
        fs::create_dir(&index).unwrap();
        fs::write(index.join("personal.txt"), b"keep").unwrap();

        assert!(remove_index_in(temp.path()).is_err());
        assert!(index.join("personal.txt").exists());
    }

    #[test]
    fn validates_sidecars_before_removing_anything() {
        let temp = tempdir().unwrap();
        let data = temp.path();
        let index = data.join("index");
        fs::create_dir(&index).unwrap();
        tantivy::Index::create_in_dir(&index, crate::index::schema::AppSchema::build().0).unwrap();
        drop(MetaDb::open(data).unwrap());
        fs::create_dir(data.join("meta.db-wal")).unwrap();

        assert!(remove_index_in(data).is_err());
        assert!(index.exists());
        assert!(data.join("meta.db").exists());
        assert!(data.join("meta.db-wal").is_dir());
    }
}
