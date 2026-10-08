# AI Workflow Rules

## Approach

[Describe the overall development approach — e.g. Build
this project incrementally using a spec-driven workflow.
Context files define what to build, how to build it, and
the current state of progress. Always implement against
these specs — do not infer or invent behavior from scratch.]

## Scoping Rules

- Work on one feature unit at a time
- Prefer small, verifiable increments over large
  speculative changes
- Do not combine unrelated system boundaries in a
  single implementation step

## When to Split Work

Split an implementation step if it combines:

- [Concern one — e.g. UI changes and background task changes]
- [Concern two — e.g. Multiple unrelated API routes]
- [Concern three — e.g. Behavior not clearly defined in
  the context files]

If a change cannot be verified end to end quickly,
the scope is too broad — split it.

## System Design Triggers

When starting a new feature, check whether it triggers
any of these system design concerns. If yes, define the
approach in `architecture.md` > System Design before
implementing:

| Trigger | Consider |
|---------|----------|
| File uploads / media | Object storage + CDN + signed URLs |
| Background / deferred work | Queue, worker, retry policy |
| Expensive or repeated query | Caching layer (CDN, Redis, in-memory) |
| Global user base | CDN, multi-region, load balancing |
| Bursty traffic / abuse risk | Rate limiting, throttling, WAF |
| Independent deploy cycles | Microservice boundary, contract testing |
| Debugging production issues | Observability: logs, metrics, traces |
| Search / discovery feature | Dedicated search index vs DB query |
| Realtime UI updates | WebSocket, SSE, polling, Durable Objects |
| Data growth beyond 1M rows | Connection pooling, read replicas, sharding |

## Handling Missing Requirements

- Do not invent product behavior not defined in the
  context files
- If a requirement is ambiguous, resolve it in the
  relevant context file before implementing
- If a requirement is missing, add it as an open question
  in `progress-tracker.md` before continuing

## Protected Files

Do not modify the following unless explicitly instructed:

- [e.g. components/ui/* — generated UI library components]
- [e.g. Any third-party library internals]

## Keeping Docs in Sync

Update the relevant context file whenever implementation
changes:

- System architecture or boundaries
- Storage model decisions
- Code conventions or standards
- Feature scope

## Before Moving to the Next Unit

1. The current unit works end to end within its defined scope
2. No invariant defined in `architecture.md` was violated
3. `progress-tracker.md` reflects the completed work
4. `npm run build` passes

## Concurrent Session Guard (session-claims)

Other AI sessions may be editing the same repo at the same time. Before
implementing, and again before committing:

```bash
bash <orchestra>/scripts/session-claims.sh check "$PWD" <paths-you-will-touch>
```

- `check` → visibility only (shows other sessions working on those paths)
- `claim`/`renew`/`release` → tracking for coordination
- Multiple sessions can work in parallel; use `check` to see who's working on what

Claim your own work at phase start, renew on long operations, release when done:

```bash
bash scripts/session-claims.sh claim  "$PWD" --scope "app/,packages/" --task "goal text"
bash scripts/session-claims.sh renew  "$PWD"
bash scripts/session-claims.sh release "$PWD"
```

Claims auto-expire after 30 min without heartbeat (`gc` purges them). Set
`PCORE_SESSION_ID` in your session env for stable identity across shells.
