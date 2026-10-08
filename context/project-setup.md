# Project Setup & Lifecycle Guide

## Getting Started

Once you've scaffolded this project (via `init-context.sh`), fill in the context files in this order:

| Step | File | What to Write |
|------|------|---------------|
| 1 | `project.yaml` | Project name, slug, type, team, stack, environments |
| 2 | `project-overview.md` | Product description, goals, features, scope, success criteria |
| 3 | `architecture.md` | System structure, stack decisions, invariants, data model |
| 4 | `code-standards.md` | Conventions, lint rules, testing approach, commit style |
| 5 | `ui-context.md` | Theme tokens, component library, layout, responsive rules |
| 6 | `ai-workflow-rules.md` | Agent behavior, scoping rules, verification expectations |
| 7 | `progress-tracker.md` | Current phase, completed items, next steps, open questions |

## Orchestration Loop

If using P-Core Orchestra (Cursor/OpenCode), the loop auto-runs on build/fix/refactor prompts:

```
User prompt → Planner → Implementer → Verifier → Reviewer → ORCHESTRA_COMPLETE
                              ↑                                    |
                              └── FIX_REQUIRED ────────────────────┘
```

The context files above are read automatically at session start. Keep them current — the agents use them as ground truth.

## Version & Lifecycle Management

### project.yaml

The `project.yaml` at the project root is the single source of truth for version and lifecycle:

```yaml
version:
  current: 0.1.0        # semver — bumped on each release
  channel: dev           # dev → alpha → beta → rc → stable
  release_name: genesis  # codename for the release cycle
  build_number: 001      # auto-incremented by orchestra

lifecycle:
  stage: idea            # idea → analysis → requirements → design → planning →
                         # development → testing → staging → production → maintenance → sunset
  status: active         # active | paused | archived | sunset
```

### When to Bump

| Change | Version Bump | Channel |
|--------|-------------|---------|
| Initial setup | 0.1.0 | dev |
| Active development | 0.x.0 minor per feature | dev |
| Feature complete | 1.0.0-alpha.1 | alpha |
| Stabilization | 1.0.0-beta.1 | beta |
| Release candidate | 1.0.0-rc.1 | rc |
| Production release | 1.0.0 | stable |
| Bug fix | 1.0.1 (patch) | stable |
| New feature | 1.1.0 (minor) | stable |
| Breaking change | 2.0.0 (major) | stable |

### Lifecycle Transitions

Advance `lifecycle.stage` when the project crosses phase boundaries. Each transition should be recorded in `_pcore.lifecycle_transitions` (orchestra does this automatically).

## Daily Workflow

1. Open the project — orchestra reads context automatically
2. State your goal (e.g. "add login page", "fix payment bug")
3. Orchestra runs: plan → implement → verify → review
4. Update `progress-tracker.md` after meaningful changes
5. Orchestra auto-bumps version on releases

## Context Maintenance

- **Update** a context file when its truth changes (architecture change → update `architecture.md`)
- **Sync** `project.yaml` version/lifecycle when advancing through SDLC
- **Review** `progress-tracker.md` at the end of each session
- **Commit** context changes alongside code changes in the same PR

## Reference

| Resource | Location |
|----------|----------|
| Six-file methodology | `context/*.md` |
| Project identity | `project.yaml` |
| Architecture templates | `docs/architecture/*.md` |
| Orchestra rules | `AGENTS.md` |
