package codex

import (
	"context"
	"time"
)

// Thread is the normalized session shape the node exposes.
type Thread struct {
	ID        string
	Title     string
	Cwd       string
	UpdatedAt time.Time
}

// Message is one user/assistant turn message.
type Message struct {
	ID        string
	Role      string
	Text      string
	Timestamp *time.Time
}

// Backend is the read/send surface the HTTP server depends on. Keeping it an
// interface lets tests run without a real Codex install.
type Backend interface {
	ListThreads(ctx context.Context, limit int) ([]Thread, error)
	Messages(ctx context.Context, threadID string, limit int) ([]Message, error)
	LatestReply(ctx context.Context, threadID string, after time.Time) (string, error)
	Queue(ctx context.Context, threadID, text string) error
}
