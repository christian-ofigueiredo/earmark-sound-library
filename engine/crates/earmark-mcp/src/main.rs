//! Earmark's MCP server: MCP clients start it and talk over stdin/stdout. EARMARK_DATABASE points
//! it at another database (tests, copies). Reads only.

#[tokio::main]
async fn main() {
    if std::env::args().any(|a| a == "--version") {
        println!("earmark-mcp {}", earmark_mcp::VERSION);
        return;
    }
    if let Err(e) = earmark_mcp::run_stdio(earmark_mcp::default_database_path()).await {
        eprintln!("earmark-mcp: {e}");
        std::process::exit(1);
    }
}
