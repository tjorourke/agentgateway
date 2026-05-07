# Proposal: First-class header-driven redaction in `promptGuard`

## TL;DR

Add a new `promptGuard` action — `headerRedaction` — that reads HTTP headers from the original client request and substitutes their values in LLM prompts (request side) and restores them in LLM responses (response side). Built into the gateway, no webhook required.

This solves a class of dynamic per-request redaction use cases that the current architecture cannot handle, because the response-side webhook receives only upstream provider headers, not the original client request headers.

---

## Problem statement

### Use case

Multi-tenant SaaS applications need to redact per-request PII (child names, parent names, school names, patient identifiers, customer names) before forwarding LLM prompts to providers like Anthropic, Bedrock, OpenAI. The values are dynamic per request, not patternable by static regex, and known only to the calling application.

The natural design:

```
edge function ──▶ agentgateway ──▶ LLM provider
              ▲                    │
              │  un-redact         │  redact
              │                    ▼
              └────────  agentgateway  ◀─── response
```

Edge function adds headers like:
```
x-redact-firstname: Tom
x-redact-surname: O'Rourke
```

The gateway should:
1. **On request:** read these headers, substitute matching values in `messages[].content` with `[FIRSTNAME]`, `[SURNAME]` tokens, forward redacted prompt to provider
2. **On response:** read the same headers (still in the request scope), restore tokens to original values in `choices[].message.content`, return to client

### What works today

The **request-side** redaction can be implemented via a webhook guardrail. Verified working on `agentgateway v1.1.0`:

- Edge function sets `x-redact-firstname: Tom` etc.
- `forwardHeaderMatches` (with `type: RegularExpression` + `value: ".*"`) forwards the header to the webhook
- Webhook reads header, redacts body, returns `Mask` action with redacted `messages`
- Provider only ever sees redacted prompt (`prompt_tokens` count confirms)

### What fails today

The **response-side** webhook cannot do the inverse. The response webhook receives the **upstream provider's HTTP response headers** (Anthropic's `request-id`, `cf-ray`, `anthropic-organization-id`, etc.) — NOT the client's original request headers.

Reproduced on `v1.1.0`: same policy with `forwardHeaderMatches` listing `x-redact-firstname` on both request AND response webhook configs. Header is forwarded to `/request`, NOT to `/response`. Webhook log shows only `Content-Length` and `Content-Type` on the response side.

### Why — source citation

`crates/agentgateway/src/llm/mod.rs` ~line 1028 — `Policy::apply_response_prompt_guard` is called with `&parts.headers`:

```rust
if let Some(dr) = Policy::apply_response_prompt_guard(
    &client,
    resp.as_mut(),
    &parts.headers,        // ← upstream response headers
    &rate_limit.prompt_guard,
)
```

Where `parts` comes from (~line 958):

```rust
let (mut parts, body) = resp.into_parts();  // resp is the upstream response
```

The `forwardHeaderMatches` filter in `crates/agentgateway/src/llm/policy/mod.rs::get_webhook_forward_headers` then filters those upstream headers. Anything the client set on the original request is not in `parts.headers`.

Therefore: **no header-based correlation between request and response webhooks is possible in v1.1.0.** The architectural gap is structural, not a config oversight.

### Workarounds and why they're poor

| Workaround | Issue |
|---|---|
| Stateful webhook with cache keyed by correlation header | No correlation header survives both phases |
| Stateful webhook with content-based correlation (unique token suffixes) | Brittle — depends on LLM faithfully reproducing tokens; needs Redis or single-replica |
| Embed substitution map in prompt body | LLMs don't reliably echo system messages back |
| Client-side un-redaction in edge function | Requires every consumer of the gateway to implement substitution |
| Add a `metadata` field to `Mask` action that gateway re-sends to response webhook | Useful but webhook-specific; doesn't address other redaction use cases |

None are clean. All require infrastructure beyond the gateway itself.

---

## Proposal: `headerRedaction` as a built-in `promptGuard` action

A new policy action that performs symmetric request/response transformation driven by client request headers, executed inside the gateway proxy. No webhook needed.

### Example policy

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: weaveone-pii
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: route-tier-2
  backend:
    ai:
      promptGuard:
        request:
        - headerRedaction:
            headerPrefix: "x-redact-"
            tokenFormat: "[{NAME}]"
        response:
        - headerRedaction:
            headerPrefix: "x-redact-"
            tokenFormat: "[{NAME}]"
```

### Behaviour

For every header on the original client request whose name starts with `headerPrefix`:

1. **Request phase**: substitute every occurrence of the header's value in `messages[].content` with `tokenFormat` where `{NAME}` is the uppercased suffix after the prefix
2. **Response phase**: substitute every occurrence of the token in `choices[].message.content` back to the original value

So `x-redact-firstname: Tom` plus `tokenFormat: "[{NAME}]"` produces:

- Request: `"Tom likes apples"` → `"[FIRSTNAME] likes apples"` (sent to LLM)
- Response: `"[FIRSTNAME] likes apples"` → `"Tom likes apples"` (returned to client)

Substitutions sorted longest-first to avoid partial matches (`"Smith"` inside `"Smithson"`).

Word-boundary regex matching by default; configurable via a future `wordBoundary: false` option if needed.

### Defaults

```yaml
headerRedaction:
  headerPrefix: "x-redact-"      # default
  tokenFormat: "[{NAME}]"        # default
```

A bare `headerRedaction: {}` works with sensible defaults.

---

## Implementation plan

Five-file change. Follows the existing `RegexRules` guard as a template throughout.

### Step 1 — Add new types

**File:** `crates/agentgateway/src/llm/policy/mod.rs`

Near the existing `PromptGuardRegex` struct (~line 1398), add:

```rust
#[apply(schema!)]
pub struct HeaderRedaction {
    /// Header name prefix. Headers with this prefix are read for redaction values.
    /// Default: "x-redact-"
    #[serde(default = "default_header_redaction_prefix")]
    pub header_prefix: String,

    /// Format string for the redaction token. {NAME} is replaced with the
    /// uppercased suffix after header_prefix. Default: "[{NAME}]"
    #[serde(default = "default_header_redaction_token_format")]
    pub token_format: String,
}

fn default_header_redaction_prefix() -> String { "x-redact-".to_string() }
fn default_header_redaction_token_format() -> String { "[{NAME}]".to_string() }
```

Add `HeaderRedaction` as a variant in both `RequestGuardKind` (~line 1151) and `ResponseGuardKind` (~line 1389):

```rust
pub enum RequestGuardKind {
    Regex(RegexRules),
    Webhook(Webhook),
    HeaderRedaction(HeaderRedaction),  // NEW
    OpenAIModeration(Moderation),
    BedrockGuardrails(BedrockGuardrails),
    GoogleModelArmor(GoogleModelArmor),
    AzureContentSafety(AzureContentSafety),
}

pub enum ResponseGuardKind {
    Regex(RegexRules),
    Webhook(Webhook),
    HeaderRedaction(HeaderRedaction),  // NEW
    BedrockGuardrails(BedrockGuardrails),
    GoogleModelArmor(GoogleModelArmor),
    AzureContentSafety(AzureContentSafety),
}
```

### Step 2 — Implement substitution logic

**File:** `crates/agentgateway/src/llm/policy/mod.rs`

Add helper near the existing `apply_regex` / `apply_regex_response` functions (~line 707):

```rust
/// Build the substitution table from headers matching the configured prefix.
/// Returns (original_value, token) pairs sorted by original_value length descending,
/// so longer matches replace before shorter ones.
fn build_header_substitutions(
    headers: &HeaderMap,
    rules: &HeaderRedaction,
) -> Vec<(String, String)> {
    let mut subs = Vec::new();
    for (name, value) in headers {
        let n = name.as_str();
        if !n.to_ascii_lowercase().starts_with(&rules.header_prefix.to_ascii_lowercase()) {
            continue;
        }
        let Ok(v) = value.to_str() else { continue; };
        if v.len() < 2 { continue; }
        let token_name = n[rules.header_prefix.len()..].to_ascii_uppercase();
        let token = rules.token_format.replace("{NAME}", &token_name);
        subs.push((v.to_string(), token));
    }
    subs.sort_by(|a, b| b.0.len().cmp(&a.0.len()));
    subs
}

/// Replace original values with tokens. Word-boundary, case-insensitive.
fn apply_redact(content: &str, subs: &[(String, String)]) -> String {
    if subs.is_empty() { return content.to_string(); }
    let mut out = content.to_string();
    for (original, token) in subs {
        let pattern = format!(r"(?i)\b{}\b", regex::escape(original));
        if let Ok(re) = regex::Regex::new(&pattern) {
            out = re.replace_all(&out, token.as_str()).to_string();
        }
    }
    out
}

/// Replace tokens with original values. Direct string substitution.
fn apply_unredact(content: &str, subs: &[(String, String)]) -> String {
    if subs.is_empty() { return content.to_string(); }
    let mut out = content.to_string();
    for (original, token) in subs {
        out = out.replace(token, original);
    }
    out
}

fn apply_header_redaction(
    req: &mut dyn RequestType,
    rules: &HeaderRedaction,
    http_headers: &HeaderMap,
) -> anyhow::Result<GuardrailOutcome> {
    let subs = build_header_substitutions(http_headers, rules);
    if subs.is_empty() {
        return Ok(GuardrailOutcome::None);
    }
    let mut msgs = req.get_messages();
    let mut any_changed = false;
    for msg in &mut msgs {
        let new_content = apply_redact(&msg.content, &subs);
        if new_content != msg.content.as_ref() {
            msg.content = new_content.into();
            any_changed = true;
        }
    }
    if any_changed {
        req.set_messages(msgs);
        return Ok(GuardrailOutcome::Masked);
    }
    Ok(GuardrailOutcome::None)
}

fn apply_header_redaction_response(
    resp: &mut dyn ResponseType,
    rules: &HeaderRedaction,
    client_headers: &HeaderMap,
) -> anyhow::Result<GuardrailOutcome> {
    let subs = build_header_substitutions(client_headers, rules);
    if subs.is_empty() {
        return Ok(GuardrailOutcome::None);
    }
    let mut choices = resp.to_webhook_choices();
    let mut any_changed = false;
    for choice in &mut choices {
        let restored = apply_unredact(&choice.message.content, &subs);
        if restored != choice.message.content.as_ref() {
            choice.message.content = restored.into();
            any_changed = true;
        }
    }
    if any_changed {
        resp.set_webhook_choices(choices)?;
        return Ok(GuardrailOutcome::Masked);
    }
    Ok(GuardrailOutcome::None)
}
```

### Step 3 — Dispatch from the guard match arms

**File:** `crates/agentgateway/src/llm/policy/mod.rs`

In `apply_prompt_guard` (~line 386), add a new match arm:

```rust
RequestGuardKind::HeaderRedaction(hr) => {
    match Self::apply_header_redaction(req, hr, http_headers)? {
        GuardrailOutcome::Masked => {
            Self::record_guardrail_trip(
                &client,
                crate::telemetry::metrics::GuardrailPhase::Request,
                crate::telemetry::metrics::GuardrailAction::Mask,
            );
        },
        GuardrailOutcome::None => {
            Self::record_guardrail_trip(
                &client,
                crate::telemetry::metrics::GuardrailPhase::Request,
                crate::telemetry::metrics::GuardrailAction::Allow,
            );
        },
        GuardrailOutcome::Rejected(_) => unreachable!(
            "header redaction never rejects"
        ),
    }
},
```

In `apply_response_prompt_guard` (~line 1033), add the same dispatch but using the **client headers** parameter (added in step 4):

```rust
ResponseGuardKind::HeaderRedaction(hr) => {
    match Self::apply_header_redaction_response(resp, hr, client_headers)? {
        GuardrailOutcome::Masked => {
            Self::record_guardrail_trip(
                client,
                crate::telemetry::metrics::GuardrailPhase::Response,
                crate::telemetry::metrics::GuardrailAction::Mask,
            );
        },
        GuardrailOutcome::None => {
            Self::record_guardrail_trip(
                client,
                crate::telemetry::metrics::GuardrailPhase::Response,
                crate::telemetry::metrics::GuardrailAction::Allow,
            );
        },
        GuardrailOutcome::Rejected(_) => unreachable!(
            "header redaction never rejects"
        ),
    }
},
```

### Step 4 — Plumb client headers through to the response guard

This is the core architectural change. Currently the response side gets upstream-response headers; we need it to also have access to the original client request headers.

**File:** `crates/agentgateway/src/llm/policy/mod.rs`

Change `apply_response_prompt_guard` signature (~line 1025) to add `client_headers`:

```rust
pub async fn apply_response_prompt_guard(
    client: &PolicyClient,
    resp: &mut dyn ResponseType,
    upstream_headers: &HeaderMap,    // RENAMED from http_headers (clarity)
    client_headers: &HeaderMap,      // NEW
    guards: &Vec<ResponseGuard>,
) -> anyhow::Result<Option<Response>> {
```

The existing `Webhook` variant continues to use `upstream_headers` (preserves backward compat). The new `HeaderRedaction` variant uses `client_headers`.

**File:** `crates/agentgateway/src/llm/mod.rs`

Change `process_response` signature (~line 938) to add `client_headers: HeaderMap`:

```rust
pub async fn process_response(
    &self,
    client: PolicyClient,
    req: LLMRequest,
    rate_limit: LLMResponsePolicies,
    log: AsyncLog<llm::LLMInfo>,
    include_completion_in_log: bool,
    client_headers: HeaderMap,    // NEW
    resp: Response,
) -> Result<Response, AIError> {
```

At the call site of `apply_response_prompt_guard` (~line 1028), pass both:

```rust
if let Some(dr) = Policy::apply_response_prompt_guard(
    &client,
    resp.as_mut(),
    &parts.headers,    // upstream_headers
    &client_headers,   // client_headers — NEW
    &rate_limit.prompt_guard,
)
```

**File:** `crates/agentgateway/src/proxy/httpproxy.rs`

At the production call site of `process_response` (~line 1822), capture client headers from `req` before it's moved into `Call`:

```rust
// Around line 1779, BEFORE: let call = client::Call { req, ... };
let client_headers = req.headers().clone();

let call = client::Call {
    req,
    target: backend_call.target,
    transport,
};
// ... existing upstream.call(call).await ...

// At the process_response call (line 1822):
llm.provider.process_response(
    policy_client.clone(),
    llm_request,
    llm_response_policies,
    llm_response_log.expect("must be set"),
    include_completion_in_log,
    client_headers,    // NEW
    resp,
)
```

**File:** `crates/agentgateway/src/llm/tests.rs`

Update the test invocation of `process_response` (~line 983) to pass an empty `HeaderMap::new()` for `client_headers`. Existing tests don't exercise prompt guard, so a default value is fine.

### Step 5 — Tests

**File:** `crates/agentgateway/src/llm/policy/mod.rs` — add unit tests at the bottom of the test module:

```rust
#[test]
fn test_build_header_substitutions() {
    let mut headers = HeaderMap::new();
    headers.insert("x-redact-firstname", HeaderValue::from_static("Tom"));
    headers.insert("x-redact-surname", HeaderValue::from_static("O'Rourke"));
    headers.insert("x-other", HeaderValue::from_static("ignored"));

    let rules = HeaderRedaction {
        header_prefix: "x-redact-".to_string(),
        token_format: "[{NAME}]".to_string(),
    };

    let subs = build_header_substitutions(&headers, &rules);
    assert_eq!(subs.len(), 2);
    // Sorted longest-first
    assert_eq!(subs[0].0, "O'Rourke");
    assert_eq!(subs[0].1, "[SURNAME]");
}

#[test]
fn test_apply_redact_word_boundary() {
    let subs = vec![
        ("Tom".to_string(), "[FIRSTNAME]".to_string()),
        ("O'Rourke".to_string(), "[SURNAME]".to_string()),
    ];
    let r1 = apply_redact("Tom O'Rourke is here", &subs);
    assert_eq!(r1, "[FIRSTNAME] [SURNAME] is here");

    // Word boundary: shouldn't match inside "Tomorrow"
    let r2 = apply_redact("Tomorrow we meet Tom", &subs);
    assert_eq!(r2, "Tomorrow we meet [FIRSTNAME]");

    // Case insensitive
    let r3 = apply_redact("TOM is here", &subs);
    assert_eq!(r3, "[FIRSTNAME] is here");
}

#[test]
fn test_apply_unredact_round_trip() {
    let subs = vec![
        ("Tom".to_string(), "[FIRSTNAME]".to_string()),
        ("O'Rourke".to_string(), "[SURNAME]".to_string()),
    ];
    let original = "Tom O'Rourke is here";
    let redacted = apply_redact(original, &subs);
    let restored = apply_unredact(&redacted, &subs);
    assert_eq!(restored, original);
}

#[test]
fn test_longest_first_ordering() {
    // "Smith" must not partial-match inside "Smithson" before Smithson is matched
    let mut headers = HeaderMap::new();
    headers.insert("x-redact-short", HeaderValue::from_static("Smith"));
    headers.insert("x-redact-full", HeaderValue::from_static("Smithson"));

    let rules = HeaderRedaction {
        header_prefix: "x-redact-".to_string(),
        token_format: "[{NAME}]".to_string(),
    };
    let subs = build_header_substitutions(&headers, &rules);

    let result = apply_redact("Mr Smithson met Mr Smith", &subs);
    assert_eq!(result, "Mr [FULL] met Mr [SHORT]");
}
```

Plus an integration test that exercises an end-to-end policy with `HeaderRedaction` in both request and response phases. Use the existing httpbun mock provider for predictable round-trip behaviour.

### Step 6 — CRD & schema regeneration

After Rust changes, regenerate the JSON schema and CRDs:

```bash
make generate    # or whatever the project's codegen target is
```

Check `crates/agentgateway/schemas/` and `manifests/charts/agentgateway-crds/` for updated outputs. Commit alongside the source.

### Step 7 — Documentation

Add a docs page to `agentgateway.dev/docs/kubernetes/main/llm/guardrails/header-redaction/` covering:

- When to use header redaction vs static regex vs webhook
- Configuration options (`headerPrefix`, `tokenFormat`)
- Example end-to-end with curl
- Compliance notes (DPIA, GDPR Recital 26)
- Performance characteristics (in-process, sub-millisecond)
- Limitations (only operates on `messages[].content` and `choices[].message.content`)

---

## Acceptance criteria

- [ ] `HeaderRedaction` accepted as a variant in both `RequestGuardKind` and `ResponseGuardKind`
- [ ] Headers matching `headerPrefix` on the **original client request** drive redaction on both request and response phases
- [ ] Round-trip: client sends `x-redact-firstname: Tom`, prompt with "Tom" reaches LLM as "[FIRSTNAME]", response with "[FIRSTNAME]" reaches client as "Tom"
- [ ] Static regex prompt guards continue to function unchanged (backward compat)
- [ ] Webhook prompt guards continue to function unchanged (backward compat)
- [ ] Word-boundary, case-insensitive matching by default
- [ ] Substitutions sorted longest-first
- [ ] Unit tests for substitution logic
- [ ] Integration test with mock provider (httpbun)
- [ ] Existing test suite passes
- [ ] CRD schema regenerated
- [ ] Docs page added

---

## Out of scope for this PR

- Configurable word-boundary mode (defer)
- Token format with multiple substitution placeholders beyond `{NAME}` (defer)
- Header value matching/filtering (defer; if needed, can use existing `forwardHeaderMatches` semantics in a future PR)
- Streaming response support — the response prompt guard is already bypassed on the streaming path (see `crates/agentgateway/src/llm/mod.rs` ~line 950); fixing that is a separate concern
- Embeddings / count-tokens / detect routes (already excluded from prompt guarding by `InputFormat::supports_prompt_guard`)

---

## Reference: source locations

| Concern | File | Approx line |
|---|---|---|
| `RequestGuardKind` enum | `crates/agentgateway/src/llm/policy/mod.rs` | 1151 |
| `ResponseGuardKind` enum | `crates/agentgateway/src/llm/policy/mod.rs` | 1389 |
| `PromptGuardRegex` (template) | `crates/agentgateway/src/llm/policy/mod.rs` | 1398 |
| `apply_prompt_guard` (request dispatch) | `crates/agentgateway/src/llm/policy/mod.rs` | 369 |
| `apply_response_prompt_guard` (response dispatch) | `crates/agentgateway/src/llm/policy/mod.rs` | 1025 |
| `apply_regex` (request impl template) | `crates/agentgateway/src/llm/policy/mod.rs` | 707 |
| `apply_regex_response` (response impl template) | `crates/agentgateway/src/llm/policy/mod.rs` | 733 |
| `get_webhook_forward_headers` (header filter logic) | `crates/agentgateway/src/llm/policy/mod.rs` | 880 |
| `process_response` (response entry point) | `crates/agentgateway/src/llm/mod.rs` | 938 |
| Response prompt guard call site | `crates/agentgateway/src/llm/mod.rs` | 1028 |
| Production caller of `process_response` | `crates/agentgateway/src/proxy/httpproxy.rs` | 1817 |
| Webhook wire format types | `crates/agentgateway/src/llm/policy/webhook.rs` | 1-130 |
| `RequestType` / `ResponseType` traits | `crates/agentgateway/src/llm/types/mod.rs` | various |

---

## Working environment

This proposal was written by a Solo SA building a SEND education SaaS (WeaveONE) on agentgateway 1.1.0 deployed to AWS EKS in eu-west-2. The webhook-based workaround is currently running with request-side redaction working but response-side blocked by the header asymmetry described above.

Reproducer for the current limitation:

```bash
# Apply a policy with both request and response webhooks targeting the same Service
# Send a request with x-redact-* headers
# Webhook log shows the headers on /request only, never on /response

curl http://gateway:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "x-redact-firstname: Tom" \
  -H "x-redact-surname: O'Rourke" \
  -d '{"messages":[{"role":"user","content":"Note about Tom O'\''Rourke"}]}'
```

---

## Questions for maintainers

1. Is there an existing roadmap entry for first-class header redaction? Don't want to duplicate effort.
2. Preferred naming — `headerRedaction` or `headers` or something else? Following existing convention of `regex` / `webhook` / `bedrockGuardrails`.
3. Should the response phase also accept upstream response headers as a configurable input source (for use cases that want to redact based on what the LLM saw)? Default to client request headers, allow opt-in for upstream.
4. CRD compatibility — does adding a new variant to `RequestGuardKind` require a CRD bump or is the existing `v1alpha1` flexible enough?
5. Streaming response handling — currently the streaming path bypasses prompt guards entirely. Out of scope for this PR but worth a maintainer note on whether streaming + redaction is a planned area.
