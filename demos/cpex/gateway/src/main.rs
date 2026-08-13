// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Praxis Contributors

//! Thin CPEX + praxis-ai gateway.
//!
//! Delegates to praxis-ai's `run_server`. Because this crate enables
//! `policy-engine` (see Cargo.toml), praxis-proxy-filter's builtins
//! registry adds the `policy` filter, and praxis-ai's server adds the AI
//! filters (mcp, …) — so a single binary composes both with no manual
//! filter registration.
//!
//! What is registered by hand is the pair of plugins the engine does not bundle.
//! `cpex.yaml` names `validator/pii-scan` and `audit/logger`, and the policy
//! filter resolves every `kind:` through its own factory registry, so those two
//! have to be handed to it before the server starts. See
//! [`register_host_plugins`].

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

/// Hand the policy filter the two plugins it cannot find on its own.
///
/// Both are unpublished reference implementations in the engine's repository
/// rather than bundled builtins: the PII scanner is regex matching with no Luhn
/// check, and the audit logger writes to stderr. Neither is something a policy
/// engine should ship as supported, and both are exactly what a deployment wants
/// to replace — which is the point of doing it this way. Swap either line for
/// your own factory and the policy document does not change.
///
/// Each registers under the plugin's own `KIND` constant rather than a string
/// literal here, so the registration cannot drift from what the plugin declares.
///
/// Must run before `run_server`. The filter reads this registry when it builds,
/// which happens at startup and again on every config reload.
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
    praxis_ai::init_tracing(&config).unwrap_or_else(|e| praxis_ai::fatal(&e));
    info!("starting cpex-praxis gateway");
    register_host_plugins();
    praxis_ai::run_server(config, config_path)
}
