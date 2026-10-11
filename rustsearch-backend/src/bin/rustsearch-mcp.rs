#[cfg(windows)]
#[path = "../mcp.rs"]
mod mcp;
#[cfg(windows)]
#[path = "../shared.rs"]
#[allow(dead_code)]
mod shared;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    #[cfg(windows)]
    return mcp::run().await;
    #[cfg(not(windows))]
    anyhow::bail!("RustSearch MCP requires Windows");
}
