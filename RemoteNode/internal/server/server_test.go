package server

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"flowcue.local/remotenode/internal/codex"
	"flowcue.local/remotenode/internal/timeutil"
)

const (
	testToken      = "123456"
	testExecutorID = "11111111-1111-4111-8111-111111111111"
)

type fakeBackend struct {
	threads  []codex.Thread
	messages []codex.Message
	reply    string
	queueErr error
	queued   []string
}

func (f *fakeBackend) ListThreads(context.Context, int) ([]codex.Thread, error) {
	return f.threads, nil
}

func (f *fakeBackend) Messages(_ context.Context, threadID string, _ int) ([]codex.Message, error) {
	if threadID != "thread-1" {
		return nil, codex.ErrThreadNotFound
	}
	return f.messages, nil
}

func (f *fakeBackend) LatestReply(context.Context, string, time.Time) (string, error) {
	return f.reply, nil
}

func (f *fakeBackend) Queue(_ context.Context, threadID, text string) error {
	if f.queueErr != nil {
		return f.queueErr
	}
	f.queued = append(f.queued, threadID+"="+text)
	return nil
}

func newTestServer(backend codex.Backend) *Server {
	return New(backend, testToken, testExecutorID, "/workspace", "test-host")
}

func TestPingNeedsNoAuth(t *testing.T) {
	server := newTestServer(&fakeBackend{})
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/v1/ping", nil))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d", recorder.Code)
	}
	var payload map[string]string
	if err := json.Unmarshal(recorder.Body.Bytes(), &payload); err != nil {
		t.Fatal(err)
	}
	if payload["protocol"] != "1" {
		t.Fatalf("protocol = %q", payload["protocol"])
	}
	if payload["name"] == "" {
		t.Fatal("name is empty")
	}
}

func TestThreadsRejectsMissingToken(t *testing.T) {
	server := newTestServer(&fakeBackend{})
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/v1/threads", nil))

	if recorder.Code != http.StatusUnauthorized {
		t.Fatalf("status = %d, want 401", recorder.Code)
	}
}

func TestThreadsUsesAppleReferenceDates(t *testing.T) {
	updated := time.Date(2026, 1, 1, 12, 0, 0, 0, time.UTC)
	backend := &fakeBackend{
		threads: []codex.Thread{{ID: "thread-1", Title: "Demo", Cwd: "/tmp/demo", UpdatedAt: updated}},
		reply:   "latest",
	}
	server := newTestServer(backend)

	request := httptest.NewRequest(http.MethodGet, "/v1/threads", nil)
	request.Header.Set("Authorization", "Bearer "+testToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d body=%s", recorder.Code, recorder.Body.String())
	}
	var snapshots []snapshotDTO
	if err := json.Unmarshal(recorder.Body.Bytes(), &snapshots); err != nil {
		t.Fatal(err)
	}
	if len(snapshots) != 1 {
		t.Fatalf("got %d snapshots", len(snapshots))
	}
	want := timeutil.ToAppleSeconds(updated)
	if snapshots[0].UpdatedAt != want {
		t.Fatalf("updatedAt = %v, want %v", snapshots[0].UpdatedAt, want)
	}
	if snapshots[0].ExecutorID != testExecutorID {
		t.Fatalf("executorID = %q", snapshots[0].ExecutorID)
	}
	if snapshots[0].ProjectDirectory == nil || *snapshots[0].ProjectDirectory != "/tmp/demo" {
		t.Fatalf("projectDirectory = %#v", snapshots[0].ProjectDirectory)
	}
}

func TestThreadMessages(t *testing.T) {
	at := time.Date(2026, 1, 1, 0, 0, 1, 0, time.UTC)
	backend := &fakeBackend{messages: []codex.Message{
		{ID: "0-user", Role: "user", Text: "hi", Timestamp: &at},
	}}
	server := newTestServer(backend)

	request := httptest.NewRequest(http.MethodGet, "/v1/threads/thread-1/messages", nil)
	request.Header.Set("Authorization", "Bearer "+testToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d", recorder.Code)
	}
	var messages []messageDTO
	if err := json.Unmarshal(recorder.Body.Bytes(), &messages); err != nil {
		t.Fatal(err)
	}
	if len(messages) != 1 || messages[0].Text != "hi" {
		t.Fatalf("messages = %#v", messages)
	}
	if messages[0].Timestamp == nil || *messages[0].Timestamp != timeutil.ToAppleSeconds(at) {
		t.Fatalf("timestamp = %#v", messages[0].Timestamp)
	}
}

func TestSendDelivers(t *testing.T) {
	backend := &fakeBackend{reply: "done"}
	server := newTestServer(backend)

	body := `{"id":"aaaaaaaa-1111-4111-8111-111111111111","threadID":"thread-1","text":"do it","createdAt":786000000.0}`
	request := httptest.NewRequest(http.MethodPost, "/v1/send", strings.NewReader(body))
	request.Header.Set("Authorization", "Bearer "+testToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d body=%s", recorder.Code, recorder.Body.String())
	}
	var response sendResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.State != "delivered" {
		t.Fatalf("state = %q", response.State)
	}
	if len(backend.queued) != 1 || backend.queued[0] != "thread-1=do it" {
		t.Fatalf("queued = %#v", backend.queued)
	}
}

func TestSendReportsFailure(t *testing.T) {
	backend := &fakeBackend{queueErr: context.DeadlineExceeded}
	server := newTestServer(backend)

	body := `{"id":"aaaaaaaa-1111-4111-8111-111111111111","threadID":"thread-1","text":"do it"}`
	request := httptest.NewRequest(http.MethodPost, "/v1/send", strings.NewReader(body))
	request.Header.Set("Authorization", "Bearer "+testToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)

	var response sendResponse
	if err := json.Unmarshal(recorder.Body.Bytes(), &response); err != nil {
		t.Fatal(err)
	}
	if response.State != "uncertain" {
		t.Fatalf("state = %q, want uncertain", response.State)
	}
}

func TestSendRejectsEmptyText(t *testing.T) {
	server := newTestServer(&fakeBackend{})
	body := `{"id":"aaaaaaaa-1111-4111-8111-111111111111","threadID":"thread-1","text":"   "}`
	request := httptest.NewRequest(http.MethodPost, "/v1/send", strings.NewReader(body))
	request.Header.Set("Authorization", "Bearer "+testToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)

	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want 400", recorder.Code)
	}
}

func TestIndexServesTheConsole(t *testing.T) {
	server := newTestServer(&fakeBackend{})
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/", nil))

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d", recorder.Code)
	}
	if contentType := recorder.Header().Get("Content-Type"); !strings.HasPrefix(contentType, "text/html") {
		t.Fatalf("content type = %q", contentType)
	}
	if !strings.Contains(recorder.Body.String(), "<title>FlowCue</title>") {
		t.Fatal("index did not contain the console title")
	}
}

func TestSessionCookieUnlocksTheAPI(t *testing.T) {
	backend := &fakeBackend{threads: []codex.Thread{{ID: "thread-1", Title: "Demo"}}}
	server := newTestServer(backend)

	bad := httptest.NewRequest(http.MethodPost, "/v1/session", strings.NewReader(`{"code":"000000"}`))
	badRecorder := httptest.NewRecorder()
	server.ServeHTTP(badRecorder, bad)
	if badRecorder.Code != http.StatusUnauthorized {
		t.Fatalf("wrong code status = %d, want 401", badRecorder.Code)
	}

	good := httptest.NewRequest(http.MethodPost, "/v1/session", strings.NewReader(`{"code":"123456"}`))
	goodRecorder := httptest.NewRecorder()
	server.ServeHTTP(goodRecorder, good)
	if goodRecorder.Code != http.StatusOK {
		t.Fatalf("right code status = %d body=%s", goodRecorder.Code, goodRecorder.Body.String())
	}

	var session *http.Cookie
	for _, cookie := range goodRecorder.Result().Cookies() {
		if cookie.Name == sessionCookie {
			session = cookie
		}
	}
	if session == nil || session.Value == "" || !session.HttpOnly {
		t.Fatalf("session cookie = %#v", session)
	}

	request := httptest.NewRequest(http.MethodGet, "/v1/threads", nil)
	request.AddCookie(session)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("threads with cookie status = %d", recorder.Code)
	}
}

func TestLogoutInvalidatesSession(t *testing.T) {
	server := newTestServer(&fakeBackend{})
	good := httptest.NewRequest(http.MethodPost, "/v1/session", strings.NewReader(`{"code":"123456"}`))
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, good)

	var session *http.Cookie
	for _, cookie := range recorder.Result().Cookies() {
		if cookie.Name == sessionCookie {
			session = cookie
		}
	}
	if session == nil {
		t.Fatal("no session cookie")
	}

	logout := httptest.NewRequest(http.MethodPost, "/v1/session/logout", nil)
	logout.AddCookie(session)
	server.ServeHTTP(httptest.NewRecorder(), logout)

	request := httptest.NewRequest(http.MethodGet, "/v1/threads", nil)
	request.AddCookie(session)
	after := httptest.NewRecorder()
	server.ServeHTTP(after, request)
	if after.Code != http.StatusUnauthorized {
		t.Fatalf("status after logout = %d, want 401", after.Code)
	}
}

type fakeApprover struct {
	*fakeBackend
	pending   []codex.Approval
	decisions []string
}

func (f *fakeApprover) PendingApprovals() []codex.Approval { return f.pending }

func (f *fakeApprover) Decide(id, decision string) error {
	f.decisions = append(f.decisions, id+"="+decision)
	for index, approval := range f.pending {
		if approval.Key == id {
			f.pending = append(f.pending[:index], f.pending[index+1:]...)
			return nil
		}
	}
	return codex.ErrThreadNotFound
}

func TestApprovalsListAndDecide(t *testing.T) {
	backend := &fakeApprover{
		fakeBackend: &fakeBackend{},
		pending: []codex.Approval{{
			Key:       "7",
			Kind:      "command",
			Title:     "Codex wants to run a command",
			Detail:    "npm test",
			ThreadID:  "thread-1",
			CreatedAt: time.Now(),
		}},
	}
	server := newTestServer(backend)

	request := httptest.NewRequest(http.MethodGet, "/v1/approvals", nil)
	request.Header.Set("Authorization", "Bearer "+testToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d", recorder.Code)
	}
	if !strings.Contains(recorder.Body.String(), "npm test") {
		t.Fatalf("body = %s", recorder.Body.String())
	}

	decision := httptest.NewRequest(http.MethodPost, "/v1/approvals/7", strings.NewReader(`{"decision":"accept"}`))
	decision.Header.Set("Authorization", "Bearer "+testToken)
	decisionRecorder := httptest.NewRecorder()
	server.ServeHTTP(decisionRecorder, decision)
	if decisionRecorder.Code != http.StatusOK {
		t.Fatalf("decision status = %d body=%s", decisionRecorder.Code, decisionRecorder.Body.String())
	}
	if len(backend.decisions) != 1 || backend.decisions[0] != "7=accept" {
		t.Fatalf("decisions = %#v", backend.decisions)
	}
}

func TestApprovalsUnavailableWithoutApprover(t *testing.T) {
	server := newTestServer(&fakeBackend{})
	request := httptest.NewRequest(http.MethodGet, "/v1/approvals", nil)
	request.Header.Set("Authorization", "Bearer "+testToken)
	recorder := httptest.NewRecorder()
	server.ServeHTTP(recorder, request)
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d", recorder.Code)
	}
	if !strings.Contains(recorder.Body.String(), `"available":false`) {
		t.Fatalf("body = %s", recorder.Body.String())
	}
}
