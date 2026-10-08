# Progress Tracker

Update this file after every meaningful implementation
change.

## Current Phase

- Phase 1 — selective default, curated domains, self-heal. Complete.

## Current Goal

- Shipped `selective` as the default routing mode with a domain list containing
  only what actually needs the tunnel, kept `full`/`local` runnable on demand,
  and made the proxy self-heal instead of silently staying "active" while dead.

## Completed

### set-key (committed as its own change, first)

- `set-key.sh`: decode an Outline `ss://` access key, update the local and
  `/opt` config files in place, resolve the new `PROXY_IP`, restart the unit.
- `proxy.sh`: new `set-key` subcommand, usage text updated.
- `install.sh`: chmods `set-key.sh` after install.

### Agent context + tool scoping

- `AGENTS.md` and the `context/` six-file set, plus `context/specs/`.
- `.ignore` and `.cursorignore` so ripgrep/fd/ag/Cursor skip build dirs and logs.

### selective default + curated domain list

- `config.sh.example`: `PROXY_MODE="selective"`.
- `proxy.sh`: fallback changed from `${PROXY_MODE:-full}` to
  `${PROXY_MODE:-selective}`. Precedence is CLI > config > built-in default.
- `domains.txt` (gitignored live list) and `domains.txt.example` (committed
  mirror) are byte-identical, trimmed to what is blocked on this network:
  - `api.github.com` — the REST API is TCP-blocked; `github.com` git/raw/release
    traffic is fast direct and deliberately NOT proxied.
  - Facebook family, enumerated per FQDN: `facebook.com`, `www.facebook.com`,
    `graph.facebook.com`, `upload.facebook.com`, `developers.facebook.com`,
    `fbcdn.net`, `fb.com`.
  - Google / googleapis / gstatic / googleusercontent / aistudio.google.com moved
    to a commented "OPTIONAL / geo-restricted" block — verified direct here, so
    proxying them is pure latency. One uncomment away if needed.
  - Header documents the literal-FQDN rule (apex does not cover subdomains) and
    the two never-add entries: `fonts.npmjs.com` (NXDOMAIN) and `packagist.org`
    (IPv6-only).
- No package registry (npm, PyPI, Go, Maven, crates.io, Docker Hub, jsdelivr,
  cdnjs, unpkg, esm.sh, RubyGems, Anaconda) is in the list.

### Self-heal + non-destructive install

- `lib/watchdog.sh` — checks ss-redir liveness, the `nat OUTPUT -> SS_REDIR` jump,
  and (in selective mode) the ipset. Restarts `vpn-proxy` only when the unit is
  active but degraded. Four guards make an intentional stop a no-op.
- `systemd/vpn-proxy-watchdog.timer` — `OnBootSec=120s`, then every 60s.
- `systemd/vpn-proxy-watchdog.service` — oneshot running the script; no
  `[Install]`, reached via the timer.
- `systemd/vpn-proxy.service` — gains `Wants=`/`After=` the timer; `Restart=on-failure`
  documented as not being the self-heal.
- `install.sh` renders all three units from `systemd/` (repo copy is the single
  source of truth) and verifies byte-identity with `cmp` under default paths.
- `install.sh` excludes `config.sh` from the sync, backs up every file it rewrites
  to `<file>.bak-<epoch>`, prunes to the newest 5, and writes **only**
  `PROXY_MODE`. `DEFAULT_PROXY_MODE` overrides the written value.

### Docs

- `README.md`: routing-modes table with selective as default, "Switching to full
  tunnel" (per-invocation and persistent), self-heal section, update path, new
  troubleshooting rows, refreshed project structure.
- `docs/domain-routing.md`: selective marked as shipped default, the
  literal-FQDN caveat, the shipped list with per-group rationale, never-add
  table, watchdog section, revised "Choosing a mode".

## In Progress

- None.

## Next Up

- Run the install on the target host and verify `selective` end to end
  (`systemctl start`, `vpn-proxy status`, ipset entry count).
- Confirm the watchdog fires in anger (kill `ss-redir`, wait ~60s, expect an
  automatic restart) and that `systemctl stop vpn-proxy` stays stopped.

## Open Questions

- Whether `SELECTIVE_SCOPE="local"` (the default) is right long term. `full`
  scope would also proxy forwarded/LAN traffic, which is usually not wanted.
- Whether the optional Google/AI block should ever become active. Right now the
  network reaches those hosts direct, so it stays commented out.

## Architecture Decisions

- **`selective` is the shipped default, `full` is opt-in.** Rationale: full-tunnel
  by default costs latency and proxy-cleanup latency on registries and CDNs that
  work fine direct. Decision recorded in `config.sh.example`, `proxy.sh`
  fallback, README, and `docs/domain-routing.md`.
- **Mode precedence is CLI > `config.sh` > built-in default.** `proxy.sh` reads
  `PROXY_MODE` from the sourced config first, then applies `${PROXY_MODE:-…}`,
  then `parse_args()` overwrites it with any CLI mode. This ordering is why the
  fallback change alone was enough.
- **Self-heal is an out-of-process watchdog, not `Type=simple`.** `proxy.sh`
  forks `ss-redir` and returns, so `Type=simple` + `Restart=always` would restart
  the unit in a loop forever. A timer + oneshot that inspects real state is the
  only approach that works with a forking daemon.
- **No `PartOf=`/`Requires=` between the watchdog and `vpn-proxy`.** A stop
  dependency either kills the watchdog's own `systemctl` client mid-restart, or
  makes the watchdog fail every minute once the main unit is in `failed` state.
  The in-script `is-active` guards are the mechanism instead, and the timer stays
  armed across stops so a later manual start is watched immediately.
- **A stopped unit is never auto-healed.** Self-heal covers "active but dead"
  only. Operator intent always wins; a unit in `failed` state is surfaced rather
  than retried, which also prevents restart storms.
- **`install.sh` is the update path and must be re-runnable.** It excludes the
  live `config.sh` from the sync instead of backing up and restoring it, so the
  key material is never on disk in the replaced state — not even transiently.
- **Unit files are rendered from `systemd/`, not heredoc'd in `install.sh`.** One
  source of truth; `cmp` proves the installed copy matches the repo copy.

## System Design Checklist

Refer to `architecture.md` > System Design & Infrastructure
when adopting new infrastructure concepts. Each row documents
a decision point with service choice and trade-offs.

Not applicable: this is a host-level shell/systemd project with no
network services, datastore, or CDN to track. The relevant state is
in-process (ipset in the kernel, ss-redir as a local daemon), so
nothing in that table applies.

## Session Notes

- Repo is standalone (`/home/peter/Documents/Project/vpn-proxy`), not part of the
  pcore monorepo. Deployed copy lives at `/opt/vpn-proxy`, with
  `/usr/local/bin/vpn-proxy -> /opt/vpn-proxy/proxy.sh`.
- `config.sh` and `domains.txt` are gitignored by design: `config.sh` holds the
  real `ss://` credentials, and `domains.txt` is the operator's live copy of
  `domains.txt.example`. Keep them that way — never stage either.
- `install.sh` backs up before rewriting; look for
  `/opt/vpn-proxy/config.sh.bak-<epoch>` to recover a previous mode or key.
- Verified from this host: package registries, `github.com`, Google and the
  major CDNs are all reachable direct. Do not add them to `domains.txt`.
- To flip modes without editing config by hand:
  `sudo vpn-proxy start full` for a one-off, or set `PROXY_MODE` and
  `systemctl restart vpn-proxy`.