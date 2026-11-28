package codex

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"time"
)

// ErrRPCClosed means the app-server process is gone.
var ErrRPCClosed = errors.New("codex app-server is not running")

// Approval is one pending approval request from Codex.
type Approval struct {
	Key       string
	RawID     json.RawMessage
	Kind      string
	Title     string
	Detail    string
	ThreadID  string
	TurnID    string
	CreatedAt time.Time
}

// Approver is implemented by backends that can surface and answer approvals.
type Approver interface {
	PendingApprovals() []Approval
	Decide(id, decision string) error
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type rpcMessage struct {
	ID     json.RawMessage `json:"id"`
	Method string          `json:"method"`
	Params json.RawMessage `json:"params"`
	Result json.RawMessage `json:"result"`
	Error  *rpcError       `json:"error"`
}

// RPCClient keeps one `codex app-server` process alive. It owns turns started
// by the node, which is what makes approval requests visible here instead of
// in a separate Codex TUI.
type RPCClient struct {
	Executable string
	Timeout    time.Duration

	startMu sync.Mutex
	writeMu sync.Mutex
	mu      sync.Mutex
	cmd     *exec.Cmd
	stdin   io.WriteCloser
	pending map[string]chan rpcMessage
	nextID  int64
	done    chan struct{}
	closed  bool

	approvals chan Approval
	closeOnce sync.Once
}

func NewRPCClient(executable string) *RPCClient {
	return &RPCClient{
		Executable: executable,
		Timeout:    30 * time.Second,
		pending:    make(map[string]chan rpcMessage),
		done:       make(chan struct{}),
		approvals:  make(chan Approval, 32),
	}
}

// Approvals delivers requests that need a decision. The caller must consume
// this channel or the reader will block.
func (c *RPCClient) Approvals() <-chan Approval { return c.approvals }

func (c *RPCClient) ensure() error {
	c.startMu.Lock()
	defer c.startMu.Unlock()
	if c.cmd != nil && !c.closed {
		return nil
	}
	if c.cmd != nil {
		// The previous process exited; drop the stale handle and start over.
		if c.cmd.Process != nil {
			_ = c.cmd.Process.Kill()
			_ = c.cmd.Wait()
		}
		c.cmd = nil
		c.stdin = nil
	}
	if c.Executable == "" {
		return errors.New("codex executable is not configured")
	}

	cmd := buildCommand(context.Background(), c.Executable, "app-server")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("start codex app-server: %w", err)
	}

	c.mu.Lock()
	c.cmd = cmd
	c.stdin = stdin
	c.pending = make(map[string]chan rpcMessage)
	c.nextID = 0
	c.done = make(chan struct{})
	c.closed = false
	c.closeOnce = sync.Once{}
	done := c.done
	c.mu.Unlock()

	go c.readLoop(stdout, done)

	initCtx, cancel := context.WithTimeout(context.Background(), c.timeout())
	defer cancel()
	if _, err := c.Call(initCtx, "initialize", map[string]any{
		"clientInfo": map[string]string{
			"name":    "flowcue_remote_node",
			"title":   "FlowCue Node",
			"version": appServerClientVersion,
		},
	}); err != nil {
		c.Close()
		return fmt.Errorf("initialize codex app-server: %w (stderr: %s)", err, tailText(stderr.String()))
	}
	if err := c.write(map[string]any{"method": "initialized"}); err != nil {
		c.Close()
		return err
	}
	return nil
}

func (c *RPCClient) timeout() time.Duration {
	if c.Timeout > 0 {
		return c.Timeout
	}
	return 30 * time.Second
}

func (c *RPCClient) readLoop(stdout io.Reader, done chan struct{}) {
	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 64*1024), 16*1024*1024)
	for scanner.Scan() {
		line := scanner.Bytes()
		var message rpcMessage
		if err := json.Unmarshal(line, &message); err != nil {
			continue
		}
		if message.Method != "" && len(message.ID) > 0 {
			c.handleServerRequest(message)
			continue
		}
		if len(message.ID) == 0 {
			continue // notification
		}
		key := idKey(message.ID)
		c.mu.Lock()
		channel := c.pending[key]
		delete(c.pending, key)
		c.mu.Unlock()
		if channel != nil {
			channel <- message
		}
	}
	c.closeOnce.Do(func() {
		c.mu.Lock()
		c.closed = true
		for key, channel := range c.pending {
			delete(c.pending, key)
			close(channel)
		}
		c.mu.Unlock()
		close(done)
	})
}

func (c *RPCClient) handleServerRequest(message rpcMessage) {
	if approval, ok := parseApproval(message); ok {
		select {
		case c.approvals <- approval:
		case <-c.done:
		}
		return
	}
	// Unknown server request: answer with an error so the turn is not stuck.
	_ = c.write(map[string]any{
		"id": message.ID,
		"error": map[string]any{
			"code":    -32601,
			"message": "unsupported by FlowCue Node: " + message.Method,
		},
	})
}

// Call sends one client request and waits for its response.
func (c *RPCClient) Call(ctx context.Context, method string, params any) (json.RawMessage, error) {
	c.mu.Lock()
	if c.cmd == nil || c.closed {
		c.mu.Unlock()
		return nil, ErrRPCClosed
	}
	c.nextID++
	id := c.nextID
	channel := make(chan rpcMessage, 1)
	c.pending[strconv.FormatInt(id, 10)] = channel
	c.mu.Unlock()

	if err := c.write(map[string]any{"method": method, "id": id, "params": params}); err != nil {
		c.mu.Lock()
		delete(c.pending, strconv.FormatInt(id, 10))
		c.mu.Unlock()
		return nil, err
	}

	select {
	case message, ok := <-channel:
		if !ok {
			return nil, ErrRPCClosed
		}
		if message.Error != nil {
			return nil, fmt.Errorf("%s: %s", method, message.Error.Message)
		}
		return message.Result, nil
	case <-ctx.Done():
		c.mu.Lock()
		delete(c.pending, strconv.FormatInt(id, 10))
		c.mu.Unlock()
		return nil, ctx.Err()
	case <-c.done:
		return nil, ErrRPCClosed
	}
}

func (c *RPCClient) write(value any) error {
	c.writeMu.Lock()
	defer c.writeMu.Unlock()
	if c.stdin == nil {
		return ErrRPCClosed
	}
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	data = append(data, '\n')
	_, err = c.stdin.Write(data)
	return err
}

// StartTurn starts a turn owned by this node. This is what makes approvals
// arrive here; `codex queue` hands the turn to another process instead.
func (c *RPCClient) StartTurn(ctx context.Context, threadID, text string) error {
	if err := c.ensure(); err != nil {
		return err
	}
	timeoutCtx, cancel := context.WithTimeout(context.Background(), c.timeout())
	defer cancel()
	_, err := c.Call(timeoutCtx, "turn/start", map[string]any{
		"threadId":       threadID,
		"input":          []map[string]string{{"type": "text", "text": text}},
		"approvalPolicy": "on-request",
	})
	return err
}

// Respond answers a pending approval.
func (c *RPCClient) Respond(id json.RawMessage, decision string) error {
	return c.write(map[string]any{
		"id":     id,
		"result": map[string]string{"decision": decision},
	})
}

// Close stops the app-server process.
func (c *RPCClient) Close() {
	c.closeOnce.Do(func() {
		c.mu.Lock()
		c.closed = true
		stdin := c.stdin
		cmd := c.cmd
		c.cmd = nil
		c.stdin = nil
		c.mu.Unlock()
		if stdin != nil {
			_ = stdin.Close()
		}
		if cmd != nil && cmd.Process != nil {
			_ = cmd.Process.Kill()
			_ = cmd.Wait()
		}
		close(c.done)
	})
}

func idKey(raw json.RawMessage) string {
	var text string
	if err := json.Unmarshal(raw, &text); err == nil {
		return text
	}
	return string(raw)
}

func parseApproval(message rpcMessage) (Approval, bool) {
	var params struct {
		Command   string  `json:"command"`
		Cwd       string  `json:"cwd"`
		Reason    *string `json:"reason"`
		ThreadID  string  `json:"threadId"`
		TurnID    string  `json:"turnId"`
		GrantRoot *string `json:"grantRoot"`
	}
	if err := json.Unmarshal(message.Params, &params); err != nil {
		return Approval{}, false
	}
	key := idKey(message.ID)
	base := Approval{
		Key:       key,
		RawID:     message.ID,
		ThreadID:  params.ThreadID,
		TurnID:    params.TurnID,
		CreatedAt: time.Now(),
	}
	switch message.Method {
	case "item/commandExecution/requestApproval":
		detail := strings.TrimSpace(params.Command)
		if detail == "" {
			detail = "A command needs your approval."
		}
		if params.Cwd != "" {
			detail += "\n" + params.Cwd
		}
		base.Kind = "command"
		base.Title = "Codex wants to run a command"
		base.Detail = detail
		return base, true
	case "item/fileChange/requestApproval":
		detail := "Codex wants to write files."
		if params.Reason != nil && strings.TrimSpace(*params.Reason) != "" {
			detail = *params.Reason
		}
		base.Kind = "fileChange"
		base.Title = "Codex wants to write files"
		base.Detail = detail
		return base, true
	}
	return Approval{}, false
}
