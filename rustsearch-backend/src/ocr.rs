use crate::{extract::MAX_TEXT_SIZE, index::Engine};
use anyhow::{bail, ensure, Context, Result};
use pdfium_render::prelude::*;
use serde::{Deserialize, Serialize};
use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{atomic::Ordering, Arc},
    thread::JoinHandle,
    time::{Duration, Instant},
};

#[derive(Debug, Default, Serialize, Deserialize)]
pub struct OcrResult {
    pub pages: Vec<OcrPage>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct OcrPage {
    pub number: u32,
    pub text: String,
}

fn runtime_dir() -> Result<PathBuf> {
    if let Some(path) = std::env::var_os("RUSTSEARCH_OCR_RUNTIME_DIR") {
        return Ok(PathBuf::from(path));
    }
    let executable = std::env::current_exe()?;
    let backend = executable
        .parent()
        .context("Backend directory is missing")?;
    let local = backend.join("OCR");
    if local.is_dir() {
        return Ok(local);
    }
    // The WPF compatibility backend shares the main package's OCR runtime.
    Ok(backend
        .parent()
        .and_then(Path::parent)
        .context("Application directory is missing")?
        .join("Backend/OCR"))
}

fn tesseract(input: &Path, runtime: &Path, timeout: Duration) -> Result<String> {
    let temp = tempfile::tempdir()?;
    let output = temp.path().join("page");
    let error_path = temp.path().join("stderr.txt");
    let executable = runtime.join("tesseract.exe");
    ensure!(executable.is_file(), "Tesseract OCR runtime is missing");
    ensure!(
        runtime.join("tessdata/chi_sim.traineddata").is_file(),
        "Chinese OCR data is missing"
    );
    ensure!(
        runtime.join("tessdata/eng.traineddata").is_file(),
        "English OCR data is missing"
    );
    let mut command = Command::new(executable);
    command
        .arg(input)
        .arg(&output)
        .arg("-l")
        .arg("chi_sim+eng")
        .arg("--tessdata-dir")
        .arg(runtime.join("tessdata"))
        .current_dir(runtime)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::from(fs::File::create(&error_path)?));
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }
    let mut child = command.spawn().context("Cannot launch Tesseract")?;
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait()? {
            let message = fs::read_to_string(&error_path).unwrap_or_default();
            ensure!(
                status.success(),
                "Tesseract exited with {status}: {}",
                message.chars().take(2000).collect::<String>()
            );
            let bytes = fs::read(output.with_extension("txt"))?;
            ensure!(bytes.len() <= MAX_TEXT_SIZE, "OCR text exceeds 8 MB");
            return Ok(String::from_utf8_lossy(&bytes).trim().to_owned());
        }
        if started.elapsed() >= timeout {
            let _ = child.kill();
            let _ = child.wait();
            bail!("Tesseract timed out");
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn recognize(path: &Path, max_pages: u32) -> Result<OcrResult> {
    let runtime = runtime_dir()?;
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or_default()
        .to_ascii_lowercase();
    if ext != "pdf" {
        let (width, height) = image::image_dimensions(path)?;
        ensure!(
            u64::from(width) * u64::from(height) <= 25_000_000,
            "image exceeds 25 megapixels"
        );
        let text = tesseract(path, &runtime, Duration::from_secs(30))?;
        return Ok(OcrResult {
            pages: text
                .split('\u{c}')
                .enumerate()
                .filter_map(|(index, part)| {
                    let part = part.trim();
                    (!part.is_empty()).then(|| OcrPage {
                        number: index as u32 + 1,
                        text: part.to_owned(),
                    })
                })
                .collect(),
        });
    }
    let bindings = Pdfium::bind_to_library(runtime.join("pdfium.dll"))
        .context("Cannot load PDFium OCR renderer")?;
    let pdfium = Pdfium::new(bindings);
    let document = pdfium.load_pdf_from_file(path, None)?;
    ensure!(
        document.pages().len() >= 0 && document.pages().len() as u32 <= max_pages,
        "PDF exceeds OCR page limit"
    );
    let render = PdfRenderConfig::new()
        .set_target_width(1800)
        .set_maximum_height(2400);
    let mut result = OcrResult::default();
    let mut text_bytes = 0usize;
    for (index, page) in document.pages().iter().enumerate() {
        let existing = page.text()?.all();
        if existing.chars().filter(|ch| ch.is_alphanumeric()).count() >= 20 {
            continue;
        }
        let image = page.render_with_config(&render)?.as_image()?;
        ensure!(
            u64::from(image.width()) * u64::from(image.height()) <= 25_000_000,
            "PDF page exceeds 25 megapixels"
        );
        let temp = tempfile::tempdir()?;
        let bitmap = temp.path().join("page.png");
        image.save_with_format(&bitmap, image::ImageFormat::Png)?;
        let text = tesseract(&bitmap, &runtime, Duration::from_secs(30))?;
        text_bytes += text.len();
        ensure!(text_bytes <= MAX_TEXT_SIZE, "OCR text exceeds 8 MB");
        if !text.is_empty() {
            result.pages.push(OcrPage {
                number: index as u32 + 1,
                text,
            });
        }
    }
    Ok(result)
}

pub fn run_child() -> Result<()> {
    let mut args = std::env::args_os().skip(2);
    let path = PathBuf::from(args.next().context("Missing OCR input")?);
    let output = PathBuf::from(args.next().context("Missing OCR output")?);
    let max_pages = args
        .next()
        .context("Missing OCR page limit")?
        .to_string_lossy()
        .parse::<u32>()?;
    let value = match recognize(&path, max_pages) {
        Ok(result) => serde_json::to_value(result)?,
        Err(error) => serde_json::json!({"error":format!("{error:#}")}),
    };
    fs::write(&output, serde_json::to_vec(&value)?)?;
    if value.get("error").is_some() {
        bail!("OCR failed");
    }
    Ok(())
}

fn run_one(path: &Path, max_pages: u32, engine: &Engine) -> Result<OcrResult> {
    let output = tempfile::Builder::new()
        .prefix("rustsearch-ocr-")
        .suffix(".json")
        .tempfile()?;
    let mut command = Command::new(std::env::current_exe()?);
    command
        .arg("--ocr-one")
        .arg(path)
        .arg(output.path())
        .arg(max_pages.to_string())
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(0x08000000);
    }
    let mut child = command.spawn().context("Cannot launch OCR worker")?;
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait()? {
            let value: serde_json::Value = serde_json::from_slice(&fs::read(output.path())?)?;
            ensure!(
                status.success(),
                "{}",
                value["error"].as_str().unwrap_or("OCR failed")
            );
            return Ok(serde_json::from_value(value)?);
        }
        if engine.stopped() || engine.paused() || started.elapsed() >= Duration::from_secs(310) {
            stop_child_tree(&mut child);
            let _ = child.wait();
            bail!("OCR interrupted or timed out");
        }
        std::thread::sleep(Duration::from_millis(100));
    }
}

fn stop_child_tree(child: &mut std::process::Child) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let _ = Command::new("taskkill")
            .args(["/PID", &child.id().to_string(), "/T", "/F"])
            .creation_flags(0x08000000)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status();
    }
    let _ = child.kill();
}

pub fn start(engine: Arc<Engine>) -> JoinHandle<()> {
    std::thread::spawn(move || {
        while !engine.stopped() {
            if !engine.paused() && !engine.indexing.load(Ordering::SeqCst) {
                let config = engine.config.lock().unwrap().clone();
                if config.ocr_enabled {
                    let next = engine.meta.lock().unwrap().next_ocr_file(&config);
                    match next {
                        Ok(Some(meta)) => {
                            let path = PathBuf::from(&meta.display_path);
                            let result = run_one(&path, config.ocr_max_pages, &engine);
                            if !engine.stopped() && !engine.paused() {
                                if let Err(error) = apply_result(&engine, meta, result) {
                                    engine.log("warn", format!("OCR update failed: {error:#}"));
                                }
                            }
                            continue;
                        }
                        Err(error) => engine.log("warn", format!("OCR queue failed: {error:#}")),
                        _ => {}
                    }
                }
            }
            std::thread::sleep(Duration::from_millis(500));
        }
    })
}

fn apply_result(
    engine: &Engine,
    meta: crate::index::meta_db::FileMeta,
    result: Result<OcrResult>,
) -> Result<()> {
    use tantivy::{doc, Term};
    let _mutation = engine.mutations.lock().unwrap();
    let current = engine.meta.lock().unwrap().file(&meta.path)?;
    if current
        .as_ref()
        .is_none_or(|m| m.size != meta.size || m.mtime_ns != meta.mtime_ns || m.status != 2)
    {
        return Ok(());
    }
    let path = PathBuf::from(&meta.display_path);
    if fs::metadata(&path).map_or(true, |m| {
        m.len() != meta.size
            || m.modified()
                .ok()
                .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
                .is_none_or(|t| t.as_nanos() as i64 != meta.mtime_ns)
    }) {
        return Ok(());
    }
    let result = match result {
        Ok(result) => result,
        Err(error) => {
            engine
                .meta
                .lock()
                .unwrap()
                .finish_ocr_failure(&meta.path, &format!("{error:#}"))?;
            engine.out.event(
                "ocr.failed",
                serde_json::json!({"path":meta.display_path,"message":format!("{error:#}")}),
            );
            return Ok(());
        }
    };
    let mut content = engine.meta.lock().unwrap().content(&meta.path)?;
    let mut pages = Vec::new();
    for page in result.pages {
        let prefix = format!("\n\n[第 {} 页]\n", page.number);
        if content.len() + prefix.len() + page.text.len() > MAX_TEXT_SIZE {
            break;
        }
        content.push_str(&prefix);
        let offset = content.len();
        content.push_str(&page.text);
        pages.push((page.number, offset, page.text.len()));
    }
    let mut writer = engine.writer.lock().unwrap();
    engine
        .meta
        .lock()
        .unwrap()
        .stage_paths(&[(meta.path.clone(), meta.display_path.clone())])?;
    writer.delete_term(Term::from_field_text(engine.fields.path, &meta.path));
    let filename = path.file_name().unwrap_or_default().to_string_lossy();
    writer.add_document(doc!(engine.fields.path=>meta.path.clone(), engine.fields.display_path=>meta.display_path.clone(),
        engine.fields.filename=>filename.as_ref(), engine.fields.content=>content.as_str(),
        engine.fields.ext=>meta.ext.clone(), engine.fields.size=>meta.size, engine.fields.mtime=>meta.mtime,
        engine.fields.title=>""))?;
    writer.commit()?;
    engine
        .meta
        .lock()
        .unwrap()
        .finish_ocr_success(&meta.path, &content, &pages)?;
    engine.committed()?;
    engine.out.event(
        "ocr.finished",
        serde_json::json!({"path":meta.display_path,"pages":pages.len()}),
    );
    Ok(())
}
