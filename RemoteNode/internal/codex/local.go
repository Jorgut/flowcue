package codex

import (
	"context"
	"errors"
	"sort"
	"sync"
	"time"
)

// Local wires the Codex pieces into one Backend. When RPC is present, sends
// start a turn owned by this node so approvals are visible here; otherwise it
// falls back to `codex queue`.
type Local struct {
	App      *AppServer
	Rollouts *RolloutStore
	Sender   *QueueRunner
	RPC      *RPCClient

	once      sync.Once
	mu        sync.Mutex
	approvals map[string]Approval
}

func NewLocal(app *AppServer, rollouts *RolloutStore, sender *QueueRunner, rpc *RPCClient) *Local {
	return &Local{
		App:       app,
		Rollouts:  rollouts,
		Sender:    sender,
		RPC:       rpc,
		approvals: make(map[string]Approval),
	}
}

func (l *Local) start() {
	l.once.Do(func() {
		if l.RPC != nil {
			go l.consumeApprovals()
		}
	})
}

func (l *Local) consumeApprovals() {
	for approval := range l.RPC.Approvals() {
		l.mu.Lock()
		if l.approvals == nil {
			l.approvals = make(map[string]Approval)
		}
		l.approvals[approval.Key] = approval
		l.mu.Unlock()
	}
}

func (l *Local) ListThreads(ctx context.Context, limit int) ([]Thread, error) {
	return l.App.ListThreads(ctx, limit)
}

func (l *Local) Messages(ctx context.Context, threadID string, limit int) ([]Message, error) {
	return l.Rollouts.Messages(threadID, limit)
}

func (l *Local) LatestReply(ctx context.Context, threadID string, after time.Time) (string, error) {
	return l.Rollouts.LatestReply(threadID, after)
}

func (l *Local) Queue(ctx context.Context, threadID, text string) error {
	if l.RPC == nil {
		return l.Sender.Queue(ctx, threadID, text)
	}
	l.start()
	return l.RPC.StartTurn(ctx, threadID, text)
}

// PendingApprovals returns the requests waiting for a decision.
func (l *Local) PendingApprovals() []Approval {
	l.start()
	l.mu.Lock()
	defer l.mu.Unlock()
	items := make([]Approval, 0, len(l.approvals))
	for _, approval := range l.approvals {
		items = append(items, approval)
	}
	sort.Slice(items, func(i, j int) bool { return items[i].CreatedAt.Before(items[j].CreatedAt) })
	return items
}

// Decide answers one approval and removes it from the pending set.
func (l *Local) Decide(id, decision string) error {
	l.mu.Lock()
	approval, ok := l.approvals[id]
	l.mu.Unlock()
	if !ok {
		return errors.New("approval not found")
	}
	if l.RPC == nil {
		return errors.New("approvals are not available")
	}
	switch decision {
	case "accept", "decline":
		if err := l.RPC.Respond(approval.RawID, decision); err != nil {
			return err
		}
	default:
		return errors.New("decision must be accept or decline")
	}
	l.mu.Lock()
	delete(l.approvals, id)
	l.mu.Unlock()
	return nil
}
