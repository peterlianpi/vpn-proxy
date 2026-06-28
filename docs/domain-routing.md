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

## Option 2: System-wide selective routing (ipset)

Route only traffic to IPs that belong to listed domains. Requires root and periodic IP refresh (CDNs change addresses).

### How it works

```
domains.txt  →  dig/resolve  →  ipset (vpn_proxy_domains)  →  iptables  →  ss-redir
```

1. Maintain a domain list (see `domains.txt.example`).
2. Resolve domains to IPs and load into an **ipset** with timeout.
3. iptables only REDIRECTs/TPROXYs TCP when destination is in that set.
4. Refresh the set every few minutes (cron or systemd timer).

### Example domain list

```
aistudio.google.com
googleapis.com
google.com
gstatic.com
facebook.com
fbcdn.net
```

### Caveats

- **Google / Facebook use many CDN IPs** — include related domains (`*.googleapis.com`, `fbcdn.net`, etc.).
- **First request** to a new subdomain may go direct until the next resolve refresh.
- **UDP/QUIC** (e.g. HTTP/3) is not handled by `ss-redir` (TCP only).
- Some apps use hardcoded IPs and bypass DNS.

> **Status:** `selective` mode is documented here for manual setup. Built-in `sudo ./proxy.sh start selective` may be added in a future release.

### Manual ipset + iptables sketch

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
| One or two CLI apps by domain | **Option 2** — ipset + domain list |
| Many domains, all apps | **Option 3** — dnsmasq + ipset |
| Everything through VPN | `sudo ./proxy.sh start` (full) |
| Only this machine's apps, all TCP | `sudo ./proxy.sh start local` |

See [README](../README.md) for `full` / `local` modes and `sudo ./proxy.sh help`.
