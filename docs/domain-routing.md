# Routing Specific Domains Only

Transparent proxy (`ss-redir` + iptables) matches **IP addresses**, not hostnames. To proxy only the GitHub API, Facebook, or other sites, you must either use a **browser SOCKS proxy** or build **domain → IP → ipset** routing.

> **`selective` is the shipped default.** `config.sh.example` sets
> `PROXY_MODE="selective"` and `proxy.sh` falls back to `selective` when
> `PROXY_MODE` is unset, so a fresh install proxies only what is listed in
> `domains.txt`. `full` and `local` remain available on demand — see
> [Switching to full tunnel](#switching-to-full-tunnel).

## Quick comparison

| Approach | Scope | Complexity | Best for |
|----------|-------|------------|----------|
| `selective` mode (ipset) | System-wide TCP | Medium | **Default** — specific apps hitting known domains |
| SOCKS + browser extension | Browser only | Low | Facebook in Chrome/Firefox only |
| dnsmasq + ipset | System-wide TCP | High | Many domains, IPs change often |

---

## Option 1: Browser-only (recommended)

Use this when you only need certain websites proxied. Everything else stays direct.

### 1. Start SOCKS proxy

From the project directory (reads `config.sh`):

```bash
source config.sh
ss-local -s "$SS_SERVER" -p "$SS_PORT" -l "$SS_SOCKS_PORT" \
  -k "$SS_PASSWORD" -m "$SS_METHOD" -b 127.0.0.1
```

Default SOCKS port is `1080` (`SS_SOCKS_PORT` in `config.sh`).

### 2. Configure browser proxy switcher

Install **SwitchyOmega** (Chrome/Edge) or **FoxyProxy** (Firefox).

Create a profile:

- Type: SOCKS5
- Server: `127.0.0.1`
- Port: `1080`

Add auto-switch rules (examples):

| Service | URL patterns |
|---------|----------------|
| Google AI Studio | `*://aistudio.google.com/*`, `*://*.googleapis.com/*`, `*://*.googleusercontent.com/*` |
| Google | `*://*.google.com/*`, `*://*.gstatic.com/*` |
| Facebook | `*://*.facebook.com/*`, `*://*.fbcdn.net/*`, `*://*.fb.com/*` |

Set default condition to **Direct**. Only matching URLs use the proxy.

### Notes

- No `sudo` required.
- Does not affect terminal, other browsers, or system apps.
- Keep `ss-local` running while you need proxied browsing.

---

## Option 2: System-wide selective routing (`selective` mode)

Route only traffic to IPs that belong to listed domains. Built into `proxy.sh` via **ipset**.

### Setup

`selective` is already the default, so on a fresh install you only need the
domain list:

```bash
sudo apt install ipset
cat domains.txt                    # shipped list: GitHub API + Facebook family
sudo ./proxy.sh start              # selective, because PROXY_MODE defaults to it
```

`ipset` is not optional for this mode, so `install.sh` preflights it: with
`PROXY_MODE=selective` a missing `ipset` is a hard failure, and the installer
tries `apt-get install -y ipset` before printing the exact command for your
distribution. That check runs *before* any unit or symlink is written, so a
host without `ipset` never gets a half-installed proxy that only fails at first
start. In `full`/`local` mode a missing `ipset` is only a warning — switching
to `selective` later would need it. `proxy.sh start` also re-checks ipset
*before* launching `ss-redir`, so a manual start cannot leave an orphan
listener with no rules behind it.

Explicitly, or with a different list:

```bash
cp domains.txt.example domains.txt                      # curated starter list
# cp domains-myanmar.txt.example domains.txt            # broad Myanmar list
nano domains.txt
sudo ./proxy.sh start selective
```

### Switching to full tunnel

Every mode stays runnable on demand — the CLI flag wins over `config.sh`, which
wins over the built-in default:

```bash
sudo ./proxy.sh start full         # all TCP through the tunnel, for now
sudo ./proxy.sh start local        # only this machine's TCP (OUTPUT)
sudo ./proxy.sh start selective    # back to the domain list
```

To make it stick across restarts, edit `PROXY_MODE` in the live config:

```bash
sudo sed -i 's/^PROXY_MODE=.*/PROXY_MODE="full"/' /opt/vpn-proxy/config.sh
sudo systemctl restart vpn-proxy
```

### How it works

```
domains.txt  →  dig/resolve  →  ipset (vpn_proxy_domains)  →  iptables  →  ss-redir
```

1. Domains are resolved to IPs and stored in **ipset** (with timeout).
2. iptables only REDIRECTs TCP when the destination IP is in the set.
3. A background job re-resolves every 5 minutes (config: `DOMAIN_REFRESH_INTERVAL`).
4. Manual refresh: `sudo ./proxy.sh refresh`

### Example domain list

The shipped `domains.txt.example` contains only what is **blocked or
geo-restricted** on the network it was built for. On the network this project
was tuned against, that is:

| Group | Entries | Why |
|-------|---------|-----|
| GitHub REST API | `api.github.com` | The API is TCP-blocked, but git clone, raw content and release downloads over `github.com` work fine direct and stay fast |
| Facebook family | `facebook.com`, `www.facebook.com`, `graph.facebook.com`, `upload.facebook.com`, `developers.facebook.com`, `fbcdn.net`, `fb.com` | The whole family is TCP-blocked direct |

Google / googleapis / gstatic / googleusercontent / aistudio.google.com are
**not** in the active list. They were verified to reach the internet fine
direct from this host, so proxying them is pure latency and CDN risk. They sit
in a clearly marked commented-out "OPTIONAL / geo-restricted" block at the
bottom of the file — uncomment the ones you need if you move to a network
where they are blocked.

Nothing from npm, PyPI, Go, Maven, crates.io, Docker Hub, jsdelivr, cdnjs,
unpkg, esm.sh, RubyGems or Anaconda belongs in this list. All of them are fast
direct, and proxying them breaks the assumption that a proxied request is
rare.

### The literal-FQDN caveat

**This list is resolved with `dig +short A <name>`. An apex name does NOT cover
its subdomains.**

`facebook.com` in `domains.txt` adds facebook.com's own A records and nothing
else. `graph.facebook.com`, `upload.facebook.com` and `static.fbcdn.net` are
separate DNS names and each needs its own line. This is why the shipped list
enumerates every Facebook host explicitly rather than relying on the apex, and
why `.facebook.com` syntax (which ipset-style wildcard matching would use) does
not work here.

Same reasoning applies to `fbcdn.net` — `scontent.fbcdn.net` and friends are
distinct names.

### Never add

| Domain | Why |
|--------|-----|
| `fonts.npmjs.com` | DNS **NXDOMAIN** — there is no A record to resolve, so it can never be proxied |
| `packagist.org` | Resolves IPv6-only on this network; resolution yields no usable IPv4, so it silently never enters the ipset |

### Self-heal (watchdog)

`selective` mode depends on three pieces of live state: the `ss-redir` process,
the `nat OUTPUT -> SS_REDIR` jump, and the `ipset` itself. If any of them dies,
`domains.txt` looks correct but nothing is proxied.

`vpn-proxy.service` is `Type=oneshot` + `RemainAfterExit=yes`, so systemd reports
`active (exited)` forever and `Restart=on-failure` never fires (it only applies
to a unit that *failed*). `vpn-proxy-watchdog.timer` closes that gap: every 60
seconds `lib/watchdog.sh` checks all three and runs `systemctl restart vpn-proxy`
if any is missing.

An intentional `systemctl stop vpn-proxy` is never undone — the watchdog exits
when the unit is not active and re-checks immediately before restarting.

```bash
systemctl status vpn-proxy-watchdog.timer
journalctl -u vpn-proxy-watchdog.service -n 20
sudo /opt/vpn-proxy/lib/watchdog.sh   # manual check
```

Also relevant to selective mode: the ipset has `IPSET_TIMEOUT=3600`, and a
background job re-resolves every `DOMAIN_REFRESH_INTERVAL=300` seconds. If that
job dies, IPs age out of the set and domains start going direct — which is
exactly what the watchdog's ipset check catches. That check is itself guarded
by `command -v ipset`, so a host without ipset installed is never judged
degraded and never restarted every 60 seconds.

### Reading status without root

`vpn-proxy status` needs root to read the iptables rules, so a non-root run
reports `UNKNOWN`, never `INACTIVE (direct connection)`:

```bash
vpn-proxy status
#   TPROXY    : UNKNOWN  (ss-redir running — sudo /opt/vpn-proxy/proxy.sh status for rule details)
#   [!] iptables rules cannot be read without root, so routing is UNKNOWN.
#       UNKNOWN is NOT 'direct' — traffic may still be redirected.

sudo vpn-proxy status
#   TPROXY    : ACTIVE   (mode=selective — listed domains via proxy)
#   ipset     : vpn_proxy_domains (9 entries)
```

The second line is the one that matters in `selective` mode: the ipset entry
count tells you the `domains.txt` → ipset resolution is actually populated.
If it reads `0 entries`, the domains resolved to nothing and nothing is being
proxied even though the rules look correct.

A root-started proxy records its mode in `/run/vpn-proxy/active-mode`, which
`RuntimeDirectoryPreserve=yes` keeps across stops. That file is world-readable,
so after one `sudo vpn-proxy start` the non-root status can report
`ACTIVE (mode=selective …)` without sudo — `UNKNOWN` only appears when the
proxy was never started as root, or `/run` was cleared by a reboot.

`stop` and `restart` follow the same rule: without root they say the rules are
unverifiable instead of claiming `Internet is now DIRECT (no proxy)`.

### Config (`config.sh`)

| Variable | Default | Description |
|----------|---------|-------------|
| `DOMAINS_FILE` | `domains.txt` | Domain list (one per line) |
| `IPSET_NAME` | `vpn_proxy_domains` | ipset name |
| `IPSET_TIMEOUT` | `3600` | IP entry lifetime (seconds) |
| `DOMAIN_REFRESH_INTERVAL` | `300` | Auto re-resolve interval |
| `SELECTIVE_SCOPE` | `local` | `local` = this machine only; `full` = forwarded traffic too |
| `PROXY_MODE` | `selective` | Shipped default; `full` and `local` override via CLI or this key |

### Caveats

- **Literal FQDNs only** — an apex name does not cover subdomains (see above).
- **Use many CDN hostnames** — Facebook and Google serve content from many
  distinct hostnames, each of which must be listed separately.
- **Only list what is blocked** — a domain that works direct gains nothing from
  being proxied.
- **First request** to a new subdomain may go direct until the next refresh.
- **UDP/QUIC** (e.g. HTTP/3) is not handled by `ss-redir` (TCP only).
- Some apps use hardcoded IPs and bypass DNS.

### Manual ipset sketch (if not using proxy.sh)

```bash
# Create set (IPs expire after 1 hour)
ipset create vpn_proxy_domains hash:ip timeout 3600 2>/dev/null || ipset flush vpn_proxy_domains

# Resolve and add (repeat for each domain in domains.txt)
for d in aistudio.google.com facebook.com; do
  dig +short A "$d" | grep -E '^[0-9.]+$' | while read -r ip; do
    ipset add vpn_proxy_domains "$ip" -exist
  done
done

# In SS_REDIR chain, only redirect if dst in set:
iptables -t nat -A SS_REDIR -m set --match-set vpn_proxy_domains dst -p tcp -j REDIRECT --to-ports 10800
```

Note the per-domain `dig` loop above: each name is resolved on its own, exactly
as `proxy.sh` does. There is no wildcard or suffix matching anywhere in this
approach.

Use `sudo ./proxy.sh stop` before experimenting so you do not stack conflicting rules.

---

## Option 3: DNS-driven routing (dnsmasq + ipset)

Most accurate for system-wide domain rules: when the system resolves a proxied domain, dnsmasq adds the answer IP to ipset automatically.

### Example dnsmasq config (`/etc/dnsmasq.d/vpn-proxy.conf`)

```
# Requires: dnsmasq built with ipset support
ipset=/aistudio.google.com/vpn_proxy_domains
ipset=/.google.com/vpn_proxy_domains
ipset=/.googleapis.com/vpn_proxy_domains
ipset=/.facebook.com/vpn_proxy_domains
ipset=/.fbcdn.net/vpn_proxy_domains
```

Point system DNS to `127.0.0.1` (dnsmasq) with upstream resolvers (e.g. `1.1.1.1`).

iptables then matches `-m set --match-set vpn_proxy_domains dst` as in Option 2.

### Trade-offs

- Best track record for changing CDN IPs.
- More moving parts: dnsmasq, local DNS, ipset, iptables.
- Misconfiguration can break DNS for the whole machine.

---

## Choosing a mode

| Goal | Use |
|------|-----|
| Only the listed domains (default behaviour) | **Option 2** — nothing to do; `sudo ./proxy.sh start` is already `selective` |
| Listed domains, system-wide (apps) | **Option 2** — `sudo ./proxy.sh start selective` |
| Facebook in the browser only, no system changes | **Option 1** — SOCKS + SwitchyOmega |
| Many domains, DNS-driven | **Option 3** — dnsmasq + ipset |
| Everything through VPN | `sudo ./proxy.sh start full` |
| Only this machine's apps, all TCP | `sudo ./proxy.sh start local` |

See [README](../README.md) for the routing-mode table, switching to `full`, and `sudo ./proxy.sh help`.
