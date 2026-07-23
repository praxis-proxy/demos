"""
emulate_client.py – Client/agent emulation script for the Skillberry Praxis filter pipeline.

Sends an OpenAI-compatible chat completion request through the Praxis proxy
(which runs the skillberry filter chain) and prints the model's response.

Praxis owns all LLM routing policy:
- The model and temperature set below are intentionally ignored by Praxis.
  Praxis injects SPAPRAXIS_MODEL and SPAPRAXIS_TEMPERATURE (set when starting
  Praxis) into the worker via x-skillberry-llm-* headers.
- The API key set below is a placeholder. Praxis credential_injection overwrites
  the Authorization header with SPAPRAXIS_API_KEY before the request reaches
  the upstream provider. The client key never leaves the proxy host.

Usage
-----
    # 1. (Optional) override the proxy address if Praxis is not on localhost:7000
    export OPENAI_API_BASE=http://localhost:7000/v1

    # 2. Run
    python pipeline/emulate_client.py

Environment variables
---------------------
OPENAI_API_BASE  – Optional. Base URL of the Praxis proxy. Default: http://localhost:7000/v1
"""

import os

from litellm import completion

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

# The Praxis proxy address. Override via OPENAI_API_BASE if needed.
os.environ.setdefault("OPENAI_API_BASE", "http://localhost:7000/v1")

# litellm requires a non-empty api_key, but Praxis credential_injection
# overwrites it before the request reaches the upstream provider.
os.environ.setdefault("OPENAI_API_KEY", "not-used")

# ---------------------------------------------------------------------------
# Request
# ---------------------------------------------------------------------------

response = completion(
    model="openai/fake-model", # Praxis is configured with its own model to be used
    messages=[{"role": "user", "content": "Show me your tools"}],
    extra_headers={
        "skillberry-context-env_id": "praxis-demo-env"
    },
)

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

print(response.choices[0].message.content)
