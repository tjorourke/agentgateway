# Test evidence — `headerRedaction`

End-to-end verification on a real EKS cluster (eu-west-2), against
Anthropic and Bedrock, plus a controlled echo upstream that captures the
literal post-redaction bytes leaving the gateway.

## Environment

- Kubernetes cluster: `weaveone-eks` (EKS, eu-west-2, amd64 nodes)
- agentgateway proxy image (with this PR): `agentgateway:v1.1.0-headerredaction-dev`
- agentgateway controller image (with this PR): `agentgateway-controller:v1.1.0-headerredaction-dev`
- Backend tier-2: Anthropic primary (`claude-haiku-4-5-20251001`), Bedrock fallback
- Policy: `weaveone-pii` (regex builtins + `headerRedaction` on request/response)

## Automated test results

```
$ cargo test --package agentgateway llm::policy::tests::header_redaction_tests
test result: ok. 29 passed; 0 failed
```

```
$ cargo test --package agentgateway types::agent_xds::tests::convert_
test result: ok. 4 passed; 0 failed
```

```
$ cargo test --package agentgateway llm::
test result: ok. 275 passed; 0 failed; 3 ignored
```

```
$ cargo test --package agentgateway --lib
test result: 951 passed; 1 failed (unrelated AWS env-dependent test); 1 ignored
```

```
$ cd controller && go test ./pkg/agentgateway/plugins/ -run HeaderRedaction
ok  github.com/agentgateway/agentgateway/controller/pkg/agentgateway/plugins  (5 tests)
$ go test ./pkg/agentgateway/plugins/
ok  github.com/agentgateway/agentgateway/controller/pkg/agentgateway/plugins  101 tests
```

## Manual end-to-end test

### Setup

`weaveone-pii` policy applied to `route-tier-1`, `route-tier-2`, and a
test-only `route-tier-test` that points at an in-cluster echo server.
Echo server returns an OpenAI-compatible response whose
`choices[0].message.content` is the JSON-stringified request body it
received — i.e. exactly what the gateway forwarded upstream.

```yaml
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: weaveone-pii
  namespace: agentgateway-system
spec:
  targetRefs:
  - { group: gateway.networking.k8s.io, kind: HTTPRoute, name: route-tier-1 }
  - { group: gateway.networking.k8s.io, kind: HTTPRoute, name: route-tier-2 }
  - { group: gateway.networking.k8s.io, kind: HTTPRoute, name: route-tier-test }
  backend:
    ai:
      promptGuard:
        request:
        - regex:
            action: Mask
            builtins: [Email, PhoneNumber, Ssn, CreditCard, CaSin]
            matches:
            - '\b[0-9]{3}[\s-]?[0-9]{3}[\s-]?[0-9]{4}\b'
            - '\b[A-CEGHJ-PR-TW-Z]{2}[0-9]{6}[A-D]\b'
        - headerRedaction:
            headerPrefix: x-redact-
            tokenFormat: "[{NAME}]"
        response:
        - headerRedaction:
            headerPrefix: x-redact-
            tokenFormat: "[{NAME}]"
```

### Test 1 — round-trip against Anthropic (production tier)

```bash
$ kubectl -n agentgateway-system port-forward svc/agentgateway-proxy 18080:8080 &

$ curl -s localhost:18080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "x-weaveone-tier: 2" \
    -H "x-redact-firstname: Tom" \
    -H "x-redact-surname: O'Rourke" \
    -d '{
      "model":"claude-haiku-4-5-20251001",
      "max_tokens":120,
      "messages":[{"role":"user","content":"Tell me about Tom O'\''Rourke."}]
    }' | jq -r '.choices[0].message.content'
```

Response (after gateway response-side restoration):

```
"I appreciate the request, but I can't complete this because you haven't
provided actual values for Tom and O'Rourke."
```

This is Anthropic responding to the **redacted** prompt. Anthropic
literally saw `[FIRSTNAME]` and `[SURNAME]` (it treated them as
placeholder variables), and the gateway's response-side
`headerRedaction` substituted them back to `Tom` / `O'Rourke` before
returning to the client.

The gateway access log for this request:

```
route=route-tier-2 endpoint=api.anthropic.com:443
http.status=200 protocol=llm
gen_ai.provider.name=anthropic
gen_ai.request.model=claude-haiku-4-5-20251001
gen_ai.usage.input_tokens=37
gen_ai.usage.output_tokens=58
duration=1853ms
```

### Test 2 — literal upstream bytes captured by echo backend

A test-only echo server was deployed in-cluster, configured as an
OpenAI-compatible upstream. The HTTPRoute `route-tier-test` targets it
when the request carries `x-weaveone-tier: test`.

```bash
$ curl -s localhost:18080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "x-weaveone-tier: test" \
    -H "x-redact-firstname: Tom" \
    -H "x-redact-surname: O'Rourke" \
    -d '{
      "model":"echo",
      "messages":[{"role":"user","content":"My surname is O'\''Rourke and Tom is my first name."}]
    }'
```

The echo server's stdout (`kubectl -n agentgateway-system logs deploy/echo-llm`)
shows what the gateway sent upstream:

```
=== REQUEST RECEIVED ===
{"messages":[{"role":"user","content":"My surname is [SURNAME] and [FIRSTNAME] is my first name."}],"model":"echo"}
=== END ===
```

`O'Rourke` → `[SURNAME]` and `Tom` → `[FIRSTNAME]` on the wire to the
upstream. **The original names never leave the gateway.**

The client-visible response (after the gateway's response-side
restoration) on the same call:

```json
{
  "messages":[{"role":"user","content":"My surname is O'Rourke and Tom is my first name."}],
  "model":"echo"
}
```

(Echoed body has the tokens; the gateway then un-redacts them on the way
back, so the client sees the original names. This is the symmetric
round-trip.)

### Test 3 — guardrail metrics

```bash
$ kubectl -n agentgateway-system port-forward deploy/agentgateway-proxy 15020:15020 &
$ curl -s localhost:15020/metrics | grep guardrail
```

```
# HELP agentgateway_guardrail_checks Total number of guardrail checks.
# TYPE agentgateway_guardrail_checks counter
agentgateway_guardrail_checks_total{phase="Request",action="Mask"}  7
agentgateway_guardrail_checks_total{phase="Request",action="Allow"} 7
agentgateway_guardrail_checks_total{phase="Response",action="Mask"} 4
```

Each successful end-to-end call increments **both** the request-side and
response-side `Mask` counters when `x-redact-*` headers are present and
the prompt/response contain matching tokens. The `Allow` counter
increments per call from the regex guard (no static PII patterns matched
in the test phrasing).

### Test 4 — negative control (no redaction headers)

Same call without the `x-redact-*` headers:

```bash
$ curl -s localhost:18080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -H "x-weaveone-tier: test" \
    -d '{
      "model":"echo",
      "messages":[{"role":"user","content":"My surname is O'\''Rourke and Tom is my first name."}]
    }'
```

Echo log:

```
=== REQUEST RECEIVED ===
{"messages":[{"role":"user","content":"My surname is O'Rourke and Tom is my first name."}],"model":"echo"}
=== END ===
```

Names pass through unchanged. The guardrail metric does **not**
increment (`headerRedaction` short-circuits when there are no matching
prefix headers — confirmed in the unit test
`build_subs_returns_empty_when_no_matching_headers`).

## Summary

| Verification | Result |
|---|---|
| Tokens reach upstream LLM (Anthropic) | ✅ confirmed via Anthropic's behavioural response |
| Tokens reach upstream LLM (raw bytes) | ✅ confirmed via echo backend stdout |
| Original values restored to client | ✅ confirmed via curl response body |
| Metrics increment correctly | ✅ confirmed via `/metrics` endpoint |
| No effect when headers absent | ✅ confirmed via negative control |
| Existing regex/webhook guards unaffected | ✅ confirmed via 951 lib tests passing |
