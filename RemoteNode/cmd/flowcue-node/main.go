// Command flowcue-node exposes local Codex sessions to FlowCue on the phone.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"flowcue.local/remotenode/internal/codex"
	"flowcue.local/remotenode/internal/config"
	"flowcue.local/remotenode/internal/server"
)

const version = "0.1.0"

func main() {
	var (
		port      = flag.Int("port", 47825, "TCP port to listen on")
		code      = flag.String("code", "", "override the persisted 6-digit pairing code")
		workspace = flag.String("workspace", "", "workspace directory shown to the phone")
		codexPath = flag.String("codex", "", "path to the codex executable")
		stateDir  = flag.String("state", "", "state directory (pairing code, executor id)")
		showVer   = flag.Bool("version", false, "print version and exit")
	)
	flag.Parse()

	if *showVer {
		fmt.Printf("flowcue-node %s\n", version)
		return
	}

	cfg, err := config.Load(*stateDir, *codexPath, *code)
	if err != nil {
		log.Fatalf("config: %v", err)
	}
	if *workspace != "" {
		info, statErr := os.Stat(*workspace)
		if statErr != nil || !info.IsDir() {
			log.Fatalf("workspace %q is not a directory", *workspace)
		}
		cfg.Workspace = *workspace
	}
	cfg.Port = *port

	rpc := codex.NewRPCClient(cfg.CodexPath)
	rpc.Timeout = 30 * time.Second
	defer rpc.Close()

	local := codex.NewLocal(
		&codex.AppServer{Executable: cfg.CodexPath, Timeout: 25 * time.Second},
		codex.NewRolloutStore(cfg.CodexHome),
		&codex.QueueRunner{Executable: cfg.CodexPath, Timeout: 45 * time.Second},
		rpc,
	)
	hostname, err := os.Hostname()
	if err != nil || hostname == "" {
		hostname = "FlowCue Node"
	}
	handler := server.New(local, cfg.Code, cfg.ExecutorID, cfg.Workspace, hostname)

	address := fmt.Sprintf("%s:%d", cfg.Listen, cfg.Port)
	listener, err := net.Listen("tcp", address)
	if err != nil {
		log.Fatalf("listen on %s: %v", address, err)
	}
	httpServer := &http.Server{
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
	}

	printBanner(cfg)

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	go func() {
		<-ctx.Done()
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		_ = httpServer.Shutdown(shutdownCtx)
	}()

	if err := httpServer.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("serve: %v", err)
	}
}

func printBanner(cfg *config.Config) {
	fmt.Printf("FlowCue Node %s\n", version)
	fmt.Printf("  pairing code: %s\n", cfg.Code)
	fmt.Printf("  codex:        %s\n", cfg.CodexPath)
	fmt.Printf("  codex home:   %s\n", cfg.CodexHome)
	fmt.Printf("  workspace:    %s\n", cfg.Workspace)
	fmt.Printf("  executor:     %s\n", cfg.ExecutorID)
	fmt.Println("  addresses:")
	for _, address := range addresses(cfg.Port) {
		fmt.Printf("    %s\n", address)
	}
	fmt.Println("Keep this window open. Pair from FlowCue on the iPhone with the IP and the 6-digit code.")
}

func addresses(port int) []string {
	urls := []string{fmt.Sprintf("http://127.0.0.1:%d", port)}
	addrs, err := net.InterfaceAddrs()
	if err != nil {
		return urls
	}
	for _, addr := range addrs {
		ipnet, ok := addr.(*net.IPNet)
		if !ok || ipnet.IP.IsLoopback() {
			continue
		}
		if v4 := ipnet.IP.To4(); v4 != nil {
			urls = append(urls, fmt.Sprintf("http://%s:%d", v4.String(), port))
		}
	}
	return urls
}
