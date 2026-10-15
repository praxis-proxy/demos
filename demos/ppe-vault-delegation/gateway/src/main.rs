// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Praxis Contributors

#[cfg(unix)]
#[global_allocator]
static GLOBAL: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;

use clap::Parser;
use tracing::info;

#[derive(Parser)]
#[command(name = "ppe-vault-demo-gateway")]
struct Cli {
    #[arg(
        short = 'c',
        long = "config",
        help = "Path to the Praxis YAML configuration."
    )]
    config: Option<String>,
}

fn main() {
    let cli = Cli::parse();
    let explicit = cli.config.or_else(|| std::env::var("PRAXIS_CONFIG").ok());
    let config_path = praxis_ai::resolve_config_path(explicit.as_deref());
    let config =
        praxis_ai::load_config(explicit.as_deref()).unwrap_or_else(|e| praxis_ai::fatal(&e));
    let _tracing = praxis_ai::init_tracing(&config).unwrap_or_else(|e| praxis_ai::fatal(&e));
    info!("starting PPE Vault Community demo gateway");
    praxis_ai::run_server(config, config_path)
}
