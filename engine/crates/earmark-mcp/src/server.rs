//! The MCP server: Earmark's tools over a transport (stdio for clients that start `earmark-mcp`).

use crate::definitions::{INSTRUCTIONS, definitions};
use crate::tools::{Answer, EarmarkTools, Outside};
use rmcp::model::{
    CallToolRequestParams, CallToolResponse, CallToolResult, ContentBlock, Implementation,
    ListToolsResult, PaginatedRequestParams, ServerCapabilities, ServerConfig, ToolsCapability,
};
use rmcp::service::{RequestContext, RoleServer};
use rmcp::{ErrorData, ServerHandler, ServiceExt};
use std::path::PathBuf;
use std::sync::Arc;

pub const VERSION: &str = "1.0";

#[derive(Clone)]
pub struct EarmarkServer {
    tools: Arc<EarmarkTools>,
}

impl EarmarkServer {
    pub fn new(tools: EarmarkTools) -> EarmarkServer {
        EarmarkServer {
            tools: Arc::new(tools),
        }
    }
}

/// The answer as JSON text (for any client) and as structured content.
fn result(answer: Answer) -> CallToolResult {
    let content = vec![ContentBlock::text(answer.text)];
    let mut out = if answer.is_error {
        CallToolResult::error(content)
    } else {
        CallToolResult::success(content)
    };
    out.structured_content = answer.structured;
    out
}

impl ServerHandler for EarmarkServer {
    fn get_info(&self) -> ServerConfig {
        let mut about = Implementation::new("Earmark", VERSION);
        about.title = Some("Earmark sound library".into());
        let mut tools = ToolsCapability::default();
        tools.list_changed = Some(false);
        ServerConfig::new(
            ServerCapabilities::builder()
                .enable_tools_with(tools)
                .build(),
        )
        .with_server_info(about)
        .with_instructions(INSTRUCTIONS)
    }

    async fn list_tools(
        &self,
        _request: Option<PaginatedRequestParams>,
        _context: RequestContext<RoleServer>,
    ) -> Result<ListToolsResult, ErrorData> {
        Ok(ListToolsResult::with_all_items(definitions()))
    }

    async fn call_tool(
        &self,
        request: CallToolRequestParams,
        _context: RequestContext<RoleServer>,
    ) -> Result<CallToolResponse, ErrorData> {
        let tools = self.tools.clone();
        let name = request.name.to_string();
        let arguments = request.arguments.unwrap_or_default();
        // Reading the library and waiting for Resolve both block.
        let answer = tokio::task::spawn_blocking(move || tools.call(&name, &arguments))
            .await
            .map_err(|e| ErrorData::internal_error(e.to_string(), None))?;
        Ok(result(answer).into())
    }
}

/// Serves on standard input and output until the client goes.
pub async fn run_stdio(database: PathBuf) -> Result<(), Box<dyn std::error::Error>> {
    let server = EarmarkServer::new(EarmarkTools::new(database, Outside::live()));
    let service = server.serve(rmcp::transport::stdio()).await?;
    service.waiting().await?;
    Ok(())
}

/// Earmark's database: `EARMARK_DATABASE` if set, else the app's own.
pub fn default_database_path() -> PathBuf {
    let env = |name: &str| {
        std::env::var_os(name)
            .filter(|v| !v.is_empty())
            .map(PathBuf::from)
    };
    if let Some(path) = env("EARMARK_DATABASE") {
        return path;
    }
    let home = crate::tools::home_folder();
    let support = if cfg!(windows) {
        env("APPDATA").unwrap_or_else(|| home.join("AppData/Roaming"))
    } else if cfg!(target_os = "macos") {
        home.join("Library/Application Support")
    } else {
        env("XDG_DATA_HOME").unwrap_or_else(|| home.join(".local/share"))
    };
    support.join("Earmark").join("library.sqlite")
}
