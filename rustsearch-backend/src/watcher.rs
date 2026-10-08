use crate::index::{builder, Engine};
use notify::{EventKind, RecursiveMode, Watcher};
use std::{
    collections::HashSet,
    path::PathBuf,
    sync::Arc,
    thread::JoinHandle,
    time::{Duration, Instant},
};

pub fn start(engine: Arc<Engine>) -> JoinHandle<()> {
    std::thread::spawn(move || {
        let (tx, rx) = crossbeam_channel::bounded(4096);
        let overflow = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let callback_overflow = overflow.clone();
        let mut watcher =
            match notify::recommended_watcher(move |event: notify::Result<notify::Event>| {
                if tx.try_send(event).is_err() {
                    callback_overflow.store(true, std::sync::atomic::Ordering::Relaxed);
                }
            }) {
                Ok(w) => w,
                Err(e) => {
                    engine.log("error", format!("Cannot start file watcher: {e}"));
                    return;
                }
            };
        let mut watched = HashSet::new();
        let mut last_change = None;
        let mut first_change = None;
        let mut pending = 0usize;
        let mut pending_paths = HashSet::new();
        let mut full_scan = false;
        let mut last_registration = Instant::now() - Duration::from_secs(5);
        let mut last_reconcile = Instant::now();
        while !engine.stopped() {
            if last_registration.elapsed() >= Duration::from_secs(1) {
                let roots = engine.meta.lock().unwrap().root_paths().unwrap_or_default();
                let desired: HashSet<_> = roots.into_iter().map(PathBuf::from).collect();
                let mut successful = HashSet::new();
                for root in desired.difference(&watched) {
                    if root.is_dir() {
                        match watcher.watch(root, RecursiveMode::Recursive) {
                            Ok(()) => {
                                successful.insert(root.clone());
                                // A fast initial scan may finish before this watch is registered.
                                // Reconcile after registration to include changes in that gap.
                                full_scan = true;
                                last_change = Some(Instant::now() - Duration::from_secs(2));
                            }
                            Err(e) => engine.log("warn", format!("{}: {e}", root.display())),
                        }
                    }
                }
                for root in watched.difference(&desired) {
                    let _ = watcher.unwatch(root);
                }
                watched = watched
                    .intersection(&desired)
                    .cloned()
                    .chain(successful)
                    .collect();
                last_registration = Instant::now();
            }
            match rx.recv_timeout(Duration::from_millis(100)) {
                Ok(Ok(event))
                    if matches!(
                        event.kind,
                        EventKind::Create(_)
                            | EventKind::Modify(_)
                            | EventKind::Remove(_)
                            | EventKind::Any
                            | EventKind::Other
                    ) =>
                {
                    let config = engine.config.lock().unwrap().clone();
                    if matches!(
                        event.kind,
                        EventKind::Remove(_)
                            | EventKind::Modify(notify::event::ModifyKind::Name(_))
                    ) || event.paths.iter().any(|p| {
                        p.is_dir()
                            || builder::eligible(p, &config, &engine.data_dir)
                            || p.file_name().is_some_and(|f| f == ".gitignore")
                    }) {
                        if event.paths.is_empty()
                            || event.paths.iter().any(|p| {
                                p.file_name()
                                    .is_some_and(|f| f == ".gitignore" || f == ".ignore")
                            })
                        {
                            full_scan = true;
                        }
                        pending_paths.extend(event.paths);
                        last_change = Some(Instant::now());
                        first_change.get_or_insert(Instant::now());
                        pending += 1;
                    }
                }
                Ok(Err(e)) => {
                    engine.log("warn", format!("Watcher error: {e}"));
                    last_change = Some(Instant::now());
                    full_scan = true;
                }
                _ => {}
            }
            if overflow.swap(false, std::sync::atomic::Ordering::Relaxed) {
                last_change = Some(Instant::now());
                first_change.get_or_insert(Instant::now());
                full_scan = true;
            }
            let due = last_change.is_some_and(|t| t.elapsed() >= Duration::from_secs(2))
                || first_change
                    .is_some_and(|t| t.elapsed() >= Duration::from_secs(3) && pending >= 50)
                || (engine
                    .retry_needed
                    .load(std::sync::atomic::Ordering::Relaxed)
                    && last_reconcile.elapsed() >= Duration::from_secs(3))
                || last_reconcile.elapsed() >= Duration::from_secs(30);
            if due && !engine.paused() && !engine.indexing.load(std::sync::atomic::Ordering::SeqCst)
            {
                let result = if full_scan
                    || pending_paths.is_empty()
                    || last_reconcile.elapsed() >= Duration::from_secs(30)
                {
                    builder::scan(&engine, None, false, true)
                } else {
                    builder::scan_paths(&engine, &pending_paths.iter().cloned().collect::<Vec<_>>())
                };
                if let Err(e) = result {
                    engine.log("error", format!("Incremental scan failed: {e:#}"));
                }
                if !engine
                    .retry_needed
                    .load(std::sync::atomic::Ordering::Relaxed)
                {
                    pending_paths.clear();
                }
                full_scan = false;
                last_change = None;
                first_change = None;
                pending = 0;
                last_reconcile = Instant::now();
            }
        }
    })
}
