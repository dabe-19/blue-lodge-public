---
trigger: glob
globs:**/*.cs
---

# C# / .NET Coding Standards

- **Naming Conventions**: Use `PascalCase` for classes, records, methods, and properties. Use `camelCase` for local variables and method parameters. Prefix interfaces with `I` (e.g., `IRepository`). Prefix private fields with `_`.
- **Async/Await**: Utilize the Task-based Asynchronous Pattern (TAP). Always append `Async` to asynchronous method names. Avoid `async void` (except for event handlers). Use `ConfigureAwait(false)` in library code.
- **Pattern Matching**: Leverage modern C# pattern matching (`switch` expressions, `is` operator, property patterns) to replace verbose conditional logic.
- **Immutability**: Use `record` types and `init`-only setters for data models and DTOs that do not require mutation after creation.
- **LINQ**: Use LINQ for declarative data transformation, but be mindful of deferred execution and unnecessary allocations in hot paths.
