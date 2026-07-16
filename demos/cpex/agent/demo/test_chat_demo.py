#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Praxis Contributors
"""
Tests for the chat-demo recorder.

Free tests ($0.00, no infra) guard against act/spotlight drift and check that
every spotlight renders. The live test (opt-in) runs the recorder's preflight
against a running stack.

  pytest demo/test_chat_demo.py                 # free tests only
  DEMO_ENABLE_LIVE=1 pytest demo/test_chat_demo.py   # + live preflight
"""

from __future__ import annotations

import importlib.util
import io
import os
from contextlib import redirect_stdout
from pathlib import Path

import pytest

_SPEC = importlib.util.spec_from_file_location(
    "record_chat_demo", Path(__file__).parent / "record_chat_demo.py")
rec = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(rec)


def test_every_act_references_a_defined_spotlight():
    for act in rec.ACTS:
        if "spotlight" in act:
            assert act["spotlight"] in rec.SPOTLIGHTS, act


def test_every_act_persona_is_known():
    for act in rec.ACTS:
        assert act["persona"] in rec.PERSONA_NAME, act


def test_hil_act_defines_a_confirm_line():
    hil = [a for a in rec.ACTS if a["kind"] == "hil"]
    assert len(hil) == 1
    assert hil[0].get("confirm"), "HIL act needs a confirm prompt"


def test_acts_cover_the_headline_features():
    keys = {a.get("spotlight") for a in rec.ACTS}
    for feature in ("allow", "taint", "deny", "cel_allow", "cel_deny", "redact", "hil"):
        assert feature in keys, f"missing feature act: {feature}"


@pytest.mark.parametrize("key", list(rec.SPOTLIGHTS))
def test_spotlight_renders(key):
    buf = io.StringIO()
    with redirect_stdout(buf):
        rec.render_spotlight(key)
    out = buf.getvalue()
    assert rec.SPOTLIGHTS[key]["title"] in out
    assert "POLICY" in out


def test_verify_markers_nonempty():
    assert rec.VERIFY_MARKERS
    assert any(m == rec.BANNER_MARKER for m, _ in rec.VERIFY_MARKERS)


@pytest.mark.skipif(not os.environ.get("DEMO_ENABLE_LIVE"),
                    reason="set DEMO_ENABLE_LIVE=1 to run preflight against a live stack")
def test_live_preflight_passes():
    assert rec.preflight(), "preflight failed — is the cpex stack up? (../restart.sh)"
