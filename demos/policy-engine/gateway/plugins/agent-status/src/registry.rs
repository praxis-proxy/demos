// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Praxis Contributors

//! Reads an agent's lifecycle status from the IBM Verify Agent Registry, and
//! caches the answer for a configured interval.
//!
//! # The cache interval is the revocation window
//!
//! An agent suspended at the tenant keeps passing until its entry expires.
//! That is the same trade the bundled api-key directory cache documents, and
//! it is the honest comparison point against a SPIFFE SVID's TTL: neither
//! mechanism is instant, and both windows are a configured number.
//!
//! # Failures are never cached
//!
//! A registry that could not answer is asked again on the next call. Caching
//! the failure would turn a blip into an outage lasting the full TTL, at
//! exactly the moment an operator is trying to recover it. The cost is that a
//! sustained outage means a lookup per call — which is the right cost, because
//! the alternative is a stale verdict about who may act.

use std::sync::RwLock;
use std::time::{Duration, Instant};

use praxis_policy_core::host::HostServices;
use praxis_policy_core::http::{HttpRequest, Method};
use praxis_policy_core::http_retry::RetryPolicy;

use crate::status::StatusLookup;

/// A status remembered until `expires_at`.
struct CachedStatus {
    status: String,
    expires_at: Instant,
}

/// Caches one agent's status. One agent per plugin instance, so this is a
/// single slot rather than a map — no key, nothing to evict, and no
/// unbounded-growth question to answer.
pub struct StatusCache {
    slot: RwLock<Option<CachedStatus>>,
    ttl: Duration,
}

impl StatusCache {
    /// A cache holding an entry for `ttl`.
    pub fn new(ttl: Duration) -> Self {
        Self {
            slot: RwLock::new(None),
            ttl,
        }
    }

    /// The cached status, when one is present and still fresh.
    pub fn get(&self) -> Option<String> {
        // A poisoned lock means another thread panicked holding it. Treat that
        // as a cache miss rather than propagating: a miss costs one lookup,
        // whereas unwrapping would turn an unrelated panic into a denial.
        let guard = self.slot.read().ok()?;
        let entry = guard.as_ref()?;
        (entry.expires_at > Instant::now()).then(|| entry.status.clone())
    }

    /// Remember `status` for the configured TTL.
    pub fn put(&self, status: String) {
        if let Ok(mut guard) = self.slot.write() {
            *guard = Some(CachedStatus {
                status,
                expires_at: Instant::now() + self.ttl,
            });
        }
    }
}

/// Where to reach the registry, and how to authenticate to it.
pub struct RegistryClient {
    /// Agent Registry collection URL (the agent id is appended).
    pub registry_url: String,
    /// Token endpoint for the admin client-credentials mint.
    pub token_url: String,
    /// Admin client id.
    pub admin_client_id: String,
    /// Admin client secret.
    pub admin_client_secret: String,
    /// Per-request deadline.
    pub timeout: Duration,
}

impl RegistryClient {
    /// Fetch `agent_id`'s status.
    ///
    /// Returns [`StatusLookup::Unavailable`] rather than an error for every
    /// failure mode: the caller's job is to decide allow/deny, and it needs a
    /// reason string, not a typed error it would only stringify.
    pub async fn fetch_status(
        &self,
        svc: &dyn HostServices,
        agent_id: &str,
    ) -> StatusLookup {
        let token = match self.admin_token(svc).await {
            Ok(t) => t,
            Err(why) => return StatusLookup::Unavailable(format!("admin token: {why}")),
        };

        let url = format!("{}/{}", self.registry_url.trim_end_matches('/'), agent_id);
        let req = match HttpRequest::get(url)
            .header("authorization", format!("Bearer {token}"))
            .and_then(|r| r.header("accept", "application/scim+json"))
        {
            Ok(r) => r.timeout(self.timeout),
            Err(e) => return StatusLookup::Unavailable(format!("bad request: {e}")),
        };

        // A GET is safe to repeat, so a transient transport failure should not
        // become a denial.
        let resp = match svc.http_request(req, RetryPolicy::idempotent()).await {
            Ok(r) => r,
            Err(e) => return StatusLookup::Unavailable(format!("registry GET: {e}")),
        };

        match resp.status {
            200 => Self::read_status(&resp.body),
            // A record that is not there is not an authorized agent. Reported
            // as Unavailable rather than as a status so the violation says
            // "could not confirm" instead of naming a status the tenant never
            // returned.
            404 => StatusLookup::Unavailable(format!("no agent record for id {agent_id}")),
            403 => StatusLookup::Unavailable(
                "registry refused the admin client (403) — check its entitlements".to_owned(),
            ),
            s => StatusLookup::Unavailable(format!("registry returned HTTP {s}")),
        }
    }

    /// Pull `.status` out of a SCIM agent record.
    fn read_status(body: &[u8]) -> StatusLookup {
        let parsed: serde_json::Value = match serde_json::from_slice(body) {
            Ok(v) => v,
            Err(e) => return StatusLookup::Unavailable(format!("registry sent non-JSON: {e}")),
        };
        match parsed.get("status").and_then(serde_json::Value::as_str) {
            Some(s) if !s.is_empty() => StatusLookup::Known(s.to_owned()),
            // Absent or non-string. NOT treated as ACTIVE: a record whose
            // status cannot be read is a record whose status is unknown.
            _ => StatusLookup::Unavailable("registry record carried no `status` field".to_owned()),
        }
    }

    /// Mint an admin access token via client_credentials.
    async fn admin_token(&self, svc: &dyn HostServices) -> Result<String, String> {
        let form = format!(
            "grant_type=client_credentials&client_id={}&client_secret={}",
            urlencode(&self.admin_client_id),
            urlencode(&self.admin_client_secret),
        );
        let req = HttpRequest::new(Method::POST, self.token_url.clone())
            .header("content-type", "application/x-www-form-urlencoded")
            .and_then(|r| r.header("accept", "application/json"))
            .map_err(|e| format!("bad request: {e}"))?
            .timeout(self.timeout)
            .body(form.into_bytes().into());

        // A client_credentials mint is not idempotent in the sense that
        // matters: a retried-but-delivered request issues a second token.
        // undelivered_only retries only when the request never arrived.
        let resp = svc
            .http_request(req, RetryPolicy::undelivered_only())
            .await
            .map_err(|e| format!("token POST: {e}"))?;

        if resp.status != 200 {
            return Err(format!("token endpoint returned HTTP {}", resp.status));
        }
        let parsed: serde_json::Value =
            serde_json::from_slice(&resp.body).map_err(|e| format!("non-JSON: {e}"))?;
        parsed
            .get("access_token")
            .and_then(serde_json::Value::as_str)
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .ok_or_else(|| "response carried no access_token".to_owned())
    }
}

/// Percent-encode a form value.
///
/// Hand-rolled rather than pulling a dependency in for two fields: a client id
/// is a UUID and a secret is base64url-ish, so the set below covers them, and
/// anything outside it is encoded rather than passed through.
fn urlencode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(char::from(b));
            },
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

#[cfg(test)]
#[allow(clippy::expect_used, reason = "tests")]
mod tests {
    use super::*;

    #[test]
    fn a_fresh_entry_is_returned() {
        let c = StatusCache::new(Duration::from_secs(60));
        c.put("ACTIVE".to_owned());
        assert_eq!(c.get().as_deref(), Some("ACTIVE"));
    }

    #[test]
    fn an_empty_cache_is_a_miss() {
        let c = StatusCache::new(Duration::from_secs(60));
        assert_eq!(c.get(), None);
    }

    /// The revocation window closing is the behavior the demo depends on.
    #[test]
    fn an_expired_entry_is_a_miss() {
        let c = StatusCache::new(Duration::from_millis(1));
        c.put("ACTIVE".to_owned());
        std::thread::sleep(Duration::from_millis(5));
        assert_eq!(c.get(), None, "a stale verdict must not be reused");
    }

    #[test]
    fn a_later_put_replaces_an_earlier_one() {
        let c = StatusCache::new(Duration::from_secs(60));
        c.put("ACTIVE".to_owned());
        c.put("SUSPENDED".to_owned());
        assert_eq!(c.get().as_deref(), Some("SUSPENDED"));
    }

    #[test]
    fn status_is_read_out_of_a_scim_record() {
        let body = br#"{"id":"x","displayName":"a","status":"SUSPENDED"}"#;
        assert_eq!(
            RegistryClient::read_status(body),
            StatusLookup::Known("SUSPENDED".to_owned())
        );
    }

    /// A record we cannot read the status of is not an ACTIVE record.
    #[test]
    fn a_record_without_status_is_unavailable_not_active() {
        let body = br#"{"id":"x","displayName":"a"}"#;
        match RegistryClient::read_status(body) {
            StatusLookup::Unavailable(why) => assert!(why.contains("status")),
            other => panic!("expected Unavailable, got {other:?}"),
        }
    }

    #[test]
    fn a_non_string_status_is_unavailable() {
        let body = br#"{"status":42}"#;
        assert!(matches!(
            RegistryClient::read_status(body),
            StatusLookup::Unavailable(_)
        ));
    }

    #[test]
    fn non_json_is_unavailable() {
        assert!(matches!(
            RegistryClient::read_status(b"<html>gateway error</html>"),
            StatusLookup::Unavailable(_)
        ));
    }

    #[test]
    fn an_empty_status_string_is_unavailable() {
        assert!(matches!(
            RegistryClient::read_status(br#"{"status":""}"#),
            StatusLookup::Unavailable(_)
        ));
    }

    #[test]
    fn form_values_are_encoded() {
        assert_eq!(urlencode("abc-123_x.y~z"), "abc-123_x.y~z");
        assert_eq!(urlencode("a+b/c=d&e"), "a%2Bb%2Fc%3Dd%26e");
    }
}
