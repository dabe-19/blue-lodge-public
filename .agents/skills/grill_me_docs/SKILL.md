---
name: grill-with-docs
description: Grilling session that challenges your plan against the existing domain model, sharpens terminology, and updates documentation (CONTEXT.md, ADRs) inline as decisions crystallise. Use when user wants to stress-test a plan against their project's language and documented decisions.
---

# Grill With Docs

## Goal
Challenge and align technical plans against a repository's ubiquitous language model and past architectural decision records (ADRs), persistently documenting vocabulary adjustments and new high-impact design choices directly to disk.

## Instructions
1. **Initialization & Analysis:** Scan the workspace for `CONTEXT.md`, `CONTEXT-MAP.md`, and files under `docs/adr/`. Understand the current single-context or multi-context layouts before initializing questions.
2. **Glossary Verification:** Cross-reference terms used by the user against definitions in `CONTEXT.md`. If a term diverges or risks introducing ambiguity, halt the plan and prompt clarification immediately.
3. **Fuzzy Language Elimination:** Detect vague or overloaded language (e.g., using "account" to mean both a billing customer entity and an auth profile identity). Force the resolution of precise, canonical nomenclature.
4. **Code Realism Mapping:** Audit the current codebase implementation against statements made during the session. If the code contradicts a stated concept, highlight it as an architecture friction point.
5. **Inline Document Mutating:** As soon as a domain concept or term boundary is clarified, update `CONTEXT.md` in-place using the structured glossary format. Do not buffer or batch documentation changes.
6. **ADR Generation Lifecycle:** Evaluate finalized decisions against the Architectural Decision Record bar. Execute the helper script `python3 .agent/skills/grill-with-docs/scripts/create_adr.py use-postgres-indexing` to seed a record whenever a choice meets the strict architectural threshold.

## Examples
### Context Glossary Layout Requirement
```md
# Context Name
## Language
**CanonicalTerm**:
A single-sentence description of what the term IS, not what it does.
_Avoid_: ErroneousSynonym1, ErroneousSynonym2
## Relationships
- A **CanonicalTerm** generates exactly one **SecondaryTerm**.