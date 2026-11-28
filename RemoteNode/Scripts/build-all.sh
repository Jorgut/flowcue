#!/bin/zsh
# Build the FlowCue remote node for macOS, Windows and Linux.
set -euo pipefail

cd "$(dirname "$0")/.."

go vet ./...
go test ./...

mkdir -p bin
go build -o bin/flowcue-node ./cmd/flowcue-node
GOOS=windows GOARCH=amd64 go build -o bin/flowcue-node-windows-amd64.exe ./cmd/flowcue-node
GOOS=linux   GOARCH=amd64 go build -o bin/flowcue-node-linux-amd64 ./cmd/flowcue-node
GOOS=linux   GOARCH=arm64 go build -o bin/flowcue-node-linux-arm64 ./cmd/flowcue-node

echo "Built:"
ls -lh bin
