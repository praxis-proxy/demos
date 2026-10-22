// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Praxis Contributors

//! Praxis Policy Engine gateway with AI filters and local plugins.

#[cfg(unix)]
#[global_allocator]
static GLOBAL: tikv_jemallocator::Jemalloc = tikv_jemallocator::Jemalloc;

use clap::Parser;
use tracing::info;

/// Praxis Policy Engine + praxis-ai gateway.
#[derive(Parser)]
#[command(name = "policy-engine-gateway")]
struct Cli {
    /// Path to the YAML configuration file.
    #[arg(short = 'c', long = "config")]
    config: Option<String>,
}

/// Register the local plugins before run_server loads the policy configuration.
fn register_host_plugins() {
    praxis_filter::register_policy_plugin_factory(
        praxis_policy_plugin_pii_scanner::KIND,
        std::sync::Arc::new(|| Box::new(praxis_policy_plugin_pii_scanner::PiiScannerFactory)),
    );
    praxis_filter::register_policy_plugin_factory(
        praxis_policy_plugin_audit_logger::KIND,
        std::sync::Arc::new(|| Box::new(praxis_policy_plugin_audit_logger::AuditLoggerFactory)),
    );
    praxis_filter::register_policy_plugin_factory(
        praxis_policy_plugin_agent_status::KIND,
        std::sync::Arc::new(|| Box::new(praxis_policy_plugin_agent_status::AgentStatusFactory)),
    );
}

fn main() {
    let cli = Cli::parse();
    let explicit = cli.config.or_else(|| std::env::var("PRAXIS_CONFIG").ok());

    let config_path = praxis_ai::resolve_config_path(explicit.as_deref());
    let config = praxis_ai::load_config(explicit.as_deref()).unwrap_or_else(|e| praxis_ai::fatal(&e));
    // Keep the tracing provider alive until the server exits.
    let _tracing = praxis_ai::init_tracing(&config).unwrap_or_else(|e| praxis_ai::fatal(&e));
    info!("starting policy-engine gateway");
    register_host_plugins();
    praxis_ai::run_server(config, config_path)
}
