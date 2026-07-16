// SPDX-License-Identifier: MIT
// Copyright (c) 2024 Praxis Contributors

//! Translate a parsed [`AuthPolicy`] into a CPEX policy document, a Praxis
//! `policy`-filter block, and a coverage report.
//!
//! Translation is best-effort but **fail-closed** (plan R19): if a policy
//! declares authorization rules and none of them survive translation, the
//! emitted CPEX policy gets a `require(false)` deny-all step and the report
//! records a [`Severity::Fatal`] entry so the CLI exits non-zero.
//!
//! Kuadrant `patternMatching`/`when` predicates are CEL, so each translated
//! rule is emitted as a `cel: { expr }` PDP step (dispatched to CPEX's
//! bundled `cel` resolver — full CEL), not wrapped in `require(...)`, whose
//! APL predicate DSL is a different, non-CEL language. The APL-native
//! `require(...)` form is used only for the `require(authenticated)`
//! presence gate and the `require(false)` fail-closed sentinel. Kuadrant
//! evaluation semantics are preserved where expressible (R22): patterns are
//! AND-combined, `any`/`all` map to `||`/`&&`, and per-rule `when` gates it.
//! Identity/response/security posture follows R21 (explicit JWT algorithms,
//! header-trust warnings, `denyWith` control-character checks).

use std::collections::BTreeMap;

use serde_yaml::Value;

use super::{
    cel::{self, Remap},
    emit::{
        AuthorizationOut, CpexDoc, DecodingKey, FilterBlock, GlobalOut, JwtConfig, PdpEntry,
        PluginEntry, PluginSettings, PolicyStep, TrustedIssuer,
    },
    model::{AuthPolicy, AuthScheme, AuthnMethod, AuthzMethod, PatternExpr, ResponseSpec, Spec},
    report::{Report, Severity},
};

/// Default algorithm pinning for JWKS-based issuers when the source
/// `AuthPolicy` does not pin algorithms (never empty). RS256 is the OIDC
/// default and the algorithm virtually every IdP (Keycloak, Auth0, Okta)
/// signs access tokens with; pinning a single algorithm avoids an
/// `InvalidAlgorithm` rejection when the JWKS also advertises keys for other
/// uses. Operators serving ES256 (etc.) widen this in the emitted policy.
const DEFAULT_JWT_ALGORITHMS: [&str; 1] = ["RS256"];

/// The output of transpiling one `AuthPolicy`.
pub(crate) struct Transpiled {
    /// Serialized CPEX policy document (YAML).
    pub cpex_doc: String,
    /// Serialized Praxis `policy` filter block (YAML).
    pub filter_block: String,
    /// Coverage report.
    pub report: Report,
}

/// Transpile an `AuthPolicy`. `slug` names the policy for placeholder paths.
pub(crate) fn transpile(policy: &AuthPolicy, slug: &str) -> Transpiled {
    let mut report = Report::default();

    if policy.spec.target_ref.is_some() {
        report.skipped(
            "spec.targetRef",
            Severity::Info,
            "Gateway API binding is not translated; wire the emitted filter block into a Praxis chain manually.",
        );
    }

    let scheme = resolve_scheme(&policy.spec, &mut report);

    let plugins = scheme.map_or_else(Vec::new, |s| translate_authn(s, &mut report));
    let authentication = scheme.map_or_else(Vec::new, jwt_plugin_names);
    let policy_steps = scheme.map_or_else(Vec::new, |s| translate_authz(policy, s, &mut report));

    if let Some(s) = scheme {
        if let Some(resp) = s.response.as_ref() {
            report_response(resp, &mut report);
        }
        report_metadata_callbacks(s, &mut report);
    }

    // Prepend the native `require(authenticated)` presence gate when an
    // identity is configured: a cheap APL attribute check that denies before
    // any CEL PDP step runs if no verified subject resolved. (Identity itself
    // also fails closed via the plugin's `on_error: fail`; this makes the
    // policy's presence requirement explicit.) It is intentionally not gated
    // by `spec.when` — presence is required whenever the policy is active.
    let mut policy_steps = policy_steps;
    if !authentication.is_empty() {
        policy_steps.insert(0, PolicyStep::require_authenticated());
    }

    // `spec.when` (policy activation) folds into each CEL step: the flat
    // `global` form has no route-level `when` gate, so a rule only denies
    // when the activation condition holds.
    let when = top_level_when(&policy.spec, &mut report);
    let steps = gate_with_when(policy_steps, when.as_deref());

    // Emit under the CPEX `global` policy using the canonical
    // `authentication:` + `authorization:` block form (no `apl:` wrapper) —
    // the designed home for catch-all, non-entity HTTP policies. CPEX
    // evaluates it for generic HTTP requests via the `cmf.http_request` hook.
    // A `cel:` step needs the `cel` resolver declared into the policy's PDP
    // router; without `pdp: [{ kind: cel }]` every `cel:` step fails closed
    // (deny) at evaluation time. Emit the declaration whenever any step is a
    // CEL step.
    let pdp = if steps.iter().any(|s| matches!(s, PolicyStep::Cel { .. })) {
        vec![PdpEntry::cel()]
    } else {
        Vec::new()
    };
    let authorization = (!steps.is_empty()).then_some(AuthorizationOut {
        pre_invocation: steps,
    });
    let global = (!authentication.is_empty() || authorization.is_some() || !pdp.is_empty())
        .then_some(GlobalOut {
            authentication,
            authorization,
            pdp,
        });

    let doc = CpexDoc {
        plugin_settings: PluginSettings {
            routing_enabled: true,
        },
        plugins,
        global,
    };

    let filter_block = FilterBlock {
        filter: "policy".to_owned(),
        config_path: format!("/etc/praxis/{slug}-cpex-policy.yaml"),
    };

    Transpiled {
        cpex_doc: serde_yaml::to_string(&doc).unwrap_or_else(|e| format!("# emit error: {e}\n")),
        filter_block: serde_yaml::to_string(&filter_block)
            .unwrap_or_else(|e| format!("# emit error: {e}\n")),
        report,
    }
}

/// Resolve the effective auth scheme, preferring implicit `spec.rules`.
/// `defaults`/`overrides` hierarchy is collapsed to a single policy and
/// reported (plan: hierarchy is a gap).
fn resolve_scheme<'a>(spec: &'a Spec, report: &mut Report) -> Option<&'a AuthScheme> {
    if let Some(rules) = spec.rules.as_ref() {
        if spec.defaults.is_some() || spec.overrides.is_some() {
            report.approximated(
                "spec.defaults/overrides",
                Severity::Warning,
                "Policy mixes implicit rules with defaults/overrides; only spec.rules was translated.",
            );
        }
        return Some(rules);
    }
    if let Some(d) = spec.overrides.as_ref().or(spec.defaults.as_ref()) {
        report.approximated(
            "spec.defaults/overrides",
            Severity::Warning,
            "defaults/overrides hierarchy is not resolved; translated as a single flat policy.",
        );
        return d.rules.as_ref();
    }
    None
}

/// Names of the JWT identity plugins, in scheme order — emitted as the
/// canonical `global.authentication` dispatch list (they are declared in
/// full under top-level `plugins:`).
fn jwt_plugin_names(scheme: &AuthScheme) -> Vec<String> {
    scheme
        .authentication
        .iter()
        .filter(|(_, r)| r.method() == AuthnMethod::Jwt)
        .map(|(name, _)| name.clone())
        .collect()
}

/// Fold `spec.when` into each CEL authorization step so a rule only denies
/// when the activation condition holds. The flat `global` policy has no
/// route `when` gate, so it is expressed per step. Only `cel:` steps are
/// folded (the fold is CEL: `!(when) || (expr)`); the native `require(...)`
/// steps — the presence gate and the fail-closed sentinel — are left
/// untouched, since APL's `require` DSL is not CEL.
fn gate_with_when(steps: Vec<PolicyStep>, when: Option<&str>) -> Vec<PolicyStep> {
    let Some(when) = when else { return steps };
    steps
        .into_iter()
        .map(|s| match s {
            PolicyStep::Cel { cel } => PolicyStep::cel(format!("!({when}) || ({})", cel.expr)),
            require @ PolicyStep::Require(_) => require,
        })
        .collect()
}

/// Translate authentication rules into `identity/jwt` plugins.
fn translate_authn(scheme: &AuthScheme, report: &mut Report) -> Vec<PluginEntry> {
    let mut plugins = Vec::new();
    let jwt_count = scheme
        .authentication
        .values()
        .filter(|r| r.method() == AuthnMethod::Jwt)
        .count();

    for (name, rule) in &scheme.authentication {
        let construct = format!("authentication/{name}");
        match rule.method() {
            AuthnMethod::Jwt => {
                let Some(jwt) = rule.jwt.as_ref() else { continue };
                let header = rule
                    .credentials
                    .as_ref()
                    .and_then(|c| {
                        c.custom_header
                            .as_ref()
                            .map(|h| h.name.clone())
                            .or_else(|| c.authorization_header.as_ref().map(|_| "Authorization".to_owned()))
                    })
                    .unwrap_or_else(|| "Authorization".to_owned());

                let (url, jwks_note) = match (jwt.jwks_url.as_ref(), jwt.issuer_url.as_ref()) {
                    (Some(jwks), _) => (jwks.clone(), None),
                    (None, Some(issuer)) => (
                        issuer.clone(),
                        Some(
                            "issuerUrl maps to OIDC discovery, which CPEX identity/jwt does not perform; set decoding_key.url to the IdP's JWKS endpoint.",
                        ),
                    ),
                    (None, None) => (
                        String::new(),
                        Some("neither issuerUrl nor jwksUrl present; decoding_key.url left blank for the operator."),
                    ),
                };
                let issuer = jwt.issuer_url.clone().unwrap_or_default();

                plugins.push(PluginEntry {
                    name: name.clone(),
                    kind: "identity/jwt".to_owned(),
                    hooks: vec!["identity.resolve".to_owned()],
                    on_error: "fail".to_owned(),
                    config: JwtConfig {
                        role: "user".to_owned(),
                        header,
                        trusted_issuers: vec![TrustedIssuer {
                            issuer,
                            audiences: Vec::new(),
                            algorithms: DEFAULT_JWT_ALGORITHMS.iter().map(|s| (*s).to_owned()).collect(),
                            decoding_key: DecodingKey::JwksUrl { url },
                        }],
                        claim_mapper: Some("standard".to_owned()),
                    },
                });

                report.translated(
                    &construct,
                    "JWT → identity/jwt (role: user; algorithms default to RS256 — widen in the emitted policy if the IdP signs with ES256/etc.).",
                );
                if let Some(note) = jwks_note {
                    report.approximated(&construct, Severity::Warning, note);
                }
                if rule.priority.is_some() && jwt_count > 1 {
                    report.approximated(
                        &construct,
                        Severity::Warning,
                        "priority/fallback ordering across multiple authentication rules is not preserved; all JWT issuers are accepted independently.",
                    );
                }
            },
            AuthnMethod::Anonymous => report.skipped(
                &construct,
                Severity::Warning,
                "anonymous authentication is not translated; the emitted policy requires a valid credential.",
            ),
            other => report.skipped(
                &construct,
                Severity::Warning,
                format!(
                    "authentication method `{}` is not supported this iteration.",
                    other.label()
                ),
            ),
        }
    }
    plugins
}

/// Translate authorization rules into `cel: { expr }` PDP steps, failing
/// closed with `require(false)` if authz was declared but nothing translated
/// (R19).
fn translate_authz(
    policy: &AuthPolicy,
    scheme: &AuthScheme,
    report: &mut Report,
) -> Vec<PolicyStep> {
    // Pre-translate named patterns so `patternRef` can inline them.
    let named = translate_named_patterns(&policy.spec, report);

    let mut steps = Vec::new();
    let mut header_rule_seen = false;
    let mut nested_claim_seen = false;

    for (name, rule) in &scheme.authorization {
        let construct = format!("authorization/{name}");
        match rule.method() {
            AuthzMethod::PatternMatching => {
                let Some(pm) = rule.pattern_matching.as_ref() else {
                    continue;
                };
                let mut ctx = CelCtx {
                    report,
                    named: &named,
                    construct: &construct,
                    ok: true,
                };
                let body = patterns_anded(&pm.patterns, &mut ctx);
                let translated_ok = ctx.ok;
                let Some(mut expr) = body else {
                    report.skipped(
                        &construct,
                        Severity::Warning,
                        "patternMatching produced no translatable predicate (all patterns were gaps).",
                    );
                    continue;
                };

                // Per-rule `when` gates the rule: applies => require(expr).
                if let Some(when) = rule.when.as_ref() {
                    let mut wctx = CelCtx {
                        report,
                        named: &named,
                        construct: &construct,
                        ok: true,
                    };
                    if let Some(when_cel) = patterns_anded(when, &mut wctx) {
                        expr = format!("!({when_cel}) || ({expr})");
                    } else {
                        report.approximated(
                            &construct,
                            Severity::Warning,
                            "rule `when` condition could not be translated; the rule is applied unconditionally.",
                        );
                    }
                }

                if expr.contains("http.request_headers.") {
                    header_rule_seen = true;
                }
                if has_nested_claim(&expr) {
                    nested_claim_seen = true;
                }

                steps.push(PolicyStep::cel(expr));
                if translated_ok {
                    report.translated(&construct, "patternMatching → CEL PDP step (`cel: { expr }`).");
                } else {
                    report.approximated(
                        &construct,
                        Severity::Warning,
                        "some patterns were dropped as gaps; the emitted rule enforces only the translatable subset.",
                    );
                }
            },
            other => report.skipped(
                &construct,
                Severity::Warning,
                format!(
                    "authorization method `{}` is not supported; its intent is NOT enforced by the emitted policy.",
                    other.label()
                ),
            ),
        }
    }

    if header_rule_seen {
        report.approximated(
            "authorization (headers)",
            Severity::Warning,
            "a rule keys on request headers; in Praxis these are client-suppliable unless stripped upstream (plan R21).",
        );
    }
    if nested_claim_seen {
        report.approximated(
            "authentication (claims)",
            Severity::Warning,
            "a rule references a nested identity claim (e.g. Keycloak realm_access.roles); the `standard` claim mapper does not surface nested claims as usable keys (needs Phase B U14).",
        );
    }

    // Fail-closed: authz declared but nothing enforceable was produced.
    if !scheme.authorization.is_empty() && steps.is_empty() {
        report.skipped(
            "authorization",
            Severity::Fatal,
            "authorization rules were declared but none translated to an enforceable policy; emitting deny-all to avoid failing open.",
        );
        steps.push(PolicyStep::deny_all());
    }

    steps
}

/// Pre-translate `spec.patterns` (named patterns) to CEL, for `patternRef`.
fn translate_named_patterns(spec: &Spec, report: &mut Report) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    let patterns = spec
        .patterns
        .as_ref()
        .or_else(|| spec.defaults.as_ref().and_then(|d| d.patterns.as_ref()))
        .or_else(|| spec.overrides.as_ref().and_then(|d| d.patterns.as_ref()));
    let Some(patterns) = patterns else { return out };
    for (name, exprs) in patterns {
        let construct = format!("patterns/{name}");
        // Named patterns cannot reference other named patterns at this layer
        // (kept simple); pass an empty map.
        let empty = BTreeMap::new();
        let mut ctx = CelCtx {
            report,
            named: &empty,
            construct: &construct,
            ok: true,
        };
        if let Some(cel) = patterns_anded(exprs, &mut ctx) {
            out.insert(name.clone(), cel);
        } else {
            report.skipped(
                &construct,
                Severity::Warning,
                "named pattern could not be translated; references to it become gaps.",
            );
        }
    }
    out
}

/// Translate top-level `spec.when` (policy activation) to CEL; the caller
/// folds it into the global policy steps.
fn top_level_when(spec: &Spec, report: &mut Report) -> Option<String> {
    let when = spec
        .when
        .as_ref()
        .or_else(|| spec.defaults.as_ref().and_then(|d| d.when.as_ref()))
        .or_else(|| spec.overrides.as_ref().and_then(|d| d.when.as_ref()))?;
    let empty = BTreeMap::new();
    let mut ctx = CelCtx {
        report,
        named: &empty,
        construct: "spec.when",
        ok: true,
    };
    if let Some(cel) = patterns_anded(when, &mut ctx) {
        report.translated(
            "spec.when",
            "policy activation condition folded into the global policy steps.",
        );
        Some(cel)
    } else {
        report.skipped(
            "spec.when",
            Severity::Warning,
            "policy activation condition could not be translated; the policy applies unconditionally.",
        );
        None
    }
}

/// Shared context threaded through pattern translation.
struct CelCtx<'a> {
    report: &'a mut Report,
    named: &'a BTreeMap<String, String>,
    construct: &'a str,
    /// Set to false when any sub-pattern is dropped as a gap.
    ok: bool,
}

/// AND a list of pattern expressions into a single CEL string.
/// Returns `None` if every pattern was a gap.
fn patterns_anded(patterns: &[PatternExpr], ctx: &mut CelCtx<'_>) -> Option<String> {
    join_patterns(patterns, "&&", ctx)
}

fn join_patterns(patterns: &[PatternExpr], op: &str, ctx: &mut CelCtx<'_>) -> Option<String> {
    let mut parts = Vec::new();
    for p in patterns {
        match pattern_to_cel(p, ctx) {
            Some(cel) => parts.push(format!("({cel})")),
            None => ctx.ok = false,
        }
    }
    if parts.is_empty() {
        return None;
    }
    Some(parts.join(&format!(" {op} ")))
}

/// Translate one pattern expression to CEL, recording gaps on `ctx`.
fn pattern_to_cel(expr: &PatternExpr, ctx: &mut CelCtx<'_>) -> Option<String> {
    match expr {
        PatternExpr::Predicate { predicate } => match cel::remap(predicate) {
            Remap::Ok(s) => Some(s),
            Remap::Gap { reference } => {
                ctx.report.skipped(
                    ctx.construct,
                    Severity::Warning,
                    format!("CEL predicate references `{reference}`, which has no CPEX equivalent; dropped."),
                );
                None
            }
        },
        PatternExpr::All { all } => join_patterns(all, "&&", ctx),
        PatternExpr::Any { any } => join_patterns(any, "||", ctx),
        PatternExpr::Ref { pattern_ref } => {
            if let Some(cel) = ctx.named.get(pattern_ref) {
                Some(cel.clone())
            } else {
                ctx.report.skipped(
                    ctx.construct,
                    Severity::Warning,
                    format!(
                        "patternRef `{pattern_ref}` is undefined or was itself a gap; dropped."
                    ),
                );
                None
            }
        }
        PatternExpr::Selector {
            selector,
            operator,
            value,
        } => selector_to_cel(selector, operator.as_deref(), value.as_ref(), ctx),
        PatternExpr::Other(_) => {
            ctx.report.skipped(
                ctx.construct,
                Severity::Warning,
                "unrecognized pattern shape; dropped.",
            );
            None
        }
    }
}

/// Lower a deprecated `selector`/`operator`/`value` pattern to CEL.
fn selector_to_cel(
    selector: &str,
    operator: Option<&str>,
    value: Option<&Value>,
    ctx: &mut CelCtx<'_>,
) -> Option<String> {
    let sel = match cel::remap(selector) {
        Remap::Ok(s) => s,
        Remap::Gap { reference } => {
            ctx.report.skipped(
                ctx.construct,
                Severity::Warning,
                format!(
                    "selector references `{reference}`, which has no CPEX equivalent; dropped."
                ),
            );
            return None;
        }
    };
    let op = operator.unwrap_or("eq");
    let lit = value.and_then(value_to_cel);
    match (op, lit) {
        ("eq", Some(v)) => Some(format!("{sel} == {v}")),
        ("neq", Some(v)) => Some(format!("{sel} != {v}")),
        ("incl", Some(v)) => Some(format!("{v} in {sel}")),
        ("excl", Some(v)) => Some(format!("!({v} in {sel})")),
        ("matches", Some(v)) => Some(format!("{sel}.matches({v})")),
        _ => {
            ctx.report.skipped(
                ctx.construct,
                Severity::Warning,
                format!(
                    "selector operator `{op}` (or its value) could not be lowered to CEL; dropped."
                ),
            );
            None
        }
    }
}

/// Render a YAML scalar as a CEL literal.
fn value_to_cel(value: &Value) -> Option<String> {
    match value {
        Value::String(s) => Some(format!("'{}'", s.replace('\'', "\\'"))),
        Value::Bool(b) => Some(b.to_string()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

/// True if `expr` references a nested identity claim (`claim.a.b`), which
/// the `standard` claim mapper cannot surface as a usable key.
fn has_nested_claim(expr: &str) -> bool {
    let mut rest = expr;
    while let Some(pos) = rest.find("claim.") {
        let after = &rest[pos + "claim.".len()..];
        let first: String = after
            .chars()
            .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
            .collect();
        let tail = &after[first.len()..];
        if tail.starts_with('.') {
            return true;
        }
        rest = after;
    }
    false
}

/// Report response customization (denyWith / success) as Phase-B-pending,
/// validating denyWith header values for control characters (R21).
fn report_response(resp: &ResponseSpec, report: &mut Report) {
    if resp.unauthenticated.is_some() {
        report.approximated(
            "response.unauthenticated",
            Severity::Warning,
            "custom unauthenticated denyWith (status/body/headers) is not carried; identity failure returns a default 401 until Phase B (U2/U7).",
        );
    }
    if let Some(unauth) = resp.unauthorized.as_ref() {
        report.approximated(
            "response.unauthorized",
            Severity::Warning,
            "custom unauthorized denyWith (status/body/headers) is not carried; authz denial uses a default status until Phase B (U2/U7).",
        );
        if let Some(headers) = unauth.headers.as_ref() {
            for (name, vos) in headers {
                let candidate = vos.value.as_ref().and_then(Value::as_str).unwrap_or("");
                if has_control_char(name) || has_control_char(candidate) {
                    report.skipped(
                        "response.unauthorized.headers",
                        Severity::Fatal,
                        format!("denyWith header `{name}` contains a control character (CR/LF/NUL); rejected to prevent response splitting (R21)."),
                    );
                }
            }
        }
    }
    if resp.success.is_some() {
        report.skipped(
            "response.success",
            Severity::Info,
            "success-response injection (headers/dynamicMetadata) is not translated this iteration.",
        );
    }
}

fn report_metadata_callbacks(scheme: &AuthScheme, report: &mut Report) {
    for name in scheme.metadata.keys() {
        report.skipped(
            format!("metadata/{name}"),
            Severity::Warning,
            "external metadata fetch is not translated this iteration (best-effort APL bridge is Phase B).",
        );
    }
    for name in scheme.callbacks.keys() {
        report.skipped(
            format!("callbacks/{name}"),
            Severity::Warning,
            "post-auth callbacks are not translated this iteration (best-effort APL bridge is Phase B).",
        );
    }
}

fn has_control_char(s: &str) -> bool {
    s.chars().any(|c| c == '\r' || c == '\n' || c == '\0')
}

#[cfg(test)]
mod tests {
    #![allow(clippy::panic, reason = "panic is idiomatic in test assertions")]
    use super::{super::model, *};

    fn transpile_str(yaml: &str) -> Transpiled {
        let policy = model::parse(yaml).expect("parse");
        transpile(&policy, "test")
    }

    #[test]
    fn jwt_and_cel_authz_translate() {
        let t = transpile_str(
            "
spec:
  rules:
    authentication:
      kc:
        jwt:
          issuerUrl: https://idp.example/realms/r
    authorization:
      allow-verified:
        patternMatching:
          patterns:
            - predicate: \"auth.identity.email_verified\"
            - predicate: \"request.method == 'GET'\"
",
        );
        assert!(t.cpex_doc.contains("kind: identity/jwt"));
        assert!(t.cpex_doc.contains("on_error: fail"));
        assert!(t.cpex_doc.contains("RS256"));
        // CEL was remapped into CPEX namespaces and emitted as a `cel:` step.
        assert!(t.cpex_doc.contains("cel:"));
        assert!(t.cpex_doc.contains("expr:"));
        assert!(t.cpex_doc.contains("claim.email_verified"));
        // A `cel:` step requires the `cel` PDP resolver to be declared, or it
        // fails closed at runtime.
        assert!(t.cpex_doc.contains("pdp:"));
        assert!(t.cpex_doc.contains("kind: cel"));
        // Quote-agnostic: serde_yaml may single-quote the expr scalar
        // (doubling inner quotes) depending on its leading character.
        assert!(t.cpex_doc.contains("http.method =="));
        // Presence gate is the native `require(authenticated)`; the CEL
        // predicate is NOT wrapped in `require(...)`.
        assert!(t.cpex_doc.contains("require(authenticated)"));
        assert!(
            !t.cpex_doc.contains("require(http.method"),
            "comparisons belong in a cel: step, not require(...);\n{}",
            t.cpex_doc
        );
        assert!(!t.report.has_fatal());
    }

    #[test]
    fn opa_only_authz_fails_closed() {
        let t = transpile_str(
            "
spec:
  rules:
    authorization:
      via-opa:
        opa:
          rego: \"allow { true }\"
",
        );
        assert!(t.report.has_fatal(), "OPA-only authz must fail closed");
        assert!(t.cpex_doc.contains("require(false)"));
    }

    #[test]
    fn selector_incl_lowers_to_cel_in() {
        let t = transpile_str(
            "
spec:
  patterns:
    admin-role:
      - selector: \"auth.identity.realm_access.roles\"
        operator: incl
        value: admin
  rules:
    authorization:
      admins:
        patternMatching:
          patterns:
            - patternRef: admin-role
",
        );
        assert!(
            t.cpex_doc.contains("'admin' in claim.realm_access.roles"),
            "selector incl should lower to CEL `in`; got:\n{}",
            t.cpex_doc
        );
        // Nested-claim warning should fire (realm_access.roles).
        assert!(
            t.report
                .entries
                .iter()
                .any(|e| e.detail.contains("nested identity claim"))
        );
    }

    #[test]
    fn unmappable_predicate_is_gap_and_fails_closed_when_only_rule() {
        let t = transpile_str(
            "
spec:
  rules:
    authorization:
      meta-based:
        patternMatching:
          patterns:
            - predicate: \"auth.metadata['x'].ok == true\"
",
        );
        assert!(t.report.has_fatal());
        assert!(t.cpex_doc.contains("require(false)"));
    }

    #[test]
    fn denywith_control_char_is_fatal() {
        let t = transpile_str(
            "
spec:
  rules:
    authorization:
      a:
        patternMatching:
          patterns:
            - predicate: \"auth.identity.email_verified\"
    response:
      unauthorized:
        headers:
          X-Bad:
            value: \"line1\\r\\nInjected: 1\"
",
        );
        assert!(
            t.report.has_fatal(),
            "CRLF in denyWith header must be fatal"
        );
    }

    #[test]
    fn spec_when_folds_into_authorization_step() {
        let t = transpile_str(
            "
spec:
  when:
    - predicate: \"request.host == 'api.example.com'\"
  rules:
    authorization:
      a:
        patternMatching:
          patterns:
            - predicate: \"auth.identity.email_verified\"
",
        );
        // spec.when folds into each cel: step's expr (no route `when:` field
        // in the canonical global block). No authn here, so no presence gate.
        assert!(t.cpex_doc.contains("pre_invocation:"));
        assert!(t.cpex_doc.contains("cel:"));
        // Quote-agnostic anchors (serde_yaml single-quotes the `!(`-leading
        // scalar, doubling inner quotes).
        assert!(t.cpex_doc.contains("http.host =="));
        assert!(
            t.cpex_doc.contains(")) || ((claim.email_verified))"),
            "spec.when should gate the rule inside the cel: expr; got:\n{}",
            t.cpex_doc
        );
        assert!(
            !t.cpex_doc.contains("require(authenticated)"),
            "no identity configured → no presence gate;\n{}",
            t.cpex_doc
        );
    }

    #[test]
    fn filter_block_is_policy_filter() {
        let t = transpile_str("spec: {}");
        assert!(t.filter_block.contains("filter: policy"));
        assert!(t.filter_block.contains("config_path:"));
        // No enforcement-mode field: the filter derives HTTP-layer
        // authorization from the emitted `global`-only policy.
        assert!(!t.filter_block.contains("enforcement"));
    }
}
