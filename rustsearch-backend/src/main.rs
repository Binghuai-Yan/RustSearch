mod app;
mod config;
mod extract;
mod index;
mod ipc;
mod ocr;
mod path_utils;
mod query;
mod uninstall;
mod watcher;

use ipc::{
    protocol::{Request, Response},
    Output,
};
use serde_json::json;
use std::{
    io::{self, BufRead},
    sync::atomic::Ordering,
};

fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_writer(io::stderr)
        .with_ansi(false)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "warn".into()),
        )
        .init();
    if std::env::args_os()
        .nth(1)
        .is_some_and(|a| a == "--delete-user-index")
    {
        return uninstall::remove_user_index();
    }
    if std::env::args_os()
        .nth(1)
        .is_some_and(|a| a == "--delete-user-data")
    {
        return uninstall::remove_user_data();
    }
    if std::env::args_os()
        .nth(1)
        .is_some_and(|a| a == "--extract-one")
    {
        let output_path = std::env::args_os()
            .nth(3)
            .ok_or_else(|| anyhow::anyhow!("Missing PDF result file"))?;
        let result = std::env::args_os()
            .nth(2)
            .ok_or_else(|| anyhow::anyhow!("Missing file path"))
            .and_then(|p| extract::extract(std::path::Path::new(&p)));
        match result {
            Ok(result) => {
                std::fs::write(&output_path, serde_json::to_vec(&result)?)?;
                return Ok(());
            }
            Err(error) => {
                std::fs::write(
                    &output_path,
                    serde_json::to_vec(&json!({"error":format!("{error:#}")}))?,
                )?;
                std::process::exit(1);
            }
        }
    }
    if std::env::args_os().nth(1).is_some_and(|a| a == "--ocr-one") {
        return ocr::run_child();
    }
    rayon::ThreadPoolBuilder::new()
        .num_threads(std::thread::available_parallelism().map_or(2, |n| n.get().min(8)))
        .build_global()?;
    let out = Output::new();
    let engine = index::Engine::open(config::data_dir()?, out.clone())?;
    let (jobs, rx) = crossbeam_channel::bounded(16);
    let app = app::App {
        engine: engine.clone(),
        jobs,
    };
    let index_worker = app::worker(engine.clone(), rx);
    let watcher = watcher::start(engine.clone());
    let ocr_worker = ocr::start(engine.clone());
    app.jobs.send(app::Job::Scan {
        root: None,
        force: false,
    })?;
    let (requests, rx) = crossbeam_channel::bounded::<Request>(64);
    let mut handlers = vec![];
    for _ in 0..4 {
        let rx = rx.clone();
        let app = app.clone();
        let out = out.clone();
        handlers.push(std::thread::spawn(move || {
            for req in rx {
                if app.engine.stopped() {
                    break;
                }
                let id = req.id;
                let response =
                    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| app.dispatch(req)))
                        .unwrap_or_else(|_| {
                            Response::failure(
                                Some(id),
                                "INTERNAL_ERROR",
                                "Unexpected request failure",
                            )
                        });
                out.send(&response);
            }
        }));
    }
    let mut shutdown_id = None;
    for line in io::stdin().lock().lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        if line.len() > 2 * 1024 * 1024 {
            out.send(&Response::failure(
                None,
                "INVALID_PARAMS",
                "Request exceeds 2 MB",
            ));
            continue;
        }
        let req: Request = match serde_json::from_str(&line) {
            Ok(req) => req,
            Err(error) => {
                let id = serde_json::from_str::<serde_json::Value>(&line)
                    .ok()
                    .and_then(|v| v["id"].as_u64());
                out.send(&Response::failure(id, "INVALID_PARAMS", error.to_string()));
                continue;
            }
        };
        if req.method == "app.shutdown" {
            shutdown_id = Some(req.id);
            break;
        }
        match requests.try_send(req) {
            Ok(()) => {}
            Err(error) => {
                let req = error.into_inner();
                out.send(&Response::failure(
                    Some(req.id),
                    "INDEX_BUSY",
                    "Request queue is full",
                ));
            }
        }
    }
    drop(requests);
    for handler in handlers {
        let _ = handler.join();
    }
    engine.shutdown.store(true, Ordering::SeqCst);
    let _ = index_worker.join();
    let _ = watcher.join();
    let _ = ocr_worker.join();
    if let Some(id) = shutdown_id {
        out.send(&Response::success(id, json!({"shutdown":true})));
    }
    Ok(())
}
