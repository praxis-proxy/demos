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

/// Plugin kind used in policy configuration.
pub const KIND: &str = "validator/agent-status";

/// Registers the checker on the configured hooks, normally cmf.tool_pre_invoke.
/// Authorization-phase denies preserve the JSON-RPC violation envelope.
pub struct AgentStatusFactory;

impl PluginFactory for AgentStatusFactory {
    fn create(&self, config: &PluginConfig) -> Result<PluginInstance, Box<PluginError>> {
        let checker = Arc::new(AgentStatusChecker::new(config.clone())?);

        // Reject a configuration that would never run the checker.
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
                // Hook names require a static lifetime; one allocation per configured hook.
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
