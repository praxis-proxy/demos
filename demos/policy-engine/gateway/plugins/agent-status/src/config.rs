// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Praxis Contributors

use serde::Deserialize;

/// Default status an agent must hold for the call to proceed.
fn default_required_status() -> String {
    "ACTIVE".to_owned()
}

/// Default per-request deadline for a registry or token call.
fn default_request_timeout_ms() -> u64 {
    5_000
}

/// Default cache lifetime for a status lookup.
///
/// This interval IS the revocation window: an agent suspended at the tenant
/// keeps passing until its entry expires. Five seconds keeps the demo honest
/// (a suspend takes effect while the presenter is still talking) without a
/// registry round-trip on every call.
fn default_cache_ttl_seconds() -> u64 {
    5
}

/// What to do when the registry cannot be consulted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OnUnavailable {
    /// Refuse the call. The default: a kill switch that fails open is not a
    /// kill switch.
    Deny,
    /// Allow the call through. Only for a demo that must survive a tenant
    /// outage; it means a suspended agent works whenever the registry is down.
    Allow,
}

impl Default for OnUnavailable {
    fn default() -> Self {
        Self::Deny
    }
}

/// `config:` block for `kind: validator/agent-status`.
#[derive(Debug, Clone, Deserialize)]
pub struct AgentStatusConfig {
    /// Agent Registry collection URL, e.g.
    /// `https://tenant.verify.ibm.com/v1.0/Agents`. The agent id is appended.
    pub registry_url: String,

    /// Agent Registry record id (a UUID).
    ///
    /// Used when the agent's token carries no claim naming its own registry
    /// id, which is the case on IBM Verify today: a `client_credentials` token
    /// carries `sub`/`client_id` (the OAuth client) but nothing linking it to
    /// the Agent record. The association is held registry-side, and
    /// `oauthClients` is write-only there, so it cannot be resolved by lookup
    /// either. Hence config.
    pub agent_id: Option<String>,

    /// Status the agent must hold. Defaults to `ACTIVE`.
    #[serde(default = "default_required_status")]
    pub required_status: String,

    /// How long a status lookup is reused. See
    /// [`default_cache_ttl_seconds`] on why this is the revocation window.
    #[serde(default = "default_cache_ttl_seconds")]
    pub cache_ttl_seconds: u64,

    /// Behavior when the registry cannot be reached or returns garbage.
    #[serde(default)]
    pub on_unavailable: OnUnavailable,

    /// Token endpoint for the admin client-credentials mint. Defaults to
    /// `<registry origin>/oauth2/token`, which is right for an IBM Verify
    /// tenant; set it explicitly for anything else.
    #[serde(default)]
    pub token_url: Option<String>,

    /// Admin client id used to read the registry.
    pub admin_client_id: String,

    /// Name of the environment variable holding the admin client secret.
    ///
    /// A name rather than the value: the secret is a live tenant credential
    /// and must not sit in a rendered config on disk. Mirrors the
    /// `client_secret_source: {kind: env_var}` shape the delegators use.
    pub admin_client_secret_env: String,

    /// Per-request deadline for the token mint and the registry GET.
    #[serde(default = "default_request_timeout_ms")]
    pub request_timeout_ms: u64,
}

impl AgentStatusConfig {
    /// The token endpoint, explicit or derived from the registry URL.
    pub fn resolved_token_url(&self) -> Result<String, String> {
        if let Some(t) = self.token_url.as_deref().filter(|t| !t.is_empty()) {
            return Ok(t.to_owned());
        }
        // Derive from the registry origin: ".../v1.0/Agents" -> ".../oauth2/token".
        let marker = "/v1.0/";
        let origin = self
            .registry_url
            .find(marker)
            .map(|i| &self.registry_url[..i])
            .ok_or_else(|| {
                format!(
                    "cannot derive a token endpoint from registry_url '{}' (expected it to \
                     contain '/v1.0/'); set `token_url` explicitly",
                    self.registry_url
                )
            })?;
        Ok(format!("{origin}/oauth2/token"))
    }
}

#[cfg(test)]
#[allow(clippy::expect_used, reason = "tests")]
mod tests {
    use super::*;

    /// The minimum an operator must write. Everything else defaults.
    fn minimal() -> serde_json::Value {
        serde_json::json!({
            "registry_url": "https://t.verify.ibm.com/v1.0/Agents",
            "admin_client_id": "admin-client",
            "admin_client_secret_env": "VERIFY_ADMIN_CLIENT_SECRET",
        })
    }

    #[test]
    fn defaults_fill_in_when_only_the_required_fields_are_given() {
        let cfg: AgentStatusConfig =
            serde_json::from_value(minimal()).expect("a minimal config must parse");
        assert_eq!(cfg.required_status, "ACTIVE");
        assert_eq!(cfg.cache_ttl_seconds, 5);
        assert_eq!(cfg.request_timeout_ms, 5_000);
        assert_eq!(
            cfg.on_unavailable,
            OnUnavailable::Deny,
            "an unreachable registry must not fail open by default"
        );
    }

    #[test]
    fn missing_registry_url_is_rejected() {
        let err = serde_json::from_value::<AgentStatusConfig>(serde_json::json!({}))
            .err()
            .expect("a config with no registry_url must not parse");
        assert!(
            err.to_string().contains("registry_url"),
            "the message must name the missing key: {err}"
        );
    }

    #[test]
    fn on_unavailable_allow_is_opt_in_by_name() {
        let mut v = minimal();
        v["on_unavailable"] = serde_json::json!("allow");
        let cfg: AgentStatusConfig =
            serde_json::from_value(v).expect("explicit allow must parse");
        assert_eq!(cfg.on_unavailable, OnUnavailable::Allow);
    }

    #[test]
    fn missing_admin_client_id_is_rejected() {
        let mut v = minimal();
        v.as_object_mut().expect("object").remove("admin_client_id");
        let err = serde_json::from_value::<AgentStatusConfig>(v)
            .err()
            .expect("must not parse");
        assert!(err.to_string().contains("admin_client_id"));
    }

    /// The secret is named, never inlined — a rendered config on disk must not
    /// carry a live tenant credential.
    #[test]
    fn missing_admin_secret_env_name_is_rejected() {
        let mut v = minimal();
        v.as_object_mut()
            .expect("object")
            .remove("admin_client_secret_env");
        let err = serde_json::from_value::<AgentStatusConfig>(v)
            .err()
            .expect("must not parse");
        assert!(err.to_string().contains("admin_client_secret_env"));
    }

    #[test]
    fn the_token_url_is_derived_from_the_registry_url() {
        let cfg: AgentStatusConfig = serde_json::from_value(minimal()).expect("parse");
        assert_eq!(
            cfg.resolved_token_url().expect("derivable"),
            "https://t.verify.ibm.com/oauth2/token"
        );
    }

    #[test]
    fn an_explicit_token_url_wins() {
        let mut v = minimal();
        v["token_url"] = serde_json::json!("https://other/token");
        let cfg: AgentStatusConfig = serde_json::from_value(v).expect("parse");
        assert_eq!(cfg.resolved_token_url().expect("explicit"), "https://other/token");
    }

    /// A registry URL that is not Verify-shaped cannot be guessed from, and the
    /// error must say what to do about it rather than inventing an endpoint.
    #[test]
    fn an_underivable_token_url_is_an_error_naming_the_fix() {
        let mut v = minimal();
        v["registry_url"] = serde_json::json!("https://example.com/agents");
        let cfg: AgentStatusConfig = serde_json::from_value(v).expect("parse");
        let err = cfg.resolved_token_url().err().expect("not derivable");
        assert!(err.contains("token_url"), "names the key to set: {err}");
    }
}
