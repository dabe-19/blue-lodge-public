---
description: 'Enforces global variable scoping in Bash test files to ensure compatibility with the test runner.'
applyTo: 'tests/**/*.sh'
---

# Bash Testing Standards

When generating, modifying, or answering questions about Bash test files:
- NEVER use the `local` keyword for variables inside `it` or `ti` blocks.
- ALL variables within these test pattern blocks MUST be defined without the `local` scope (use global scope) to maintain compatibility with our test runner's execution context.