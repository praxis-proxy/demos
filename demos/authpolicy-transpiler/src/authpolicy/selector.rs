// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Praxis Contributors

//! Recognising the predicates an `http:` route selector can carry.
//!
//! A Kuadrant `when` over the request line says the same thing as an engine
//! route selector, and saying it as a selector is what lets the rule under it be
//! only its own condition. This module reads the already-remapped CEL and
//! answers whether the whole predicate is a shape a selector expresses.
//!
//! Deliberately strict: it matches the entire predicate or nothing. A partial
//! match would leave half a condition behind, and the caller cannot tell which
//! half, so the fallback is to keep the predicate as CEL where it is provably
//! equivalent.

/// Strip one balanced layer of wrapping parentheses, repeatedly.
fn unwrap_parens(expr: &str) -> &str {
    let mut cur = expr.trim();
    while let Some(inner) = cur.strip_prefix('(').and_then(|s| s.strip_suffix(')')) {
        // Only unwrap when the leading paren closes at the very end, so
        // `(a) || (b)` is left alone.
        let mut depth = 0_i32;
        let mut closes_at_end = true;
        for (i, c) in inner.char_indices() {
            match c {
                '(' => depth += 1,
                ')' => {
                    depth -= 1;
                    if depth < 0 {
                        closes_at_end = i == inner.len();
                        break;
                    }
                },
                _ => {},
            }
        }
        if !closes_at_end || depth != 0 {
            break;
        }
        cur = inner.trim();
    }
    cur
}

/// The single-quoted argument of `<callee>('<arg>')`, when that is the whole
/// predicate.
fn single_string_arg(expr: &str, callee: &str) -> Option<String> {
    let rest = unwrap_parens(expr).strip_prefix(callee)?;
    let rest = rest.strip_prefix("('")?;
    let arg = rest.strip_suffix("')")?;
    (!arg.is_empty() && !arg.contains('\'')).then(|| arg.to_owned())
}

/// The path prefix a predicate scopes to, when the whole predicate is
/// `http.path.startsWith('<prefix>')`.
///
/// A prefix that is not absolute is refused: the engine requires one, and a
/// relative prefix would silently match nothing.
pub(crate) fn path_prefix(expr: &str) -> Option<String> {
    single_string_arg(expr, "http.path.startsWith").filter(|p| p.starts_with('/'))
}

/// The methods a predicate narrows to, when the whole predicate is
/// `http.method == '<M>'` or a `||` chain of exactly those.
///
/// Order is the order written, so the emitted selector reads like the policy.
pub(crate) fn methods(expr: &str) -> Option<Vec<String>> {
    let inner = unwrap_parens(expr);
    let mut out = Vec::new();
    for disjunct in split_top_level_or(inner)? {
        out.push(single_method(&disjunct)?);
    }
    (!out.is_empty()).then_some(out)
}

/// One `http.method == '<M>'` comparison, in either operand order.
fn single_method(expr: &str) -> Option<String> {
    let inner = unwrap_parens(expr);
    let (lhs, rhs) = inner.split_once("==")?;
    let (lhs, rhs) = (lhs.trim(), rhs.trim());
    let literal = if lhs == "http.method" {
        rhs
    } else if rhs == "http.method" {
        lhs
    } else {
        return None;
    };
    let name = literal.strip_prefix('\'')?.strip_suffix('\'')?;
    (!name.is_empty() && name.chars().all(|c| c.is_ascii_uppercase())).then(|| name.to_owned())
}

/// Split on `||` at paren depth zero. `None` when a paren is unbalanced, so a
/// malformed predicate is never half-read.
fn split_top_level_or(expr: &str) -> Option<Vec<String>> {
    let bytes = expr.as_bytes();
    let mut parts = Vec::new();
    let mut depth = 0_i32;
    let mut start = 0_usize;
    let mut i = 0_usize;
    while i < bytes.len() {
        match bytes[i] {
            b'(' => depth += 1,
            b')' => {
                depth -= 1;
                if depth < 0 {
                    return None;
                }
            },
            b'|' if depth == 0 && bytes.get(i + 1) == Some(&b'|') => {
                parts.push(expr[start..i].to_owned());
                i += 2;
                start = i;
                continue;
            },
            _ => {},
        }
        i += 1;
    }
    if depth != 0 {
        return None;
    }
    parts.push(expr[start..].to_owned());
    Some(parts)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_path_prefix_predicate_is_recognised() {
        assert_eq!(path_prefix("(http.path.startsWith('/api'))").as_deref(), Some("/api"));
        assert_eq!(path_prefix("http.path.startsWith('/v1/files')").as_deref(), Some("/v1/files"));
    }

    #[test]
    fn a_relative_prefix_is_refused() {
        assert!(path_prefix("http.path.startsWith('api')").is_none());
    }

    #[test]
    fn a_predicate_that_only_contains_a_prefix_test_is_refused() {
        assert!(path_prefix("http.path.startsWith('/api') && http.method == 'GET'").is_none());
        assert!(path_prefix("!(http.path.startsWith('/api'))").is_none());
    }

    #[test]
    fn one_method_comparison_is_recognised_in_either_order() {
        assert_eq!(methods("(http.method == 'GET')").unwrap(), vec!["GET"]);
        assert_eq!(methods("'GET' == http.method").unwrap(), vec!["GET"]);
    }

    #[test]
    fn a_disjunction_of_method_comparisons_keeps_its_order() {
        let got = methods("((http.method == 'POST') || (http.method == 'DELETE'))").unwrap();
        assert_eq!(got, vec!["POST", "DELETE"]);
    }

    #[test]
    fn a_disjunction_with_a_non_method_term_is_refused() {
        assert!(methods("((http.method == 'POST') || (http.path == '/x'))").is_none());
    }

    #[test]
    fn a_conjunction_of_methods_is_refused() {
        assert!(methods("(http.method == 'POST') && (http.method == 'DELETE')").is_none());
    }

    #[test]
    fn a_lowercase_method_is_refused() {
        assert!(methods("http.method == 'get'").is_none());
    }

    #[test]
    fn an_unbalanced_predicate_is_refused() {
        assert!(methods("((http.method == 'GET'").is_none());
    }
}
