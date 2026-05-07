package plugins

import (
	"testing"

	"github.com/agentgateway/agentgateway/api"
	"github.com/agentgateway/agentgateway/controller/api/v1alpha1/agentgateway"
)

// processHeaderRedaction must apply defaults when fields are empty so the
// Rust gateway sees a fully-populated configuration. This is the only field
// that has client-visible defaults set at the controller layer (rather than
// at runtime), so the behaviour matters for backwards-compat.
func TestProcessHeaderRedactionAppliesDefaults(t *testing.T) {
	tests := []struct {
		name        string
		input       *agentgateway.HeaderRedaction
		wantPrefix  string
		wantFormat  string
	}{
		{
			name:       "nil input returns nil",
			input:      nil,
			wantPrefix: "",
			wantFormat: "",
		},
		{
			name:       "empty struct uses defaults",
			input:      &agentgateway.HeaderRedaction{},
			wantPrefix: "x-redact-",
			wantFormat: "[{NAME}]",
		},
		{
			name: "explicit values pass through",
			input: &agentgateway.HeaderRedaction{
				HeaderPrefix: "x-pii-",
				TokenFormat:  "<<{NAME}>>",
			},
			wantPrefix: "x-pii-",
			wantFormat: "<<{NAME}>>",
		},
		{
			name: "only prefix overridden",
			input: &agentgateway.HeaderRedaction{
				HeaderPrefix: "x-pii-",
			},
			wantPrefix: "x-pii-",
			wantFormat: "[{NAME}]",
		},
		{
			name: "only format overridden",
			input: &agentgateway.HeaderRedaction{
				TokenFormat: "<{NAME}>",
			},
			wantPrefix: "x-redact-",
			wantFormat: "<{NAME}>",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := processHeaderRedaction(tt.input)
			if tt.input == nil {
				if got != nil {
					t.Fatalf("expected nil for nil input, got %+v", got)
				}
				return
			}
			if got == nil {
				t.Fatalf("expected non-nil output for non-nil input")
			}
			if got.HeaderPrefix != tt.wantPrefix {
				t.Errorf("HeaderPrefix = %q, want %q", got.HeaderPrefix, tt.wantPrefix)
			}
			if got.TokenFormat != tt.wantFormat {
				t.Errorf("TokenFormat = %q, want %q", got.TokenFormat, tt.wantFormat)
			}
		})
	}
}

// processRequestGuard must wire HeaderRedaction into the proto oneof. Without
// this dispatch path the gateway would never see the redaction config even if
// the user authored it correctly in their AgentgatewayPolicy.
func TestProcessRequestGuardDispatchesHeaderRedaction(t *testing.T) {
	reqs := []agentgateway.PromptguardRequest{{
		HeaderRedaction: &agentgateway.HeaderRedaction{
			HeaderPrefix: "x-redact-",
			TokenFormat:  "[{NAME}]",
		},
	}}
	got, err := processRequestGuard(PolicyCtx{}, "default", reqs)
	if err != nil {
		t.Fatalf("processRequestGuard error: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("expected 1 guard, got %d", len(got))
	}
	hr, ok := got[0].Kind.(*api.BackendPolicySpec_Ai_RequestGuard_HeaderRedaction)
	if !ok {
		t.Fatalf("expected HeaderRedaction kind, got %T", got[0].Kind)
	}
	if hr.HeaderRedaction.HeaderPrefix != "x-redact-" {
		t.Errorf("HeaderPrefix = %q", hr.HeaderRedaction.HeaderPrefix)
	}
}

func TestProcessResponseGuardDispatchesHeaderRedaction(t *testing.T) {
	resps := []agentgateway.PromptguardResponse{{
		HeaderRedaction: &agentgateway.HeaderRedaction{
			HeaderPrefix: "x-pii-",
			TokenFormat:  "<{NAME}>",
		},
	}}
	got, err := processResponseGuard(PolicyCtx{}, "default", resps)
	if err != nil {
		t.Fatalf("processResponseGuard error: %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("expected 1 guard, got %d", len(got))
	}
	hr, ok := got[0].Kind.(*api.BackendPolicySpec_Ai_ResponseGuard_HeaderRedaction)
	if !ok {
		t.Fatalf("expected HeaderRedaction kind, got %T", got[0].Kind)
	}
	if hr.HeaderRedaction.HeaderPrefix != "x-pii-" {
		t.Errorf("HeaderPrefix = %q", hr.HeaderRedaction.HeaderPrefix)
	}
	if hr.HeaderRedaction.TokenFormat != "<{NAME}>" {
		t.Errorf("TokenFormat = %q", hr.HeaderRedaction.TokenFormat)
	}
}
