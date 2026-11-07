GO ?= go
GOCACHE ?= $(HOME)/.cache/go-build
GOLANGCI_LINT_CACHE ?= $(HOME)/.cache/golangci-lint
export GOCACHE
export GOLANGCI_LINT_CACHE

.PHONY: build test test-race lint bench generate

build:
	$(GO) build ./...

test:
	$(GO) test ./...

test-race:
	$(GO) test -race ./...

lint:
	golangci-lint run ./...

bench:
	$(GO) test -run '^$$' -bench . ./...

generate:
	$(GO) generate ./...
