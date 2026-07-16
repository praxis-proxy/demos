// SPDX-License-Identifier: MIT
// Copyright (c) 2024 Praxis Contributors

//! Thin serializable mirrors of the transpiler's two emission targets: a
//! CPEX policy document and a Praxis `policy`-filter block.
//!
//! These are purpose-built shapes rather than a CPEX config struct: the APL
//! authorization steps a policy carries are read out-of-band by CPEX's
//! apl-cpex visitor and are not fields on its route entry, so a faithful
//! emission needs its own shape. Output is checked by the golden corpus and
//! the structural invariant assertions in `main.rs`; this demo does not
//! depend on the CPEX crate.

use serde::Serialize;

// ---------------------------------------------------------------------------
// CPEX policy document
// ---------------------------------------------------------------------------

/// A CPEX policy document (the file a `policy` filter's `config_path`
/// points at).
#[derive(Debug, Serialize)]
pub(crate) struct CpexDoc {
    pub plugin_settings: PluginSettings,
    pub plugins: Vec<PluginEntry>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub global: Option<GlobalOut>,
}

#[derive(Debug, Serialize)]
pub(crate) struct PluginSettings {
    pub routing_enabled: bool,
}

/// One CPEX plugin entry. Only `identity/jwt` is emitted this iteration.
#[derive(Debug, Serialize)]
pub(crate) struct PluginEntry {
    pub name: String,
    pub kind: String,
    pub hooks: Vec<String>,
    /// `fail` so a bad/missing credential denies (fail-closed identity).
    pub on_error: String,
    pub config: JwtConfig,
}

/// `identity/jwt` plugin config (mirrors `JwtIdentityResolverConfig`).
#[derive(Debug, Serialize)]
pub(crate) struct JwtConfig {
    /// Identity slot the claim mapper fills. `user` so the standard mapper's
    /// `map_subject` runs and populates `role.*` / `perm.*` / `team.*`.
    pub role: String,
    pub header: String,
    pub trusted_issuers: Vec<TrustedIssuer>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub claim_mapper: Option<String>,
}

#[derive(Debug, Serialize)]
pub(crate) struct TrustedIssuer {
    pub issuer: String,
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub audiences: Vec<String>,
    /// Never empty — explicit algorithm pinning (plan R21).
    pub algorithms: Vec<String>,
    pub decoding_key: DecodingKey,
}

/// Subset of `cpex` `DecodingKeySource` we emit (tagged by `kind`).
#[derive(Debug, Serialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub(crate) enum DecodingKey {
    JwksUrl { url: String },
    Secret { secret: String },
}

/// The CPEX `global` catch-all policy — where a generic-HTTP (non-MCP)
/// authorization policy belongs. Emitted in the **canonical block form**
/// (`authentication:` + `authorization:` directly under `global:`, no `apl:`
/// wrapper). CPEX evaluates this policy for entity-less HTTP requests via the
/// `cmf.http_request` hook.
#[derive(Debug, Serialize)]
pub(crate) struct GlobalOut {
    /// Identity dispatch list (names of the `identity/jwt` plugins declared
    /// under top-level `plugins:`). The renamed canonical form of `identity:`.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub authentication: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub authorization: Option<AuthorizationOut>,
    /// PDP resolver declarations. Emitted as `[{ kind: cel }]` whenever any
    /// `cel:` step is produced: a `cel:` step needs the `cel` resolver
    /// declared into the policy's PDP router, or it fails closed (deny) at
    /// evaluation time. The CEL expression lives in the step, so the entry
    /// just names the kind.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub pdp: Vec<PdpEntry>,
}

/// One `global.pdp` entry — declares a PDP resolver by `kind`.
#[derive(Debug, Serialize)]
pub(crate) struct PdpEntry {
    pub kind: String,
}

impl PdpEntry {
    /// The bundled CEL resolver declaration (`- kind: cel`).
    pub(crate) fn cel() -> Self {
        Self {
            kind: "cel".to_owned(),
        }
    }
}

/// The canonical `authorization:` block. `pre_invocation` is the renamed
/// form of the legacy `policy:` step list (which CPEX now rejects).
#[derive(Debug, Serialize)]
pub(crate) struct AuthorizationOut {
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub pre_invocation: Vec<PolicyStep>,
}

/// One `pre_invocation` step. Kuadrant predicates are CEL, so they are
/// emitted as `cel: { expr }` PDP steps (dispatched to CPEX's bundled `cel`
/// resolver, which evaluates full CEL: `startsWith`, `&&`/`||`, literal
/// `in`, …). The APL-native `require(...)` form is reserved for the two
/// things that are genuinely native attribute predicates — the
/// `require(authenticated)` presence gate and the `require(false)`
/// fail-closed sentinel — because `require(...)` parses APL's own predicate
/// DSL (`&`/`|`, key-in-key membership), not CEL.
#[derive(Debug, Serialize)]
#[serde(untagged)]
pub(crate) enum PolicyStep {
    /// A bare APL predicate rule, e.g. `require(authenticated)`.
    Require(String),
    /// A CEL PDP step: `cel: { expr: "..." }`.
    Cel { cel: CelExpr },
}

/// The `expr:` payload of a `cel:` PDP step.
#[derive(Debug, Serialize)]
pub(crate) struct CelExpr {
    pub expr: String,
}

impl PolicyStep {
    /// The `require(authenticated)` native presence gate.
    pub(crate) fn require_authenticated() -> Self {
        Self::Require("require(authenticated)".to_owned())
    }

    /// The `require(false)` fail-closed deny-all sentinel.
    pub(crate) fn deny_all() -> Self {
        Self::Require("require(false)".to_owned())
    }

    /// A `cel: { expr }` PDP step wrapping a remapped CEL predicate.
    pub(crate) fn cel(expr: String) -> Self {
        Self::Cel {
            cel: CelExpr { expr },
        }
    }
}

// ---------------------------------------------------------------------------
// Praxis policy-filter block
// ---------------------------------------------------------------------------

/// The Praxis `policy` filter entry the operator adds to a filter chain.
/// The filter derives its evaluation from the loaded policy: a `global`-only
/// document (as emitted here) is authorized at the HTTP layer, so no
/// enforcement-mode field is needed.
#[derive(Debug, Serialize)]
pub(crate) struct FilterBlock {
    pub filter: String,
    pub config_path: String,
}
