//! Earmark's MCP server (docs/mcp-plan.md): the tools agents use to find sounds in the owner's
//! libraries and put them on a timeline. Reads Earmark's database read-only (works with Earmark
//! closed); never writes sound files or Earmark's data. Port of `EarmarkMCP`.

pub mod definitions;
pub mod server;
pub mod tools;

pub use server::{EarmarkServer, VERSION, default_database_path, run_stdio};
pub use tools::{Answer, EarmarkTools, Outside};
