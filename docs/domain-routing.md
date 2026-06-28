# Routing Specific Domains Only

Transparent proxy (`ss-redir` + iptables) matches **IP addresses**, not hostnames. To proxy only Google AI Studio, Facebook, or other sites, you must either use a **browser SOCKS proxy** or build **domain → IP → ipset** routing.

## Quick comparison

| Approach | Scope | Complexity | Best for |
|----------|-------|------------|----------|
| SOCKS + browser extension | Browser only | Low | AI Studio, Facebook in Chrome/Firefox |
| `selective` mode (ipset) | System-wide TCP | Medium | Specific apps hitting known domains |
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

```bash
cp domains.txt.example domains.txt   # edit: add AI Studio, Facebook, etc.
sudo apt install ipset               # if not installed
sudo ./proxy.sh start selective
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

See `domains.txt.example` for Google AI Studio and Facebook entries.

### Config (`config.sh`)

| Variable | Default | Description |
|----------|---------|-------------|
| `DOMAINS_FILE` | `domains.txt` | Domain list (one per line) |
| `IPSET_NAME` | `vpn_proxy_domains` | ipset name |
| `IPSET_TIMEOUT` | `3600` | IP entry lifetime (seconds) |
| `DOMAIN_REFRESH_INTERVAL` | `300` | Auto re-resolve interval |
| `SELECTIVE_SCOPE` | `local` | `local` = this machine only; `full` = forwarded traffic too |

### Caveats

- **Google / Facebook use many CDN IPs** — include related domains (`googleapis.com`, `fbcdn.net`, etc.).
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
| Only AI Studio / Facebook in browser | **Option 1** — SOCKS + SwitchyOmega |
| Listed domains, system-wide (apps) | **Option 2** — `sudo ./proxy.sh start selective` |
| Many domains, DNS-driven | **Option 3** — dnsmasq + ipset |
| Everything through VPN | `sudo ./proxy.sh start` (full) |
| Only this machine's apps, all TCP | `sudo ./proxy.sh start local` |

See [README](../README.md) for `full` / `local` modes and `sudo ./proxy.sh help`.
