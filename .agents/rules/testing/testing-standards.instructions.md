---
trigger: glob
globs:**/{*{test,spec}*.{py,ts,tsx,js,jsx,go,rs,cs,java,kt,cpp,rb},{test,tests,__tests__}/**/*}
---

# Testing Standards

- **Arrange / Act / Assert**: Structure every test in three visually-separated blocks. Whitespace or short comments make the intent skimmable in five seconds.
- **One Behavior Per Test**: A test name describes a single behavior under a single condition. If the test needs `and` in its name, split it.
- **Descriptive Names**: `test_user_cannot_withdraw_more_than_balance` beats `test_withdraw_2`. The name is the first line of the failure report — make it carry meaning.
- **Isolation**: Tests do not depend on execution order, shared mutable state, or the previous test's side effects. A randomized test order in CI catches violations early.
- **No Sleeps for Synchronization**: Replace `sleep(N)` with explicit waits on observable conditions (poll-with-timeout, event subscription, deterministic clock injection). Sleeps are how flaky suites are born.
- **Fixtures Over Setup Repetition**: Use the framework's fixture mechanism (`pytest` fixtures, `beforeEach`, `t.Cleanup`, `IClassFixture`) so resource lifecycle is centralized and leak-free.
- **Mock at Boundaries, Not Internals**: Mock the database driver, HTTP client, message broker — the things you don't own. Mocking your own internal classes couples tests to implementation and rots on every refactor.
- **Deterministic Inputs**: Seed any randomness (`random.seed(0)`, `Math.random` stubs, faker seeds). A test that fails 1 in 100 runs is a bug, not a feature.
- **Real Time Is Banned**: Inject a clock interface or use the framework's time-travel helper (`freezegun`, `jest.useFakeTimers`, `time.Now` injection). Tests that read wall-clock time are tomorrow's flake.
- **Coverage Is Diagnostic, Not A Goal**: Track line + branch coverage, but treat it as a smoke detector for untested critical paths — not a quota to game. 100% coverage of trivial getters proves nothing.
- **Fast Unit, Honest Integration, Few E2E**: The classic test pyramid. Unit tests run in milliseconds with no I/O. Integration tests touch real adapters (DB, queue) in containers. E2E covers user-visible smoke paths only — they're slow, brittle, and expensive.
- **Test the Failure Modes**: For every happy path, write at least one test for the documented error path (invalid input, dependency timeout, partial failure). The bug reports come from the unhappy paths.
- **CI Parity**: Tests pass on a fresh clone with `<install> && <test>` and nothing else. No "works on my machine" prerequisites — encode them in the test setup or a dev-container.
- **Snapshots Sparingly**: Snapshot tests are useful for stable serialized output. They become noise when the underlying format churns. Review every snapshot diff; do not bulk-`-u`.
