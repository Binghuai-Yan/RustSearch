pub mod builder;
pub mod meta_db;
pub mod schema;
pub mod tokenizer;

use crate::{
    config::Config,
    ipc::{protocol::SearchResult, Output},
};
use anyhow::Result;
use meta_db::MetaDb;
use schema::AppSchema;
use std::{
    collections::VecDeque,
    fs,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc, Mutex,
    },
};
use tantivy::{Index, IndexReader, IndexWriter, ReloadPolicy};

pub struct Engine {
    pub index: Index,
    pub fields: AppSchema,
    pub reader: IndexReader,
    pub writer: Mutex<IndexWriter>,
    pub meta: Mutex<MetaDb>,
    pub config: Mutex<Config>,
    pub data_dir: PathBuf,
    pub out: Output,
    pub indexing: AtomicBool,
    pub shutdown: AtomicBool,
    pub generation: AtomicU64,
    pub retry_needed: AtomicBool,
    pub cache: Mutex<VecDeque<(String, u64, SearchResult)>>,
    pub mutations: Mutex<()>,
}
impl Engine {
    pub fn open(data_dir: PathBuf, out: Output) -> Result<Arc<Self>> {
        let config = Config::load(&data_dir)?;
        let (schema, fields) = AppSchema::build();
        let index_dir = data_dir.join("index");
        fs::create_dir_all(&index_dir)?;
        let index = if index_dir.join("meta.json").exists() {
            let index = Index::open_in_dir(&index_dir)?;
            anyhow::ensure!(
                index.schema() == schema,
                "Index schema changed; move the data directory aside and rebuild"
            );
            index
        } else {
            Index::create_in_dir(&index_dir, schema)?
        };
        tokenizer::register(&index, &config.user_dictionary)?;
        let reader = index
            .reader_builder()
            .reload_policy(ReloadPolicy::Manual)
            .try_into()?;
        let writer = index.writer(500_000_000)?;
        let meta = MetaDb::open(&data_dir)?;
        Ok(Arc::new(Self {
            index,
            fields,
            reader,
            writer: Mutex::new(writer),
            meta: Mutex::new(meta),
            config: Mutex::new(config),
            data_dir,
            out,
            indexing: AtomicBool::new(false),
            shutdown: AtomicBool::new(false),
            generation: AtomicU64::new(0),
            retry_needed: AtomicBool::new(false),
            cache: Mutex::new(VecDeque::new()),
            mutations: Mutex::new(()),
        }))
    }
    pub fn committed(&self) -> Result<()> {
        self.reader.reload()?;
        self.generation.fetch_add(1, Ordering::SeqCst);
        self.cache.lock().unwrap().clear();
        Ok(())
    }
    pub fn log(&self, level: &str, message: impl Into<String>) {
        let message = message.into();
        tracing::warn!(%message);
        self.out.event(
            "backend.log",
            serde_json::json!({"level":level,"msg":message}),
        );
    }
    pub fn stopped(&self) -> bool {
        self.shutdown.load(Ordering::Relaxed)
    }
    pub fn paused(&self) -> bool {
        self.config.lock().unwrap().paused
    }
}
