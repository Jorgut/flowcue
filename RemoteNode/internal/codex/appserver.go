package codex

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"
	"time"
)

// AppServer talks to `codex app-server` over stdio JSON-RPC. It is the same
// protocol the Mac app uses for thread/list, so both ends see identical data.
type AppServer struct {
	Executable string
	Timeout    time.Duration
}

const appServerClientVersion = "0.1.0"

type appServerResponse struct {
	ID     int             `json:"id"`
	Result json.RawMessage `json:"result"`
	Error  *struct {
		Message string `json:"message"`
	} `json:"error"`
}

// ListThreads returns recent, non-archived threads, newest first.
func (a *AppServer) ListThreads(ctx context.Context, limit int) ([]Thread, error) {
	if a.Executable == "" {
		return nil, errors.New("codex executable is not configured")
	}
	if limit <= 0 {
		limit = 50
	}
	timeout := a.Timeout
	if timeout <= 0 {
		timeout = 25 * time.Second
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	cmd := buildCommand(ctx, a.Executable, "app-server")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr

	if err := cmd.Start(); err != nil {
		return nil, fmt.Errorf("start codex app-server: %w", err)
	}
	defer func() {
		_ = stdin.Close()
		if cmd.Process != nil {
			_ = cmd.Process.Kill()
		}
		_ = cmd.Wait()
	}()

	requests := []string{
		`{"method":"initialize","id":1,"params":{"clientInfo":{"name":"flowcue_remote_node","title":"FlowCue Node","version":"` + appServerClientVersion + `"}}}`,
		`{"method":"initialized"}`,
		fmt.Sprintf(`{"method":"thread/list","id":2,"params":{"cursor":null,"limit":%d,"sortKey":"recency_at","sortDirection":"desc","archived":false,"useStateDbOnly":true,"sourceKinds":[]}}`, limit),
	}
	for _, request := range requests {
		if _, err := io.WriteString(stdin, request+"\n"); err != nil {
			return nil, fmt.Errorf("write to codex app-server: %w", err)
		}
	}

	scanner := bufio.NewScanner(stdout)
	scanner.Buffer(make([]byte, 64*1024), 16*1024*1024)
	for scanner.Scan() {
		line := scanner.Bytes()
		// Cheap filter before paying for JSON decoding on notifications.
		if !bytes.Contains(line, []byte(`"id":2`)) {
			continue
		}
		var response appServerResponse
		if err := json.Unmarshal(line, &response); err != nil {
			continue
		}
		if response.ID != 2 {
			continue
		}
		if response.Error != nil {
			return nil, fmt.Errorf("thread/list failed: %s", response.Error.Message)
		}
		return parseThreadList(response.Result)
	}
	if err := scanner.Err(); err != nil {
		return nil, fmt.Errorf("read codex app-server: %w", err)
	}
	return nil, fmt.Errorf("codex app-server closed before replying: %s", tailText(stderr.String()))
}

func parseThreadList(raw json.RawMessage) ([]Thread, error) {
	var result struct {
		Data []struct {
			ID        string      `json:"id"`
			Name      string      `json:"name"`
			Preview   string      `json:"preview"`
			Cwd       string      `json:"cwd"`
			UpdatedAt json.Number `json:"updatedAt"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &result); err != nil {
		return nil, fmt.Errorf("decode thread/list: %w", err)
	}

	threads := make([]Thread, 0, len(result.Data))
	for _, item := range result.Data {
		if item.ID == "" {
			continue
		}
		title := strings.TrimSpace(item.Name)
		if title == "" {
			title = cleanPreview(item.Preview)
		}
		var updated time.Time
		if seconds, err := item.UpdatedAt.Float64(); err == nil && seconds > 0 {
			updated = time.Unix(int64(seconds), 0).UTC()
		}
		threads = append(threads, Thread{
			ID:        item.ID,
			Title:     title,
			Cwd:       item.Cwd,
			UpdatedAt: updated,
		})
	}
	return threads, nil
}

// cleanPreview mirrors the Mac's display cleanup: drop markup, collapse
// whitespace, cap the title length.
func cleanPreview(preview string) string {
	cleaned := htmlTagPattern.ReplaceAllString(preview, " ")
	cleaned = strings.Join(strings.Fields(cleaned), " ")
	if cleaned == "" {
		return "Untitled"
	}
	runes := []rune(cleaned)
	if len(runes) > 60 {
		runes = runes[:60]
	}
	return string(runes)
}

func tailText(value string) string {
	value = strings.TrimSpace(value)
	if len(value) > 400 {
		return value[len(value)-400:]
	}
	return value
}
