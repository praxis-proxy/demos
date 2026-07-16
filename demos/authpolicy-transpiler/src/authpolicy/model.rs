// SPDX-License-Identifier: MIT
// Copyright (c) 2024 Praxis Contributors

//! Serde model for the supported subset of the Kuadrant `AuthPolicy`
//! resource (`kuadrant.io/v1`, targeting Authorino `v1beta3`).
//!
//! The model is **best-effort by design**: it does not use
//! `deny_unknown_fields`, so unknown or future fields are ignored rather
//! than rejected. Each authentication/authorization rule carries an
//! explicit `Option` for every Authorino method we recognize (supported
//! or not); a rule whose recognized method is `None` is reported as an
//! unsupported construct by the translator rather than failing the parse.
//! Pattern expressions parse totally via a trailing [`PatternExpr::Other`]
//! variant so an unrecognized shape never aborts a document.
//!
//! Maps use [`BTreeMap`] so emission is deterministic (golden tests).

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_yaml::Value;

// ---------------------------------------------------------------------------
// Top-level resource
// ---------------------------------------------------------------------------

/// A single Kuadrant `AuthPolicy` document.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AuthPolicy {
    #[serde(default)]
    pub api_version: Option<String>,
    #[serde(default)]
    pub kind: Option<String>,
    #[serde(default)]
    pub metadata: ObjectMeta,
    pub spec: Spec,
}

/// Subset of Kubernetes object metadata we care about.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub(crate) struct ObjectMeta {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub namespace: Option<String>,
}

/// `AuthPolicy.spec`.
///
/// `rules`/`when`/`patterns` (implicit defaults) are mutually exclusive
/// with `defaults`/`overrides` in a valid resource, but we model all of
/// them as optional and let the translator resolve precedence and report
/// `defaults`/`overrides` hierarchy as a gap.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Spec {
    pub target_ref: Option<TargetRef>,
    #[serde(default)]
    pub rules: Option<AuthScheme>,
    #[serde(default)]
    pub when: Option<Vec<PatternExpr>>,
    #[serde(default)]
    pub patterns: Option<BTreeMap<String, Vec<PatternExpr>>>,
    #[serde(default)]
    pub defaults: Option<CommonSpec>,
    #[serde(default)]
    pub overrides: Option<CommonSpec>,
}

/// `spec.defaults` / `spec.overrides` (Gateway API GEP-2649 composition).
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct CommonSpec {
    #[serde(default)]
    pub rules: Option<AuthScheme>,
    #[serde(default)]
    pub when: Option<Vec<PatternExpr>>,
    #[serde(default)]
    pub patterns: Option<BTreeMap<String, Vec<PatternExpr>>>,
}

/// Gateway API target reference (carried for reporting; not translated —
/// Praxis has no Gateway API surface).
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct TargetRef {
    #[serde(default)]
    pub group: Option<String>,
    #[serde(default)]
    pub kind: Option<String>,
    pub name: String,
    #[serde(default)]
    pub section_name: Option<String>,
}

// ---------------------------------------------------------------------------
// Auth scheme
// ---------------------------------------------------------------------------

/// `spec.rules` — the five-phase Authorino auth scheme.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub(crate) struct AuthScheme {
    #[serde(default)]
    pub authentication: BTreeMap<String, AuthenticationRule>,
    #[serde(default)]
    pub metadata: BTreeMap<String, Value>,
    #[serde(default)]
    pub authorization: BTreeMap<String, AuthorizationRule>,
    #[serde(default)]
    pub response: Option<ResponseSpec>,
    #[serde(default)]
    pub callbacks: BTreeMap<String, Value>,
}

// ---------------------------------------------------------------------------
// Authentication
// ---------------------------------------------------------------------------

/// One `spec.rules.authentication` entry. Exactly one method field is set
/// in a valid resource; `jwt` is the only method translated this iteration.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AuthenticationRule {
    // -- methods --
    #[serde(default)]
    pub jwt: Option<JwtSpec>,
    #[serde(default)]
    pub api_key: Option<Value>,
    #[serde(default)]
    pub oauth2_introspection: Option<Value>,
    #[serde(default)]
    pub kubernetes_token_review: Option<Value>,
    #[serde(default)]
    pub x509: Option<Value>,
    #[serde(default)]
    pub plain: Option<Value>,
    #[serde(default)]
    pub anonymous: Option<Value>,

    // -- common --
    #[serde(default)]
    pub priority: Option<i64>,
    #[serde(default)]
    pub when: Option<Vec<PatternExpr>>,
    #[serde(default)]
    pub credentials: Option<Credentials>,
}

impl AuthenticationRule {
    /// The recognized authentication method, if any.
    pub(crate) fn method(&self) -> AuthnMethod {
        if self.jwt.is_some() {
            AuthnMethod::Jwt
        } else if self.api_key.is_some() {
            AuthnMethod::ApiKey
        } else if self.oauth2_introspection.is_some() {
            AuthnMethod::Oauth2Introspection
        } else if self.kubernetes_token_review.is_some() {
            AuthnMethod::KubernetesTokenReview
        } else if self.x509.is_some() {
            AuthnMethod::X509
        } else if self.plain.is_some() {
            AuthnMethod::Plain
        } else if self.anonymous.is_some() {
            AuthnMethod::Anonymous
        } else {
            AuthnMethod::Unknown
        }
    }
}

/// Recognized authentication methods. Only [`AuthnMethod::Jwt`] is
/// translated; the rest are reported as coverage gaps.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AuthnMethod {
    Jwt,
    ApiKey,
    Oauth2Introspection,
    KubernetesTokenReview,
    X509,
    Plain,
    Anonymous,
    Unknown,
}

impl AuthnMethod {
    /// Human-readable label for coverage reports.
    pub(crate) fn label(self) -> &'static str {
        match self {
            Self::Jwt => "jwt",
            Self::ApiKey => "apiKey",
            Self::Oauth2Introspection => "oauth2Introspection",
            Self::KubernetesTokenReview => "kubernetesTokenReview",
            Self::X509 => "x509",
            Self::Plain => "plain",
            Self::Anonymous => "anonymous",
            Self::Unknown => "<unrecognized>",
        }
    }
}

/// JWT authentication method (the one we translate).
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct JwtSpec {
    #[serde(default)]
    pub issuer_url: Option<String>,
    #[serde(default)]
    pub jwks_url: Option<String>,
    #[serde(default)]
    pub ttl: Option<i64>,
    #[serde(default)]
    pub timeout: Option<i64>,
}

/// Credential location (`spec.rules.authentication.<name>.credentials`).
/// At most one field is set; defaults to the `Authorization: Bearer` header.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Credentials {
    #[serde(default)]
    pub authorization_header: Option<HeaderCredential>,
    #[serde(default)]
    pub custom_header: Option<NamedCredential>,
    #[serde(default)]
    pub query_string: Option<NamedCredential>,
    #[serde(default)]
    pub cookie: Option<NamedCredential>,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub(crate) struct HeaderCredential {
    #[serde(default)]
    pub prefix: Option<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub(crate) struct NamedCredential {
    pub name: String,
}

// ---------------------------------------------------------------------------
// Authorization
// ---------------------------------------------------------------------------

/// One `spec.rules.authorization` entry. Only `patternMatching` (CEL /
/// selector predicates) is translated; `opa`/`spicedb`/
/// `kubernetesSubjectAccessReview` are reported as gaps.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AuthorizationRule {
    // -- methods --
    #[serde(default)]
    pub pattern_matching: Option<PatternMatching>,
    #[serde(default)]
    pub opa: Option<Value>,
    #[serde(default)]
    pub spicedb: Option<Value>,
    #[serde(default)]
    pub kubernetes_subject_access_review: Option<Value>,

    // -- common --
    #[serde(default)]
    pub priority: Option<i64>,
    #[serde(default)]
    pub when: Option<Vec<PatternExpr>>,
}

impl AuthorizationRule {
    /// The recognized authorization method, if any.
    pub(crate) fn method(&self) -> AuthzMethod {
        if self.pattern_matching.is_some() {
            AuthzMethod::PatternMatching
        } else if self.opa.is_some() {
            AuthzMethod::Opa
        } else if self.spicedb.is_some() {
            AuthzMethod::SpiceDb
        } else if self.kubernetes_subject_access_review.is_some() {
            AuthzMethod::KubernetesSubjectAccessReview
        } else {
            AuthzMethod::Unknown
        }
    }
}

/// Recognized authorization methods. Only
/// [`AuthzMethod::PatternMatching`] is translated.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum AuthzMethod {
    PatternMatching,
    Opa,
    SpiceDb,
    KubernetesSubjectAccessReview,
    Unknown,
}

impl AuthzMethod {
    /// Human-readable label for coverage reports.
    pub(crate) fn label(self) -> &'static str {
        match self {
            Self::PatternMatching => "patternMatching",
            Self::Opa => "opa",
            Self::SpiceDb => "spicedb",
            Self::KubernetesSubjectAccessReview => "kubernetesSubjectAccessReview",
            Self::Unknown => "<unrecognized>",
        }
    }
}

/// `authorization.<name>.patternMatching` — a conjunction of pattern
/// expressions (Authorino ANDs them by default).
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub(crate) struct PatternMatching {
    #[serde(default)]
    pub patterns: Vec<PatternExpr>,
}

// ---------------------------------------------------------------------------
// Pattern expressions (when / patterns / patternMatching)
// ---------------------------------------------------------------------------

/// A Kuadrant `PatternExpressionOrRef`. Parsing is total: any shape we do
/// not recognize lands in [`PatternExpr::Other`] so a document never fails
/// to parse on an unexpected pattern (the translator reports it as a gap).
///
/// Variant order matters for `serde(untagged)`: the discriminating key of
/// each named variant is required, and `Other` is the trailing catch-all.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(untagged)]
pub(crate) enum PatternExpr {
    /// `all: [...]` — AND group.
    All { all: Vec<PatternExpr> },
    /// `any: [...]` — OR group.
    Any { any: Vec<PatternExpr> },
    /// `patternRef: <name>` — reference into `spec.patterns`.
    Ref {
        #[serde(rename = "patternRef")]
        pattern_ref: String,
    },
    /// `predicate: <cel>` — CEL boolean expression (preferred form).
    Predicate { predicate: String },
    /// `selector: <path>` + `operator` + `value` — deprecated GJSON form.
    Selector {
        selector: String,
        #[serde(default)]
        operator: Option<String>,
        #[serde(default)]
        value: Option<Value>,
    },
    /// Any unrecognized pattern shape — reported, never emitted.
    Other(Value),
}

// ---------------------------------------------------------------------------
// Response customization
// ---------------------------------------------------------------------------

/// `spec.rules.response`.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub(crate) struct ResponseSpec {
    #[serde(default)]
    pub unauthenticated: Option<DenyWith>,
    #[serde(default)]
    pub unauthorized: Option<DenyWith>,
    /// Success-response injection (headers / dynamicMetadata). Carried as
    /// an opaque value and reported best-effort.
    #[serde(default)]
    pub success: Option<Value>,
}

/// `denyWith` customization for the unauthenticated/unauthorized response.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub(crate) struct DenyWith {
    #[serde(default)]
    pub code: Option<u16>,
    #[serde(default)]
    pub message: Option<ValueOrSelector>,
    #[serde(default)]
    pub headers: Option<BTreeMap<String, ValueOrSelector>>,
    #[serde(default)]
    pub body: Option<ValueOrSelector>,
}

/// Authorino `ValueOrSelector` — exactly one of static `value`, a CEL
/// `expression`, or a (deprecated) GJSON `selector`.
#[derive(Debug, Clone, Default, Deserialize, Serialize)]
pub(crate) struct ValueOrSelector {
    #[serde(default)]
    pub value: Option<Value>,
    #[serde(default)]
    pub expression: Option<String>,
    #[serde(default)]
    pub selector: Option<String>,
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/// Parse a single `AuthPolicy` document from YAML.
pub(crate) fn parse(yaml: &str) -> Result<AuthPolicy, serde_yaml::Error> {
    serde_yaml::from_str(yaml)
}

/// Split a multi-document YAML stream and parse each `AuthPolicy`.
///
/// Documents are separated by `---`. Empty documents (blank or
/// comment-only) are skipped. The first parse error aborts with its
/// document index for diagnostics.
pub(crate) fn parse_documents(yaml: &str) -> Result<Vec<AuthPolicy>, ParseError> {
    let mut policies = Vec::new();
    for (idx, doc) in split_documents(yaml).into_iter().enumerate() {
        if doc.trim().is_empty() {
            continue;
        }
        let policy = parse(&doc).map_err(|source| ParseError { index: idx, source })?;
        policies.push(policy);
    }
    Ok(policies)
}

/// Split a YAML stream into documents on `---` separators.
fn split_documents(yaml: &str) -> Vec<String> {
    let mut docs = Vec::new();
    let mut current = String::new();
    for line in yaml.lines() {
        if line.trim_end() == "---" {
            docs.push(std::mem::take(&mut current));
        } else {
            current.push_str(line);
            current.push('\n');
        }
    }
    docs.push(current);
    docs
}

/// A parse failure tagged with the document index within a stream.
#[derive(Debug)]
pub(crate) struct ParseError {
    pub index: usize,
    pub source: serde_yaml::Error,
}

impl std::fmt::Display for ParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(
            f,
            "failed to parse AuthPolicy document #{}: {}",
            self.index, self.source
        )
    }
}

impl std::error::Error for ParseError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        Some(&self.source)
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    #![allow(
        clippy::indexing_slicing,
        clippy::panic,
        reason = "indexing and panic are idiomatic in test assertions"
    )]
    use super::*;

    const JWT_RBAC: &str = r#"
apiVersion: kuadrant.io/v1
kind: AuthPolicy
metadata:
  name: api-jwt-rbac
  namespace: default
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: api-route
  when:
    - predicate: "!request.path.startsWith('/public')"
  patterns:
    admin-role:
      - selector: "auth.identity.realm_access.roles"
        operator: incl
        value: "admin"
  rules:
    authentication:
      keycloak-jwt:
        jwt:
          issuerUrl: "https://keycloak.example.com/realms/myrealm"
          ttl: 3600
        credentials:
          authorizationHeader:
            prefix: "Bearer"
    authorization:
      members-can-read:
        when:
          - all:
              - predicate: "request.method == 'GET'"
              - any:
                  - predicate: "request.method == 'GET'"
                  - predicate: "request.method == 'HEAD'"
        patternMatching:
          patterns:
            - patternRef: "admin-role"
            - predicate: "auth.identity.email_verified"
    response:
      unauthenticated:
        code: 401
        headers:
          WWW-Authenticate:
            value: "Bearer realm=\"api\""
        body:
          value: "{\"error\":\"unauthenticated\"}"
      unauthorized:
        code: 403
        body:
          expression: "'{\"error\":\"forbidden\"}'"
"#;

    #[test]
    fn parses_jwt_rbac_example() {
        let p = parse(JWT_RBAC).expect("parse");
        assert_eq!(p.kind.as_deref(), Some("AuthPolicy"));
        assert_eq!(p.metadata.name.as_deref(), Some("api-jwt-rbac"));
        let spec = &p.spec;
        assert_eq!(
            spec.target_ref.as_ref().unwrap().kind.as_deref(),
            Some("HTTPRoute")
        );

        // Top-level `when`.
        let when = spec.when.as_ref().expect("when");
        assert!(matches!(&when[0], PatternExpr::Predicate { .. }));

        // Named patterns.
        let patterns = spec.patterns.as_ref().expect("patterns");
        assert!(patterns.contains_key("admin-role"));

        let rules = spec.rules.as_ref().expect("rules");

        // JWT authentication.
        let authn = &rules.authentication["keycloak-jwt"];
        assert_eq!(authn.method(), AuthnMethod::Jwt);
        let jwt = authn.jwt.as_ref().unwrap();
        assert_eq!(
            jwt.issuer_url.as_deref(),
            Some("https://keycloak.example.com/realms/myrealm")
        );
        assert_eq!(jwt.ttl, Some(3600));
        let creds = authn.credentials.as_ref().unwrap();
        assert_eq!(
            creds
                .authorization_header
                .as_ref()
                .unwrap()
                .prefix
                .as_deref(),
            Some("Bearer")
        );

        // patternMatching authorization with patternRef + predicate, gated by when.
        let authz = &rules.authorization["members-can-read"];
        assert_eq!(authz.method(), AuthzMethod::PatternMatching);
        let pm = authz.pattern_matching.as_ref().unwrap();
        assert_eq!(pm.patterns.len(), 2);
        assert!(matches!(&pm.patterns[0], PatternExpr::Ref { .. }));
        assert!(matches!(&pm.patterns[1], PatternExpr::Predicate { .. }));
        let aw = authz.when.as_ref().unwrap();
        assert!(matches!(&aw[0], PatternExpr::All { .. }));

        // Response denyWith.
        let resp = rules.response.as_ref().unwrap();
        assert_eq!(resp.unauthenticated.as_ref().unwrap().code, Some(401));
        assert_eq!(resp.unauthorized.as_ref().unwrap().code, Some(403));
        assert!(
            resp.unauthorized
                .as_ref()
                .unwrap()
                .body
                .as_ref()
                .unwrap()
                .expression
                .is_some()
        );
    }

    #[test]
    fn unknown_authn_method_parses_as_unknown_not_error() {
        let yaml = "
spec:
  rules:
    authentication:
      future-method:
        webauthn: { rp_id: example.com }
";
        let p = parse(yaml).expect("best-effort parse must not fail on unknown method");
        let rule = &p.spec.rules.unwrap().authentication["future-method"];
        assert_eq!(rule.method(), AuthnMethod::Unknown);
    }

    #[test]
    fn unsupported_authz_methods_detected() {
        let yaml = r#"
spec:
  rules:
    authorization:
      via-opa:
        opa:
          rego: "allow { true }"
      via-spicedb:
        spicedb:
          endpoint: "spicedb:50051"
"#;
        let rules = parse(yaml).unwrap().spec.rules.unwrap();
        assert_eq!(rules.authorization["via-opa"].method(), AuthzMethod::Opa);
        assert_eq!(
            rules.authorization["via-spicedb"].method(),
            AuthzMethod::SpiceDb
        );
    }

    #[test]
    fn anonymous_and_apikey_recognized() {
        let yaml = "
spec:
  rules:
    authentication:
      anon:
        anonymous: {}
      keys:
        apiKey:
          selector:
            matchLabels: { app: x }
";
        let authn = parse(yaml).unwrap().spec.rules.unwrap().authentication;
        assert_eq!(authn["anon"].method(), AuthnMethod::Anonymous);
        assert_eq!(authn["keys"].method(), AuthnMethod::ApiKey);
    }

    #[test]
    fn defaults_and_overrides_parse() {
        let yaml = r#"
spec:
  defaults:
    when:
      - predicate: "request.host.endsWith('.internal')"
    rules:
      authentication:
        jwt-internal:
          jwt:
            issuerUrl: "https://sso.internal"
"#;
        let spec = parse(yaml).unwrap().spec;
        let defaults = spec.defaults.expect("defaults");
        assert!(defaults.when.is_some());
        assert_eq!(
            defaults.rules.unwrap().authentication["jwt-internal"].method(),
            AuthnMethod::Jwt
        );
    }

    #[test]
    fn unrecognized_pattern_shape_is_other() {
        let yaml = "
spec:
  rules:
    authorization:
      weird:
        patternMatching:
          patterns:
            - someFutureShape: { foo: bar }
";
        let authz = parse(yaml).unwrap().spec.rules.unwrap().authorization;
        let pm = authz["weird"].pattern_matching.as_ref().unwrap();
        assert!(matches!(&pm.patterns[0], PatternExpr::Other(_)));
    }

    #[test]
    fn multi_document_stream() {
        let yaml = format!("{JWT_RBAC}\n---\n{JWT_RBAC}");
        let docs = parse_documents(&yaml).expect("multi-doc parse");
        assert_eq!(docs.len(), 2);
    }

    #[test]
    fn selector_pattern_parses() {
        let yaml = r#"
spec:
  when:
    - selector: "context.request.http.path"
      operator: matches
      value: "^/api(/.*)?$"
"#;
        let when = parse(yaml).unwrap().spec.when.unwrap();
        match &when[0] {
            PatternExpr::Selector {
                selector,
                operator,
                value,
            } => {
                assert_eq!(selector, "context.request.http.path");
                assert_eq!(operator.as_deref(), Some("matches"));
                assert!(value.is_some());
            }
            other => panic!("expected selector, got {other:?}"),
        }
    }
}
