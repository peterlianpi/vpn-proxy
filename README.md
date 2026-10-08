# Outline VPN Proxy

Transparent TCP proxy using Outline/Shadowsocks. By default only the domains
listed in `domains.txt` (the GitHub REST API and the Facebook family) are routed
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
the GitHub REST API (`api.github.com`) and the Facebook family
(`facebook.com`, `www.facebook.com`, `graph.facebook.com`,
`upload.facebook.com`, `developers.facebook.com`, `fbcdn.net`, `fb.com`).

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
sudo systemctl restart vpn-proxy     # or: sudo systemctl restart vpn-proxy-watchdog.timer
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
| `start` | Starts `ss-redir`, then asks for sudo for iptables | Full start |
| `stop` | Stops user `ss-redir`; warns if iptables still active | Full stop |
| `restart` | Restarts `ss-redir` only if rules already exist | Full restart |
| `status` | Shows process + IP check | Shows exact iptables mode |

**Important:** `./proxy.sh stop` without sudo can leave iptables redirecting to a dead port and break connectivity. Always run `sudo ./proxy.sh stop` when the proxy was started with sudo.

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
| Boot start fails | DNS/network not ready at boot | `journalctl -u vpn-proxy`; check `/var/log/vpn-proxy/ss-redir.log` |
| Unit says `active (exited)` but no traffic is proxied | The oneshot can never self-heal | `systemctl status vpn-proxy-watchdog.timer`; `sudo /opt/vpn-proxy/lib/watchdog.sh` |
| A listed domain still goes direct | Apex name doesn't cover subdomains | Add the exact FQDN to `domains.txt`, then `sudo vpn-proxy refresh` |
| DNS not resolving | Resolver issue | Add `nameserver 1.1.1.1` to `/etc/resolv.conf` |

## Requirements

- `shadowsocks-libev` (`ss-redir`, `ss-local`)
- `iptables`, `ip` (iproute2)
- `ipset` (for selective mode)
- `dig` or `getent` for DNS resolution
