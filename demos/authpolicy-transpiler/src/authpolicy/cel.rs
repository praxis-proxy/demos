// SPDX-License-Identifier: MIT
// Copyright (c) 2024 Praxis Contributors

//! Kuadrant → CPEX CEL namespace remapping (plan R20).
//!
//! Kuadrant predicates reference an Envoy/Authorino attribute vocabulary
//! (`auth.identity.*`, `request.method/path/host`, `request.headers[...]`)
//! that does not exist verbatim in CPEX's evaluation bag. CPEX surfaces the
//! HTTP request line/headers on the `HttpExtension` as `http.method` /
//! `http.path` / `http.host` / `http.request_headers.*`.
//!
//! Identity is special. CPEX's `standard` claim mapper does not surface a raw
//! `claim.*` bag; it maps `roles` / `permissions` / `groups`|`teams` into
//! per-name booleans exposed to CEL as `role.<name>` / `perm.<name>` /
//! `team.<name>`. So the common Kuadrant RBAC idiom `'<value>' in
//! auth.identity.roles` is rewritten to the guarded boolean form
//! `(has(role.<value>) && role.<value>)` rather than a (never-populated)
//! `claim.roles` array test. Non-RBAC identity references fall back to the
//! lexical `auth.identity.* → claim.*` rewrite and remain a documented
//! runtime gap wherever `claim.*` is unpopulated.
//!
//! This module rewrites the recognized prefixes to their CPEX equivalents
//! and then scans for any *un-remapped* reference into a source namespace
//! (`auth.*`, `request.*`, `context.*`, `metadata.*`). A leftover reference
//! is returned as a [`Remap::Gap`] so the translator reports it and refuses
//! to emit the expression — wrong-namespace CEL would otherwise compile
//! cleanly and fail **closed** (deny-all) at runtime, which is exactly the
//! silent failure R20 exists to prevent.
//!
//! The rewriting is intentionally lexical (prefix substitution + a header
//! scanner), not a full CEL parse. Its known limitations — string literals
//! that happen to contain a source token, and exotic indexing forms — are
//! documented in the Phase A feasibility gate; for the gate's purpose
//! (quantifying how much of a real corpus maps) a lexical pass is adequate
//! and never produces a *silently wrong* emission: anything it cannot
//! confidently rewrite becomes a gap, not a guess.

/// Result of remapping a single Kuadrant CEL predicate.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Remap {
    /// Fully remapped to CPEX namespaces.
    Ok(String),
    /// An un-remappable reference remains; the string names it.
    Gap { reference: String },
}

/// Remap a Kuadrant CEL predicate into CPEX's bag vocabulary.
pub(crate) fn remap(expr: &str) -> Remap {
    // Order matters: rewrite the most specific prefixes first so that, e.g.,
    // `context.request.http.path` is consumed before a bare `request.`
    // scan could see it.
    let mut out = expr.to_owned();

    // Envoy-style `context.request.http.*` (used by older selectors).
    out = out.replace("context.request.http.method", "http.method");
    out = out.replace("context.request.http.path", "http.path");
    out = out.replace("context.request.http.host", "http.host");

    // Request line.
    out = out.replace("request.method", "http.method");
    out = out.replace("request.path", "http.path");
    out = out.replace("request.host", "http.host");

    // Headers: `request.headers['X']`, `request.headers["X"]`, and
    // `request.headers.X` → `http.request_headers.<lowercased>`.
    out = rewrite_headers(&out);

    // RBAC membership idiom: `'<value>' in auth.identity.{roles|permissions|
    // groups|teams}` → `(has(<ns>.<value>) && <ns>.<value>)`, since CPEX
    // exposes these as per-name booleans, not arrays. Runs before the generic
    // identity rewrite below so the membership forms are consumed first.
    out = rewrite_membership(&out);

    // Remaining identity references: `auth.identity.<rest>` → `claim.<rest>`.
    out = out.replace("auth.identity.", "claim.");

    // Anything still pointing at a source namespace could not be mapped.
    if let Some(reference) = leftover_reference(&out) {
        return Remap::Gap { reference };
    }
    Remap::Ok(out)
}

/// Rewrite every `request.headers...` access in `expr` to the CPEX
/// `http.request_headers.<lowercased-name>` form. Unrecognized header
/// access shapes are left intact so [`leftover_reference`] flags them.
fn rewrite_headers(expr: &str) -> String {
    const NEEDLE: &str = "request.headers";
    let mut out = String::with_capacity(expr.len());
    let mut rest = expr;
    while let Some(pos) = rest.find(NEEDLE) {
        out.push_str(&rest[..pos]);
        let after = &rest[pos + NEEDLE.len()..];
        if let Some((name, consumed)) = parse_header_access(after) {
            out.push_str("http.request_headers.");
            out.push_str(&name.to_ascii_lowercase());
            rest = &after[consumed..];
        } else {
            // Unrecognized shape — leave the needle in place so the scanner
            // advances and the leftover check still sees `request.headers`.
            out.push_str(NEEDLE);
            rest = after;
        }
    }
    out.push_str(rest);
    out
}

/// Rewrite the Kuadrant RBAC membership idiom
/// `'<value>' in auth.identity.{roles|permissions|groups|teams}` into CPEX's
/// guarded boolean form `(has(<ns>.<value>) && <ns>.<value>)`. CPEX's standard
/// claim mapper surfaces these claims as per-name booleans (`role.hr`,
/// `perm.view_ssn`, `team.engineering`), not as arrays, so an array-membership
/// test would never match. Non-membership references are left untouched for
/// the generic `auth.identity.* → claim.*` pass.
fn rewrite_membership(expr: &str) -> String {
    let mut out = String::with_capacity(expr.len());
    let mut rest = expr;
    while let Some(q) = rest.find('\'') {
        out.push_str(&rest[..q]);
        let after_open = &rest[q + 1..];
        let Some(qc) = after_open.find('\'') else {
            // Unterminated quote — emit the rest verbatim and stop scanning.
            out.push_str(&rest[q..]);
            return out;
        };
        let literal = &after_open[..qc];
        let tail = &after_open[qc + 1..];
        if let Some((replacement, consumed)) = membership_replacement(literal, tail) {
            out.push_str(&replacement);
            rest = &tail[consumed..];
        } else {
            // Not a membership form — emit `'literal'` unchanged.
            out.push('\'');
            out.push_str(literal);
            out.push('\'');
            rest = tail;
        }
    }
    out.push_str(rest);
    out
}

/// If `tail` (the text immediately after a closing quote) begins with
/// ` in auth.identity.<field>` for a known RBAC field, return the CPEX boolean
/// replacement for `'<literal>' in auth.identity.<field>` and the number of
/// bytes of `tail` consumed. Returns `None` for any other shape.
fn membership_replacement(literal: &str, tail: &str) -> Option<(String, usize)> {
    let trimmed = tail.trim_start();
    let lead_ws = tail.len() - trimmed.len();
    let after_in = trimmed.strip_prefix("in ")?;
    let after_in_t = after_in.trim_start();
    let in_ws = after_in.len() - after_in_t.len();
    let after_ns = after_in_t.strip_prefix("auth.identity.")?;
    let field: String = after_ns
        .chars()
        .take_while(|c| c.is_ascii_alphanumeric() || *c == '_')
        .collect();
    let ns = match field.as_str() {
        "roles" => "role",
        "permissions" => "perm",
        "groups" | "teams" => "team",
        _ => return None,
    };
    // The literal must be a safe bag-key segment (no spaces/quotes/operators),
    // otherwise leave it alone rather than emit malformed CEL.
    if literal.is_empty()
        || !literal
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '-' | '.' | ':'))
    {
        return None;
    }
    let replacement = format!("(has({ns}.{literal}) && {ns}.{literal})");
    let consumed = lead_ws + "in ".len() + in_ws + "auth.identity.".len() + field.len();
    Some((replacement, consumed))
}

/// Parse a header accessor immediately following `request.headers`.
///
/// Returns the header name and the number of bytes consumed from `after`.
/// Handles `['name']`, `["name"]`, and `.name`.
fn parse_header_access(after: &str) -> Option<(String, usize)> {
    let bytes = after.as_bytes();
    match bytes.first()? {
        b'[' => {
            let quote = *bytes.get(1)?;
            if quote != b'\'' && quote != b'"' {
                return None;
            }
            let close_quote = after.get(2..)?.find(quote as char)? + 2;
            // Expect `]` right after the closing quote.
            if after.as_bytes().get(close_quote + 1)? != &b']' {
                return None;
            }
            let name = after.get(2..close_quote)?.to_owned();
            Some((name, close_quote + 2))
        }
        b'.' => {
            let name: String = after[1..]
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || *c == '_' || *c == '-')
                .collect();
            if name.is_empty() {
                return None;
            }
            let consumed = 1 + name.len();
            Some((name, consumed))
        }
        _ => None,
    }
}

/// Find the first leftover reference into a source (Kuadrant) namespace
/// that survived rewriting, if any.
fn leftover_reference(expr: &str) -> Option<String> {
    const SOURCES: [&str; 5] = [
        "auth.identity",
        "auth.metadata",
        "auth.",
        "request.",
        "context.",
    ];
    let mut best: Option<usize> = None;
    for needle in SOURCES {
        if let Some(pos) = expr.find(needle) {
            best = Some(best.map_or(pos, |b| b.min(pos)));
        }
    }
    let pos = best?;
    // Capture the dotted reference for a useful diagnostic.
    let reference: String = expr[pos..]
        .chars()
        .take_while(|c| {
            c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '-' | '[' | ']' | '\'' | '"')
        })
        .collect();
    Some(reference)
}

#[cfg(test)]
mod tests {
    #![allow(clippy::panic, reason = "panic is idiomatic in test assertions")]
    use super::*;

    fn ok(expr: &str) -> String {
        match remap(expr) {
            Remap::Ok(s) => s,
            Remap::Gap { reference } => panic!("unexpected gap on `{expr}`: {reference}"),
        }
    }

    #[test]
    fn request_line_maps_to_http() {
        assert_eq!(ok("request.method == 'POST'"), "http.method == 'POST'");
        assert_eq!(
            ok("request.path.startsWith('/admin')"),
            "http.path.startsWith('/admin')"
        );
        assert_eq!(
            ok("request.host.endsWith('.example.com')"),
            "http.host.endsWith('.example.com')"
        );
    }

    #[test]
    fn envoy_context_form_maps() {
        assert_eq!(ok("context.request.http.path == '/x'"), "http.path == '/x'");
    }

    #[test]
    fn identity_claims_map_to_claim() {
        assert_eq!(ok("auth.identity.email_verified"), "claim.email_verified");
        assert_eq!(
            ok("auth.identity.realm_access.roles.exists(r, r == 'admin')"),
            "claim.realm_access.roles.exists(r, r == 'admin')"
        );
    }

    #[test]
    fn headers_bracket_and_dot_forms() {
        assert_eq!(
            ok("request.headers['X-Env'] == 'prod'"),
            "http.request_headers.x-env == 'prod'"
        );
        assert_eq!(
            ok("request.headers[\"X-Env\"] == 'prod'"),
            "http.request_headers.x-env == 'prod'"
        );
        assert_eq!(
            ok("request.headers.x_team == 'sec'"),
            "http.request_headers.x_team == 'sec'"
        );
    }

    #[test]
    fn unmapped_auth_metadata_is_gap() {
        match remap("auth.metadata['user-info'].active == true") {
            Remap::Gap { reference } => assert!(reference.starts_with("auth.metadata")),
            Remap::Ok(s) => panic!("expected gap, got {s}"),
        }
    }

    #[test]
    fn unknown_request_attribute_is_gap() {
        match remap("request.time > 0") {
            Remap::Gap { reference } => assert!(reference.starts_with("request.")),
            Remap::Ok(s) => panic!("expected gap, got {s}"),
        }
    }

    #[test]
    fn combined_expression_maps() {
        let got = ok("request.method == 'GET' && auth.identity.email_verified");
        assert_eq!(got, "http.method == 'GET' && claim.email_verified");
    }

    #[test]
    fn rbac_membership_maps_to_boolean_namespaces() {
        assert_eq!(
            ok("'hr' in auth.identity.roles"),
            "(has(role.hr) && role.hr)"
        );
        assert_eq!(
            ok("'tool_execute' in auth.identity.permissions"),
            "(has(perm.tool_execute) && perm.tool_execute)"
        );
        assert_eq!(
            ok("'engineering' in auth.identity.teams"),
            "(has(team.engineering) && team.engineering)"
        );
        assert_eq!(
            ok("'admins' in auth.identity.groups"),
            "(has(team.admins) && team.admins)"
        );
    }

    #[test]
    fn membership_composes_with_http_and_other_claims() {
        assert_eq!(
            ok("request.method == 'POST' && 'hr' in auth.identity.roles"),
            "http.method == 'POST' && (has(role.hr) && role.hr)"
        );
        // A non-RBAC identity field still falls back to the claim.* rewrite.
        assert_eq!(
            ok("'hr' in auth.identity.roles && auth.identity.email_verified"),
            "(has(role.hr) && role.hr) && claim.email_verified"
        );
    }

    #[test]
    fn membership_only_for_known_rbac_fields() {
        // `auth.identity.scopes` is not an RBAC field → generic claim.* rewrite,
        // leaving a plain array membership over `claim.scopes`.
        assert_eq!(
            ok("'read' in auth.identity.scopes"),
            "'read' in claim.scopes"
        );
    }
}
