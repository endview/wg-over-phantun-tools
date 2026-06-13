# WireGuard over Phantun Tools

[English](README.md) | [簡體中文](README.zh-CN.md)

純 CLI 工具，用於在兩台伺服器之間部署透過
[Phantun](https://github.com/dndx/phantun) fake TCP 承載的 WireGuard 隧道。
在伺服器 A 上執行腳本，提供伺服器 B 的 SSH 資訊後，腳本會自動部署 A/B 兩端，
不包含 Web UI。

## 功能

- 在 A/B 兩端安裝 WireGuard 工具、Phantun 和必要依賴。
- 在 A/B 兩端產生或重用 WireGuard 金鑰。
- 在 A 啟動 `phantun_client`，在 B 啟動 `phantun_server`。
- 寫入 WireGuard 和 Phantun 的 systemd 服務。
- 寫入帶有 `wg-phantun-*` 註解的受控 iptables NAT/FORWARD 規則。
- 修改系統前列印部署計畫。
- 部署時顯示分階段進度。
- 測試 A -> B TCP 可達性、A -> B WireGuard ping、B -> A WireGuard ping
  和 WireGuard 最新握手時間。
- 內建診斷、清理、iperf3 測速和 MTU 調校。

## 拓撲

```text
伺服器 A wgpt0 10.66.66.1
  -> 127.0.0.1:51820/udp
  -> A phantun_client
  -> B_PUBLIC_IP:4567/fake-tcp
  -> B phantun_server
  -> 127.0.0.1:51820/udp
  -> 伺服器 B wgpt0 10.66.66.2
```

預設值：

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

- 兩台 Linux 伺服器，使用 systemd。
- 伺服器 A 上需要 root。
- 伺服器 B 支援 root SSH，或 B 使用者可執行免密碼 `sudo -n`。
- 伺服器 A 必須能 SSH 到伺服器 B。
- B 的雲端防火牆/安全群組必須放行 fake TCP 連接埠，預設 `TCP 4567`。

這個隧道透過 Phantun 承載 WireGuard，公開的 WireGuard UDP 連接埠不需要開放。

## 快速開始

在伺服器 A 上：

```bash
curl -fsSLO https://raw.githubusercontent.com/endview/wg-over-phantun-tools/main/wg-phantun-tunnel.sh
chmod +x wg-phantun-tunnel.sh
sudo bash wg-phantun-tunnel.sh
```

腳本會詢問 B 的 SSH 主機、使用者、連接埠、可選密碼和可選公開入口。正式修改系統前，
會先列印部署計畫。

非互動示例：

```bash
export B_PASS='your-ssh-password'
sudo -E bash wg-phantun-tunnel.sh \
  --b-ssh root@203.0.113.10:22 \
  --b-endpoint 203.0.113.10 \
  --b-password-env B_PASS \
  --phantun-port 4567 \
  --yes
```

只預覽，不修改 A/B：

```bash
bash wg-phantun-tunnel.sh \
  --dry-run \
  --b-ssh root@203.0.113.10:22 \
  --b-endpoint 203.0.113.10 \
  --yes
```

## 常用命令

查看狀態：

```bash
sudo bash wg-phantun-tunnel.sh --status --b-ssh root@203.0.113.10
```

輸出診斷：

```bash
sudo bash wg-phantun-tunnel.sh --diagnose --b-ssh root@203.0.113.10
```

透過隧道跑 iperf3：

```bash
sudo bash wg-phantun-tunnel.sh --speed-test --b-ssh root@203.0.113.10
```

測試常見 MTU 並可選擇套用推薦值：

```bash
sudo bash wg-phantun-tunnel.sh --tune-mtu --b-ssh root@203.0.113.10
```

清理腳本產生的服務和設定：

```bash
sudo bash wg-phantun-tunnel.sh --cleanup --b-ssh root@203.0.113.10 --yes
```

本機自測：

```bash
bash wg-phantun-tunnel.sh --self-test
```

## 重要參數

```text
--b-ssh <user@host[:port]>  B SSH 目標快捷寫法
--b-endpoint <host>         A 存取 B 的公開 IPv4/網域
--b-password-env <name>     從環境變數讀取 B SSH 密碼
--sudo                      在 B 上使用免密碼 sudo，而不是 root
--mtu <mtu>                 WireGuard MTU，預設 1280
--phantun-port <port>       B Phantun fake-TCP 連接埠，預設 4567
--copy-phantun              部署前從 A 複製 Phantun 到 B，預設開啟
--no-copy-phantun           讓 B 自行下載 Phantun
--speed-test                透過隧道執行 iperf3 測速
--tune-mtu                  測試常見 MTU 並給出推薦值
--cleanup                   刪除產生的服務和設定
--diagnose                  輸出詳細診斷
--dry-run                   驗證參數並列印計畫，不改系統
--yes                       跳過確認
```

## 注意事項

- Phantun 不是 TLS/HTTPS，不能放在 Nginx、Cloudflare 等七層 HTTP 代理後面。
- 腳本裡的 Phantun 資料通道是 IPv4-only。B 的 SSH 可以使用 IPv6，
  但 `--b-endpoint` 必須是 IPv4 或解析到 IPv4 的網域。
- 覆蓋 `/etc/wireguard/<iface>.conf` 前，腳本會自動備份原檔案。
- 預設會把 Phantun 從 A 複製到 B，以降低 B 存取 GitHub 失敗的問題。
  如果希望 B 自行下載，可以使用 `--no-copy-phantun`。
- 建議使用 `--b-password-env`，避免把密碼留在 shell 歷史中。

## 授權

MIT
