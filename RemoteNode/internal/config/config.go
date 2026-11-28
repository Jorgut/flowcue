// Package config resolves runtime paths, the pairing code, and the executor id.
package config

import (
	"crypto/rand"
	"fmt"
	"math/big"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strings"
)

const defaultPort = 47825

// Config is everything the node needs to start.
type Config struct {
	Listen     string
	Port       int
	Code       string
	Workspace  string
	CodexPath  string
	CodexHome  string
	StateDir   string
	ExecutorID string
}

var digitsPattern = regexp.MustCompile(`^[0-9]{6}$`)

// Load fills in defaults and persists the pairing code and executor id so a
// phone keeps the same identity across node restarts.
func Load(stateDir, codexPath, code string) (*Config, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	if stateDir == "" {
		stateDir = filepath.Join(home, ".flowcue", "node")
	}
	if err := os.MkdirAll(stateDir, 0o700); err != nil {
		return nil, fmt.Errorf("create state dir: %w", err)
	}

	executorID, err := loadExecutorID(stateDir)
	if err != nil {
		return nil, err
	}
	pairingCode, err := loadPairingCode(stateDir, code)
	if err != nil {
		return nil, err
	}
	if codexPath == "" {
		codexPath = discoverCodex()
	}
	codexHome := os.Getenv("CODEX_HOME")
	if codexHome == "" {
		codexHome = filepath.Join(home, ".codex")
	}
	workspace, err := os.Getwd()
	if err != nil {
		return nil, err
	}

	return &Config{
		Listen:     "0.0.0.0",
		Port:       defaultPort,
		Code:       pairingCode,
		Workspace:  workspace,
		CodexPath:  codexPath,
		CodexHome:  codexHome,
		StateDir:   stateDir,
		ExecutorID: executorID,
	}, nil
}

func loadExecutorID(stateDir string) (string, error) {
	path := filepath.Join(stateDir, "executor-id")
	if data, err := os.ReadFile(path); err == nil {
		if value := strings.TrimSpace(string(data)); value != "" {
			return value, nil
		}
	}
	value, err := newUUID()
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(path, []byte(value+"\n"), 0o600); err != nil {
		return "", fmt.Errorf("write executor id: %w", err)
	}
	return value, nil
}

func loadPairingCode(stateDir, override string) (string, error) {
	if override != "" {
		if !digitsPattern.MatchString(override) {
			return "", fmt.Errorf("pairing code must be exactly 6 digits")
		}
		return override, nil
	}
	path := filepath.Join(stateDir, "pairing-code")
	if data, err := os.ReadFile(path); err == nil {
		if value := strings.TrimSpace(string(data)); digitsPattern.MatchString(value) {
			return value, nil
		}
	}
	value, err := newPairingCode()
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(path, []byte(value+"\n"), 0o600); err != nil {
		return "", fmt.Errorf("write pairing code: %w", err)
	}
	return value, nil
}

func newPairingCode() (string, error) {
	limit := big.NewInt(1_000_000)
	number, err := rand.Int(rand.Reader, limit)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%06d", number.Int64()), nil
}

func newUUID() (string, error) {
	buffer := make([]byte, 16)
	if _, err := rand.Read(buffer); err != nil {
		return "", err
	}
	buffer[6] = (buffer[6] & 0x0f) | 0x40
	buffer[8] = (buffer[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", buffer[0:4], buffer[4:6], buffer[6:8], buffer[8:10], buffer[10:16]), nil
}

func discoverCodex() string {
	home, _ := os.UserHomeDir()
	if runtime.GOOS == "windows" {
		// Prefer a native .exe: a .cmd shim has to go through cmd.exe, which
		// makes message quoting fragile. The npm package usually ships both.
		candidates := []string{
			filepath.Join(os.Getenv("LOCALAPPDATA"), "Programs", "codex", "codex.exe"),
			filepath.Join(os.Getenv("APPDATA"), "npm", "node_modules", "@openai", "codex", "bin", "codex.exe"),
			filepath.Join(os.Getenv("APPDATA"), "npm", "codex.exe"),
		}
		for _, candidate := range candidates {
			if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
				return candidate
			}
		}
		if path, err := exec.LookPath("codex.exe"); err == nil {
			return path
		}
		if path, err := exec.LookPath("codex"); err == nil {
			return path
		}
		return "codex"
	}

	if path, err := exec.LookPath("codex"); err == nil {
		return path
	}
	candidates := []string{
		"/opt/homebrew/bin/codex",
		"/usr/local/bin/codex",
		filepath.Join(home, ".local", "bin", "codex"),
	}
	for _, candidate := range candidates {
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate
		}
	}
	return "codex"
}
