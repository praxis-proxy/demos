// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Praxis Contributors

use async_trait::async_trait;

use praxis_policy_core::cmf::{CmfHook, MessagePayload};
use praxis_policy_core::context::PluginContext;
use praxis_policy_core::error::{PluginError, PluginViolation};
use praxis_policy_core::hooks::payload::Extensions;
use praxis_policy_core::hooks::trait_def::{HookHandler, PluginResult};
use praxis_policy_core::plugin::{Plugin, PluginConfig};

use crate::{
    config::{AgentStatusConfig, OnUnavailable},
    registry::{RegistryClient, StatusCache},
    VIOLATION_AGENT_SUSPENDED, VIOLATION_REGISTRY_UNAVAILABLE,
};

/// Outcome of consulting the registry, before it becomes a `PluginResult`.
///
/// Separated from the HTTP fetch so the decision is testable without a tenant:
/// everything security-relevant is a pure function of this value.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StatusLookup {
    /// The registry answered with this status string.
    Known(String),
    /// The registry could not be consulted, or answered unintelligibly.
    Unavailable(String),
}

/// Denies a call when the calling agent is not in the required status.
pub struct AgentStatusChecker {
    cfg: PluginConfig,
    typed: AgentStatusConfig,
    client: RegistryClient,
    cache: StatusCache,
}

impl AgentStatusChecker {
    /// Builds the checker from its `config:` block.
    pub fn new(config: PluginConfig) -> Result<Self, Box<PluginError>> {
        let raw = config.config.clone().unwrap_or(serde_json::Value::Null);
        let typed: AgentStatusConfig =
            serde_json::from_value(raw).map_err(|e| PluginError::Config {
                message: format!(
                    "plugin '{}' (praxis-policy-plugin-agent-status): invalid config: {e}",
                    config.name
                ),
            })?;
        if typed.cache_ttl_seconds == 0 {
            return Err(Box::new(PluginError::Config {
                message: format!(
                    "plugin '{}' (praxis-policy-plugin-agent-status): `cache_ttl_seconds` must \
                     be greater than zero; omit it to take the default",
                    config.name
                ),
            }));
        }
        let token_url = typed.resolved_token_url().map_err(|e| PluginError::Config {
            message: format!(
                "plugin '{}' (praxis-policy-plugin-agent-status): {e}",
                config.name
            ),
        })?;
        // Read now, not per request: a missing secret is a startup fault, and
        // discovering it on the first agent call would present as a denial.
        let admin_client_secret = std::env::var(&typed.admin_client_secret_env).map_err(|_| {
            PluginError::Config {
                message: format!(
                    "plugin '{}' (praxis-policy-plugin-agent-status): environment variable \
                     '{}' (admin_client_secret_env) is not set",
                    config.name, typed.admin_client_secret_env
                ),
            }
        })?;
        let timeout = std::time::Duration::from_millis(typed.request_timeout_ms);
        let client = RegistryClient {
            registry_url: typed.registry_url.clone(),
            token_url,
            admin_client_id: typed.admin_client_id.clone(),
            admin_client_secret,
            timeout,
        };
        let cache = StatusCache::new(std::time::Duration::from_secs(typed.cache_ttl_seconds));
        Ok(Self {
            cfg: config,
            typed,
            client,
            cache,
        })
    }

    /// Turns a lookup into an allow/deny decision.
    ///
    /// Pure, so every branch that matters is unit-testable. Note that only an
    /// exact match on the required status allows: an unrecognized status
    /// string denies rather than being treated as benign, because a status
    /// this plugin does not understand is not a status it can vouch for.
    pub fn decide(&self, lookup: &StatusLookup) -> Decision {
        match lookup {
            StatusLookup::Known(s) if s == &self.typed.required_status => Decision::Allow,
            StatusLookup::Known(s) => Decision::Deny {
                code: VIOLATION_AGENT_SUSPENDED,
                reason: format!(
                    "agent status is '{s}', not '{}' — the agent is registered but not \
                     authorized to act",
                    self.typed.required_status
                ),
            },
            StatusLookup::Unavailable(why) => match self.typed.on_unavailable {
                OnUnavailable::Allow => Decision::Allow,
                OnUnavailable::Deny => Decision::Deny {
                    code: VIOLATION_REGISTRY_UNAVAILABLE,
                    reason: format!(
                        "could not confirm the agent's registry status ({why}) — refusing \
                         rather than assuming it is authorized"
                    ),
                },
            },
        }
    }

    /// The configured required status, for callers that report it.
    pub fn required_status(&self) -> &str {
        &self.typed.required_status
    }
}

/// Allow or deny, with the violation already shaped.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Decision {
    /// Let the call proceed.
    Allow,
    /// Refuse, carrying the violation code and human-readable reason.
    Deny {
        /// Machine-readable violation code.
        code: &'static str,
        /// Human-readable explanation.
        reason: String,
    },
}

#[async_trait]
impl Plugin for AgentStatusChecker {
    fn config(&self) -> &PluginConfig {
        &self.cfg
    }
}

impl HookHandler<CmfHook> for AgentStatusChecker {
    async fn handle(
        &self,
        _payload: &MessagePayload,
        ext: &Extensions,
        _ctx: &mut PluginContext,
    ) -> PluginResult<MessagePayload> {
        let Some(agent_id) = self.agent_id(ext) else {
            // No id means nothing to ask the registry about. Denying is the
            // only safe reading: the route asked for this check, so letting the
            // call through would silently skip governance.
            return PluginResult::deny(PluginViolation::new(
                VIOLATION_REGISTRY_UNAVAILABLE,
                "no agent id available (absent from the subject's claims and from \
                 `agent_id` in config), so the agent's status could not be checked",
            ));
        };

        // Cache first; the TTL is the revocation window (see registry.rs).
        let lookup = match self.cache.get() {
            Some(status) => StatusLookup::Known(status),
            None => {
                let fetched = self.client.fetch_status(ext, &agent_id).await;
                // Only a real answer is cached. A failure is retried next call
                // rather than pinned for the TTL.
                if let StatusLookup::Known(ref s) = fetched {
                    self.cache.put(s.clone());
                }
                fetched
            },
        };

        match self.decide(&lookup) {
            Decision::Allow => PluginResult::allow(),
            Decision::Deny { code, reason } => {
                PluginResult::deny(PluginViolation::new(code, reason))
            },
        }
    }
}

impl AgentStatusChecker {
    /// The agent's registry id: from the resolved subject's claims when the
    /// token carries one, else from config.
    ///
    /// Config is the normal path today. An IBM Verify `client_credentials`
    /// token carries `sub`/`client_id` (the OAuth client) but no claim naming
    /// the Agent Registry record, and the association is held registry-side
    /// where `oauthClients` is write-only — so it cannot be resolved by lookup
    /// either. The claim is read first anyway, so a tenant that starts issuing
    /// one needs no code change.
    fn agent_id(&self, ext: &Extensions) -> Option<String> {
        let from_claim = ext
            .security
            .as_ref()
            .and_then(|sec| sec.subject.as_ref())
            .and_then(|s| s.claim_str("agent_id"))
            .map(std::borrow::Cow::into_owned);
        from_claim.or_else(|| self.typed.agent_id.clone())
    }
}

#[cfg(test)]
#[allow(clippy::expect_used, reason = "tests")]
mod tests {
    use super::*;
    use praxis_policy_core::plugin::{OnError, PluginMode};

    /// The constructor reads the admin secret from the environment, so tests
    /// set the variable their fixture names.
    fn with_test_secret() {
        // Safe here: every test in this module uses the same name and value.
        unsafe { std::env::set_var("AGENT_STATUS_TEST_SECRET", "test-secret") };
    }

    fn checker(extra: serde_json::Value) -> AgentStatusChecker {
        with_test_secret();
        let mut cfg = serde_json::json!({
            "registry_url": "https://t.verify.ibm.com/v1.0/Agents",
            "admin_client_id": "admin-client",
            "admin_client_secret_env": "AGENT_STATUS_TEST_SECRET",
        });
        if let (Some(base), Some(add)) = (cfg.as_object_mut(), extra.as_object()) {
            for (k, v) in add {
                base.insert(k.clone(), v.clone());
            }
        }
        AgentStatusChecker::new(PluginConfig {
            name: "agent-status".into(),
            kind: crate::KIND.into(),
            hooks: vec!["cmf.tool_pre_invoke".into()],
            mode: PluginMode::Sequential,
            priority: 20,
            on_error: OnError::Fail,
            config: Some(cfg),
            ..Default::default()
        })
        .expect("config must build")
    }

    fn deny_code(d: &Decision) -> &str {
        match d {
            Decision::Deny { code, .. } => code,
            Decision::Allow => panic!("expected a deny, got allow"),
        }
    }

    #[test]
    fn active_allows() {
        let c = checker(serde_json::json!({}));
        assert_eq!(
            c.decide(&StatusLookup::Known("ACTIVE".to_owned())),
            Decision::Allow
        );
    }

    /// The whole point of the feature: the tenant still issues the token, so
    /// this is the only thing standing between a suspended agent and the tool.
    #[test]
    fn suspended_denies_with_the_agent_suspended_code() {
        let c = checker(serde_json::json!({}));
        let d = c.decide(&StatusLookup::Known("SUSPENDED".to_owned()));
        assert_eq!(deny_code(&d), VIOLATION_AGENT_SUSPENDED);
    }

    #[test]
    fn under_review_denies() {
        let c = checker(serde_json::json!({}));
        let d = c.decide(&StatusLookup::Known("UNDER_REVIEW".to_owned()));
        assert_eq!(deny_code(&d), VIOLATION_AGENT_SUSPENDED);
    }

    #[test]
    fn default_status_denies() {
        let c = checker(serde_json::json!({}));
        let d = c.decide(&StatusLookup::Known("DEFAULT".to_owned()));
        assert_eq!(deny_code(&d), VIOLATION_AGENT_SUSPENDED);
    }

    /// A status the plugin has never heard of is not a status it can vouch for.
    #[test]
    fn unrecognized_status_denies_rather_than_passing() {
        let c = checker(serde_json::json!({}));
        let d = c.decide(&StatusLookup::Known("PENDING_SOMETHING_NEW".to_owned()));
        assert_eq!(deny_code(&d), VIOLATION_AGENT_SUSPENDED);
    }

    #[test]
    fn deny_reason_names_the_actual_and_required_status() {
        let c = checker(serde_json::json!({}));
        let d = c.decide(&StatusLookup::Known("SUSPENDED".to_owned()));
        let Decision::Deny { reason, .. } = d else {
            panic!("expected deny");
        };
        assert!(reason.contains("SUSPENDED"), "names actual: {reason}");
        assert!(reason.contains("ACTIVE"), "names required: {reason}");
    }

    /// Fail-closed by default, and under a DISTINCT code: a tenant outage must
    /// not be reported as a governance decision.
    #[test]
    fn unavailable_denies_by_default_under_its_own_code() {
        let c = checker(serde_json::json!({}));
        let d = c.decide(&StatusLookup::Unavailable("connect timeout".to_owned()));
        assert_eq!(deny_code(&d), VIOLATION_REGISTRY_UNAVAILABLE);
        assert_ne!(deny_code(&d), VIOLATION_AGENT_SUSPENDED);
    }

    #[test]
    fn unavailable_allows_only_when_explicitly_configured() {
        let c = checker(serde_json::json!({ "on_unavailable": "allow" }));
        assert_eq!(
            c.decide(&StatusLookup::Unavailable("connect timeout".to_owned())),
            Decision::Allow
        );
    }

    #[test]
    fn a_non_default_required_status_is_honored() {
        let c = checker(serde_json::json!({ "required_status": "UNDER_REVIEW" }));
        assert_eq!(
            c.decide(&StatusLookup::Known("UNDER_REVIEW".to_owned())),
            Decision::Allow
        );
        assert_eq!(
            deny_code(&c.decide(&StatusLookup::Known("ACTIVE".to_owned()))),
            VIOLATION_AGENT_SUSPENDED
        );
    }

    #[test]
    fn zero_cache_ttl_is_rejected() {
        with_test_secret();
        let err = AgentStatusChecker::new(PluginConfig {
            name: "agent-status".into(),
            kind: crate::KIND.into(),
            hooks: vec!["cmf.tool_pre_invoke".into()],
            mode: PluginMode::Sequential,
            priority: 20,
            on_error: OnError::Fail,
            config: Some(serde_json::json!({
                "registry_url": "https://t.verify.ibm.com/v1.0/Agents",
                "admin_client_id": "admin-client",
                "admin_client_secret_env": "AGENT_STATUS_TEST_SECRET",
                "cache_ttl_seconds": 0,
            })),
            ..Default::default()
        })
        .err()
        .expect("zero ttl must not build");
        assert!(err.to_string().contains("cache_ttl_seconds"));
    }
}
