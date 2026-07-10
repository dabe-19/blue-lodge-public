---
trigger: glob
globs: **/*.rs
---

# Rust Coding Standards

- **Error Handling**: Never use `.unwrap()` or `.expect()` in production logic unless a panic is the desired and provable outcome of a broken invariant. Always propagate errors using the `?` operator or pattern matching.
- **Ownership & Borrowing**: Pass by reference (`&T` or `&mut T`) by default to avoid unnecessary cloning. Only take ownership (`T`) when the function logically consumes the value.
- **Traits**: Use Traits to define shared behavior. Prefer trait bounds on generic functions (`fn process<T: Processor>(item: &T)`) over dynamic dispatch (`&dyn Processor`) unless heterogeneous collections are required.
- **Enums & Pattern Matching**: Leverage Rust's powerful `enum` types to represent state machines and exhaustive pattern matching (`match`) to ensure all variants are handled.
- **Immutability**: Variables are immutable by default; only use `mut` when explicitly necessary.
