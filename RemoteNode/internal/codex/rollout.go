package codex

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"time"
)

var (
	htmlTagPattern = regexp.MustCompile(`<[^>]+>`)
	uuidPattern    = regexp.MustCompile(`[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}`)
)

// ErrThreadNotFound means no rollout file matched the requested thread.
var ErrThreadNotFound = errors.New("thread not found")

// RolloutStore reads Codex's local session rollout files. It never writes to
// them. The layout is ~/.codex/sessions/YYYY/MM/DD/rollout-...-<thread>.jsonl.
type RolloutStore struct {
	Home string

	mu       sync.Mutex
	index    map[string]string
	indexAt  time.Time
	replies  map[string]cachedReply
	indexTTL time.Duration
}

type cachedReply struct {
	mtime time.Time
	text  string
}

// NewRolloutStore creates a store rooted at the Codex home directory
// (normally ~/.codex or %USERPROFILE%\.codex).
func NewRolloutStore(home string) *RolloutStore {
	return &RolloutStore{
		Home:     home,
		replies:  make(map[string]cachedReply),
		indexTTL: 3 * time.Second,
	}
}

func (s *RolloutStore) sessionsDir() string {
	return filepath.Join(s.Home, "sessions")
}

// Find returns the newest rollout file for a thread id.
func (s *RolloutStore) Find(threadID string) (string, error) {
	if !validThreadID(threadID) {
		return "", ErrThreadNotFound
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.index == nil || time.Since(s.indexAt) > s.indexTTL {
		s.rebuildIndexLocked()
	}
	if path, ok := s.index[strings.ToLower(threadID)]; ok {
		return path, nil
	}
	return "", ErrThreadNotFound
}

func validThreadID(id string) bool {
	if id == "" || len(id) > 128 || strings.Contains(id, "..") {
		return false
	}
	for _, r := range id {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_':
		default:
			return false
		}
	}
	return true
}

func (s *RolloutStore) rebuildIndexLocked() {
	index := make(map[string]string)
	mtimes := make(map[string]time.Time)
	_ = filepath.WalkDir(s.sessionsDir(), func(path string, entry fs.DirEntry, err error) error {
		if err != nil || entry.IsDir() {
			return nil
		}
		if !strings.HasSuffix(strings.ToLower(entry.Name()), ".jsonl") {
			return nil
		}
		matches := uuidPattern.FindAllString(entry.Name(), -1)
		if len(matches) == 0 {
			return nil
		}
		id := strings.ToLower(matches[len(matches)-1])
		info, statErr := entry.Info()
		if statErr != nil {
			return nil
		}
		if _, ok := index[id]; ok {
			// Keep the newest file if the same thread has multiple rollouts.
			if !info.ModTime().After(mtimes[id]) {
				return nil
			}
		}
		index[id] = path
		mtimes[id] = info.ModTime()
		return nil
	})
	s.index = index
	s.indexAt = time.Now()
}

// Messages returns the last `limit` user/assistant text messages of a thread.
func (s *RolloutStore) Messages(threadID string, limit int) ([]Message, error) {
	path, err := s.Find(threadID)
	if err != nil {
		return nil, err
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	reader := bufio.NewReaderSize(file, 256*1024)
	var messages []Message
	index := 0
	for {
		line, readErr := reader.ReadBytes('\n')
		if len(line) > 0 {
			if message, ok := parseMessageLine(line, index); ok {
				messages = append(messages, message)
				index++
			}
		}
		if readErr == io.EOF {
			break
		}
		if readErr != nil {
			return nil, readErr
		}
	}
	if limit > 0 && len(messages) > limit {
		messages = messages[len(messages)-limit:]
	}
	return messages, nil
}

// LatestReply returns the last assistant text, optionally only messages newer
// than `after`.
func (s *RolloutStore) LatestReply(threadID string, after time.Time) (string, error) {
	path, err := s.Find(threadID)
	if err != nil {
		return "", err
	}
	info, err := os.Stat(path)
	if err != nil {
		return "", err
	}
	if after.IsZero() {
		s.mu.Lock()
		cached, ok := s.replies[path]
		s.mu.Unlock()
		if ok && cached.mtime.Equal(info.ModTime()) {
			return cached.text, nil
		}
	}

	text, err := latestAssistantInTail(path, after)
	if err != nil {
		return "", err
	}
	if after.IsZero() {
		s.mu.Lock()
		if s.replies == nil {
			s.replies = make(map[string]cachedReply)
		}
		s.replies[path] = cachedReply{mtime: info.ModTime(), text: text}
		s.mu.Unlock()
	}
	return text, nil
}

type wireLine struct {
	Timestamp string `json:"timestamp"`
	Type      string `json:"type"`
	Payload   struct {
		Type    string `json:"type"`
		Role    string `json:"role"`
		Content []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
	} `json:"payload"`
}

func parseMessageLine(line []byte, index int) (Message, bool) {
	var wire wireLine
	if err := json.Unmarshal(line, &wire); err != nil {
		return Message{}, false
	}
	if wire.Type != "response_item" || wire.Payload.Type != "message" {
		return Message{}, false
	}
	role := wire.Payload.Role
	if role != "user" && role != "assistant" {
		return Message{}, false
	}

	var parts []string
	for _, item := range wire.Payload.Content {
		text := strings.TrimSpace(item.Text)
		if text != "" {
			parts = append(parts, text)
		}
	}
	text := strings.Join(parts, "\n")
	if text == "" {
		return Message{}, false
	}
	// Codex injects synthetic context/page markers as user messages.
	if role == "user" && isSyntheticUserText(text) {
		return Message{}, false
	}

	message := Message{
		ID:   fmt.Sprintf("%d-%s", index, role),
		Role: role,
		Text: truncateRunes(text, 20_000),
	}
	if parsed, err := time.Parse(time.RFC3339Nano, wire.Timestamp); err == nil {
		message.Timestamp = &parsed
	}
	return message, true
}

func latestAssistantInTail(path string, after time.Time) (string, error) {
	file, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer file.Close()

	info, err := file.Stat()
	if err != nil {
		return "", err
	}
	const tailBytes int64 = 256 * 1024
	offset := info.Size() - tailBytes
	if offset < 0 {
		offset = 0
	}
	if _, err := file.Seek(offset, io.SeekStart); err != nil {
		return "", err
	}
	data, err := io.ReadAll(file)
	if err != nil {
		return "", err
	}

	var result string
	for _, line := range splitLines(data) {
		var wire wireLine
		if err := json.Unmarshal(line, &wire); err != nil {
			continue
		}
		if wire.Type != "response_item" || wire.Payload.Type != "message" || wire.Payload.Role != "assistant" {
			continue
		}
		if !after.IsZero() && wire.Timestamp != "" {
			if parsed, err := time.Parse(time.RFC3339Nano, wire.Timestamp); err == nil && parsed.Before(after) {
				continue
			}
		}
		var parts []string
		for _, item := range wire.Payload.Content {
			text := strings.TrimSpace(item.Text)
			if text != "" {
				parts = append(parts, text)
			}
		}
		text := strings.Join(parts, "\n")
		if text != "" {
			result = truncateRunes(text, 20_000)
		}
	}
	return result, nil
}

func splitLines(data []byte) [][]byte {
	var lines [][]byte
	start := 0
	for index, b := range data {
		if b == '\n' {
			if index > start {
				lines = append(lines, data[start:index])
			}
			start = index + 1
		}
	}
	if start < len(data) {
		lines = append(lines, data[start:])
	}
	return lines
}

func isSyntheticUserText(text string) bool {
	trimmed := strings.TrimSpace(text)
	if strings.HasPrefix(trimmed, "<") && strings.HasSuffix(trimmed, ">") {
		return true
	}
	lower := strings.ToLower(trimmed)
	for _, prefix := range []string{
		"# agents.md instructions",
		"# global agents.md",
		"<instructions>",
		"<environment_context",
		"<user_instructions",
		"<turn_aborted",
	} {
		if strings.HasPrefix(lower, prefix) {
			return true
		}
	}
	return false
}

func truncateRunes(value string, limit int) string {
	runes := []rune(value)
	if len(runes) <= limit {
		return value
	}
	return string(runes[:limit])
}
