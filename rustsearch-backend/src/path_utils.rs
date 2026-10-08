use anyhow::{Context, Result};
use std::{
    fs,
    path::{Path, PathBuf},
};

pub fn display_path(path: &Path) -> String {
    let raw = path.to_string_lossy();
    let raw = if let Some(unc) = raw.strip_prefix("\\\\?\\UNC\\") {
        format!("\\\\{unc}")
    } else {
        raw.strip_prefix("\\\\?\\").unwrap_or(&raw).to_owned()
    };
    #[cfg(windows)]
    let mut raw = raw.replace('/', "\\");
    #[cfg(not(windows))]
    let mut raw = raw;
    if raw.as_bytes().get(1) == Some(&b':') {
        raw.replace_range(..1, &raw[..1].to_ascii_uppercase());
    }
    raw
}
pub fn key(path: &Path) -> String {
    display_path(path).to_lowercase()
}
pub fn canonical(path: &Path) -> Result<PathBuf> {
    Ok(PathBuf::from(display_path(
        &fs::canonicalize(path).with_context(|| format!("Path unavailable: {}", path.display()))?,
    )))
}
pub fn within(path: &str, root: &str) -> bool {
    if path == root {
        return true;
    }
    let root = root.trim_end_matches(['/', '\\']);
    path.strip_prefix(root)
        .is_some_and(|suffix| suffix.starts_with(['/', '\\']))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn root_boundaries() {
        assert!(within("c:\\docs\\a.txt", "c:\\docs"));
        assert!(!within("c:\\docs-other\\a.txt", "c:\\docs"));
        assert!(within("c:\\a.txt", "c:\\"));
    }
    #[test]
    fn extended_paths() {
        assert_eq!(
            display_path(Path::new("\\\\?\\c:\\Docs\\A.txt")),
            "C:\\Docs\\A.txt"
        );
        assert_eq!(key(Path::new("C:\\Docs\\A.txt")), "c:\\docs\\a.txt");
        assert_eq!(
            display_path(Path::new("\\\\?\\UNC\\server\\share\\A.txt")),
            "\\\\server\\share\\A.txt"
        );
    }
}
