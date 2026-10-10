# Progress Tracker

Update this file after every meaningful implementation
change.

## Current Phase

- Phase 1 — selective default, curated domains, self-heal. Complete.
- Phase 2 — honesty without root, systemd state preservation, dependency
  preflight, watchdog restart-loop fix. Complete.

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

## Phase 2 — honesty without root (2026-10-09)

Four bugs, one atomic commit each, then docs + tests.

### `4a74e8b` fix(proxy): status/stop/reload lie without root

The worst class of proxy bug is a confident wrong answer. A non-root run
could not read iptables, but `detect_proxy_mode()` still probed with
`sudo -n test -f` / `sudo -n cat` / `sudo -n iptables` — probes that can never
succeed without a working passwordless sudo. They always fell through to
`none`, so a **running** selective proxy reported `INACTIVE (direct
connection)` and `stop` printed `Internet is now DIRECT (no proxy)` while
traffic was still being redirected into a dead `ss-redir`.

- `can_verify_rules()` — root, or a `sudo -n` that actually works. It runs
  `sudo -n true`, not a rule query, so the probe cannot be mistaken for state.
- `iptables_active()` — non-root returns "not verified" immediately instead of
  issuing probes that cannot succeed.
- `detect_proxy_mode()` — dead probes deleted; reads the root-run state file
  `/run/vpn-proxy/active-mode` directly (`RuntimeDirectory=` makes it 0755, so
  it is world-readable). Undeterminable non-root → `unknown`, never `none`.
- `cmd_status()` — `unknown` label + an explicit `[!]` block. The existing
  ss-redir override now also covers `unknown`.
- `cmd_stop()` / `cmd_reload()` — unverifiable state is reported as such.
- `cmd_start()` — `require_ipset` runs **before** `start_ss_redir`, so a
  missing ipset cannot leave an orphan listener with no rules behind it.
- `VPN_PROXY_ACTIVE_MODE_FILE` overrides the state-file path (default
  unchanged) purely so the sandbox tests stay hermetic.

### `1e64041` fix(systemd): RuntimeDirectoryPreserve=yes

A clean stop already deletes `active-mode` in `clean_tproxy`, so systemd
deleting `/run/vpn-proxy` on every stop also erased the only evidence of what
was live after an *unclean* stop — exactly when `status` and the watchdog need
it. `RuntimeDirectoryPreserve=yes` keeps the directory.

### `7c72536` feat(install): dependency preflight

`preflight_deps()` runs after `ensure_proxy_mode` and **before**
`install_bin_link` / `install_systemd`, so a missing package fails with nothing
installed. Hard fail on `iptables`, `ss-redir` (named as the
`shadowsocks-libev` binary it is) and `dig`; `ipset` is fatal only for
`selective` (auto-installed via `apt-get`, else the exact per-distro command is
printed); `curl` is a warning. The mode is read from `config.sh` with `grep`,
never sourced — that file holds the `ss://` key.

### `0f965ec` fix(watchdog): no more 60s restart loop

`active_mode()`'s `sudo -n cat` fallback was dead code (the watchdog is already
root under the unit). The selective ipset check ran unguarded, so on a host
without ipset every 60s looked like a degraded proxy and the watchdog restarted
the unit forever — a loop no restart can satisfy. Now guarded by
`command -v ipset`, matching how `nat_rules_ok` already treats a missing
iptables.

### Decisions from this phase

- **"Cannot verify" is a distinct state from "not active".** Reported as
  `UNKNOWN` in `status`, as an unverifiable warning in `stop`/`reload`, and as
  `not active` only when root really did look and found nothing.
- **State files beat privilege escalation for a status read.** The mode file is
  world-readable by design, so a non-root status reads it directly instead of
  trying `sudo`. No sudo prompt, no dead probe, no false negative.
- **The watchdog never judges an uninstalled dependency "unhealthy."** A missing
  `ipset` binary is a host configuration problem, not a dead proxy; restarting
  cannot fix it and would fight the operator.
- **Preflight before mutation, not after.** Failing after the units are written
  leaves a machine that looks installed and fails at first start.

### Verification

`tests/sandbox/status-degrade.sh` — 17 assertions, all passing; **10 of them
fail against the pre-fix `proxy.sh`** (verified by checking out `HEAD:proxy.sh`
and re-running). Plus `bash -n` on every touched script,
`systemd-analyze verify` on all three units, `git diff --check`, and a
seven-case matrix over `preflight_deps` (missing iptables / ss-redir / dig /
ipset-fail / ipset-ok / non-selective / curl-only). `shellcheck` is not
installed on this host and was **not** run.

### Not changed (deliberately)

`domains.txt` and `domains.txt.example` (still exactly 8 active entries:
`api.github.com`, `facebook.com`, `www.facebook.com`, `graph.facebook.com`,
`upload.facebook.com`, `developers.facebook.com`, `fbcdn.net`, `fb.com`),
`set-key.sh`, `config.sh.example`, `lib/wait-network.sh`, and the
`apply_tproxy` / `clean_tproxy` rule bodies. `PROXY_MODE` precedence
(CLI > `config.sh` > default) is untouched, `install.sh` still excludes the live
`config.sh` and `domains.txt` from its sync, and the `cmp` byte-parity check on
installed units is intact.

## Phase 3 — supervision: `start` delegates to systemd (2026-10-09)

### Root cause

`sudo vpn-proxy start` ran `nohup ss-redir … &` **from the user's
terminal**. That child inherits the terminal's *session* cgroup, so when the
terminal closes `logind` reaps the whole session — and `ss-redir` dies with
no error in any log. `systemctl status vpn-proxy` never saw the process
either, because it was never in the unit's cgroup. `nohup` only ignores
`SIGHUP`; it does nothing about a session-wide reap, which is why adding it
changed nothing. The watchdog could not save it either: the watchdog checks
*health*, and an actively-working-but-unsupervised proxy looks healthy.

The same ordering bug had a second face: `require_root "start"` sat
*after* `start_ss_redir`, so a plain `vpn-proxy start` really did fork a
listener and write a pidfile, and only then exited 1 on the root check.

### Delegation decision

`start` now hands the whole job to the unit instead of doing it:

```
sudo vpn-proxy start
  → write /run/vpn-proxy/start-request   (mode + excludes, umask 077, 300s TTL)
  → drop any unsupervised leftover ss-redir
  → systemctl start vpn-proxy.service
       → ExecStart: proxy.sh start   (VP_SYSTEMD=1, inside the unit cgroup)
            → read_start_request, then start ss-redir as before
```

- **Delegation conditions:** root, not already in the unit, `LoadState ==
  loaded`, and the unit's `ExecStart` resolves to *this* script. A masked
  unit, a missing `/run/systemd/system`, or a unit pointing at another
  checkout all take the direct path instead — delegation to the wrong script
  would be worse than no delegation.
- **Recursion is guarded twice**, independently: `Environment=VP_SYSTEMD=1`
  (survives a systemd that does not export `INVOCATION_ID`) and
  `INVOCATION_ID` (survives a unit file predating the `Environment=` line).
  Either alone is sufficient. Without them, `ExecStart` → `systemctl` →
  `ExecStart` would never terminate.
- **A request file, because `systemctl start` cannot pass argv.** Mode and
  `--exclude` values travel as `KEY=VALUE` lines under `umask 077`. The 300 s
  timestamp TTL means a request that was never consumed (crash, failed
  start) expires instead of re-applying an old mode after a reboot. An
  explicit CLI mode still wins over the file (`PROXY_MODE_FROM_CLI`).
- **`stop` and `restart` delegate too.** Stopping `ss-redir` directly would
  leave the unit `active (exited)` and the watchdog would faithfully
  resurrect the proxy the operator just stopped.
- **Failure is never silent.** A failed `systemctl start` prints the error,
  the journal hint, removes the request file and returns 1. There is no
  unsupervised fallback — an unsupervised proxy that claims to be running is
  the exact failure this phase removes.

### `setsid` fallback (the direct path)

When there is no usable unit, the listener is launched as
`nohup ${setsid_bin} ss-redir …`, which puts it in a session with no
controlling terminal. That is a mitigation, not supervision: logind no
longer reaps it with your session, but nothing restarts it and systemd still
cannot see it. The path therefore always prints
`[WARN] Not supervised by systemd … Fix: sudo systemctl start vpn-proxy`.

`setsid` **forks** when it has a controlling terminal, so `$!` is the
short-lived parent. The pidfile used to record `$!`, which was wrong on both
the old and the new path. It is now resolved from `ss_redir_pids()` after
the process is confirmed alive, so the recorded PID is always the live
`ss-redir`.

### `status` gained supervision truth

`ss_redir_supervision()` greps `/proc/<pid>/cgroup` — world-readable, so no
sudo — and reports `vpn-proxy.service (systemd, watchdog-protected)` or
`NONE — unsupervised; dies when its session closes` plus the fix, along with
a `unit:` line. The Phase 2 invariant is preserved: the `unknown` mode branch
and its `[!]` block are untouched, and `INACTIVE (direct connection)` is
still never printed for merely unverifiable rules.

### Decisions from this phase

- **A process that nothing supervises must say so out loud.** Every direct
  start warns; a non-root `status` can prove supervision without privilege.
- **Refuse before creating, not after.** The non-root `start` check is the
  first statement in `cmd_start` — no pidfile, no ipset, no orphan listener.
- **The root check and the delegation check are both seams for tests.**
  `have_root()` accepts `VP_ASSUME_ROOT=1`; `require_root()` now calls
  `have_root()` so both agree. Production never sets it.
- **The watchdog's intentional-stop guard is untouched** —
  `lib/watchdog.sh` is not modified by this phase.

### Verification

- `bash -n` on `proxy.sh`, `install.sh`, `lib/*.sh`, `tests/sandbox/*.sh` — clean.
- `tests/sandbox/start-delegate.sh` — **64 assertions, all passing**; **30 of
  them fail** against `HEAD:proxy.sh` (checked out and re-run), including the
  exact leak this fixes: pre-change output is
  `[OK] ss-redir started (pid=…)` *followed by* `[ERROR] 'start' needs root`.
- `tests/sandbox/status-degrade.sh` — **24 assertions, all passing**
  (the 17 existing ones unchanged, plus 7 new supervision assertions).
- `systemd-analyze verify` on all three units — clean.
- `git diff --check` — clean. No occurrence of the real SS password in the
  diff (checked programmatically against `/opt/vpn-proxy/config.sh`).

### Not changed (deliberately)

`install.sh` (still never overwrites the live `config.sh` key or
`domains.txt`, unit `cmp` byte-parity intact), `lib/watchdog.sh`,
`set-key.sh`, `config.sh.example`, `domains.txt` and `domains.txt.example`
(still exactly 8 active entries). Mode precedence is CLI > `config.sh` >
built-in `selective`, with the request file inserted strictly below CLI.

## Phase 4 — cursor.com in the selective list (2026-10-10)

Added `cursor.com` as an active entry in a new third group and renumbered the
commented OPTIONAL block, so the shipped list now enumerates three active
groups.

### Active list change

- New **Group 3: AI / dev tools (geo-restricted)** in `domains.txt.example`
  holds the single literal FQDN `cursor.com` with a short, neutral rationale.
  Subdomains are still added on their own line per the literal-FQDN rule.
- The former **Group 3: OPTIONAL / geo-restricted** block is renumbered
  **Group 4**; its commented Google / AI Studio entries are otherwise
  untouched.
- `domains.txt` was updated in place with the exact same insertion + renumber,
  so the two files stay in line-parity. It remains **gitignored and is not part
  of this commit**.

### Docs synced

- `README.md` — the top parenthetical and the shipped-list paragraph now read
  GitHub REST API + Facebook family + the AI coding tool Cursor (`cursor.com`).
- `docs/domain-routing.md` — the `cat domains.txt` command comment, the
  example-list intro ("three active groups"), and a new Cursor row after the
  Facebook row in the group table. The Google OPTIONAL prose is left intact.

### Changed files

- `domains.txt.example`
- `README.md`
- `docs/domain-routing.md`
- `context/progress-tracker.md`

### Not changed (deliberately)

`domains.txt` is updated on disk but never staged. No other domain was added;
`domains-myanmar.txt.example`, `proxy.sh`, `install.sh`, the systemd units and
the sandbox tests are untouched.

The Phase 2 / Phase 3 "Not changed (deliberately)" notes still record "exactly
8 active entries" — that was accurate for those phases and is kept as the
historical record. This Phase 4 entry supersedes them: the list now has
9 active entries across 3 groups.

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