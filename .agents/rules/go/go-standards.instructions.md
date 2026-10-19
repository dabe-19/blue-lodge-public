---
trigger: glob
globs: **/*.go
---

# Go Coding Standards

- **Error Handling**: Return `error` as the last value. Wrap with `fmt.Errorf("context: %w", err)` to preserve chains. Check errors immediately — never ignore with `_` unless documented inline.
- **No Sentinel Panics**: Use `panic` only for truly unrecoverable programmer errors (nil-deref-on-init). All recoverable failure paths return `error`.
- **Context Propagation**: Pass `context.Context` as the first parameter of any function that performs I/O, blocks, or spawns goroutines. Never store a `Context` inside a struct field.
- **Concurrency**: Prefer channels for ownership transfer; prefer `sync.Mutex` for protecting shared state. Always `defer mu.Unlock()` immediately after `mu.Lock()`.
- **Goroutine Lifecycle**: Every goroutine must have a clearly-owned shutdown path (context cancel, channel close, or `WaitGroup`). Leaks are bugs.
- **Interfaces at Use-Site**: Define interfaces in the package that consumes them, not the package that implements them. Keep them small (1–3 methods).
- **Zero Values**: Design types so the zero value is useful. Avoid required `New...` constructors when a `var x Foo` works.
- **Formatting & Linting**: `gofmt` (or `goimports`) on save is mandatory. Run `go vet` and `staticcheck` (or `golangci-lint`) in CI.
- **Project Layout**: Follow the standard layout — `cmd/<binary>/`, `internal/` for non-exported packages, `pkg/` only when you genuinely intend external reuse.
- **Testing**: Use the standard `testing` package with table-driven tests. Place tests in `_test.go` files in the same package (white-box) or `<pkg>_test` (black-box) when testing the public API.
- **Generics**: Use type parameters when they remove duplication; do not over-generalize. A concrete implementation is better than a half-justified generic one.
- **Modules**: Pin dependencies with `go.mod` + `go.sum`. Run `go mod tidy` before commits.
