use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use std::{
    env, fs,
    path::{Path, PathBuf},
};

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default, deny_unknown_fields)]
pub struct Config {
    pub max_file_size_mb: u64,
    pub skip_dirs: Vec<String>,
    pub user_dictionary: String,
    pub paused: bool,
    pub ocr_enabled: bool,
    pub ocr_images: bool,
    pub ocr_pdf: bool,
    pub ocr_max_pages: u32,
}
impl Default for Config {
    fn default() -> Self {
        Self {
            max_file_size_mb: 200,
            skip_dirs: [
                "node_modules",
                ".git",
                "__pycache__",
                "$RECYCLE.BIN",
                "System Volume Information",
                "target",
                "venv",
                ".venv",
            ]
            .into_iter()
            .map(str::to_string)
            .collect(),
            user_dictionary: String::new(),
            paused: false,
            ocr_enabled: false,
            ocr_images: true,
            ocr_pdf: true,
            ocr_max_pages: 100,
        }
    }
}
impl Config {
    pub fn load(dir: &Path) -> Result<Self> {
        fs::create_dir_all(dir)?;
        let path = dir.join("config.json");
        let mut config: Self = if path.exists() {
            serde_json::from_slice(&fs::read(&path)?).context("Invalid config.json")?
        } else {
            Self::default()
        };
        if dir.join("user_dict.txt").exists() {
            config.user_dictionary = fs::read_to_string(dir.join("user_dict.txt"))?;
        }
        config.validate()?;
        config.save(dir)?;
        Ok(config)
    }
    pub fn validate(&self) -> Result<()> {
        if !(1..=2048).contains(&self.max_file_size_mb) {
            bail!("max_file_size_mb must be between 1 and 2048");
        }
        if self
            .skip_dirs
            .iter()
            .any(|d| d.is_empty() || d.contains(['/', '\\']))
        {
            bail!("skip_dirs must contain directory names");
        }
        if self.user_dictionary.len() > 1024 * 1024 {
            bail!("user dictionary exceeds 1 MB");
        }
        if !(1..=500).contains(&self.ocr_max_pages) {
            bail!("ocr_max_pages must be between 1 and 500");
        }
        Ok(())
    }
    pub fn save(&self, dir: &Path) -> Result<()> {
        self.validate()?;
        atomic_write(&dir.join("config.json"), &serde_json::to_vec_pretty(self)?)?;
        atomic_write(&dir.join("user_dict.txt"), self.user_dictionary.as_bytes())
    }
    pub fn patch(&self, value: serde_json::Value) -> Result<Self> {
        let mut merged = serde_json::to_value(self)?;
        let object = value
            .as_object()
            .context("config params must be an object")?;
        for (key, value) in object {
            merged[key] = value.clone();
        }
        let result: Self = serde_json::from_value(merged)?;
        result.validate()?;
        Ok(result)
    }
}
fn atomic_write(path: &Path, bytes: &[u8]) -> Result<()> {
    let temporary = path.with_extension("tmp");
    fs::write(&temporary, bytes)?;
    fs::rename(&temporary, path).with_context(|| format!("Cannot save {}", path.display()))
}
pub fn data_dir() -> Result<PathBuf> {
    if let Some(path) = env::var_os("RUSTSEARCH_DATA_DIR") {
        return Ok(PathBuf::from(path));
    }
    Ok(
        PathBuf::from(env::var_os("LOCALAPPDATA").context("LOCALAPPDATA is not set")?)
            .join("RustSearch"),
    )
}
