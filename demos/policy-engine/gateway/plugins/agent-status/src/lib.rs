// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 Praxis Contributors

//! Deny tool calls unless the agent is ACTIVE in the IBM Verify Agent Registry.
//!
//! Runs on cmf.tool_pre_invoke via run(agent-status), after identity resolution.
//! Authorization denies carry the JSON-RPC error envelope used by the scenarios;
//! authentication denies return HTTP 401.
//!
//! Verify can issue tokens to suspended agents, so the gateway checks registry
//! status separately. Cached status remains valid until its TTL expires.

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

/// Violation code for an agent whose status is not ACTIVE.
pub const VIOLATION_AGENT_SUSPENDED: &str = "auth.agent_suspended";

/// Violation code for a failed registry lookup.
pub const VIOLATION_REGISTRY_UNAVAILABLE: &str = "auth.agent_registry_unavailable";
