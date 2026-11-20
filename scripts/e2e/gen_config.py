#!/usr/bin/env python3
"""Writes the isolated E2E config.json. Keys come from the environment (set by up.sh), never from this file.

Routing (all mapped to MP_E2E_MODEL on DeepSeek's Anthropic endpoint):
  claude-sonnet-5, claude-opus-5-5, claude-opus-5, claude-fable-5-1, claude-haiku-4-5* -> "DeepSeek" (defaults)
  claude-sonnet-4-6 -> "DeepSeek Strip" (strip Claude-only fields on, count tokens off)
  claude-opus-4-7   -> "DeepSeek NoThinking" (supports thinking blocks off)
  claude-relay-5    -> "zcode relay (dead store)" (vendorKind relay, ultra-zai pin; credentialStoreBase
                       points at an empty dir, so the signing chain fails cold locally — the
                       dead-signing scenario)
Clients: "Claude Code" on E2E_PORT routes unmapped models to DeepSeek; "Claude Code Passthrough" on
E2E_PASSTHROUGH_PORT passes unmapped models through to api.anthropic.com.
Off-peak async surface: E2E_ASYNC_OFFPEAK=1 enables it with the origin pointed at 127.0.0.1:9
(nothing listens — instant connection refused) so the control-plane-failure ladder runs without
any ticket server; 0 leaves it disabled (default-OFF answers).
"""
import json
import os
import sys

out_path = sys.argv[1]
key = os.environ["DEEPSEEK_API_KEY"]
model = os.environ.get("MP_E2E_MODEL", "deepseek-flash")
port = int(os.environ["E2E_PORT"])
passthrough_port = int(os.environ["E2E_PASSTHROUGH_PORT"])
google_key = os.environ.get("GOOGLE_SEARCH_API_KEY", "")
google_cx = os.environ.get("GOOGLE_SEARCH_ENGINE_ID", "")
credential_store_base = os.environ.get("E2E_CREDENTIAL_STORE_BASE", "")
async_offpeak = os.environ.get("E2E_ASYNC_OFFPEAK", "1") == "1"

DEFAULT, STRIP, NO_THINKING, RELAY = (
    "11111111-1111-1111-1111-111111111111",
    "22222222-2222-2222-2222-222222222222",
    "66666666-6666-6666-6666-666666666666",
    "77777777-7777-7777-7777-777777777777",
)


def vendor(vendor_id, name, **overrides):
    v = {
        "id": vendor_id,
        "name": name,
        "baseURL": "https://api.deepseek.com/anthropic",
        "apiKey": key,
        "connectTimeoutSeconds": 10,
        "readTimeoutSeconds": 300,
        "supportedModels": [model],
        "supportsThinkingBlocks": True,
    }
    v.update(overrides)
    return v


def mapping(index, source, vendor_id):
    return {
        "id": f"44444444-4444-4444-4444-{index:012d}",
        "sourceModel": source,
        "targetModel": model,
        "targetVendorID": vendor_id,
        "isEnabled": True,
    }


sources = ["claude-sonnet-5", "claude-opus-5-5", "claude-opus-5", "claude-fable-5-1",
           "claude-haiku-4-5", "claude-haiku-4-5-20251001"]
mappings = [mapping(i, s, DEFAULT) for i, s in enumerate(sources)]
mappings.append(mapping(90, "claude-sonnet-4-6", STRIP))
mappings.append(mapping(91, "claude-opus-4-7", NO_THINKING))
# The relay-dead-signing scenario's route: target model mirrors the live
# install's GLM mapping; the vendor never gets a working signing chain.
mappings.append({
    "id": "44444444-4444-4444-4444-555555555555",
    "sourceModel": "claude-relay-5",
    "targetModel": "GLM-5.3",
    "targetVendorID": RELAY,
    "isEnabled": True,
})

config = {
    # Empty store base for the relay vendor's signing chain (see module docstring).
    "credentialStoreBase": credential_store_base or None,
    "vendors": [
        # No count-tokens key on purpose: exercises the decoded default.
        vendor(DEFAULT, "DeepSeek"),
        vendor(STRIP, "DeepSeek Strip", stripsClaudeOnlyRequestFields=True, supportsAnthropicCountTokens=False),
        vendor(NO_THINKING, "DeepSeek NoThinking", supportsThinkingBlocks=False),
        # Relay vendor: the RESOLVED ultra pin (probe-A outcome — the wave's
        # zcode-plan pre-routing pin was reverted), no key — auth is the
        # signing chain, which fails cold against the empty credential store.
        {
            "id": RELAY,
            "name": "zcode relay (dead store)",
            "baseURL": "https://zcode.z.ai/api/v1/ultra-zai/anthropic",
            "apiKey": "",
            "connectTimeoutSeconds": 10,
            "readTimeoutSeconds": 300,
            "supportedModels": [],
            "supportsThinkingBlocks": True,
            "vendorKind": "relay",
        },
    ],
    "clients": [
        {"id": "33333333-3333-3333-3333-333333333333", "clientName": "Claude Code", "port": port,
         "defaultUpstream": "https://api.anthropic.com", "unmappedPolicy": "routeAll",
         "fallbackVendorID": DEFAULT, "fallbackTargetModel": model},
        {"id": "33333333-3333-3333-3333-333333333334", "clientName": "Claude Code Passthrough",
         "port": passthrough_port, "defaultUpstream": "https://api.anthropic.com",
         "unmappedPolicy": "passthrough"},
    ],
    "modelMappings": mappings,
    "debug": {"isEnabled": True, "minimumLogLevel": "debug", "autoCleanupEnabled": False,
              "cleanupAfterDays": 7, "compressAfterDays": 3},
    # Off-peak async surface (relay fidelity Task 10): origin on a dead local
    # port so every control call is an instant connection-refused — the
    # ladder aborts without contacting anything real.
    "offPeak": {"enabled": async_offpeak, "origin": "http://127.0.0.1:9"},
    "webSearch": {
        "provider": "google" if google_key and google_cx else "forwardAsIs",
        "braveAPIKey": "", "googleAPIKey": google_key, "googleSearchEngineID": google_cx, "tavilyAPIKey": "",
    },
}

with open(out_path, "w") as f:
    json.dump(config, f, indent=2)
print(f"wrote {out_path} (web search provider: {config['webSearch']['provider']})")
