---
name: grill-me
description: Interview the user relentlessly about a plan or design until reaching shared understanding, resolving each branch of the decision tree. Use when user wants to stress-test a plan, get grilled on their design, or mentions "grill me".
---

# Grill Me

## Goal
Exhaustively cross-examine a proposed technical plan, architecture layout, or sequence of changes to resolve latent dependencies, uncover hidden edge cases, and reach structural alignment before implementation begins.

## Instructions
1. **Tree Traversal:** Isolate the user's plan and break it down into an abstract decision tree. Traverse each branch sequentially to evaluate downstream consequences.
2. **Socratic Sequencing:** Formulate precise questions focusing on hidden trade-offs, ordering constraints, fallback states, and potential failure points.
3. **Isolation Rule:** Present exactly ONE question at a time to the user. Do not batch queries or overwhelm the chat surface.
4. **Presumptive Recommendations:** For every single question posed, provide an accompanying, well-reasoned recommended answer or architecture choice to reduce user cognitive load and drive convergence.
5. **Autonomy Check:** Before externalizing a question to the human user, run file-reading and codebase search utilities to determine if the answer can be derived autonomously from code context. If it can, skip the question and state the discovery.

## Examples
### Architecture Stress-Test
**Agent:** "We need to handle event synchronization if the message bus drops out. Given your plan to process incoming webhooks synchronously, what happens if the internal store goes read-only? 
Recommendation: Implement an in-memory fallback queue with a dead-letter directory so we do not drop ingest traffic."

## Constraints
- Do NOT ask more than one primary question per conversation turn.
- Do NOT allow weak transitions, vague assumptions, or open-ended configurations to pass without a counter-proposal.