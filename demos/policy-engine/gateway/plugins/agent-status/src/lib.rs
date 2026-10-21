// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Praxis Contributors

//! Denies a request when the calling agent's IBM Verify Agent Registry status
//! is not `ACTIVE`.
//!
//! IBM Verify records an agent's lifecycle status (`ACTIVE`, `SUSPENDED`,
//! `UNDER_REVIEW`, `DEFAULT`) but does not enforce it at the token endpoint: a
//! suspended agent still mints tokens, and tokens minted before the suspend
//! stay valid. Verified against a live tenant. So "suspend this agent" is only
//! a real control if something downstream of the IdP honors it, and here that
//! is the policy layer.
//!
//! Runs on `cmf.tool_pre_invoke`, reached by a `run(agent-status)` step in the
//! route's `authorization:` block, and reads the already-resolved subject from
//! `Extensions`. On the allow path it returns the payload unchanged — it makes
//! no contribution of its own, it only decides.
//!
//! It runs on an authorization hook rather than `identity.resolve`, despite the
//! `auth.*` violation code, for a wire-shape reason: a deny during
//! authentication becomes HTTP 401 with a plain-text body, whereas the demo's
//! scenario harness asserts the violation code in BOTH the
//! `X-Policy-Violation` header and the JSON-RPC `.error.data.violation`. Only
//! an authorization-phase deny produces that envelope. See the note on
//! [`factory::AgentStatusFactory`].

/// Plugin configuration.
pub mod config;
/// Constructs the checker from configuration.
pub mod factory;
/// Reads agent status from the registry, with a TTL cache.
pub mod registry;
/// The status decision.
pub mod status;

pub use config::AgentStatusConfig;
pub use factory::{AgentStatusFactory, KIND};
pub use registry::{RegistryClient, StatusCache};
pub use status::AgentStatusChecker;

/// Violation code emitted when the agent is not `ACTIVE`.
///
/// Follows the `auth.*` convention used by the identity plugins
/// (`auth.untrusted_issuer`, `auth.token_expired`). There is no central
/// violation registry; the code is the string the host maps to the wire.
pub const VIOLATION_AGENT_SUSPENDED: &str = "auth.agent_suspended";

/// Violation code emitted when the registry could not be consulted.
///
/// Distinct from [`VIOLATION_AGENT_SUSPENDED`] on purpose: "we could not ask"
/// and "we asked and it is suspended" are different operational facts, and
/// collapsing them would make a tenant outage look like a governance action.
pub const VIOLATION_REGISTRY_UNAVAILABLE: &str = "auth.agent_registry_unavailable";
