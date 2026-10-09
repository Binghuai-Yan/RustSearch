use super::ExtractResult;
use anyhow::{ensure, Result};
use std::path::Path;

pub fn extract(path: &Path) -> Result<ExtractResult> {
    let (width, height) = image::image_dimensions(path)?;
    ensure!(width > 0 && height > 0, "image has no pixels");
    ensure!(
        u64::from(width) * u64::from(height) <= 25_000_000,
        "image exceeds 25 megapixels"
    );
    Ok(ExtractResult {
        needs_ocr: true,
        ..ExtractResult::default()
    })
}
