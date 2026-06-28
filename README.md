# Outline VPN Proxy

Transparent TCP proxy using Outline/Shadowsocks — route traffic through an external server while keeping local/management traffic (SSH, RDP, LAN) untouched.

## Project Structure

```
vpn-proxy/
├── config.sh              # Your server key (copy from config.sh.example)
├── config.sh.example      # Configuration template
├── proxy.sh               # Main control: start|stop|status|restart
├── decode-key.sh          # Decode "ss://..." Outline access keys
├── domains.txt.example    # Example domain list for selective routing
├── docs/
│   └── domain-routing.md  # Proxy only specific sites (AI Studio, Facebook, …)
├── warp-setup.sh          # Register WARP through this proxy
├── systemd/
│   └── vpn-proxy.service  # Auto-start on boot
└── README.md
```

## Quick Start

```bash
# 1. Configure your key
cp config.sh.example config.sh
nano config.sh

# 2. Start VPN (all TCP through proxy)
sudo ./proxy.sh start

# 3. Stop VPN (always use sudo to clear iptables)
sudo ./proxy.sh stop

# 4. Check status / IP
./proxy.sh status
```

## Routing Modes

| Mode | Command | What gets proxied |
|------|---------|-------------------|
| `full` | `sudo ./proxy.sh start` | All TCP (forwarded + local) — default |
| `local` | `sudo ./proxy.sh start local` | Only this machine's TCP (OUTPUT) |
| `selective` | `sudo ./proxy.sh start selective` | Only domains in `domains.txt` |

Use `domains-myanmar.txt.example` for a pre-built list of junta-blocked social + geo-restricted AI services.


```bash
sudo ./proxy.sh start --exclude 203.0.113.0/24   # bypass specific CIDR
sudo ./proxy.sh start --mode local
sudo ./proxy.sh refresh                          # re-resolve domain IPs (selective)
cp domains.txt.example domains.txt               # then edit domain list
./proxy.sh help
```

Set default mode in `config.sh`: `PROXY_MODE="full"` or `PROXY_MODE="local"`.

### Sudo vs non-sudo

| Command | Without sudo | With sudo |
|---------|--------------|-----------|
| `start` | Starts `ss-redir`, then asks for sudo for iptables | Full start |
| `stop` | Stops user `ss-redir`; warns if iptables still active | Full stop |
| `restart` | Restarts `ss-redir` only if rules already exist | Full restart |
| `status` | Shows process + IP check | Shows exact iptables mode |

**Important:** `./proxy.sh stop` without sudo can leave iptables redirecting to a dead port and break connectivity. Always run `sudo ./proxy.sh stop` when the proxy was started with sudo.

## Proxy Only Specific Domains

iptables cannot match domain names — only IPs. For sites like **Google AI Studio** or **Facebook** only:

- **Browser:** SOCKS (`ss-local`) + SwitchyOmega — see [docs/domain-routing.md](docs/domain-routing.md)
- **System-wide:** `sudo ./proxy.sh start selective` with `domains.txt` — see [docs/domain-routing.md](docs/domain-routing.md)

## Configuration

Edit `config.sh`:

| Variable | Description |
|----------|-------------|
| `SS_SERVER` | Outline server hostname |
| `SS_PORT` | Server port (from access key) |
| `SS_PASSWORD` | Password (from access key) |
| `SS_METHOD` | Encryption method (e.g. `chacha20-ietf-poly1305`) |
| `PROXY_IP` | Resolved IP of proxy server (anti-loop); auto-resolved if empty |
| `PROXY_MODE` | `full`, `local`, or `selective` |
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

## Auto-Start on Boot

```bash
sudo cp systemd/vpn-proxy.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now vpn-proxy
```

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
| IP check `(timeout)` after `stop` | iptables still redirecting, `ss-redir` dead | `sudo ./proxy.sh stop` |
| `start` succeeds but IP unchanged | Outline server down | `nc -zv <server> <port>` |
| `Address already in use` | Lingering `ss-redir` | `sudo pkill -f ss-redir` |
| DNS not resolving | Resolver issue | Add `nameserver 1.1.1.1` to `/etc/resolv.conf` |

## Requirements

- `shadowsocks-libev` (`ss-redir`, `ss-local`)
- `iptables`, `ip` (iproute2)
- `ipset` (for selective mode)
- `dig` or `getent` for DNS resolution
