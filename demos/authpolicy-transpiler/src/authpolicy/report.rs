// SPDX-License-Identifier: MIT
// Copyright (c) 2024 Praxis Contributors

//! Coverage report for the `AuthPolicy` transpiler.
//!
//! Every construct the translator encounters is recorded as
//! [`Coverage::Translated`], [`Coverage::Approximated`], or
//! [`Coverage::Skipped`] with a [`Severity`] and a human-readable reason.
//! A [`Severity::Fatal`] entry (e.g. an authorization policy that lost all
//! its rules to gaps, R19) makes [`Report::has_fatal`] true, which the CLI
//! turns into a non-zero exit so a fail-open fragment is never shipped
//! silently.

use std::fmt::Write as _;

/// How completely a construct was carried into the emitted output.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Coverage {
    /// Fully represented in the emitted CPEX doc / filter block.
    Translated,
    /// Partially represented; some fidelity is lost (detail says what).
    Approximated,
    /// Not represented at all; reported and (where relevant) stubbed.
    Skipped,
}

impl Coverage {
    fn label(self) -> &'static str {
        match self {
            Self::Translated => "translated",
            Self::Approximated => "approximated",
            Self::Skipped => "skipped",
        }
    }
}

/// How much the operator needs to care about an entry.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub(crate) enum Severity {
    /// Informational — no action required.
    Info,
    /// The operator should review this before relying on the output.
    Warning,
    /// Enforcement correctness is at stake; the CLI exits non-zero.
    Fatal,
}

impl Severity {
    fn label(self) -> &'static str {
        match self {
            Self::Info => "INFO",
            Self::Warning => "WARN",
            Self::Fatal => "FATAL",
        }
    }
}

/// One reported construct.
#[derive(Debug, Clone)]
pub(crate) struct Entry {
    /// Dotted path of the construct, e.g. `authentication/keycloak-jwt`.
    pub construct: String,
    pub coverage: Coverage,
    pub severity: Severity,
    pub detail: String,
}

/// Accumulated coverage for one transpiled `AuthPolicy`.
#[derive(Debug, Default, Clone)]
pub(crate) struct Report {
    pub entries: Vec<Entry>,
}

impl Report {
    fn push(
        &mut self,
        construct: impl Into<String>,
        coverage: Coverage,
        severity: Severity,
        detail: impl Into<String>,
    ) {
        self.entries.push(Entry {
            construct: construct.into(),
            coverage,
            severity,
            detail: detail.into(),
        });
    }

    /// Record a fully-translated construct.
    pub(crate) fn translated(&mut self, construct: impl Into<String>, detail: impl Into<String>) {
        self.push(construct, Coverage::Translated, Severity::Info, detail);
    }

    /// Record a construct carried with reduced fidelity.
    pub(crate) fn approximated(
        &mut self,
        construct: impl Into<String>,
        severity: Severity,
        detail: impl Into<String>,
    ) {
        self.push(construct, Coverage::Approximated, severity, detail);
    }

    /// Record a construct that could not be carried.
    pub(crate) fn skipped(
        &mut self,
        construct: impl Into<String>,
        severity: Severity,
        detail: impl Into<String>,
    ) {
        self.push(construct, Coverage::Skipped, severity, detail);
    }

    /// True if any entry is [`Severity::Fatal`] — the CLI exits non-zero.
    pub(crate) fn has_fatal(&self) -> bool {
        self.entries.iter().any(|e| e.severity == Severity::Fatal)
    }

    /// `(translated, approximated, skipped)` counts.
    pub(crate) fn counts(&self) -> (usize, usize, usize) {
        let mut counts = (0, 0, 0);
        for e in &self.entries {
            match e.coverage {
                Coverage::Translated => counts.0 += 1,
                Coverage::Approximated => counts.1 += 1,
                Coverage::Skipped => counts.2 += 1,
            }
        }
        counts
    }

    /// Render a deterministic, human-readable report.
    pub(crate) fn render(&self) -> String {
        let mut out = String::new();
        let (t, a, s) = self.counts();
        out.push_str("AuthPolicy → Praxis coverage report\n");
        out.push_str("===================================\n");
        writeln!(out, "translated: {t}   approximated: {a}   skipped: {s}")
            .expect("writing to a String is infallible");
        if self.has_fatal() {
            out.push_str(
                "\nFATAL: authorization coverage is incomplete in a way that would fail open.\n\
                 The emitted policy denies by default; resolve the FATAL entries below before use.\n",
            );
        }
        out.push('\n');
        for e in &self.entries {
            writeln!(
                out,
                "[{:<5}] {:<13} {}\n          {}",
                e.severity.label(),
                e.coverage.label(),
                e.construct,
                e.detail,
            )
            .expect("writing to a String is infallible");
        }
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn counts_and_fatal() {
        let mut r = Report::default();
        r.translated("authentication/jwt", "JWT → identity/jwt");
        r.approximated(
            "authentication/jwt",
            Severity::Warning,
            "issuerUrl→JWKS discovery",
        );
        r.skipped(
            "authorization/opa",
            Severity::Warning,
            "OPA/Rego unsupported",
        );
        assert_eq!(r.counts(), (1, 1, 1));
        assert!(!r.has_fatal());

        r.skipped(
            "authorization",
            Severity::Fatal,
            "all authz rules lost to gaps",
        );
        assert!(r.has_fatal());
        assert_eq!(r.counts(), (1, 1, 2));
    }

    #[test]
    fn render_mentions_fatal_banner() {
        let mut r = Report::default();
        r.skipped("authorization", Severity::Fatal, "fail-closed");
        let text = r.render();
        assert!(text.contains("FATAL"));
        assert!(text.contains("denies by default"));
    }
}
