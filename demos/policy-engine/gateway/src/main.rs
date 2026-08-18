// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Praxis Contributors

//! Thin Praxis Policy Engine + praxis-ai gateway.
//!
//! Enabling `policy-engine` registers the `policy` filter, and praxis-ai's
//! server registers the AI filters, so one binary composes both. The only
//! thing wired by hand is the pair of plugins the engine does not bundle.

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

/// Hand the policy filter the two plugins it cannot find on its own.
///
/// Both are unpublished reference implementations: the PII scanner is regex
/// matching with no Luhn check, and the audit logger writes to stderr. Swap
/// either line for your own factory and the policy document does not change.
///
/// Each registers under the plugin's own `KIND` so the registration cannot
/// drift from what the plugin declares.
///
/// Must run before `run_server`, which reads this registry at startup and
/// again on every config reload.
fn register_host_plugins() {
    praxis_filter::register_policy_plugin_factory(
        praxis_policy_plugin_pii_scanner::KIND,
        std::sync::Arc::new(|| Box::new(praxis_policy_plugin_pii_scanner::PiiScannerFactory)),
    );
    praxis_filter::register_policy_plugin_factory(
        praxis_policy_plugin_audit_logger::KIND,
        std::sync::Arc::new(|| Box::new(praxis_policy_plugin_audit_logger::AuditLoggerFactory)),
    );
}

fn main() {
    let cli = Cli::parse();
    let explicit = cli.config.or_else(|| std::env::var("PRAXIS_CONFIG").ok());

    let config_path = praxis_ai::resolve_config_path(explicit.as_deref());
    let config = praxis_ai::load_config(explicit.as_deref()).unwrap_or_else(|e| praxis_ai::fatal(&e));
    // Held for the life of the process: dropping the guard shuts the tracer
    // provider down and the gateway logs nothing.
    let _tracing = praxis_ai::init_tracing(&config).unwrap_or_else(|e| praxis_ai::fatal(&e));
    info!("starting policy-engine gateway");
    register_host_plugins();
    praxis_ai::run_server(config, config_path)
}
