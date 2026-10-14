// SPDX-License-Identifier: Apache-2.0

//! `mcp_classify`: the minimum MCP classification the `policy` filter needs.
//!
//! The policy filter routes on `mcp.method` / `mcp.name` filter metadata and
//! fails closed when it is missing. In a full Praxis AI deployment the `mcp`
//! filter from praxis-proxy/ai sets them (and validates headers, sessions and
//! batches). That crate is not published, so this demo carries a small
//! stand-in: buffer the JSON-RPC body, read `method` and `params.name`,
//! stamp both, release the body unchanged. Swap it for `filter: mcp` when the
//! demo runs on the Praxis AI image.

use async_trait::async_trait;
use bytes::Bytes;
use praxis_filter::{
    BodyAccess, BodyMode, FilterAction, FilterError, HttpFilter, HttpFilterContext, export_filters,
};

/// Upper bound on a buffered tool call. The demo's payloads are tiny.
const MAX_BODY_BYTES: usize = 256 * 1024;

struct McpClassify;

impl McpClassify {
    #[expect(clippy::unnecessary_wraps, reason = "factory signature")]
    fn from_config(_config: &serde_yaml::Value) -> Result<Box<dyn HttpFilter>, FilterError> {
        Ok(Box::new(Self))
    }
}

#[async_trait]
impl HttpFilter for McpClassify {
    fn name(&self) -> &'static str {
        "mcp_classify"
    }

    fn request_body_access(&self) -> BodyAccess {
        BodyAccess::ReadOnly
    }

    fn request_body_mode(&self) -> BodyMode {
        BodyMode::StreamBuffer {
            max_bytes: Some(MAX_BODY_BYTES),
        }
    }

    async fn on_request(
        &self,
        _ctx: &mut HttpFilterContext<'_>,
    ) -> Result<FilterAction, FilterError> {
        Ok(FilterAction::Continue)
    }

    async fn on_request_body(
        &self,
        ctx: &mut HttpFilterContext<'_>,
        body: &mut Option<Bytes>,
        end_of_stream: bool,
    ) -> Result<FilterAction, FilterError> {
        if !end_of_stream {
            return Ok(FilterAction::Continue);
        }
        let Some(rpc) = body
            .as_ref()
            .and_then(|b| serde_json::from_slice::<serde_json::Value>(b).ok())
        else {
            // Not JSON-RPC: leave the metadata unset and let the policy
            // filter's `require_protocol_metadata` gate reject it.
            return Ok(FilterAction::Release);
        };
        if let Some(method) = rpc.get("method").and_then(serde_json::Value::as_str) {
            ctx.set_metadata("json_rpc.method", method);
            ctx.set_metadata("mcp.method", method);
        }
        let name = rpc
            .get("params")
            .and_then(|p| p.get("name").or_else(|| p.get("uri")))
            .and_then(serde_json::Value::as_str);
        if let Some(name) = name {
            ctx.set_metadata("mcp.name", name);
        }
        Ok(FilterAction::Release)
    }
}

export_filters! {
    http "mcp_classify" => McpClassify::from_config,
}
