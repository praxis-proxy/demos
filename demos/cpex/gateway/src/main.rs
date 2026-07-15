// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Praxis Contributors

//! Thin CPEX + praxis-ai gateway.
//!
//! Delegates to praxis-ai's `run_server`. Because this crate enables
//! `cpex-policy-engine` (see Cargo.toml), praxis-proxy-filter's builtins
//! registry adds the `policy` filter, and praxis-ai's server adds the AI
//! filters (mcp, …) — so a single binary composes both with no manual
//! registration.

#[cfg(unix)]
#[global_allocator]
static GLOBAL: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;

use clap::Parser;
use tracing::info;

/// CPEX policy + praxis-ai gateway.
#[derive(Parser)]
#[command(name = "cpex-praxis-gateway")]
struct Cli {
    /// Path to the YAML configuration file.
    #[arg(short = 'c', long = "config")]
    config: Option<String>,
}

fn main() {
    let cli = Cli::parse();
    let explicit = cli.config.or_else(|| std::env::var("PRAXIS_CONFIG").ok());

    let config_path = praxis_ai::resolve_config_path(explicit.as_deref());
    let config = praxis_ai::load_config(explicit.as_deref()).unwrap_or_else(|e| praxis_ai::fatal(&e));
    praxis_ai::init_tracing(&config).unwrap_or_else(|e| praxis_ai::fatal(&e));
    info!("starting cpex-praxis gateway");
    praxis_ai::run_server(config, config_path)
}
