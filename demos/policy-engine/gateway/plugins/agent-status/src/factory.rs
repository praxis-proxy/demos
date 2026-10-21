// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Praxis Contributors

use std::sync::Arc;

use praxis_policy_core::{
    cmf::CmfHook,
    error::PluginError,
    factory::{PluginFactory, PluginInstance},
    hooks::TypedHandlerAdapter,
    plugin::PluginConfig,
};

use crate::status::AgentStatusChecker;

/// `kind:` string operators write in PPE YAML to declare an agent-status
/// check.
pub const KIND: &str = "validator/agent-status";

/// Factory for `kind: validator/agent-status`.
///
/// Registers a handler for every hook name in `cfg.hooks`. In practice that is
/// `cmf.tool_pre_invoke`, reached by a `run(agent-status)` step in the route's
/// `authorization:` block.
///
/// Why not `identity.resolve`, where an `auth.*` violation would more naturally
/// belong: a deny raised during authentication is mapped by the host to HTTP
/// 401 with a plain-text body, while the scenario harness
/// (`scenarios/_lib.sh` `expect_violation`) requires the violation code in both
/// the `X-Policy-Violation` header and the JSON-RPC `.error.data.violation`.
/// Only an authorization-phase deny produces that envelope. Measured both ways;
/// `proto_error_code` does not change it.
pub struct AgentStatusFactory;

impl PluginFactory for AgentStatusFactory {
    fn create(&self, config: &PluginConfig) -> Result<PluginInstance, Box<PluginError>> {
        let checker = Arc::new(AgentStatusChecker::new(config.clone())?);

        // A checker wired to no hooks loads cleanly and never runs, so the
        // operator believes agent status is enforced when nothing checks it.
        // That is the one misconfiguration this plugin must not permit.
        if config.hooks.is_empty() {
            return Err(Box::new(PluginError::Config {
                message: format!(
                    "plugin '{}' (praxis-policy-plugin-agent-status): `hooks:` must list at \
                     least one hook to check on (e.g. cmf.tool_pre_invoke)",
                    config.name
                ),
            }));
        }

        let handlers: Vec<_> = config
            .hooks
            .iter()
            .map(|h| -> (&'static str, _) {
                // Leaked for a 'static lifetime, as the reference plugins do:
                // configs are read at startup and live for the process, so the
                // leak is bounded by plugin x hook pairs in config.
                let leaked: &'static str = Box::leak(h.clone().into_boxed_str());
                let adapter: Arc<dyn praxis_policy_core::registry::AnyHookHandler> =
                    Arc::new(TypedHandlerAdapter::<CmfHook, _>::new(Arc::clone(&checker)));
                (leaked, adapter)
            })
            .collect();

        Ok(PluginInstance {
            plugin: checker,
            handlers,
        })
    }
}

#[cfg(test)]
#[allow(clippy::expect_used, clippy::indexing_slicing, reason = "tests")]
mod tests {
    use super::*;
    use praxis_policy_core::plugin::{OnError, PluginMode};

    fn cfg(hooks: Vec<String>) -> PluginConfig {
        // The checker's constructor reads this at build time.
        unsafe { std::env::set_var("AGENT_STATUS_TEST_SECRET", "test-secret") };
        PluginConfig {
            name: "agent-status".into(),
            kind: KIND.into(),
            hooks,
            mode: PluginMode::Sequential,
            priority: 20,
            on_error: OnError::Fail,
            config: Some(serde_json::json!({
                "registry_url": "https://t.verify.ibm.com/v1.0/Agents",
                "admin_client_id": "admin-client",
                "admin_client_secret_env": "AGENT_STATUS_TEST_SECRET",
            })),
            ..Default::default()
        }
    }

    #[test]
    fn one_hook_yields_one_handler_under_that_name() {
        let inst = AgentStatusFactory
            .create(&cfg(vec!["cmf.tool_pre_invoke".into()]))
            .expect("a config with one hook must build");
        assert_eq!(inst.handlers.len(), 1);
        assert_eq!(inst.handlers[0].0, "cmf.tool_pre_invoke");
    }

    #[test]
    fn empty_hooks_is_rejected_and_names_the_key() {
        let err = AgentStatusFactory
            .create(&cfg(vec![]))
            .err()
            .expect("no hooks must not build");
        assert!(matches!(*err, PluginError::Config { .. }));
        assert!(err.to_string().contains("hooks:"));
    }

    #[test]
    fn a_bad_config_block_is_rejected_at_factory_time() {
        let mut c = cfg(vec!["cmf.tool_pre_invoke".into()]);
        c.config = Some(serde_json::json!({}));
        let err = AgentStatusFactory
            .create(&c)
            .err()
            .expect("missing registry_url must not build");
        assert!(err.to_string().contains("registry_url"));
    }
}
