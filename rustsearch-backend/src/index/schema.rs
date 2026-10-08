use tantivy::schema::*;

#[derive(Clone)]
pub struct AppSchema {
    pub path: Field,
    pub display_path: Field,
    pub filename: Field,
    pub content: Field,
    pub ext: Field,
    pub size: Field,
    pub mtime: Field,
    pub title: Field,
}
impl AppSchema {
    pub fn build() -> (Schema, Self) {
        let mut builder = Schema::builder();
        let mixed = TextOptions::default().set_stored().set_indexing_options(
            TextFieldIndexing::default()
                .set_tokenizer("mixed")
                .set_index_option(IndexRecordOption::WithFreqsAndPositions),
        );
        let content_options = TextOptions::default().set_indexing_options(
            TextFieldIndexing::default()
                .set_tokenizer("mixed")
                .set_index_option(IndexRecordOption::WithFreqsAndPositions),
        );
        let fields = Self {
            path: builder.add_text_field("path", STRING | STORED | FAST),
            display_path: builder.add_text_field("display_path", STORED),
            filename: builder.add_text_field("filename", mixed.clone()),
            content: builder.add_text_field("content", content_options),
            ext: builder.add_text_field("ext", STRING | STORED | FAST),
            size: builder.add_u64_field("size", FAST | STORED),
            mtime: builder.add_u64_field("mtime", FAST | STORED),
            title: builder.add_text_field("title", mixed),
        };
        (builder.build(), fields)
    }
}
