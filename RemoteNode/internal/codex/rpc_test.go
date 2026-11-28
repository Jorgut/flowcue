package codex

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestParseApprovalCommand(t *testing.T) {
	message := rpcMessage{
		ID:     json.RawMessage(`7`),
		Method: "item/commandExecution/requestApproval",
		Params: json.RawMessage(`{"command":"npm test","cwd":"/tmp/app","threadId":"thread-1","turnId":"turn-1"}`),
	}
	approval, ok := parseApproval(message)
	if !ok {
		t.Fatal("command approval was not parsed")
	}
	if approval.Key != "7" || approval.Kind != "command" {
		t.Fatalf("approval = %#v", approval)
	}
	if approval.ThreadID != "thread-1" || approval.TurnID != "turn-1" {
		t.Fatalf("ids = %#v", approval)
	}
	if approval.Detail != "npm test\n/tmp/app" {
		t.Fatalf("detail = %q", approval.Detail)
	}
}

func TestParseApprovalFileChange(t *testing.T) {
	message := rpcMessage{
		ID:     json.RawMessage(`"abc"`),
		Method: "item/fileChange/requestApproval",
		Params: json.RawMessage(`{"reason":"Extra write access","threadId":"thread-2","itemId":"item-1","startedAtMs":1}`),
	}
	approval, ok := parseApproval(message)
	if !ok {
		t.Fatal("file change approval was not parsed")
	}
	if approval.Key != "abc" || approval.Kind != "fileChange" {
		t.Fatalf("approval = %#v", approval)
	}
	if approval.Detail != "Extra write access" {
		t.Fatalf("detail = %q", approval.Detail)
	}
}

func TestParseApprovalIgnoresOtherMethods(t *testing.T) {
	message := rpcMessage{
		ID:     json.RawMessage(`1`),
		Method: "item/tool/requestUserInput",
		Params: json.RawMessage(`{}`),
	}
	if _, ok := parseApproval(message); ok {
		t.Fatal("unrelated request was parsed as an approval")
	}
}

func TestIDKeyHandlesStringAndNumber(t *testing.T) {
	if got := idKey(json.RawMessage(`12`)); got != "12" {
		t.Fatalf("number key = %q", got)
	}
	if got := idKey(json.RawMessage(`"abc"`)); got != "abc" {
		t.Fatalf("string key = %q", got)
	}
}

func TestMain(m *testing.M) {
	if os.Getenv("FLOWCUE_RPC_HELPER") == "1" {
		runRPCHelper()
		return
	}
	os.Exit(m.Run())
}

// runRPCHelper emulates codex app-server for the approval round-trip test.
func runRPCHelper() {
	output := os.Getenv("FLOWCUE_RPC_HELPER_OUT")
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Buffer(make([]byte, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		var message struct {
			ID     json.RawMessage `json:"id"`
			Method string          `json:"method"`
			Result json.RawMessage `json:"result"`
		}
		if err := json.Unmarshal(scanner.Bytes(), &message); err != nil {
			continue
		}
		if message.Method == "" && len(message.ID) > 0 {
			if output != "" {
				_ = os.WriteFile(output, message.Result, 0o600)
			}
			return
		}
		switch message.Method {
		case "initialize":
			respondHelper(message.ID, map[string]any{"userAgent": "helper"})
		case "turn/start":
			respondHelper(message.ID, map[string]any{"turn": map[string]string{"id": "turn-1"}})
			fmt.Println(`{"id":99,"method":"item/commandExecution/requestApproval","params":{"command":"echo hi","cwd":"/tmp","threadId":"thread-1","turnId":"turn-1"}}`)
		}
	}
}

func respondHelper(id json.RawMessage, result any) {
	payload, _ := json.Marshal(map[string]any{"id": id, "result": result})
	fmt.Println(string(payload))
}

func TestRPCApprovalRoundTrip(t *testing.T) {
	output := filepath.Join(t.TempDir(), "decision.json")
	t.Setenv("FLOWCUE_RPC_HELPER", "1")
	t.Setenv("FLOWCUE_RPC_HELPER_OUT", output)
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}

	client := NewRPCClient(executable)
	defer client.Close()

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if err := client.StartTurn(ctx, "thread-1", "hello"); err != nil {
		t.Fatal(err)
	}

	select {
	case approval := <-client.Approvals():
		if approval.Kind != "command" || approval.ThreadID != "thread-1" {
			t.Fatalf("approval = %#v", approval)
		}
		if err := client.Respond(approval.RawID, "accept"); err != nil {
			t.Fatal(err)
		}
	case <-ctx.Done():
		t.Fatal("timed out waiting for approval")
	}

	deadline := time.Now().Add(2 * time.Second)
	for time.Now().Before(deadline) {
		data, err := os.ReadFile(output)
		if err == nil {
			if string(data) != `{"decision":"accept"}` {
				t.Fatalf("decision = %s", data)
			}
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("helper did not record the decision")
}
