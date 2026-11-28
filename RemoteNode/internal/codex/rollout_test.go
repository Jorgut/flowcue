package codex

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const testThreadID = "11111111-2222-4333-8444-555555555555"

func writeRollout(t *testing.T, home string, lines []string) string {
	t.Helper()
	dir := filepath.Join(home, "sessions", "2026", "01", "01")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, "rollout-2026-01-01T00-00-00-"+testThreadID+".jsonl")
	if err := os.WriteFile(path, []byte(strings.Join(lines, "\n")+"\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	return path
}

func fixtureLines() []string {
	return []string{
		`{"timestamp":"2026-01-01T00:00:01Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Hello"}]}}`,
		`{"timestamp":"2026-01-01T00:00:02Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"World"}]}}`,
		`{"timestamp":"2026-01-01T00:00:03Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"<environment_context>noise</environment_context>"}]}}`,
		`{"timestamp":"2026-01-01T00:00:03Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"text","text":"# AGENTS.md instructions\n\n<INSTRUCTIONS>noise</INSTRUCTIONS>"}]}}`,
		`{"timestamp":"2026-01-01T00:00:04Z","type":"event_msg","payload":{"type":"agent_message","message":"ignored"}}`,
	}
}

func TestMessagesReadsUserAndAssistantOnly(t *testing.T) {
	home := t.TempDir()
	writeRollout(t, home, fixtureLines())

	store := NewRolloutStore(home)
	messages, err := store.Messages(testThreadID, 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) != 2 {
		t.Fatalf("got %d messages, want 2: %#v", len(messages), messages)
	}
	if messages[0].Role != "user" || messages[0].Text != "Hello" {
		t.Fatalf("first = %#v", messages[0])
	}
	if messages[1].Role != "assistant" || messages[1].Text != "World" {
		t.Fatalf("second = %#v", messages[1])
	}
	if messages[1].Timestamp == nil {
		t.Fatal("assistant timestamp is nil")
	}
}

func TestMessagesRespectsLimit(t *testing.T) {
	home := t.TempDir()
	writeRollout(t, home, fixtureLines())

	store := NewRolloutStore(home)
	messages, err := store.Messages(testThreadID, 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(messages) != 1 || messages[0].Role != "assistant" {
		t.Fatalf("got %#v, want the last assistant message", messages)
	}
}

func TestLatestReply(t *testing.T) {
	home := t.TempDir()
	writeRollout(t, home, fixtureLines())

	store := NewRolloutStore(home)
	reply, err := store.LatestReply(testThreadID, time.Time{})
	if err != nil {
		t.Fatal(err)
	}
	if reply != "World" {
		t.Fatalf("reply = %q, want World", reply)
	}
}

func TestLatestReplyRespectsAfter(t *testing.T) {
	home := t.TempDir()
	writeRollout(t, home, fixtureLines())

	store := NewRolloutStore(home)
	after := time.Date(2026, 1, 1, 0, 0, 2, 500_000_000, time.UTC)
	reply, err := store.LatestReply(testThreadID, after)
	if err != nil {
		t.Fatal(err)
	}
	if reply != "" {
		t.Fatalf("reply = %q, want empty before the assistant turn", reply)
	}
}

func TestUnknownThreadIsNotFound(t *testing.T) {
	store := NewRolloutStore(t.TempDir())
	_, err := store.Messages(testThreadID, 10)
	if !errors.Is(err, ErrThreadNotFound) {
		t.Fatalf("err = %v, want ErrThreadNotFound", err)
	}
}

func TestSyntheticUserText(t *testing.T) {
	for _, text := range []string{
		"<environment_context>noise</environment_context>",
		"# AGENTS.md instructions\n\n<INSTRUCTIONS>noise</INSTRUCTIONS>",
		"<user_instructions>noise</user_instructions>",
	} {
		if !isSyntheticUserText(text) {
			t.Fatalf("expected synthetic: %q", text)
		}
	}
	if isSyntheticUserText("把登录接口的错误码统一一下") {
		t.Fatal("real user text was treated as synthetic")
	}
}

func TestPathTraversalRejected(t *testing.T) {
	store := NewRolloutStore(t.TempDir())
	for _, id := range []string{"../etc/passwd", `..\windows\system32`, "a/b", ""} {
		if _, err := store.Messages(id, 10); !errors.Is(err, ErrThreadNotFound) {
			t.Fatalf("id %q: err = %v, want ErrThreadNotFound", id, err)
		}
	}
}
