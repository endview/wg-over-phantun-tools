# WireGuard over Phantun Tools

[简体中文](README.zh-CN.md) | [繁體中文](README.zh-TW.md)

Pure CLI tooling for deploying a two-server WireGuard tunnel carried by
[Phantun](https://github.com/dndx/phantun) fake TCP. Run the script on server A,
provide server B SSH access, and it deploys both sides without a Web UI.

## What It Does

- Installs WireGuard tools, Phantun, and required helper packages on A and B.
- Generates or reuses WireGuard key pairs on both servers.
- Starts `phantun_client` on A and `phantun_server` on B.
- Writes systemd services for WireGuard and Phantun.
- Adds managed iptables NAT/FORWARD rules with `wg-phantun-*` comments.
- Prints a deployment plan before changing the system.
- Shows phased deployment progress.
- Tests A -> B TCP reachability, A -> B WireGuard ping, B -> A WireGuard ping,
  and WireGuard handshake freshness.
- Includes CLI diagnostics, cleanup, iperf3 speed tests, and MTU tuning.

## Topology

```text
Server A wgpt0 10.66.66.1
  -> 127.0.0.1:51820/udp
  -> A phantun_client
  -> B_PUBLIC_IP:4567/fake-tcp
  -> B phantun_server
  -> 127.0.0.1:51820/udp
  -> Server B wgpt0 10.66.66.2
```

Default values:

```text
WireGuard interface: wgpt0
A WireGuard IP:      10.66.66.1
B WireGuard IP:      10.66.66.2
B WireGuard UDP:     51820
B Phantun TCP:       4567
A local UDP:         51820
MTU:                 1280
Phantun release:     v0.8.1
```

## Requirements

- Linux servers with systemd.
- Root on server A.
- Root SSH to server B, or a B user with passwordless `sudo -n`.
- Server A must be able to SSH into server B.
- B cloud firewall/security group must allow the fake TCP port, default `TCP 4567`.

The public WireGuard UDP port does not need to be opened for this tunnel because
WireGuard is carried through Phantun.

## Quick Start

On server A:

```bash
curl -fsSLO https://raw.githubusercontent.com/endview/wg-over-phantun-tools/main/wg-phantun-tunnel.sh
chmod +x wg-phantun-tunnel.sh
sudo bash wg-phantun-tunnel.sh
```

The script asks for server B SSH host, user, port, optional password, and optional
public endpoint. It prints a plan before applying changes.

Non-interactive example:

```bash
export B_PASS='your-ssh-password'
sudo -E bash wg-phantun-tunnel.sh \
  --b-ssh root@203.0.113.10:22 \
  --b-endpoint 203.0.113.10 \
  --b-password-env B_PASS \
  --phantun-port 4567 \
  --yes
```

Dry run without touching A or B:

```bash
bash wg-phantun-tunnel.sh \
  --dry-run \
  --b-ssh root@203.0.113.10:22 \
  --b-endpoint 203.0.113.10 \
  --yes
```

## Common Commands

Show status:

```bash
sudo bash wg-phantun-tunnel.sh --status --b-ssh root@203.0.113.10
```

Print diagnostics:

```bash
sudo bash wg-phantun-tunnel.sh --diagnose --b-ssh root@203.0.113.10
```

Run iperf3 over the tunnel:

```bash
sudo bash wg-phantun-tunnel.sh --speed-test --b-ssh root@203.0.113.10
```

Test common MTU values and optionally apply the recommendation:

```bash
sudo bash wg-phantun-tunnel.sh --tune-mtu --b-ssh root@203.0.113.10
```

Clean generated services and configs:

```bash
sudo bash wg-phantun-tunnel.sh --cleanup --b-ssh root@203.0.113.10 --yes
```

Run local self-tests:

```bash
bash wg-phantun-tunnel.sh --self-test
```

## Important Options

```text
--b-ssh <user@host[:port]>  Shortcut for B SSH target
--b-endpoint <host>         Public IPv4/domain for A to reach B
--b-password-env <name>     Read B SSH password from an environment variable
--sudo                      Use passwordless sudo on B instead of root
--mtu <mtu>                 WireGuard MTU, default 1280
--phantun-port <port>       B Phantun fake-TCP port, default 4567
--copy-phantun              Copy Phantun from A to B before deploy, default
--no-copy-phantun           Let B download Phantun itself
--speed-test                Run iperf3 tests over the tunnel
--tune-mtu                  Test common MTU values and recommend one
--cleanup                   Remove generated services/configs
--diagnose                  Print detailed diagnostics
--dry-run                   Validate inputs and print planned changes
--yes                       Skip confirmations
```

## Notes

- Phantun is not TLS/HTTPS and cannot be placed behind Nginx, Cloudflare, or
  other layer-7 HTTP proxies.
- The Phantun data path in this script is IPv4-only. Server B SSH may use IPv6,
  but `--b-endpoint` must be an IPv4 address or a domain that resolves to IPv4.
- Existing `/etc/wireguard/<iface>.conf` files are backed up before overwrite.
- The script defaults to copying Phantun binaries from A to B to avoid B-side
  GitHub download problems. Use `--no-copy-phantun` if you prefer B to download
  Phantun directly.
- Prefer `--b-password-env` over `--b-password` to avoid leaving passwords in
  shell history.

## License

MIT
