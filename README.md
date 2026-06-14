# Outline VPN Proxy

Transparent TCP proxy using Outline/Shadowsocks — routes all traffic through an external server while keeping local/management traffic (SSH, RDP, LAN) untouched.

## Project Structure

```
vpn-proxy/
├── config.sh         # Edit your server key here
├── proxy.sh          # Main control: start|stop|status|restart
├── decode-key.sh     # Decode "ss://..." Outline access keys
├── warp-setup.sh     # Register WARP through this proxy
├── setup-tproxy.sh   # iptables rules (applied by proxy.sh)
├── clean-tproxy.sh   # Remove iptables rules
├── status.sh         # Quick status check
├── systemd/
│   └── vpn-proxy.service  # Auto-start on boot
└── README.md
```

## Quick Start

```bash
# 1. Configure your key
nano config.sh

# 2. Start VPN (all TCP through proxy)
sudo ./proxy.sh start

# 3. Stop VPN
sudo ./proxy.sh stop

# 4. Check status / IP
sudo ./proxy.sh status
```

## Configuration

Edit `config.sh`:

| Variable | Description |
|----------|-------------|
| `SS_SERVER` | Your Outline server hostname |
| `SS_PORT` | Server port (from access key) |
| `SS_PASSWORD` | Password (from access key) |
| `SS_METHOD` | Encryption method (e.g. chacha20-ietf-poly1305) |
| `EXTRA_EXCLUDED_IPS` | IPs NOT to proxy (e.g. your management IPs) |

To decode an Outline access key:

```bash
./decode-key.sh "ss://Y2hhY2hhMjAtaWV0Zi1wb2x5MTMwNTpwYXNzd29yZA@example.com:25266#Server"
```

## What Is NOT Proxied

Traffic to these destinations goes DIRECT (bypasses the VPN):

- **Local subnets**: `10.x.x.x`, `192.168.x.x`, `172.16-31.x.x`
- **Localhost**: `127.0.0.1`
- **Link-local**: `169.254.x.x`
- **The proxy server itself** (prevents routing loops)
- **WARP infrastructure** (Cloudflare's IPs)
- **Any IPs in `EXTRA_EXCLUDED_IPS`**

This ensures SSH/RDP/VNC to your machine's local IP always work.

## Auto-Start on Boot

```bash
sudo cp systemd/vpn-proxy.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now vpn-proxy
```

## Using with WARP

Cloudflare WARP is geo-blocked in some regions. Use this proxy to register/connect WARP:

```bash
sudo ./warp-setup.sh
```

This registers WARP's API call through the Japan proxy, then connects the WARP tunnel.

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

| Symptom | Likely Cause |
|---------|-------------|
| `start` succeeds but IP doesn't change | Outline server is down — check with `nc -zv <server> <port>` |
| `Address already in use` | Previous process is lingering — `sudo pkill -f ss-redir` |
| DNS not resolving | Try adding `nameserver 1.1.1.1` to `/etc/resolv.conf` |
| internet goes down after `stop` | `sudo ./clean-tproxy.sh` to reset iptables |

## Requirements

- `shadowsocks-libev` (provides `ss-redir`, `ss-local`)
- `iptables` (built-in on Ubuntu)
