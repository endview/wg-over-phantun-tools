# WireGuard over Phantun Tools

[English](README.md) | [繁體中文](README.zh-TW.md)

纯 CLI 工具，用于在两台服务器之间部署通过
[Phantun](https://github.com/dndx/phantun) fake TCP 承载的 WireGuard 隧道。
在服务器 A 上运行脚本，提供服务器 B 的 SSH 信息后，脚本会自动部署 A/B 两端，
不包含 Web UI。

## 功能

- 在 A/B 两端安装 WireGuard 工具、Phantun 和必要依赖。
- 在 A/B 两端生成或复用 WireGuard 密钥。
- 在 A 启动 `phantun_client`，在 B 启动 `phantun_server`。
- 写入 WireGuard 和 Phantun 的 systemd 服务。
- 写入带 `wg-phantun-*` 注释的受控 iptables NAT/FORWARD 规则。
- 修改系统前打印部署计划。
- 部署时显示分阶段进度。
- 测试 A -> B TCP 可达性、A -> B WireGuard ping、B -> A WireGuard ping
  和 WireGuard 最新握手时间。
- 内置诊断、清理、iperf3 测速和 MTU 调优。

## 拓扑

```text
服务器 A wgpt0 10.66.66.1
  -> 127.0.0.1:51820/udp
  -> A phantun_client
  -> B_PUBLIC_IP:4567/fake-tcp
  -> B phantun_server
  -> 127.0.0.1:51820/udp
  -> 服务器 B wgpt0 10.66.66.2
```

默认值：

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

## 要求

- 两台 Linux 服务器，使用 systemd。
- 服务器 A 上需要 root。
- 服务器 B 支持 root SSH，或 B 用户可执行免密 `sudo -n`。
- 服务器 A 必须能 SSH 到服务器 B。
- B 的云防火墙/安全组必须放行 fake TCP 端口，默认 `TCP 4567`。

这个隧道通过 Phantun 承载 WireGuard，公网 WireGuard UDP 端口不需要开放。

## 快速开始

在服务器 A 上：

```bash
curl -fsSLO https://raw.githubusercontent.com/endview/wg-over-phantun-tools/main/wg-phantun-tunnel.sh
chmod +x wg-phantun-tunnel.sh
sudo bash wg-phantun-tunnel.sh
```

脚本会询问 B 的 SSH 主机、用户、端口、可选密码和可选公网入口。正式修改系统前，
会先打印部署计划。

非交互示例：

```bash
export B_PASS='your-ssh-password'
sudo -E bash wg-phantun-tunnel.sh \
  --b-ssh root@203.0.113.10:22 \
  --b-endpoint 203.0.113.10 \
  --b-password-env B_PASS \
  --phantun-port 4567 \
  --yes
```

只预览，不修改 A/B：

```bash
bash wg-phantun-tunnel.sh \
  --dry-run \
  --b-ssh root@203.0.113.10:22 \
  --b-endpoint 203.0.113.10 \
  --yes
```

## 常用命令

查看状态：

```bash
sudo bash wg-phantun-tunnel.sh --status --b-ssh root@203.0.113.10
```

输出诊断：

```bash
sudo bash wg-phantun-tunnel.sh --diagnose --b-ssh root@203.0.113.10
```

通过隧道跑 iperf3：

```bash
sudo bash wg-phantun-tunnel.sh --speed-test --b-ssh root@203.0.113.10
```

测试常见 MTU 并可选择应用推荐值：

```bash
sudo bash wg-phantun-tunnel.sh --tune-mtu --b-ssh root@203.0.113.10
```

清理脚本生成的服务和配置：

```bash
sudo bash wg-phantun-tunnel.sh --cleanup --b-ssh root@203.0.113.10 --yes
```

本地自测：

```bash
bash wg-phantun-tunnel.sh --self-test
```

## 重要参数

```text
--b-ssh <user@host[:port]>  B SSH 目标快捷写法
--b-endpoint <host>         A 访问 B 的公网 IPv4/域名
--b-password-env <name>     从环境变量读取 B SSH 密码
--sudo                      在 B 上使用免密 sudo，而不是 root
--mtu <mtu>                 WireGuard MTU，默认 1280
--phantun-port <port>       B Phantun fake-TCP 端口，默认 4567
--copy-phantun              部署前从 A 复制 Phantun 到 B，默认开启
--no-copy-phantun           让 B 自己下载 Phantun
--speed-test                通过隧道运行 iperf3 测速
--tune-mtu                  测试常见 MTU 并给出推荐值
--cleanup                   删除生成的服务和配置
--diagnose                  输出详细诊断
--dry-run                   校验参数并打印计划，不改系统
--yes                       跳过确认
```

## 注意事项

- Phantun 不是 TLS/HTTPS，不能放在 Nginx、Cloudflare 等七层 HTTP 代理后面。
- 脚本里的 Phantun 数据通道是 IPv4-only。B 的 SSH 可以用 IPv6，
  但 `--b-endpoint` 必须是 IPv4 或解析到 IPv4 的域名。
- 覆盖 `/etc/wireguard/<iface>.conf` 前，脚本会自动备份原文件。
- 默认会把 Phantun 从 A 复制到 B，以减少 B 访问 GitHub 失败的问题。
  如果希望 B 自己下载，可以使用 `--no-copy-phantun`。
- 建议使用 `--b-password-env`，避免把密码留在 shell 历史中。

## 许可证

MIT
