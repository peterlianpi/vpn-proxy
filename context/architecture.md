# Architecture Context

## Stack

| Layer     | Technology                  | Role   |
| --------- | --------------------------- | ------ |
| Framework | [e.g. Next.js + TypeScript] | [Role] |
| UI        | [e.g. Tailwind + shadcn/ui] | [Role] |
| Auth      | [e.g. Clerk]                | [Role] |
| Database  | [e.g. Prisma + PostgreSQL]  | [Role] |
| [Layer]   | [Technology]                | [Role] |

## System Boundaries

- `[folder]` — [What this folder owns and is responsible for]
- `[folder]` — [What this folder owns and is responsible for]
- `[folder]` — [What this folder owns and is responsible for]
- `[folder]` — [What this folder owns and is responsible for]

## Storage Model

- **[Storage type e.g. Database]**: [What lives here —
  e.g. metadata, ownership, relationships]
- **[Storage type e.g. Blob/File Storage]**: [What lives
  here — e.g. generated files, media, large artifacts]

## Auth and Access Model

- [How authentication works — e.g. Every user signs in
  via Clerk]
- [How ownership works — e.g. Every project has a single
  owner]
- [How access control works — e.g. Only the owner or a
  collaborator can mutate project resources]

## System Design & Infrastructure

Fill in the concepts relevant to this project. Leave rows
blank if not yet decided — the list serves as a checklist.

| Concept | Service / Tech | Notes |
|---------|---------------|-------|
| **Compute** | [e.g. Next.js on Vercel, Cloudflare Workers, Node server] | Serverless vs container vs VM |
| **Database** | [e.g. PostgreSQL via Neon, Supabase, Turso] | Scaling approach: read replicas, connection pooling, sharding |
| **Object Storage** | [e.g. R2, S3, Cloudflare Images] | File uploads, generated content, media, backups |
| **CDN** | [e.g. Cloudflare, Vercel Edge, Fastly] | Static assets, global caching, edge functions |
| **Caching** | [e.g. Redis, Cloudflare Cache, in-memory] | Cache strategy: stale-while-revalidate, CDN cache keys, distributed cache |
| **Queue / Async** | [e.g. BullMQ, Cloudflare Queues, RabbitMQ] | Background jobs, email delivery, webhook dispatch, retries with backoff |
| **Rate Limiting** | [e.g. Upstash, Cloudflare Rate Limiting, Token bucket] | Per-user, per-IP, per-endpoint tiers |
| **Load Balancing** | [e.g. Cloudflare, ALB, DNS round-robin] | Multi-region, session affinity, health checks |
| **Microservices** | [e.g. Internal APIs, Workers, Docker services] | Service boundaries, inter-service auth, sync vs event-driven |
| **Observability** | [e.g. OpenTelemetry, Sentry, Grafana, Cloudflare Analytics] | Logs, metrics, traces, alerting, dashboards |
| **Search** | [e.g. Typesense, Meilisearch, Algolia, pgvector] | Full-text search, vector embeddings, faceted filters |
| **Streaming / Realtime** | [e.g. WebSockets, SSE, Realtime Supabase, Durable Objects] | Live updates, collaborative editing, push notifications |

## Scaling & Performance Constraints

- [Expected traffic volume — e.g. 10K DAU, 1M requests/month]
- [P99 latency target — e.g. <200ms for API, <1s for page load]
- [Data growth estimate — e.g. 10GB/month, 1M new rows/month]
- [Availability target — e.g. 99.9% uptime, multi-region failover]
- [Budget constraint — e.g. PaaS free tier, <$50/mo infra cost]

## Invariants

1. [Rule the codebase must never violate — e.g. Request
   handlers do not run long-lived background work]
2. [Invariant two]
3. [Invariant three]
4. [Invariant four]
