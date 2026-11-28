package codex

import (
	"bytes"
	"context"
	"fmt"
	"time"
)

// QueueRunner sends a message to an existing Codex session with
// `codex queue --thread <id> --message <text>`, the same path the Mac app uses.
type QueueRunner struct {
	Executable string
	Timeout    time.Duration
}

// Queue returns nil only when the CLI reported success.
func (q *QueueRunner) Queue(ctx context.Context, threadID, text string) error {
	if q.Executable == "" {
		return fmt.Errorf("codex executable is not configured")
	}
	timeout := q.Timeout
	if timeout <= 0 {
		timeout = 45 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	cmd := buildCommand(ctx, q.Executable, "queue", "--thread", threadID, "--message", text)
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	cmd.Stdout = &stderr
	if err := cmd.Run(); err != nil {
		return fmt.Errorf("codex queue: %w: %s", err, tailText(stderr.String()))
	}
	return nil
}
