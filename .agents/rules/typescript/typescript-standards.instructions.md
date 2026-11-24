---
trigger: glob
globs:**/*.{ts,tsx,mts,cts}
---

# TypeScript Coding Standards

- **Strict Mode**: Enable `strict: true` in `tsconfig.json`, including `noImplicitAny`, `strictNullChecks`, `strictFunctionTypes`, and `noUncheckedIndexedAccess`.
- **No `any`**: Treat `any` as a code smell. Prefer `unknown` at boundaries and narrow with type guards. Use `// eslint-disable-next-line` with a justification comment for the rare unavoidable case.
- **Type vs Interface**: Prefer `type` for unions, intersections, and aliases of primitive/utility shapes. Use `interface` for object shapes intended to be extended or implemented by classes.
- **Discriminated Unions**: Model variant data with a literal `kind` / `type` discriminator and exhaustive `switch` checks (use a `never`-typed default branch to enforce exhaustiveness at compile time).
- **Readonly by Default**: Use `readonly` arrays, `Readonly<T>`, and `as const` for data that should not mutate. Mutation is opt-in, not the default.
- **No Enums**: Prefer `as const` object literals or string-literal unions over TypeScript `enum` (smaller emit, better tree-shaking, clearer JS interop).
- **Async/Await Discipline**: Always `await` promises or explicitly handle them. Configure `@typescript-eslint/no-floating-promises`. Wrap top-level async work in a function that handles rejection.
- **Module Boundaries**: Export only what callers need. Use `index.ts` barrel files sparingly — they hurt tree-shaking and cause circular-dependency surprises.
- **Path Aliases**: Configure `paths` in `tsconfig.json` to avoid `../../../` import chains. Mirror the alias configuration in the bundler/runtime (Vite, Jest, ts-node, etc.).
- **Branded Types**: For domain primitives that should not be interchangeable with raw `string`/`number` (UserId, Email, Cents), use a branded-type helper to prevent accidental cross-assignment.
- **Errors**: Throw `Error` subclasses, not strings. Type catch clauses as `unknown` and narrow before use.
- **Tooling**: Use `eslint` with `@typescript-eslint`, `prettier` for formatting, and `tsc --noEmit` in CI as the source-of-truth type check.
