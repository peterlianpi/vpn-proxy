## Application Building Context

Read the following files in order before implementing
or making any architectural decision:

0. `project.yaml` — project identity, version, lifecycle
   stage, team, and stack definition
1. `context/project-setup.md` — onboarding guide, version/lifecycle
   management, and daily workflow
2. `docs/architecture/` — architecture templates matching
   the project type (auto-scaffolded by init-project)
3. `context/project-overview.md` — product definition,
   goals, features, and scope
4. `context/architecture.md` — system structure,
   boundaries, storage model, system design &
   infrastructure, and invariants
5. `context/ui-context.md` — theme, colors, typography,
   component conventions, and UI skill usage
6. `context/code-standards.md` — implementation rules
   and conventions
7. `context/ai-workflow-rules.md` — development workflow,
   scoping rules, and delivery approach
8. `context/progress-tracker.md` — current phase,
   completed work, open questions, and next steps
9. `context/specs/` — optional unit specs (one file per
   feature); see `specs/README.md`

### Repo type (fill in one)

- [ ] **Single repo** — all source in this directory. Scope all
      reads and globs to this root. Use project-relative paths
      (`AGENTS.md`, `context/*.md`), not `**/AGENTS.md`.
- [ ] **Monorepo** — this root contains multiple subprojects.
      Work in ONE subproject at a time. Do NOT glob `**/` from
      this root — it scans thousands of files across subprojects.
      Read the subproject's own `AGENTS.md` and `context/` instead.

### Performance scoping (both types)

- `.ignore` / `.cursorignore` / `.gitignore` at this root exclude
  `node_modules/`, `vendor/`, `venv/`, caches, and build artifacts.
  Respect them — do not use `--no-ignore` from this root.
- Use `rg` (respects `.ignore`) for search, not bare `find` or `grep -r`.
- Read only the files you need for the current task — do not
  dump-read entire directories.
- Generate or refresh scoping files:
  `bash pcore-orchestra/scripts/setup-repo-scoping.sh .`

### UI skills (when building product UI)

Prefer installed skills `ui-ux-pro-max`, `brand`, `design-system`,
and `ui-styling` for design guidance. Persist tokens and conventions
into `context/ui-context.md` (see Skills section there). Complements
`web-design-guidelines` / `shadcn` Agent Skills.

Update `context/progress-tracker.md` after each
meaningful implementation change.
Update `project.yaml` lifecycle stage and version when
the project advances through SDLC phases.

If implementation changes the architecture, scope, or
standards documented in the context files, update the
relevant file before continuing.
