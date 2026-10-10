# Outline VPN Proxy

Transparent TCP proxy using Outline/Shadowsocks. By default only the domains
listed in `domains.txt` (the GitHub REST API, the Facebook family, and the AI
coding tool Cursor `cursor.com`) are routed
through an external server; everything else — package registries, `github.com`,
Google, CDNs — stays direct at full speed. A `vpn-proxy-watchdog.timer` keeps the
proxy alive: if `ss-redir`, the iptables jump or the ipset dies, the unit is
restarted automatically, and an intentional `systemctl stop` is never undone.

## Project Structure

```
vpn-proxy/
├── config.sh              # Your server key (copy from config.sh.example)
├── config.sh.example      # Configuration template
├── proxy.sh               # Main control: start|stop|status|restart
├── decode-key.sh          # Decode "ss://..." Outline access keys
├── set-key.sh             # Apply a new ss:// key + restart
├── domains.txt            # Live domain list for selective mode (gitignored)
├── domains.txt.example    # Committed template for domains.txt
├── domains-myanmar.txt.example  # Broad Myanmar censorship + AI geo-block list
├── docs/
│   └── domain-routing.md  # Proxy only specific sites (GitHub API, Facebook, …)
├── lib/
│   ├── log.sh             # Logging helpers
│   ├── wait-network.sh    # Boot-time DNS/network wait (ExecStartPre)
│   └── watchdog.sh        # Self-heal check (restart if ss-redir/iptables/ipset died)
├── tests/
│   └── sandbox/
│       ├── status-degrade.sh      # Non-root honesty checks for status/stop
│       └── start-delegate.sh      # start delegates to systemd (or warns)
├── warp-setup.sh          # Register WARP through this proxy
├── systemd/
│   ├── vpn-proxy.service              # Auto-start on boot
│   ├── vpn-proxy-watchdog.service      # Oneshot self-heal check
│   └── vpn-proxy-watchdog.timer        # Runs that check every 60s
└── README.md
```

## Quick Start

```bash
# 1. Configure your key
cp config.sh.example config.sh
nano config.sh

# 2. Start VPN
#    default (PROXY_MODE=selective): only domains in domains.txt
sudo ./proxy.sh start
#    or explicitly: sudo ./proxy.sh start selective

# 3. Stop VPN (always use sudo to clear iptables)
sudo ./proxy.sh stop

# 4. Check status / IP
./proxy.sh status
```

## Routing Modes

**`selective` is the shipped default.** Only the domains listed in `domains.txt`
go through the tunnel; everything else connects directly. That keeps package
registries, `github.com`, Google, CDNs and everything else at full direct speed
while unblocking the sites that actually need the VPN.

| Mode | Command | What gets proxied |
|------|---------|-------------------|
| `selective` | `sudo ./proxy.sh start selective` | Only domains in `domains.txt` — **default** |
| `full` | `sudo ./proxy.sh start full` | All TCP (forwarded + local) |
| `local` | `sudo ./proxy.sh start local` | Only this machine's TCP (OUTPUT) |

Precedence: **CLI flag > `PROXY_MODE` in `config.sh` > built-in `selective`.**

The shipped `domains.txt` covers what needs the tunnel on most networks:
the GitHub REST API (`api.github.com`), the Facebook family
(`facebook.com`, `www.facebook.com`, `graph.facebook.com`,
`upload.facebook.com`, `developers.facebook.com`, `fbcdn.net`, `fb.com`),
and the AI coding tool Cursor (`cursor.com`).

> **The domain list is literal FQDNs only.** It is resolved with `dig +short A <name>`,
> so an apex name does **not** cover its subdomains — `facebook.com` will not
> proxy `graph.facebook.com`. Add each hostname you need on its own line.

Use `domains-myanmar.txt.example` for a pre-built list of junta-blocked social +
geo-restricted AI services.

### Switching to full tunnel

Per-invocation, without changing the config:

```bash
sudo ./proxy.sh start full      # everything through the VPN now
```

Persistently, for good or until you change it back:

```bash
sudo sed -i 's/^PROXY_MODE=.*/PROXY_MODE="full"/' /opt/vpn-proxy/config.sh
sudo systemctl restart vpn-proxy
```

Back to selective:

```bash
sudo sed -i 's/^PROXY_MODE=.*/PROXY_MODE="selective"/' /opt/vpn-proxy/config.sh
sudo systemctl restart vpn-proxy
```

`PROXY_MODE` is the only key `install.sh` ever writes into your live
`config.sh`; your `SS_SERVER` / `SS_PORT` / `SS_PASSWORD` / `SS_METHOD` /
`PROXY_IP` are never touched.


```bash
sudo ./proxy.sh start --exclude 203.0.113.0/24   # bypass specific CIDR
sudo ./proxy.sh start --mode local
sudo ./proxy.sh refresh                          # re-resolve domain IPs (selective)
cp domains.txt.example domains.txt               # then edit domain list
./proxy.sh help
```

Set the persisted default in `config.sh`: `PROXY_MODE="selective"` (shipped),
`"full"` or `"local"`.

### Sudo vs non-sudo

| Command | Without sudo | With sudo |
|---------|--------------|-----------|
| `start` | **Refuses**, before creating anything, and says how to start it supervised | Hands off to `systemctl start vpn-proxy` |
| `stop` | Stops user `ss-redir`; warns the rules could not be verified | Stops the unit if it is active, otherwise removes the rules directly |
| `restart` | Restarts `ss-redir` only if rules can be verified | Restarts the unit |
| `status` | Shows process, mode file, **supervision** and IP check; mode is `UNKNOWN` without root | Shows exact iptables mode |

**Important:** `./proxy.sh stop` without sudo can leave iptables redirecting to a dead port and break connectivity. Always run `sudo ./proxy.sh stop` when the proxy was started with sudo.

#### How `start` works

`sudo vpn-proxy start` **does not start ss-redir itself.** If the unit is not
already active, it writes the requested mode to a short-lived request file
and runs `systemctl start vpn-proxy`. The unit's `ExecStart` then runs
`vpn-proxy start` again — this time inside the unit — and *that* run starts
ss-redir, so the listener ends up in `/system.slice/vpn-proxy.service`,
watched by the watchdog timer.

If the unit **is** already active, `start` is idempotent: it prints
`[OK] vpn-proxy.service already active — nothing to do`, kills nothing, and
issues no `systemctl start`. That guard is not cosmetic. `systemctl start`
on an active `Type=oneshot` + `RemainAfterExit=yes` unit is a **no-op** —
ExecStart is *not* re-run — so cleaning up leftover ss-redir processes
first would take the healthy listener down with nothing to replace it, while
still printing `[OK] … started`. Use `vpn-proxy restart` to change the mode.

Why this matters: the old implementation ran `nohup ss-redir … &` from your
terminal. That child inherits your **session** cgroup, so closing the
terminal makes `logind` reap the whole session — and the proxy dies with no
error anywhere. `systemctl status vpn-proxy` never saw it either.

Because `systemctl start` cannot pass argv, the requested mode and any
`--exclude CIDR` travel in the request file instead. It is stamped with a
timestamp and expires after 300 seconds, so a request that was never
consumed cannot silently re-apply an old mode on a later boot. An explicit
mode on the command line still wins over the file.

Delegation needs a unit that actually runs *this* script. If the unit is
missing, masked, or points at a different checkout, `start` takes the
**direct path** instead: it launches `setsid ss-redir …`, which at least
keeps the listener out of your session cgroup, and says plainly:

```
[OK] ss-redir started (pid=1234)
[WARN] Not supervised by systemd — this ss-redir dies when this session closes.
       Fix: sudo systemctl start vpn-proxy.service
```

`setsid` forks in an interactive shell, so the pid that `$!` returns is the
short-lived `setsid` parent. `proxy.sh` therefore resolves the real listener
PID after startup and only then writes the pidfile — the recorded PID is
always the live `ss-redir`.

Recursion is guarded twice: `Environment=VP_SYSTEMD=1` in the unit file, and
systemd's own `INVOCATION_ID`. Either one alone is enough to stop the
in-unit run from calling `systemctl` again.

#### `start` without sudo refuses, and creates nothing

```console
$ vpn-proxy start
[ERROR] 'start' needs root: it writes iptables rules and owns /run/vpn-proxy.
        Fix: sudo systemctl start vpn-proxy.service
        A plain start here would leave an unsupervised ss-redir behind,
        which dies silently when this session closes. Nothing was created.
$ echo $?
1
```

Before, the root check happened *after* the spawn: the command really did
start an `ss-redir`, wrote a pidfile, and only then failed on `iptables` —
an orphan listener with no rules, invisible to `systemctl`.

#### Status without root says UNKNOWN, never "direct"

`iptables -L` needs root. Without it there is no way to know what the rules
are, so `proxy.sh` refuses to guess: it reports `UNKNOWN` instead of
`INACTIVE`. Before, dead `sudo -n iptables` probes always failed and fell
through to "no rules", so a **running** proxy was reported as
`INACTIVE (direct connection)` — confident and wrong.

```
$ vpn-proxy status                     # no sudo
=== Outline VPN Proxy Status ===

  ss-redir  : RUNNING  (:10800 -> proxy.example.com:47266)
  supervision: NONE — unsupervised; dies when its session closes.
                Fix: sudo systemctl start vpn-proxy.service
  unit      : active
  TPROXY    : UNKNOWN  (ss-redir running — sudo /opt/vpn-proxy/proxy.sh status for rule details)

  [!] iptables rules cannot be read without root, so routing is UNKNOWN.
      UNKNOWN is NOT 'direct' — traffic may still be redirected.
      Verify with: sudo /opt/vpn-proxy/proxy.sh status

--- IP Check ---
{ "ip": "203.0.113.9", ... }
```

The same holds for `stop` and `restart`: when the rules cannot be verified
they say so rather than reporting a clean, direct connection.

#### Supervision is reported even without root

`/proc/<pid>/cgroup` is world-readable, so `status` can always tell whether
the listener is inside `vpn-proxy.service` — no sudo needed. A listener
outside the unit is reported as `NONE`, with the fix, instead of looking
identical to a healthy one:

```
$ vpn-proxy status
  ss-redir  : RUNNING  (:10800 -> proxy.example.com:47266)
  supervision: NONE — unsupervised; dies when its session closes.
                Fix: sudo systemctl start vpn-proxy.service
```

Once started through the unit, the same line reads
`supervision: vpn-proxy.service (systemd, watchdog-protected)`.

A root-started proxy writes its mode to `/run/vpn-proxy/active-mode`.
`RuntimeDirectoryPreserve=yes` keeps that file across a stop (a clean stop
already deletes it), so a non-root `status` still reports `ACTIVE
(mode=selective …)` with no sudo at all once the proxy has been started as
root. Only a host with a proxy that was never started as root — or whose
`/run` was cleared by a reboot — needs `sudo`.

```bash
vpn-proxy status        # UNKNOWN  → re-run: sudo vpn-proxy status
sudo vpn-proxy status   # ACTIVE (mode=selective — listed domains via proxy)
```

## Dependency Preflight

`install.sh` checks dependencies **before** it writes anything to the host, so
a missing package fails with nothing installed instead of leaving units and a
symlink behind a proxy that cannot start:

| Dependency | If missing |
|------------|-----------|
| `iptables`, `ss-redir` (from `shadowsocks-libev`), `dig` | **hard fail** — install, then re-run `sudo ./install.sh` |
| `ipset` with `PROXY_MODE=selective` | **hard fail** — auto-installed with `apt-get install -y ipset`, or install it yourself and re-run |
| `ipset` with `full`/`local` | warning only |
| `curl` | warning only (it is just the public-IP check in `status`) |

The mode is read out of `config.sh` with `grep`, never sourced, because that
file holds the `ss://` key. Per-distro install commands are printed on failure.

## Proxy Only Specific Domains

iptables cannot match domain names — only IPs. **This is the shipped default**,
so out of the box only the domains in `domains.txt` are proxied:

- **System-wide (default):** `sudo ./proxy.sh start` in `selective` mode with `domains.txt` — see [docs/domain-routing.md](docs/domain-routing.md)
- **Browser only:** SOCKS (`ss-local`) + SwitchyOmega — see [docs/domain-routing.md](docs/domain-routing.md)

Two rules matter when editing `domains.txt`:

1. **Literal FQDNs only.** Resolution is `dig +short A <name>`; an apex does not
   cover subdomains.
2. **Add only what is blocked.** A domain that reaches the internet fine direct
   gains nothing and risks latency. Never add `fonts.npmjs.com` (NXDOMAIN) or
   `packagist.org` (IPv6-only here).

## Configuration

Edit `config.sh`:

| Variable | Description |
|----------|-------------|
| `SS_SERVER` | Outline server hostname |
| `SS_PORT` | Server port (from access key) |
| `SS_PASSWORD` | Password (from access key) |
| `SS_METHOD` | Encryption method (e.g. `chacha20-ietf-poly1305`) |
| `PROXY_IP` | Resolved IP of proxy server (anti-loop); auto-resolved if empty |
| `PROXY_MODE` | `selective` (default), `full`, or `local` |
| `DOMAINS_FILE` | Domain list for selective mode (`domains.txt`) |
| `SS_REDIR_PORT` | Transparent proxy port (default `10800`) |
| `SS_SOCKS_PORT` | SOCKS port for browser proxy (default `1080`) |
| `EXTRA_EXCLUDED_IPS` | Space-separated CIDRs to bypass (management IPs, etc.) |

Decode an Outline access key:

```bash
./decode-key.sh "ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpwYXNzd29yZA@example.com:25266#Server"
```

## What Is NOT Proxied

Traffic to these destinations goes **direct** (bypasses the VPN):

- **Local subnets**: `10.x.x.x`, `192.168.x.x`, `172.16–31.x.x`
- **Localhost**: `127.0.0.1`
- **Link-local**: `169.254.x.x`
- **The proxy server itself** (prevents routing loops)
- **WARP infrastructure** (Cloudflare IPs)
- **Any IPs in `EXTRA_EXCLUDED_IPS`**

SSH/RDP/VNC to your machine's LAN IP stays direct.

## System Install (global command)

Install once, then run `vpn-proxy` from any directory:

```bash
sudo ./install.sh
```

One line from GitHub:

```bash
# latest
curl -fsSL https://raw.githubusercontent.com/peterlianpi/vpn-proxy/main/install.sh | sudo bash

# pinned release
curl -fsSL https://raw.githubusercontent.com/peterlianpi/vpn-proxy/v1.0.0/install.sh | sudo bash
```

After install:

```bash
vpn-proxy status
sudo vpn-proxy start         # uses PROXY_MODE from config.sh (selective by default)
sudo vpn-proxy start full    # temporary switch to a full tunnel
sudo vpn-proxy stop
vpn-proxy logs -f
```

Installs to `/opt/vpn-proxy`, links `/usr/local/bin/vpn-proxy`, installs and
enables both `vpn-proxy.service` and the self-heal watchdog, and sets up
passwordless sudo for the installing user. Logs: `/var/log/vpn-proxy/vpn-proxy.log`.

### Updating

Re-run the installer. It is safe to run repeatedly:

```bash
sudo ./install.sh
```

It backs up `config.sh` and `domains.txt` to `<file>.bak-<epoch>` before touching
anything, keeps the newest 5 snapshots, and writes **only** `PROXY_MODE` into
your live `config.sh`. Your server, port, password, method and `PROXY_IP` are
never overwritten. Pass `DEFAULT_PROXY_MODE=full` to change what mode is written.

## Auto-Start on Boot

```bash
sudo ./install.sh                       # recommended — installs command + units + watchdog
# or manually:
sudo cp systemd/vpn-proxy*.service systemd/vpn-proxy*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now vpn-proxy.service vpn-proxy-watchdog.timer
```

`vpn-proxy.service` carries `Wants=vpn-proxy-watchdog.timer`, so
`systemctl enable vpn-proxy` alone is enough to get self-healing as well.

Once installed, `sudo vpn-proxy start` and `sudo systemctl start vpn-proxy`
are the same thing: the first delegates to the second, which is what keeps
`ss-redir` inside the unit's cgroup. See [How `start` works](#how-start-works).

```bash
sudo vpn-proxy start        # == systemctl start vpn-proxy (supervised)
sudo vpn-proxy stop         # == systemctl stop vpn-proxy when active
systemctl show -p Environment vpn-proxy   # confirm VP_SYSTEMD=1
```

## Self-Heal (Watchdog)

`vpn-proxy.service` is `Type=oneshot` + `RemainAfterExit=yes`: `proxy.sh`
backgrounds `ss-redir` and returns, so systemd keeps reporting `active (exited)`
forever. `Restart=on-failure` cannot help here — it only fires when the unit
*failed*, never after it succeeded once. That is why the proxy could show a
healthy unit while `ss-redir` was dead and the iptables tables were empty.

So `vpn-proxy-watchdog.timer` checks every 60 seconds (`lib/watchdog.sh`) and
restarts the unit when any of these is true:

- `ss-redir` is not listening on `SS_REDIR_PORT`
- the `nat OUTPUT -> SS_REDIR` jump is missing
- the `ipset` is missing while the active mode is `selective`

**Your intentional stops are respected.** The watchdog exits immediately
whenever `vpn-proxy` is not active, re-checks after a short settle sleep, and
checks once more right before restarting — so `sudo systemctl stop vpn-proxy`
stays stopped until you start it again. `PartOf=`/`Requires=` are deliberately
not used, which would either kill the watchdog's own client or make it fail
every minute once the main unit is in `failed` state.

Inspect it:

```bash
systemctl status vpn-proxy-watchdog.timer
systemctl list-timers vpn-proxy-watchdog.timer
journalctl -u vpn-proxy-watchdog.service -n 20
sudo /opt/vpn-proxy/lib/watchdog.sh     # run a check by hand
sudo systemctl stop vpn-proxy-watchdog.timer   # disable self-heal
```

The watchdog runs as root, so it reads the mode file directly — no `sudo`
probe. It also refuses to call a dependency that is simply not installed
"unhealthy": if `ipset` is absent, the missing set is ignored rather than
triggering a restart every 60 seconds that no restart could ever fix.

## Tests

```bash
bash tests/sandbox/status-degrade.sh        # or: ./tests/sandbox/status-degrade.sh
bash tests/sandbox/start-delegate.sh         # or: ./tests/sandbox/start-delegate.sh
echo $?                                     # 0 = all assertions passed
```

`tests/sandbox/status-degrade.sh` guards the non-root honesty contract. It
puts a fake `sudo`, `iptables`, `ipset`, `pgrep`, `curl`, `pkill`, `dig` and
`logger` on `PATH` and runs the real `proxy.sh` as your own user, asserting
that:

1. with an unusable `sudo` and `ss-redir` running, `status` says `UNKNOWN`
   and never `INACTIVE (direct connection)` — and says so with no listener too;
2. `stop` warns that the rules are unverifiable and never claims
   `Internet is now DIRECT`;
3. with a working `sudo`, a fake `SS_REDIR` chain carrying
   `match-set vpn_proxy_domains` is reported as `ACTIVE (mode=selective)`;
4. a world-readable `/run/vpn-proxy/active-mode` is honoured with no sudo at
   all;
5. `status` prints a `supervision:` line and never regresses to
   `INACTIVE (direct connection)`.

`tests/sandbox/start-delegate.sh` guards the supervision contract. It fakes
`systemctl` (including actually running the unit's `ExecStart` the way
systemd would), `setsid`, `ss-redir`, `ipset`, `iptables` and `sudo`, and
asserts that:

1. a non-root `start` exits 1 with the right hint and creates **nothing** —
   no listener, no pidfile, no ipset, no request file;
2. root + a loaded unit results in exactly one `systemctl start` and zero
   direct spawns;
3. the delegated start really runs the unit, and the in-unit run makes **zero**
   `systemctl` calls (no ExecStart↔systemctl recursion) — with `VP_SYSTEMD=1`
   and with `INVOCATION_ID` alone;
4. `start full` and `--exclude` survive the round trip through the request
   file, and a stale request older than the TTL is discarded;
5. a masked unit, a missing `/run/systemd/system` or a unit running a
   different script falls back to the direct path, where the **pidfile holds
   the real `ss-redir` PID**, not `setsid`'s short-lived parent;
6. `stop` with an active unit only calls `systemctl stop`, so the watchdog
   cannot resurrect the proxy;
7. a failing `systemctl start` is loud and never falls back silently;
8. a **second** `start` while the unit is already active leaves the healthy
   `ss-redir` **alive and unreplaced** — same PID, same pidfile, no second
   spawn — and never issues `systemctl start`;
9. a malformed (`ts=abc`) or zero-byte request file degrades to the config
   mode instead of aborting the in-unit start, and is consumed rather than
   left behind in `/run`.

Both harnesses run the real `proxy.sh` as your own user against a private
copy with a placeholder key and a unique `SS_REDIR_PORT`, so a production
`ss-redir` on the host is never matched or killed.

Both harnesses touch nothing on the host — every path is a `mktemp`
directory, and `VPN_PROXY_ACTIVE_MODE_FILE` repoints the one absolute path
`proxy.sh` reads — and both must be run **as a non-root user** (they fake
privilege rather than using it, via the `VP_ASSUME_ROOT` seam).
`start-delegate.sh` needs `config.sh` to exist only to read its mode; it
runs a private copy with a placeholder key and a unique `SS_REDIR_PORT`, and
never prints the `ss://` key.

## Using with WARP

Cloudflare WARP is geo-blocked in some regions. Register/connect through this proxy:

```bash
sudo ./warp-setup.sh
```

## Traffic Flow

```
Without VPN (direct):
  App ──────────────────────────────────▶ Internet

With VPN (proxy active):
  App ──▶ iptables REDIRECT ──▶ Shadowsocks Server ──▶ Internet
  SSH ──▶ (bypasses proxy, direct to LAN/WAN)

With WARP + VPN:
  App ──▶ WARP tunnel ──▶ iptables REDIRECT ──▶ Shadowsocks ──▶ Internet
```

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|----------------|-----|
| `Permission denied` on `/run/vpn-proxy/` | Ran `start` without sudo after a sudo start | `sudo ./proxy.sh stop` then `sudo ./proxy.sh start` |
| `supervision: NONE` in `status` | `ss-redir` was started from a terminal, not by the unit — it dies when that terminal closes | `sudo systemctl start vpn-proxy` |
| `ss-redir` dies when the terminal closes | Started outside the unit, so it inherited the session cgroup | `sudo systemctl start vpn-proxy`, then confirm `systemctl status vpn-proxy` |
| `'start' needs root` | Plain `vpn-proxy start` | `sudo systemctl start vpn-proxy` (nothing was created) |
| `[WARN] Not supervised by systemd` | No usable unit, so `start` took the direct `setsid` path | `sudo systemctl start vpn-proxy` |
| `systemctl start … failed — NOT falling back` | The unit refused to start; there is no silent unsupervised proxy by design | `journalctl -u vpn-proxy -n 30` |
| `TPROXY : UNKNOWN` | Rules cannot be read without root — this is *not* "direct" | `sudo vpn-proxy status` |
| IP check `(timeout)` after `stop` | iptables still redirecting, `ss-redir` dead | `sudo ./proxy.sh stop` |
| `start` succeeds but IP unchanged | Outline server down | `nc -zv <server> <port>` |
| `Address already in use` | Lingering `ss-redir` | `sudo pkill -f ss-redir` |
| Boot start fails | DNS/network not ready at boot | `journalctl -u vpn-proxy`; check `/var/log/vpn-proxy/ss-redir.log` |
| Unit says `active (exited)` but no traffic is proxied | The oneshot can never self-heal | `systemctl status vpn-proxy-watchdog.timer`; `sudo /opt/vpn-proxy/lib/watchdog.sh` |
| A listed domain still goes direct | Apex name doesn't cover subdomains | Add the exact FQDN to `domains.txt`, then `sudo vpn-proxy refresh` |
| DNS not resolving | Resolver issue | Add `nameserver 1.1.1.1` to `/etc/resolv.conf` |

## Requirements

- `shadowsocks-libev` (`ss-redir`, `ss-local`)
- `util-linux` (`setsid`, used only on the direct, non-systemd start path)
- `iptables`, `ip` (iproute2)
- `ipset` (for selective mode)
- `dig` or `getent` for DNS resolution
