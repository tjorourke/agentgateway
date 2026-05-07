# `headerRedaction` — header-driven dynamic PII redaction

## What this is

A new `promptGuard` action that performs **symmetric, in-process** redaction
of LLM prompt and response content driven by HTTP headers attached to the
*original client request*.

```
edge ──▶ agentgateway ──▶ LLM provider
     ▲                    │
     │  un-redact          │  redact
     │                    ▼
     └────────  agentgateway  ◀─── response
```

- **Request phase**: every header whose name starts with `headerPrefix`
  (default `x-redact-`) drives an in-place substitution of the value in
  `messages[].content` with a token derived from `tokenFormat`
  (default `[{NAME}]`, where `{NAME}` is the uppercased header suffix).
- **Response phase**: the inverse substitution restores original values in
  `choices[].message.content`, using **the same client request headers**.
  The response side does not depend on what the upstream provider returned
  in *its* headers — that asymmetry is exactly the gap that prevents a
  webhook-based solution from working.

## When to use it vs other guards

| Use case | Best fit |
|---|---|
| Static patterns (email, phone, credit card, SSN, NHS, postcode, NI, vehicle reg, IPv4, URL, …) | `regex` (builtins + custom patterns) |
| **Dynamic per-request values you already know** (this child's name, this parent's email, this case ref) | `headerRedaction` |
| Heavyweight stateful detection (dictionary, ML, content-policy) | `webhook` (request side only — response side has the header asymmetry limitation) |
| Provider-side guardrails | `bedrockGuardrails` / `googleModelArmor` / `azureContentSafety` |

## Configuration

### Minimal (defaults)

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: pii-headers
  namespace: agentgateway-system
spec:
  targetRefs:
  - { group: gateway.networking.k8s.io, kind: HTTPRoute, name: my-llm-route }
  backend:
    ai:
      promptGuard:
        request:  [{ headerRedaction: {} }]   # uses x-redact-, [{NAME}]
        response: [{ headerRedaction: {} }]
```

### Explicit

```yaml
spec:
  backend:
    ai:
      promptGuard:
        request:
        - headerRedaction:
            headerPrefix: x-redact-
            tokenFormat: "[{NAME}]"
        response:
        - headerRedaction:
            headerPrefix: x-redact-
            tokenFormat: "[{NAME}]"
```

### Combined with regex (the recommended production shape)

```yaml
spec:
  backend:
    ai:
      promptGuard:
        request:
        # Static patterns: emails, phones, NHS, NI, postcodes...
        - regex:
            action: Mask
            builtins: [ Email, PhoneNumber, Ssn, CreditCard, CaSin ]
            matches:
            - '\b[A-CEGHJ-PR-TW-Z]{2}[0-9]{6}[A-D]\b'        # NI number
            - '\b[A-Z]{1,2}\d[A-Z\d]?\s*\d[A-Z]{2}\b'         # UK postcode
            - '\b\d{3}\s?\d{3}\s?\d{4}\b'                     # NHS number
            - '\b[A-Z]{2}\d{2}\s?[A-Z]{3}\b'                  # UK vehicle reg
            - 'https?://\S+'                                  # URL
        # Dynamic per-tenant values from request headers
        - headerRedaction: {}
        response:
        # Restore the dynamic tokens. Static regex matches are not restored
        # — they were one-way redactions by design.
        - headerRedaction: {}
```

## Configuration options

| Field | Type | Default | Notes |
|---|---|---|---|
| `headerPrefix` | string | `x-redact-` | Case-insensitive match. Suffix becomes the token name. |
| `tokenFormat` | string | `[{NAME}]` | The literal `{NAME}` is replaced with the uppercased suffix. |

## Behaviour

- **Token derivation**: `x-redact-firstname: Tom` → token `[FIRSTNAME]`.
  The header suffix is uppercased verbatim, including underscores
  (`x-redact-parent1_first` → `[PARENT1_FIRST]`).
- **Matching**: word-boundary, case-insensitive regex (`\bvalue\b`).
  `Tom` redacts in `Tom said hello` but not in `Tomorrow`.
- **Ordering**: substitutions sorted **longest-first** so `Smithson`
  redacts before `Smith` and they don't collide.
- **Special characters**: values are `regex::escape`'d before matching, so
  apostrophes (`O'Rourke`), dots, brackets etc. are handled literally.
- **Empty header values** (length < 2) are skipped — protects against
  accidental over-redaction of single common letters.
- **Response restoration**: direct string replacement (no regex), so any
  occurrence of the token in the LLM output is restored to the original
  value, including inside larger words if the LLM concatenated the token.

## Architectural change behind the feature

Pre-existing `webhook` guards on the response side received only the
**upstream provider's** response headers (`anthropic-organization-id`,
`request-id`, `cf-ray`, …). The original *client* request headers were
never propagated — so a webhook had no way to look up which redaction
values to restore.

This PR adds a `client_headers: HeaderMap` parameter through:

```
proxy::httpproxy::stream_http_to_backend
  └─ snapshot req.headers() before the upstream call
     └─ llm::process_response(client_headers)
        └─ Policy::apply_response_prompt_guard(upstream_headers, client_headers, …)
           └─ headerRedaction guard reads client_headers
```

The `webhook` variant still uses `upstream_headers` (no behavioural change
for existing users).

## Use cases

This was built for SEND education software where each request is scoped to
a specific child/parent/local-authority/school whose names cannot be
expressed as static regex but must never reach the LLM provider.

The same shape applies to:

- Healthcare per-patient identifiers
- Multi-tenant SaaS where tenant-specific entity names should be redacted
- Customer-support tools where customer names appear in transcripts
- Any "we know the values, we just don't want them leaving our network"
  scenario

## Acceptance criteria

- ✅ `HeaderRedaction` is a variant on both `RequestGuardKind` and
  `ResponseGuardKind`
- ✅ Headers matching `headerPrefix` on the **original client request**
  drive substitution on both phases
- ✅ Round-trip: `x-redact-firstname: Tom`, prompt with `Tom` reaches LLM
  as `[FIRSTNAME]`, response with `[FIRSTNAME]` reaches client as `Tom`
- ✅ Static regex prompt guards continue to work unchanged
- ✅ Webhook prompt guards continue to work unchanged (still get upstream
  response headers, no behaviour change)
- ✅ Word-boundary, case-insensitive matching by default
- ✅ Substitutions sorted longest-first (no partial-match clobbering)
- ✅ Unit tests for substitution logic (29 tests)
- ✅ Proto→Rust conversion tests (4 tests)
- ✅ Go controller dispatch + defaults tests (5 tests)
- ✅ Existing test suite passes (no regressions)

## See also

- [proposal](./proposals/header-redaction-prompt-guard.md) — original design doc
- [test evidence](./test-evidence-header-redaction.md) — manual end-to-end
  verification on a real EKS cluster against Anthropic
