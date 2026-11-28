package codex

import (
	"context"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

// buildCommand builds an exec.Cmd for a Codex CLI path. On Windows the npm
// shim is a .cmd batch file, which CreateProcess cannot execute directly, so
// route it through cmd.exe. Native .exe paths are used as-is.
func buildCommand(ctx context.Context, executable string, args ...string) *exec.Cmd {
	if runtime.GOOS == "windows" {
		switch strings.ToLower(filepath.Ext(executable)) {
		case ".cmd", ".bat":
			all := append([]string{"/c", executable}, args...)
			return exec.CommandContext(ctx, "cmd.exe", all...)
		}
	}
	return exec.CommandContext(ctx, executable, args...)
}
