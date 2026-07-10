# Contract: Bootstrap the Agent Team

## Feature Overview
Bootstrap the Blue Lodge agent team by running the scout-architect-scribe pipeline to discover the repository structure, design a 14-agent roster, and render the agent workflow files.

## Layer Changes

### Agent Workflows
- Generate 10 canonical-core agent workflows under `.agents/workflows/`.
- Generate 4 project-specific layer specialists under `.agents/workflows/`.

## Touched Layers (Handoff Routing)
- **core-specialist**: no
- **commands-specialist**: no
- **ui-specialist**: no
- **tests-specialist**: no

## Tooling Layer (Provisioning)
- **Tooling**: no

## Functional Verification
- **Verification**: yes — Verify zero remaining template markers and run automated test suite.

## Security
- **Security**: no

## Style
- **Style**: no
