// Package server exposes the subset of the FlowCue LAN protocol that the
// existing iPhone app already speaks: ping, threads, thread messages, send.
package server

import (
	"context"
	"crypto/rand"
	"crypto/subtle"
	"embed"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"net/url"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"flowcue.local/remotenode/internal/codex"
	"flowcue.local/remotenode/internal/timeutil"
)

//go:embed web/index.html web/app.css web/app.js
var webAssets embed.FS

const sessionCookie = "flowcue_session"

const (
	ProtocolVersion = 1
	AppVersion      = "0.1.0"
	cacheTTL        = 10 * time.Second
	messageLimit    = 80
	threadLimit     = 50
)

// Server serves the FlowCue remote-node API.
type Server struct {
	Backend    codex.Backend
	Token      string
	ExecutorID string
	Workspace  string
	Name       string
	Host       string

	authMu   sync.Mutex
	sessions map[string]time.Time

	buildMu sync.Mutex
	mu      sync.Mutex
	cached  []snapshotDTO
	cacheAt time.Time
}

func New(backend codex.Backend, token, executorID, workspace, host string) *Server {
	return &Server{
		Backend:    backend,
		Token:      token,
		ExecutorID: executorID,
		Workspace:  workspace,
		Name:       "FlowCue Node",
		Host:       host,
		sessions:   make(map[string]time.Time),
	}
}

func (s *Server) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodGet && r.URL.Path == "/v1/ping" {
		s.writeJSON(w, http.StatusOK, map[string]string{
			"name":       s.Name,
			"version":    strconv.Itoa(ProtocolVersion),
			"protocol":   strconv.Itoa(ProtocolVersion),
			"appVersion": AppVersion,
		})
		return
	}
	if r.Method == http.MethodPost && r.URL.Path == "/v1/session" {
		s.handleSession(w, r)
		return
	}
	if r.Method == http.MethodGet && isAssetPath(r.URL.Path) {
		s.serveAsset(w, r)
		return
	}
	if !s.authorized(r) {
		s.writeJSON(w, http.StatusUnauthorized, map[string]string{})
		return
	}

	switch {
	case r.Method == http.MethodPost && r.URL.Path == "/v1/session/logout":
		s.handleLogout(w, r)
	case r.Method == http.MethodGet && r.URL.Path == "/v1/node/info":
		s.handleNodeInfo(w)
	case r.Method == http.MethodGet && r.URL.Path == "/v1/approvals":
		s.handleApprovals(w)
	case r.Method == http.MethodPost && strings.HasPrefix(r.URL.Path, "/v1/approvals/"):
		s.handleApprovalDecision(w, r)
	case r.Method == http.MethodGet && r.URL.Path == "/v1/threads":
		s.handleThreads(w, r)
	case r.Method == http.MethodPost && r.URL.Path == "/v1/send":
		s.handleSend(w, r)
	case r.Method == http.MethodGet && strings.HasPrefix(r.URL.Path, "/v1/threads/") && strings.HasSuffix(r.URL.Path, "/messages"):
		s.handleMessages(w, r)
	default:
		s.writeJSON(w, http.StatusNotFound, map[string]string{})
	}
}

func (s *Server) authorized(r *http.Request) bool {
	if s.Token != "" {
		expected := "Bearer " + s.Token
		if subtle.ConstantTimeCompare([]byte(r.Header.Get("Authorization")), []byte(expected)) == 1 {
			return true
		}
	}
	cookie, err := r.Cookie(sessionCookie)
	if err != nil || cookie.Value == "" {
		return false
	}
	s.authMu.Lock()
	defer s.authMu.Unlock()
	expiry, ok := s.sessions[cookie.Value]
	if !ok {
		return false
	}
	if time.Now().After(expiry) {
		delete(s.sessions, cookie.Value)
		return false
	}
	return true
}

func (s *Server) handleSession(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Code string `json:"code"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil {
		s.writeJSON(w, http.StatusBadRequest, map[string]string{})
		return
	}
	if s.Token == "" || subtle.ConstantTimeCompare([]byte(body.Code), []byte(s.Token)) != 1 {
		s.writeJSON(w, http.StatusUnauthorized, map[string]string{})
		return
	}
	token, err := randomToken()
	if err != nil {
		s.writeJSON(w, http.StatusInternalServerError, map[string]string{})
		return
	}
	s.authMu.Lock()
	now := time.Now()
	for value, expiry := range s.sessions {
		if now.After(expiry) {
			delete(s.sessions, value)
		}
	}
	s.sessions[token] = now.Add(12 * time.Hour)
	s.authMu.Unlock()

	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookie,
		Value:    token,
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
		MaxAge:   12 * 60 * 60,
	})
	s.writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) handleLogout(w http.ResponseWriter, r *http.Request) {
	if cookie, err := r.Cookie(sessionCookie); err == nil {
		s.authMu.Lock()
		delete(s.sessions, cookie.Value)
		s.authMu.Unlock()
	}
	http.SetCookie(w, &http.Cookie{
		Name:     sessionCookie,
		Value:    "",
		Path:     "/",
		HttpOnly: true,
		SameSite: http.SameSiteStrictMode,
		MaxAge:   -1,
	})
	s.writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func randomToken() (string, error) {
	buffer := make([]byte, 32)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	return hex.EncodeToString(buffer), nil
}

func isAssetPath(path string) bool {
	switch path {
	case "/", "/app.css", "/app.js":
		return true
	default:
		return false
	}
}

func (s *Server) serveAsset(w http.ResponseWriter, r *http.Request) {
	name := "index.html"
	contentType := "text/html; charset=utf-8"
	switch r.URL.Path {
	case "/app.css":
		name = "app.css"
		contentType = "text/css; charset=utf-8"
	case "/app.js":
		name = "app.js"
		contentType = "application/javascript; charset=utf-8"
	}
	data, err := webAssets.ReadFile("web/" + name)
	if err != nil {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "no-store")
	_, _ = w.Write(data)
}

func (s *Server) handleNodeInfo(w http.ResponseWriter) {
	s.writeJSON(w, http.StatusOK, map[string]any{
		"name":       s.Name,
		"hostname":   s.Host,
		"appVersion": AppVersion,
		"protocol":   ProtocolVersion,
		"platform":   runtime.GOOS,
		"executorID": s.ExecutorID,
		"workspace":  s.Workspace,
		"agents": []map[string]any{{
			"id":           "codex",
			"displayName":  "Codex",
			"capabilities": []string{"session", "chat", "drive"},
		}},
	})
}

type approvalDTO struct {
	ID        string  `json:"id"`
	Kind      string  `json:"kind"`
	Title     string  `json:"title"`
	Detail    string  `json:"detail"`
	ThreadID  string  `json:"threadId,omitempty"`
	CreatedAt float64 `json:"createdAt"`
}

func (s *Server) handleApprovals(w http.ResponseWriter) {
	approver, ok := s.Backend.(codex.Approver)
	if !ok {
		s.writeJSON(w, http.StatusOK, map[string]any{"available": false, "pending": []approvalDTO{}})
		return
	}
	items := make([]approvalDTO, 0)
	for _, approval := range approver.PendingApprovals() {
		items = append(items, approvalDTO{
			ID:        approval.Key,
			Kind:      approval.Kind,
			Title:     approval.Title,
			Detail:    approval.Detail,
			ThreadID:  approval.ThreadID,
			CreatedAt: timeutil.ToAppleSeconds(approval.CreatedAt),
		})
	}
	s.writeJSON(w, http.StatusOK, map[string]any{"available": true, "pending": items})
}

func (s *Server) handleApprovalDecision(w http.ResponseWriter, r *http.Request) {
	approver, ok := s.Backend.(codex.Approver)
	if !ok {
		s.writeJSON(w, http.StatusNotFound, map[string]string{})
		return
	}
	id, err := url.PathUnescape(strings.TrimPrefix(r.URL.Path, "/v1/approvals/"))
	if err != nil || id == "" {
		s.writeJSON(w, http.StatusBadRequest, map[string]string{})
		return
	}
	var body struct {
		Decision string `json:"decision"`
	}
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 4096)).Decode(&body); err != nil {
		s.writeJSON(w, http.StatusBadRequest, map[string]string{})
		return
	}
	if body.Decision != "accept" && body.Decision != "decline" {
		s.writeJSON(w, http.StatusBadRequest, map[string]string{})
		return
	}
	if err := approver.Decide(id, body.Decision); err != nil {
		s.writeJSON(w, http.StatusConflict, map[string]string{"error": err.Error()})
		return
	}
	s.writeJSON(w, http.StatusOK, map[string]bool{"ok": true})
}

func (s *Server) handleThreads(w http.ResponseWriter, r *http.Request) {
	snapshots, err := s.snapshots(r.Context())
	if err != nil {
		s.writeJSON(w, http.StatusInternalServerError, map[string]string{"error": err.Error()})
		return
	}
	s.writeJSON(w, http.StatusOK, snapshots)
}

func (s *Server) snapshots(ctx context.Context) ([]snapshotDTO, error) {
	s.mu.Lock()
	if s.cached != nil && time.Since(s.cacheAt) < cacheTTL {
		cached := s.cached
		s.mu.Unlock()
		return cached, nil
	}
	s.mu.Unlock()

	// Only one goroutine refreshes at a time; everyone else waits and then
	// picks up the fresh cache instead of spawning another app-server.
	s.buildMu.Lock()
	defer s.buildMu.Unlock()

	s.mu.Lock()
	if s.cached != nil && time.Since(s.cacheAt) < cacheTTL {
		cached := s.cached
		s.mu.Unlock()
		return cached, nil
	}
	s.mu.Unlock()

	threads, err := s.Backend.ListThreads(ctx, threadLimit)
	if err != nil {
		return nil, err
	}
	items := make([]snapshotDTO, 0, len(threads))
	for _, thread := range threads {
		reply, replyErr := s.Backend.LatestReply(ctx, thread.ID, time.Time{})
		if replyErr != nil {
			reply = ""
		}
		var projectDirectory *string
		if thread.Cwd != "" {
			cwd := thread.Cwd
			projectDirectory = &cwd
		}
		items = append(items, snapshotDTO{
			ID:               thread.ID,
			Title:            thread.Title,
			ProjectDirectory: projectDirectory,
			LastReply:        reply,
			UpdatedAt:        timeutil.ToAppleSeconds(thread.UpdatedAt),
			ExecutorID:       s.ExecutorID,
		})
	}

	s.mu.Lock()
	s.cached = items
	s.cacheAt = time.Now()
	s.mu.Unlock()
	return items, nil
}

func (s *Server) handleMessages(w http.ResponseWriter, r *http.Request) {
	const prefix = "/v1/threads/"
	const suffix = "/messages"
	raw := strings.TrimSuffix(strings.TrimPrefix(r.URL.Path, prefix), suffix)
	threadID, err := url.PathUnescape(raw)
	if err != nil || threadID == "" {
		s.writeJSON(w, http.StatusBadRequest, []messageDTO{})
		return
	}
	messages, err := s.Backend.Messages(r.Context(), threadID, messageLimit)
	if err != nil {
		if errors.Is(err, codex.ErrThreadNotFound) {
			s.writeJSON(w, http.StatusNotFound, []messageDTO{})
			return
		}
		s.writeJSON(w, http.StatusInternalServerError, []messageDTO{})
		return
	}
	items := make([]messageDTO, 0, len(messages))
	for _, message := range messages {
		item := messageDTO{ID: message.ID, Role: message.Role, Text: message.Text}
		if message.Timestamp != nil {
			seconds := timeutil.ToAppleSeconds(*message.Timestamp)
			item.Timestamp = &seconds
		}
		items = append(items, item)
	}
	s.writeJSON(w, http.StatusOK, items)
}

type sendRequest struct {
	ID         string          `json:"id"`
	PhoneID    string          `json:"phoneID"`
	ExecutorID string          `json:"executorID"`
	ThreadID   string          `json:"threadID"`
	Text       string          `json:"text"`
	Images     []string        `json:"images"`
	CreatedAt  json.RawMessage `json:"createdAt"`
}

type sendResponse struct {
	ID        string  `json:"id"`
	State     string  `json:"state"`
	Reply     string  `json:"reply,omitempty"`
	UpdatedAt float64 `json:"updatedAt"`
}

func (s *Server) handleSend(w http.ResponseWriter, r *http.Request) {
	var request sendRequest
	if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 1<<20)).Decode(&request); err != nil {
		s.writeJSON(w, http.StatusBadRequest, map[string]string{})
		return
	}
	if strings.TrimSpace(request.Text) == "" || request.ThreadID == "" {
		s.writeJSON(w, http.StatusBadRequest, map[string]string{})
		return
	}

	state := "delivered"
	if err := s.Backend.Queue(r.Context(), request.ThreadID, request.Text); err != nil {
		state = "failed"
		if errors.Is(err, context.DeadlineExceeded) {
			state = "uncertain"
		}
	}

	reply, err := s.Backend.LatestReply(r.Context(), request.ThreadID, parseAppleTime(request.CreatedAt))
	if err != nil {
		reply = ""
	}
	s.writeJSON(w, http.StatusOK, sendResponse{
		ID:        request.ID,
		State:     state,
		Reply:     reply,
		UpdatedAt: timeutil.ToAppleSeconds(time.Now()),
	})
}

func parseAppleTime(raw json.RawMessage) time.Time {
	if len(raw) == 0 {
		return time.Time{}
	}
	var number float64
	if err := json.Unmarshal(raw, &number); err == nil {
		return timeutil.FromAppleSeconds(number)
	}
	var text string
	if err := json.Unmarshal(raw, &text); err == nil {
		text = strings.TrimSpace(text)
		if parsed, err := time.Parse(time.RFC3339Nano, text); err == nil {
			return parsed
		}
		if number, err := strconv.ParseFloat(text, 64); err == nil {
			return timeutil.FromAppleSeconds(number)
		}
	}
	return time.Time{}
}

type snapshotDTO struct {
	ID               string  `json:"id"`
	Title            string  `json:"title"`
	ProjectDirectory *string `json:"projectDirectory"`
	LastReply        string  `json:"lastReply"`
	UpdatedAt        float64 `json:"updatedAt"`
	ExecutorID       string  `json:"executorID"`
}

type messageDTO struct {
	ID        string   `json:"id"`
	Role      string   `json:"role"`
	Text      string   `json:"text"`
	Timestamp *float64 `json:"timestamp,omitempty"`
}

func (s *Server) writeJSON(w http.ResponseWriter, status int, value any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(value)
}
