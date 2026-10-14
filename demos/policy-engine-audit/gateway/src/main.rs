// SPDX-License-Identifier: Apache-2.0

//! Praxis gateway for the praxis-audit demo.
//!
//! The stock `praxis` binary plus three registrations made before the
//! server starts:
//!
//! - `audit/ocsf`: the OCSF audit sink from praxis-proxy/policy. The policy
//!   document names it with no `hooks:`, so it attaches as an audit sink and
//!   sees every pipeline verdict, denials included.
//! - `validator/pii-scan`: the reference PII scanner.
//! - `mcp_classify`: an HTTP filter that stamps `mcp.method` / `mcp.name`
//!   for the policy filter (see [`mcp_classify`]).
//!
//! Everything else (listeners, the policy filter, routing) is ordinary
//! Praxis YAML under `config/`.

mod mcp_classify;

use std::{process::ExitCode, sync::Arc};

use praxis_core::config::{Config, ConfigFile};
use praxis_filter::{FilterRegistry, register_policy_plugin_factory};

fn main() -> ExitCode {
    praxis::install_crypto_provider();

    register_policy_plugin_factory(
        ocsf_audit::KIND,
        Arc::new(|| Box::new(ocsf_audit::OcsfAuditFactory)),
    );
    register_policy_plugin_factory(
        pii_scanner::KIND,
        Arc::new(|| Box::new(pii_scanner::PiiScannerFactory)),
    );

    let explicit = std::env::args()
        .skip_while(|a| a != "-c" && a != "--config")
        .nth(1)
        .or_else(|| std::env::var("PRAXIS_CONFIG").ok());
    let config_path = praxis::resolve_config_path(explicit.as_deref());
    let config_file = config_path
        .as_deref()
        .map(ConfigFile::read)
        .transpose()
        .unwrap_or_else(|e| praxis::fatal(&e));
    let config = praxis::with_bootstrap_logging(|| {
        Config::from_config_file_or(config_file.as_ref(), praxis_core::config::DEFAULT_CONFIG)
    })
    .unwrap_or_else(|e| praxis::fatal(&e));

    let tracing_guard = praxis::init_tracing(&config).unwrap_or_else(|e| praxis::fatal(&e));
    let log_level = Some(tracing_guard.log_level_state());
    let log_output = config.runtime.logging.output;

    let mut registry = FilterRegistry::with_builtins();
    mcp_classify::register_filters(&mut registry);

    let _tracing_guard = tracing_guard;
    praxis::try_run_server_with_registry(config, registry, config_file, log_level).map_or_else(
        |e| praxis::report_fatal(&e, log_output),
        |()| ExitCode::SUCCESS,
    )
}
