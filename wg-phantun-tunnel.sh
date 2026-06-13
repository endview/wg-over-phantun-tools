#!/usr/bin/env bash
#
# wg-phantun-tunnel.sh
#
# Run this script on server A. It connects to server B over SSH and deploys:
#   A WireGuard -> local Phantun client -> B Phantun server -> B WireGuard
#
# The result is a point-to-point WireGuard tunnel carried over Phantun fake TCP.

set -euo pipefail

SCRIPT_VERSION="0.15.0"
PHANTUN_VERSION_DEFAULT="v0.8.1"

IFACE="wgpt0"
A_WG_IP="10.66.66.1"
B_WG_IP="10.66.66.2"
WG_PORT="51820"
PHANTUN_TCP_PORT="4567"
PHANTUN_CLIENT_UDP_PORT="51820"
WG_MTU="1280"
PHANTUN_VERSION="$PHANTUN_VERSION_DEFAULT"
GITHUB_MIRROR_ARG="${GITHUB_MIRROR:-}"

B_HOST=""
B_USER="root"
B_SSH_PORT="22"
B_PASSWORD=""
B_PASSWORD_ENV=""
B_ENDPOINT_HOST=""
USE_SUDO="n"
A_OUTER_IFACE=""
B_OUTER_IFACE=""
YES="n"
MODE="deploy"
KEEP_KEYS="y"
AUTO_COPY_PHANTUN="y"
DEPLOY_STEP=0
DEPLOY_TOTAL=12

INSTALL_DIR="/usr/local/bin"
STATE_ROOT="/etc/wg-phantun"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[0;36m'
NC=$'\033[0m'
if [[ ! -t 1 ]]; then
    RED=""; GREEN=""; YELLOW=""; CYAN=""; NC=""
fi

info() { echo "${CYAN}[INFO]${NC} $*"; }
ok() { echo "${GREEN}[OK]${NC} $*"; }
warn() { echo "${YELLOW}[WARN]${NC} $*"; }
err() { echo "${RED}[ERROR]${NC} $*" >&2; }
die() { err "$*"; exit 1; }

phase() {
    DEPLOY_STEP=$((DEPLOY_STEP + 1))
    info "[$DEPLOY_STEP/$DEPLOY_TOTAL] $*"
}

next_step_ssh_target() {
    if [[ -n "${B_HOST:-}" ]]; then
        ssh_target
    else
        echo "<user@B_HOST>"
    fi
}

die_with_next_steps() {
    err "$*"
    echo >&2
    echo "Next steps:" >&2
    echo "  sudo bash $0 --diagnose --b-ssh $(next_step_ssh_target)" >&2
    echo "  sudo bash $0 --cleanup --b-ssh $(next_step_ssh_target) --yes" >&2
    exit 1
}

usage() {
    cat <<EOF_USAGE
wg-phantun-tunnel.sh ${SCRIPT_VERSION}

Run on server A. The script SSHes into server B, deploys WireGuard plus
Phantun on both servers, then tests connectivity.

Usage:
  sudo bash wg-phantun-tunnel.sh
  sudo bash wg-phantun-tunnel.sh --b-host 203.0.113.10 --b-user root
  sudo bash wg-phantun-tunnel.sh --b-ssh root@203.0.113.10:22 --yes
  sudo bash wg-phantun-tunnel.sh --status [--b-ssh root@203.0.113.10]
  sudo bash wg-phantun-tunnel.sh --diagnose [--b-ssh root@203.0.113.10]
  sudo bash wg-phantun-tunnel.sh --cleanup [--b-ssh root@203.0.113.10] --yes
  sudo bash wg-phantun-tunnel.sh --speed-test --b-ssh root@203.0.113.10
  sudo bash wg-phantun-tunnel.sh --tune-mtu --b-ssh root@203.0.113.10
  bash wg-phantun-tunnel.sh --dry-run --b-ssh root@203.0.113.10 --yes
  bash wg-phantun-tunnel.sh --check-download
  bash wg-phantun-tunnel.sh --self-test

Required in non-interactive mode:
  --b-host <host>             B server SSH host/IP
  --b-user <user>             B server SSH user, default: root
  --b-ssh <user@host[:port]>  Shortcut for B SSH target

Common options:
  --iface <name>              WireGuard interface, default: ${IFACE}
  --a-ip <ip>                 A WireGuard IP, default: ${A_WG_IP}
  --b-ip <ip>                 B WireGuard IP, default: ${B_WG_IP}
  --wg-port <port>            B WireGuard UDP listen port, default: ${WG_PORT}
  --phantun-port <port>       B Phantun fake-TCP listen port, default: ${PHANTUN_TCP_PORT}
  --local-port <port>         A local UDP port for Phantun client, default: ${PHANTUN_CLIENT_UDP_PORT}
  --mtu <mtu>                 WireGuard MTU, default: ${WG_MTU}
  --b-endpoint <host>         Public IPv4/domain for A to reach B; auto-detected when omitted
  --b-ssh-port <port>         B SSH port, default: ${B_SSH_PORT}
  --b-password <password>     B SSH password; prefer --b-password-env
  --b-password-env <name>     Read B SSH password from environment variable
  --sudo                      Use passwordless sudo on B instead of logging in as root
  --a-outer-iface <name>      A outbound NIC for Phantun NAT; auto-detected by default
  --b-outer-iface <name>      B outbound NIC for Phantun DNAT; auto-detected by default
  --phantun-version <version> Phantun release tag, default: ${PHANTUN_VERSION_DEFAULT}
  --github-mirror <url>       Optional GitHub mirror prefix for Phantun download
  --copy-phantun              Copy Phantun from A to B before deploy, default
  --no-copy-phantun           Let B download Phantun itself
  --status                    Show local status; also shows B status when B SSH is provided
  --diagnose                  Print detailed local diagnostics; also checks B when SSH is provided
  --cleanup                   Remove generated services/configs; also cleans B when B SSH is provided
  --speed-test                Run iperf3 tests over the WireGuard tunnel
  --tune-mtu                  Test common MTU values and print a recommendation
  --dry-run                   Validate inputs and print planned changes without touching A/B
  --check-download            Download and verify Phantun archive without installing it
  --self-test                 Run local syntax and parser checks without touching the system
  --keep-keys                 Keep WireGuard key files during cleanup, default
  --remove-keys               Remove WireGuard key files during cleanup
  -y, --yes                   Do not prompt; use SSH key auth unless a password option is set
  -h, --help                  Show this help

Environment:
  GITHUB_MIRROR               Optional GitHub mirror prefix, for example https://ghproxy.net

Notes:
  - Existing /etc/wireguard/<iface>.conf is backed up before overwrite.
  - Cloud/provider firewalls must allow B's TCP --phantun-port.
  - B's WireGuard UDP port is used locally by Phantun; close it externally if desired.
EOF_USAGE
}

need_root() {
    [[ "${EUID}" -eq 0 ]] || die "Run as root on server A: sudo bash $0"
}

has_cmd() {
    command -v "$1" >/dev/null 2>&1
}

need_cmd() {
    has_cmd "$1" || die "Missing command: $1"
}

require_value() {
    local opt=$1
    [[ $# -ge 2 && -n "${2:-}" && "${2:-}" != -* ]] || die "Missing value for ${opt}"
}

confirm_or_exit() {
    local question=$1 answer
    if [[ "$YES" == "y" ]]; then
        return 0
    fi
    read -r -p "${question} [y/N]: " answer
    [[ "$answer" == "y" || "$answer" == "Y" ]] || die "Cancelled."
}

ask_yes_no() {
    local question=$1 answer
    if [[ "$YES" == "y" ]]; then
        return 0
    fi
    read -r -p "${question} [y/N]: " answer
    [[ "$answer" == "y" || "$answer" == "Y" ]]
}

tcp_port_in_use() {
    local port=$1
    if has_cmd ss; then
        ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
    elif has_cmd netstat; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
    else
        return 1
    fi
}

udp_port_in_use() {
    local port=$1
    if has_cmd ss; then
        ss -H -lun 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
    elif has_cmd netstat; then
        netstat -lun 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
    else
        return 1
    fi
}

validate_iface() {
    local value=$1
    [[ "$value" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || die "Invalid interface name: $value"
}

validate_ipv4() {
    local value=$1 label=$2
    local a b c d
    IFS=. read -r a b c d <<<"$value"
    [[ -n "${a:-}" && -n "${b:-}" && -n "${c:-}" && -n "${d:-}" ]] || die "Invalid ${label}: ${value}"
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || die "Invalid ${label}: ${value}"
    (( a >= 1 && a <= 223 && b >= 0 && b <= 255 && c >= 0 && c <= 255 && d >= 1 && d <= 254 )) || die "Invalid ${label}: ${value}"
}

validate_port() {
    local value=$1 label=$2
    [[ "$value" =~ ^[0-9]+$ ]] || die "Invalid ${label}: ${value}"
    (( value >= 1 && value <= 65535 )) || die "Invalid ${label}: ${value}"
}

validate_mtu() {
    local value=$1
    [[ "$value" =~ ^[0-9]+$ ]] || die "Invalid MTU: $value"
    (( value >= 576 && value <= 9000 )) || die "Invalid MTU: $value"
}

validate_host() {
    local value=$1 label=$2
    [[ -n "$value" ]] || die "${label} cannot be empty"
    if [[ "$value" == \[*\] ]]; then
        [[ "$value" =~ ^\[[A-Fa-f0-9:.]+\]$ ]] || die "Invalid ${label}: use a hostname, IPv4, or IPv6 address only"
    else
        [[ "$value" =~ ^[A-Za-z0-9_.:-]+$ ]] || die "Invalid ${label}: use a hostname, IPv4, or IPv6 address only"
    fi
}

validate_ipv4_or_domain() {
    local value=$1 label=$2
    [[ -n "$value" ]] || die "${label} cannot be empty"
    [[ "$value" != \[*\]* && "$value" != *:* ]] || die "${label} must be an IPv4 address or domain name; IPv6 Phantun endpoint is not supported by this script."
    [[ "$value" =~ ^[A-Za-z0-9_.-]+$ ]] || die "Invalid ${label}: use an IPv4 address or domain name only"
    if is_ipv4_like "$value"; then
        validate_ipv4 "$value" "$label"
    fi
}

is_ipv4_literal() {
    local value=$1
    [[ "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

is_ipv4_like() {
    local value=$1
    [[ "$value" =~ ^[0-9]+(\.[0-9]+){3}$ ]]
}

is_non_public_ipv4() {
    local value=$1
    local a b c d
    is_ipv4_literal "$value" || return 1
    IFS=. read -r a b c d <<<"$value"
    [[ "$a" =~ ^[0-9]+$ && "$b" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ && "$d" =~ ^[0-9]+$ ]] || return 1
    (( a == 10 )) && return 0
    (( a == 127 )) && return 0
    (( a == 169 && b == 254 )) && return 0
    (( a == 172 && b >= 16 && b <= 31 )) && return 0
    (( a == 192 && b == 168 )) && return 0
    (( a == 100 && b >= 64 && b <= 127 )) && return 0
    (( a == 192 && b == 0 && c == 2 )) && return 0
    (( a == 198 && b == 51 && c == 100 )) && return 0
    (( a == 203 && b == 0 && c == 113 )) && return 0
    (( a == 0 )) && return 0
    (( a >= 224 )) && return 0
    return 1
}

warn_if_non_public_endpoint() {
    local value=$1
    if is_non_public_ipv4 "$value"; then
        warn "B endpoint ${value} is not a public IPv4 address. Use it only when A can route to that private/internal address."
    fi
}

validate_release_tag() {
    local value=$1
    [[ "$value" =~ ^[A-Za-z0-9._-]+$ ]] || die "Invalid Phantun release tag: $value"
}

validate_url_prefix() {
    local value=$1
    [[ -z "$value" ]] && return 0
    [[ "$value" != *[[:space:]]* ]] || die "Invalid GitHub mirror URL: contains whitespace"
    [[ "$value" != *"'"* && "$value" != *'"'* && "$value" != *";"* && "$value" != *'`'* ]] || die "Invalid GitHub mirror URL: unsafe character"
}

parse_b_ssh() {
    local target=$1
    local user_part host_part
    if [[ "$target" == *@* ]]; then
        user_part=${target%%@*}
        host_part=${target#*@}
        [[ -n "$user_part" ]] && B_USER="$user_part"
    else
        host_part=$target
    fi

    if [[ "$host_part" =~ ^\[([^]]+)\]:([0-9]+)$ ]]; then
        B_HOST="${BASH_REMATCH[1]}"
        B_SSH_PORT="${BASH_REMATCH[2]}"
    elif [[ "$host_part" =~ ^\[([^]]+)\]$ ]]; then
        B_HOST="${BASH_REMATCH[1]}"
    elif [[ "$host_part" =~ ^([^:]+):([0-9]+)$ ]]; then
        B_HOST="${BASH_REMATCH[1]}"
        B_SSH_PORT="${BASH_REMATCH[2]}"
    else
        B_HOST="$host_part"
    fi
}

format_host_port() {
    local host=$1 port=$2
    if [[ "$host" == \[*\] ]]; then
        printf '%s:%s' "$host" "$port"
    elif [[ "$host" == *:* ]]; then
        printf '[%s]:%s' "$host" "$port"
    else
        printf '%s:%s' "$host" "$port"
    fi
}

unbracket_host() {
    local host=$1
    if [[ "$host" =~ ^\[(.*)\]$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '%s' "$host"
    fi
}

tcp_probe_host_port() {
    local host=$1 port=$2 timeout=${3:-3}
    host=$(unbracket_host "$host")
    if has_cmd nc; then
        nc -z -w "$timeout" "$host" "$port" >/dev/null 2>&1
        return $?
    fi
    if has_cmd timeout; then
        timeout "$timeout" bash -c 'cat < /dev/null > /dev/tcp/$1/$2' _ "$host" "$port" >/dev/null 2>&1
        return $?
    fi
    return 2
}

safe_tun_name() {
    local prefix=$1 iface=$2 slug
    slug=$(printf '%s' "$iface" | tr -c 'A-Za-z0-9' '_' | cut -c1-10)
    printf '%s%s' "$prefix" "$slug" | cut -c1-15
}

detect_default_iface() {
    ip route show default 2>/dev/null | awk '/default/{print $5; exit}'
}

pkg_install() {
    local packages=("$@")
    if has_cmd apt-get; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
    elif has_cmd dnf; then
        dnf install -y "${packages[@]}"
    elif has_cmd yum; then
        yum install -y epel-release || true
        yum install -y "${packages[@]}"
    else
        die "Unsupported OS: install dependencies manually."
    fi
}

ensure_local_deps() {
    info "Checking local dependencies on server A..."
    need_cmd systemctl

    if ! has_cmd wg || ! has_cmd wg-quick || ! has_cmd curl || ! has_cmd unzip || ! has_cmd iptables || ! has_cmd ping || ! has_cmd ssh; then
        info "Installing local packages..."
        if has_cmd apt-get; then
            pkg_install wireguard-tools curl wget unzip iproute2 iptables iputils-ping ca-certificates openssh-client
        elif has_cmd dnf || has_cmd yum; then
            pkg_install wireguard-tools curl wget unzip iproute iptables iputils ca-certificates openssh-clients
        else
            die "Unsupported OS: install wireguard-tools, curl, unzip, iptables, iputils, and openssh-client manually."
        fi
    fi

    need_cmd wg
    need_cmd wg-quick
    need_cmd curl
    need_cmd unzip
    need_cmd ip
    need_cmd iptables
    need_cmd ping
    need_cmd ssh
    if ! has_cmd nc; then
        warn "nc/netcat is not installed; TCP port probes will fall back to bash /dev/tcp when available."
    fi
    if ! has_cmd setcap; then
        warn "setcap is not installed; Phantun will run as root without file capabilities."
    fi
    ok "Local dependency check passed."
}

precheck_local_ports() {
    info "Checking local ports on server A..."
    systemctl stop "$PHANTUN_CLIENT_SERVICE" >/dev/null 2>&1 || true
    if udp_port_in_use "$PHANTUN_CLIENT_UDP_PORT"; then
        die "A local UDP port ${PHANTUN_CLIENT_UDP_PORT} is already in use. Change --local-port."
    fi
    ok "Local port check passed."
}

print_deploy_plan() {
    local plan_mode=${1:-dry-run}
    wg_paths
    local endpoint
    endpoint=${B_ENDPOINT_HOST:-"<auto-detect on B>"}
    if [[ -n "$B_ENDPOINT_HOST" ]]; then
        warn_if_non_public_endpoint "$B_ENDPOINT_HOST"
    fi
    if [[ "$plan_mode" == "dry-run" ]]; then
        echo "wg-phantun-tunnel.sh ${SCRIPT_VERSION} dry run"
        echo
        echo "No system changes were made."
    else
        echo "wg-phantun-tunnel.sh ${SCRIPT_VERSION} deployment plan"
        echo
        echo "No system changes have been made yet."
    fi
    cat <<EOF_PLAN

Server A:
  WireGuard interface: ${IFACE}
  WireGuard IP:        ${A_WG_IP}/24
  WireGuard MTU:       ${WG_MTU}
  Local UDP endpoint:  127.0.0.1:${PHANTUN_CLIENT_UDP_PORT}
  Outbound NIC:        ${A_OUTER_IFACE:-<auto-detect during deploy>}
  Services:            ${PHANTUN_CLIENT_SERVICE}, ${WG_SERVICE}
  Config paths:         ${WG_CONF}, ${LOCAL_STATE_DIR}

Server B:
  SSH target:           $(next_step_ssh_target)
  SSH port:             ${B_SSH_PORT}
  Use sudo:             ${USE_SUDO}
  WireGuard IP:         ${B_WG_IP}/24
  WireGuard MTU:        ${WG_MTU}
  WireGuard UDP port:   ${WG_PORT}
  Phantun TCP port:     ${PHANTUN_TCP_PORT}
  Public endpoint:      ${endpoint}
  Outbound NIC:         ${B_OUTER_IFACE:-<auto-detect during deploy>}
  Services:             wg-phantun-server-${IFACE}.service, ${WG_SERVICE}

Tunnel:
  A wg ${A_WG_IP} -> 127.0.0.1:${PHANTUN_CLIENT_UDP_PORT}/udp
  A phantun_client -> $(format_host_port "$endpoint" "$PHANTUN_TCP_PORT")/fake-tcp
  B phantun_server -> 127.0.0.1:${WG_PORT}/udp
  B wg ${B_WG_IP}

Deployment will:
  - install WireGuard tools, Phantun, and helper packages on A and B
  - copy Phantun from A to B when B does not already have the binaries
  - generate or reuse WireGuard key pairs on A and B
  - write /etc/wireguard/${IFACE}.conf on both servers, backing up existing files
  - create systemd services and managed iptables NAT/FORWARD rules
  - test A -> B TCP reachability, A -> B WG ping, B -> A WG ping, and handshake freshness
EOF_PLAN
}

ensure_sshpass_if_needed() {
    [[ -n "$B_PASSWORD" ]] || return 0
    if has_cmd sshpass; then
        return 0
    fi
    info "Installing sshpass for password SSH login..."
    if has_cmd apt-get; then
        pkg_install sshpass
    elif has_cmd dnf || has_cmd yum; then
        pkg_install sshpass
    else
        die "sshpass is required for password login."
    fi
}

detect_arch_target() {
    case "$(uname -m)" in
        x86_64|amd64) echo "x86_64-unknown-linux-gnu" ;;
        aarch64|arm64) echo "aarch64-unknown-linux-gnu" ;;
        i386|i686) echo "i686-unknown-linux-gnu" ;;
        arm|armv6l|armv6*) echo "arm-unknown-linux-gnueabihf" ;;
        armv7l|armv7*) echo "armv7-unknown-linux-gnueabihf" ;;
        *) return 1 ;;
    esac
}

download_file() {
    local url=$1 dest=$2
    if has_cmd curl; then
        curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 -o "$dest" "$url"
    elif has_cmd wget; then
        wget -O "$dest" "$url"
    elif has_cmd python3 || has_cmd python; then
        local py
        py=$(command -v python3 2>/dev/null || command -v python 2>/dev/null)
        "$py" - "$url" "$dest" <<'PY_DOWNLOAD'
import shutil
import sys
import urllib.request

url, dest = sys.argv[1], sys.argv[2]
with urllib.request.urlopen(url, timeout=30) as response, open(dest, "wb") as output:
    shutil.copyfileobj(response, output)
PY_DOWNLOAD
    else
        die "Need curl, wget, python3, or python to download Phantun."
    fi
}

phantun_download_url() {
    local arch=$1 base
    base="https://github.com"
    if [[ -n "${GITHUB_MIRROR_ARG:-}" ]]; then
        base="${GITHUB_MIRROR_ARG%/}/https://github.com"
    fi
    printf '%s/dndx/phantun/releases/download/%s/phantun_%s.zip' "$base" "$PHANTUN_VERSION" "$arch"
}

verify_phantun_archive() {
    local zip=$1
    local listing py
    if has_cmd unzip; then
        listing=$(unzip -Z1 "$zip" 2>/dev/null || unzip -l "$zip")
    else
        py=$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)
        [[ -n "$py" ]] || die "Need unzip or python3/python to inspect the Phantun archive."
        listing=$("$py" - "$zip" <<'PY_ZIP_LIST'
import sys
import zipfile

with zipfile.ZipFile(sys.argv[1]) as zf:
    for name in zf.namelist():
        print(name)
PY_ZIP_LIST
)
    fi
    grep -Eq '(^|[[:space:]/])phantun_client([[:space:]]|$)' <<<"$listing" || die "Phantun archive does not contain phantun_client."
    grep -Eq '(^|[[:space:]/])phantun_server([[:space:]]|$)' <<<"$listing" || die "Phantun archive does not contain phantun_server."
}

find_extracted_phantun_binary() {
    local root=$1 name=$2 found
    found=$(find "$root" -type f -name "$name" -print -quit)
    [[ -n "$found" ]] || die "Cannot find ${name} after extracting Phantun archive."
    printf '%s\n' "$found"
}

check_phantun_download() {
    local arch url tmpdir
    arch=$(detect_arch_target) || die "Unsupported architecture for Phantun: $(uname -m)"
    url=$(phantun_download_url "$arch")
    info "Checking Phantun download: ${url}"
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN
    download_file "$url" "$tmpdir/phantun.zip"
    verify_phantun_archive "$tmpdir/phantun.zip"
    ok "Phantun ${PHANTUN_VERSION} archive looks usable for ${arch}."
    rm -rf "$tmpdir"
    trap - RETURN
}

install_phantun() {
    local arch url tmpdir phantun_server_path phantun_client_path
    if [[ -x "${INSTALL_DIR}/phantun_client" && -x "${INSTALL_DIR}/phantun_server" ]]; then
        ok "Phantun already installed on server A."
        return 0
    fi
    arch=$(detect_arch_target) || die "Unsupported architecture for Phantun: $(uname -m)"
    url=$(phantun_download_url "$arch")

    info "Installing Phantun ${PHANTUN_VERSION} on server A (${arch})..."
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN
    download_file "$url" "$tmpdir/phantun.zip"
    verify_phantun_archive "$tmpdir/phantun.zip"
    unzip -o "$tmpdir/phantun.zip" -d "$tmpdir/phantun" >/dev/null
    install -m 0755 "$(find_extracted_phantun_binary "$tmpdir/phantun" phantun_server)" "${INSTALL_DIR}/phantun_server"
    install -m 0755 "$(find_extracted_phantun_binary "$tmpdir/phantun" phantun_client)" "${INSTALL_DIR}/phantun_client"
    if has_cmd setcap; then
        setcap cap_net_admin=+pe "${INSTALL_DIR}/phantun_server" || true
        setcap cap_net_admin=+pe "${INSTALL_DIR}/phantun_client" || true
    fi
    rm -rf "$tmpdir"
    trap - RETURN
    ok "Phantun installed on server A."
}

enable_ipv4_forwarding() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    mkdir -p /etc/sysctl.d
    cat >/etc/sysctl.d/99-wg-phantun.conf <<'EOF_SYSCTL'
net.ipv4.ip_forward=1
EOF_SYSCTL
}

wg_paths() {
    WG_CONF="/etc/wireguard/${IFACE}.conf"
    WG_PRIVATE_KEY_FILE="/etc/wireguard/${IFACE}_privatekey"
    WG_PUBLIC_KEY_FILE="/etc/wireguard/${IFACE}_publickey"
    WG_SERVICE="wg-quick@${IFACE}.service"
    PHANTUN_CLIENT_SERVICE="wg-phantun-client-${IFACE}.service"
    LOCAL_STATE_DIR="${STATE_ROOT}/${IFACE}"
}

backup_if_exists() {
    local file=$1
    if [[ -f "$file" ]]; then
        cp -a "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)"
        warn "Backed up existing file: $file"
    fi
}

generate_local_wg_key() {
    umask 077
    mkdir -p /etc/wireguard
    if [[ ! -f "$WG_PRIVATE_KEY_FILE" ]]; then
        wg genkey | tee "$WG_PRIVATE_KEY_FILE" | wg pubkey >"$WG_PUBLIC_KEY_FILE"
        chmod 600 "$WG_PRIVATE_KEY_FILE" "$WG_PUBLIC_KEY_FILE"
        ok "Generated A WireGuard key pair."
    else
        ok "Reusing existing A WireGuard key pair."
    fi
    A_PRIVATE_KEY=$(<"$WG_PRIVATE_KEY_FILE")
    A_PUBLIC_KEY=$(<"$WG_PUBLIC_KEY_FILE")
}

write_local_wireguard_config() {
    local b_public_key=$1
    backup_if_exists "$WG_CONF"
    cat >"$WG_CONF" <<EOF_WG_A
[Interface]
# Generated by wg-phantun-tunnel.sh on server A
PrivateKey = ${A_PRIVATE_KEY}
Address = ${A_WG_IP}/24
MTU = ${WG_MTU}

[Peer]
PublicKey = ${b_public_key}
AllowedIPs = ${B_WG_IP}/32
Endpoint = 127.0.0.1:${PHANTUN_CLIENT_UDP_PORT}
PersistentKeepalive = 25
EOF_WG_A
    chmod 600 "$WG_CONF"
}

ensure_service_active() {
    local service=$1
    sleep 1
    if ! systemctl is-active --quiet "$service"; then
        systemctl status "$service" --no-pager -l || true
        die "Service ${service} is not active."
    fi
}

write_local_phantun_client_service() {
    local remote_host=$1
    local outer_iface=$2
    local tun_name tun_local tun_peer remote
    tun_name=$(safe_tun_name "ptnc_" "$IFACE")
    tun_local="172.30.111.1"
    tun_peer="172.30.111.2"
    remote_host=$(unbracket_host "$remote_host")
    remote=$(format_host_port "$remote_host" "$PHANTUN_TCP_PORT")

    mkdir -p "$LOCAL_STATE_DIR"
    cat >"${LOCAL_STATE_DIR}/phantun-client-iptables-up.sh" <<EOF_UP
#!/usr/bin/env bash
while iptables -w -t nat -D POSTROUTING -s ${tun_local}/24 -o ${outer_iface} -j MASQUERADE -m comment --comment wg-phantun-client-${IFACE} 2>/dev/null; do :; done
while iptables -w -D FORWARD -i ${tun_name} -o ${outer_iface} -s ${tun_peer}/32 -m comment --comment wg-phantun-client-${IFACE} -j ACCEPT 2>/dev/null; do :; done
while iptables -w -D FORWARD -i ${outer_iface} -o ${tun_name} -d ${tun_peer}/32 -m comment --comment wg-phantun-client-${IFACE} -j ACCEPT 2>/dev/null; do :; done
iptables -w -t nat -A POSTROUTING -s ${tun_local}/24 -o ${outer_iface} -j MASQUERADE -m comment --comment wg-phantun-client-${IFACE}
iptables -w -I FORWARD 1 -i ${tun_name} -o ${outer_iface} -s ${tun_peer}/32 -m comment --comment wg-phantun-client-${IFACE} -j ACCEPT
iptables -w -I FORWARD 1 -i ${outer_iface} -o ${tun_name} -d ${tun_peer}/32 -m comment --comment wg-phantun-client-${IFACE} -j ACCEPT
EOF_UP
    chmod +x "${LOCAL_STATE_DIR}/phantun-client-iptables-up.sh"

    cat >"${LOCAL_STATE_DIR}/phantun-client-iptables-down.sh" <<EOF_DOWN
#!/usr/bin/env bash
while iptables -w -t nat -D POSTROUTING -s ${tun_local}/24 -o ${outer_iface} -j MASQUERADE -m comment --comment wg-phantun-client-${IFACE} 2>/dev/null; do :; done
while iptables -w -D FORWARD -i ${tun_name} -o ${outer_iface} -s ${tun_peer}/32 -m comment --comment wg-phantun-client-${IFACE} -j ACCEPT 2>/dev/null; do :; done
while iptables -w -D FORWARD -i ${outer_iface} -o ${tun_name} -d ${tun_peer}/32 -m comment --comment wg-phantun-client-${IFACE} -j ACCEPT 2>/dev/null; do :; done
EOF_DOWN
    chmod +x "${LOCAL_STATE_DIR}/phantun-client-iptables-down.sh"

    cat >"/etc/systemd/system/${PHANTUN_CLIENT_SERVICE}" <<EOF_SERVICE
[Unit]
Description=Phantun client for ${IFACE} WireGuard tunnel
After=network-online.target
Wants=network-online.target
Before=${WG_SERVICE}

[Service]
Type=simple
Environment=RUST_LOG=warn
ExecStartPre=${LOCAL_STATE_DIR}/phantun-client-iptables-up.sh
ExecStart=${INSTALL_DIR}/phantun_client --local 127.0.0.1:${PHANTUN_CLIENT_UDP_PORT} --remote ${remote} --tun ${tun_name} --tun-local ${tun_local} --tun-peer ${tun_peer} -4
ExecStopPost=${LOCAL_STATE_DIR}/phantun-client-iptables-down.sh
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF_SERVICE
}

start_local_services() {
    info "Starting Phantun client and WireGuard on server A..."
    systemctl daemon-reload
    systemctl enable "$PHANTUN_CLIENT_SERVICE" >/dev/null
    systemctl restart "$PHANTUN_CLIENT_SERVICE"
    ensure_service_active "$PHANTUN_CLIENT_SERVICE"

    systemctl stop "$WG_SERVICE" >/dev/null 2>&1 || true
    wg-quick down "$IFACE" >/dev/null 2>&1 || true
    systemctl enable "$WG_SERVICE" >/dev/null
    systemctl restart "$WG_SERVICE"
    ensure_service_active "$WG_SERVICE"
    ok "Server A services are running."
}

print_local_diagnostics() {
    warn "Local diagnostics:"
    systemctl status "$PHANTUN_CLIENT_SERVICE" --no-pager -l || true
    systemctl status "$WG_SERVICE" --no-pager -l || true
    journalctl -u "$PHANTUN_CLIENT_SERVICE" -n 80 --no-pager || true
    journalctl -u "$WG_SERVICE" -n 80 --no-pager || true
    wg show "$IFACE" || true
    ip route || true
    echo "----- next steps -----"
    echo "sudo bash $0 --diagnose --b-ssh $(next_step_ssh_target)"
    echo "sudo bash $0 --cleanup --b-ssh $(next_step_ssh_target) --yes"
}

status_local() {
    wg_paths
    echo "== Server A local status =="
    echo "Interface: ${IFACE}"
    systemctl is-active "$PHANTUN_CLIENT_SERVICE" >/dev/null 2>&1 && echo "Phantun client: active" || echo "Phantun client: inactive"
    systemctl is-active "$WG_SERVICE" >/dev/null 2>&1 && echo "WireGuard: active" || echo "WireGuard: inactive"
    echo
    systemctl status "$PHANTUN_CLIENT_SERVICE" --no-pager -l 2>/dev/null || true
    echo
    systemctl status "$WG_SERVICE" --no-pager -l 2>/dev/null || true
    echo
    wg show "$IFACE" 2>/dev/null || true
}

cleanup_local() {
    wg_paths
    confirm_or_exit "Remove local A services/config for ${IFACE}?"
    info "Cleaning local A services/config for ${IFACE}..."
    systemctl disable --now "$PHANTUN_CLIENT_SERVICE" >/dev/null 2>&1 || true
    systemctl disable --now "$WG_SERVICE" >/dev/null 2>&1 || true
    wg-quick down "$IFACE" >/dev/null 2>&1 || true
    if [[ -x "${LOCAL_STATE_DIR}/phantun-client-iptables-down.sh" ]]; then
        "${LOCAL_STATE_DIR}/phantun-client-iptables-down.sh" || true
    fi
    rm -f "/etc/systemd/system/${PHANTUN_CLIENT_SERVICE}"
    rm -rf "$LOCAL_STATE_DIR"
    rm -f "$WG_CONF"
    if [[ "$KEEP_KEYS" != "y" ]]; then
        rm -f "$WG_PRIVATE_KEY_FILE" "$WG_PUBLIC_KEY_FILE"
    fi
    systemctl daemon-reload >/dev/null 2>&1 || true
    ok "Local A cleanup finished."
}

ssh_target() {
    if [[ "$B_HOST" == \[*\] ]]; then
        printf '%s@%s' "$B_USER" "$B_HOST"
    elif [[ "$B_HOST" == *:* ]]; then
        printf '%s@[%s]' "$B_USER" "$B_HOST"
    else
        printf '%s@%s' "$B_USER" "$B_HOST"
    fi
}

build_ssh_base() {
    SSH_BASE=(ssh -p "$B_SSH_PORT" -o ConnectTimeout=12 -o ServerAliveInterval=10 -o ServerAliveCountMax=2 -o StrictHostKeyChecking=accept-new)
    if [[ -n "$B_PASSWORD" ]]; then
        SSH_BASE=(sshpass -e "${SSH_BASE[@]}")
    else
        SSH_BASE+=(-o BatchMode=yes)
    fi
}

remote_runner_args() {
    if [[ "$USE_SUDO" == "y" ]]; then
        REMOTE_RUNNER=(sudo -n bash -s -- "$@")
    else
        REMOTE_RUNNER=(bash -s -- "$@")
    fi
}

ssh_exec_plain() {
    local command=$1
    build_ssh_base
    if [[ -n "$B_PASSWORD" ]]; then
        SSHPASS="$B_PASSWORD" "${SSH_BASE[@]}" "$(ssh_target)" "$command"
    else
        "${SSH_BASE[@]}" "$(ssh_target)" "$command"
    fi
}

precheck_ssh() {
    info "Checking SSH access to server B..."
    if ! ssh_exec_plain "echo SSH_OK" >/dev/null 2>&1; then
        die "Cannot SSH to server B. Check host/user/port/password/key."
    fi
    ok "SSH access to server B works."
}

precheck_remote_privilege() {
    [[ "$USE_SUDO" == "y" ]] || return 0
    info "Checking passwordless sudo on server B..."
    if ! ssh_exec_plain "sudo -n true" >/dev/null 2>&1; then
        die "Server B user ${B_USER} cannot run passwordless sudo. Use root, configure NOPASSWD sudo, or omit --sudo."
    fi
    ok "Passwordless sudo on server B works."
}

copy_phantun_to_remote_b() {
    [[ "$AUTO_COPY_PHANTUN" == "y" ]] || return 0
    [[ -x "${INSTALL_DIR}/phantun_client" && -x "${INSTALL_DIR}/phantun_server" ]] || die "Local Phantun binaries are missing; cannot copy them to server B."

    info "Ensuring Phantun binaries are available on server B..."
    if remote_simple_cmd "test -x '${INSTALL_DIR}/phantun_client' && test -x '${INSTALL_DIR}/phantun_server'" >/dev/null 2>&1; then
        ok "Phantun already exists on server B."
        return 0
    fi

    need_cmd tar
    build_ssh_base
    local remote_cmd
    if [[ "$USE_SUDO" == "y" ]]; then
        remote_cmd='tmp=$(mktemp -d); tar -xzf - -C "$tmp"; sudo -n install -m 0755 "$tmp/phantun_client" /usr/local/bin/phantun_client; sudo -n install -m 0755 "$tmp/phantun_server" /usr/local/bin/phantun_server; rm -rf "$tmp"'
    else
        remote_cmd='mkdir -p /usr/local/bin; tar -xzf - -C /usr/local/bin; chmod 0755 /usr/local/bin/phantun_client /usr/local/bin/phantun_server'
    fi

    set +e
    if [[ -n "$B_PASSWORD" ]]; then
        export SSHPASS="$B_PASSWORD"
    fi
    tar -C "$INSTALL_DIR" -czf - phantun_client phantun_server | "${SSH_BASE[@]}" "$(ssh_target)" "$remote_cmd"
    local rc=$?
    if [[ -n "$B_PASSWORD" ]]; then
        unset SSHPASS
    fi
    set -e
    [[ "$rc" -eq 0 ]] || die "Could not copy Phantun binaries from A to server B."
    ok "Copied Phantun binaries from A to server B."
}

deploy_remote_b() {
    local output rc
    info "Deploying WireGuard and Phantun on server B..."
    build_ssh_base
    remote_runner_args \
        "$IFACE" "$A_WG_IP" "$B_WG_IP" "$WG_PORT" "$PHANTUN_TCP_PORT" \
        "$A_PUBLIC_KEY" "$PHANTUN_VERSION" "$B_ENDPOINT_HOST" "$WG_MTU" "$B_OUTER_IFACE" "$GITHUB_MIRROR_ARG"

    set +e
    if [[ -n "$B_PASSWORD" ]]; then
        export SSHPASS="$B_PASSWORD"
    fi
    output=$("${SSH_BASE[@]}" "$(ssh_target)" "${REMOTE_RUNNER[@]}" 2>&1 <<'REMOTE_B_SETUP'
set -euo pipefail

IFACE=$1
A_WG_IP=$2
B_WG_IP=$3
WG_PORT=$4
PHANTUN_TCP_PORT=$5
A_PUBLIC_KEY=$6
PHANTUN_VERSION=$7
B_ENDPOINT_HOST=$8
WG_MTU=$9
B_OUTER_IFACE=${10:-}
GITHUB_MIRROR=${11:-}

INSTALL_DIR="/usr/local/bin"
STATE_ROOT="/etc/wg-phantun"

info() { echo "[B INFO] $*"; }
ok() { echo "[B OK] $*"; }
warn() { echo "[B WARN] $*"; }
die() { echo "[B ERROR] $*" >&2; exit 1; }
has_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_default_iface() {
    ip route show default 2>/dev/null | awk '/default/{print $5; exit}'
}

detect_arch_target() {
    case "$(uname -m)" in
        x86_64|amd64) echo "x86_64-unknown-linux-gnu" ;;
        aarch64|arm64) echo "aarch64-unknown-linux-gnu" ;;
        i386|i686) echo "i686-unknown-linux-gnu" ;;
        arm|armv6l|armv6*) echo "arm-unknown-linux-gnueabihf" ;;
        armv7l|armv7*) echo "armv7-unknown-linux-gnueabihf" ;;
        *) return 1 ;;
    esac
}

pkg_install() {
    local packages=("$@")
    if has_cmd apt-get; then
        DEBIAN_FRONTEND=noninteractive apt-get update -qq
        DEBIAN_FRONTEND=noninteractive apt-get install -y "${packages[@]}"
    elif has_cmd dnf; then
        dnf install -y "${packages[@]}"
    elif has_cmd yum; then
        yum install -y epel-release || true
        yum install -y "${packages[@]}"
    else
        die "Unsupported OS: install dependencies manually."
    fi
}

ensure_deps() {
    has_cmd systemctl || die "systemctl is required on server B."
    if ! has_cmd wg || ! has_cmd wg-quick || ! has_cmd curl || ! has_cmd unzip || ! has_cmd iptables || ! has_cmd ping; then
        info "Installing packages..."
        if has_cmd apt-get; then
            pkg_install wireguard-tools curl wget unzip iproute2 iptables iputils-ping ca-certificates
        elif has_cmd dnf || has_cmd yum; then
            pkg_install wireguard-tools curl wget unzip iproute iptables iputils ca-certificates
        else
            die "Unsupported OS: install wireguard-tools, curl, unzip, iptables, and iputils manually."
        fi
    fi
    has_cmd setcap || warn "setcap is not installed; Phantun will run as root without file capabilities."
}

tcp_port_in_use() {
    local port=$1
    if has_cmd ss; then
        ss -H -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
    elif has_cmd netstat; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
    else
        return 1
    fi
}

udp_port_in_use() {
    local port=$1
    if has_cmd ss; then
        ss -H -lun 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
    elif has_cmd netstat; then
        netstat -lun 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
    else
        return 1
    fi
}

install_phantun() {
    local arch url tmpdir listing
    if [[ -x "${INSTALL_DIR}/phantun_client" && -x "${INSTALL_DIR}/phantun_server" ]]; then
        ok "Phantun already installed."
        return 0
    fi
    arch=$(detect_arch_target) || die "Unsupported architecture for Phantun: $(uname -m)"
    if [[ -n "${GITHUB_MIRROR:-}" ]]; then
        url="${GITHUB_MIRROR%/}/https://github.com/dndx/phantun/releases/download/${PHANTUN_VERSION}/phantun_${arch}.zip"
    else
        url="https://github.com/dndx/phantun/releases/download/${PHANTUN_VERSION}/phantun_${arch}.zip"
    fi
    info "Installing Phantun ${PHANTUN_VERSION} (${arch})..."
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' RETURN
    if has_cmd curl; then
        curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 10 -o "$tmpdir/phantun.zip" "$url"
    elif has_cmd wget; then
        wget -O "$tmpdir/phantun.zip" "$url"
    else
        die "Need curl or wget to download Phantun."
    fi
    listing=$(unzip -Z1 "$tmpdir/phantun.zip" 2>/dev/null || unzip -l "$tmpdir/phantun.zip")
    grep -Eq '(^|[[:space:]/])phantun_client([[:space:]]|$)' <<<"$listing" || die "Phantun archive does not contain phantun_client."
    grep -Eq '(^|[[:space:]/])phantun_server([[:space:]]|$)' <<<"$listing" || die "Phantun archive does not contain phantun_server."
    unzip -o "$tmpdir/phantun.zip" -d "$tmpdir/phantun" >/dev/null
    phantun_server_path=$(find "$tmpdir/phantun" -type f -name phantun_server -print -quit)
    phantun_client_path=$(find "$tmpdir/phantun" -type f -name phantun_client -print -quit)
    [[ -n "$phantun_server_path" ]] || die "Cannot find phantun_server after extracting Phantun archive."
    [[ -n "$phantun_client_path" ]] || die "Cannot find phantun_client after extracting Phantun archive."
    install -m 0755 "$phantun_server_path" "${INSTALL_DIR}/phantun_server"
    install -m 0755 "$phantun_client_path" "${INSTALL_DIR}/phantun_client"
    if has_cmd setcap; then
        setcap cap_net_admin=+pe "${INSTALL_DIR}/phantun_server" || true
        setcap cap_net_admin=+pe "${INSTALL_DIR}/phantun_client" || true
    fi
    rm -rf "$tmpdir"
    trap - RETURN
}

detect_public_ipv4() {
    local ip
    for url in https://api.ipify.org https://ipv4.icanhazip.com https://ifconfig.me; do
        ip=$(curl -4fsS --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]' || true)
        if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    done
    return 1
}

safe_tun_name() {
    local prefix=$1 iface=$2 slug
    slug=$(printf '%s' "$iface" | tr -c 'A-Za-z0-9' '_' | cut -c1-10)
    printf '%s%s' "$prefix" "$slug" | cut -c1-15
}

backup_if_exists() {
    local file=$1
    if [[ -f "$file" ]]; then
        cp -a "$file" "${file}.bak.$(date +%Y%m%d%H%M%S)"
        warn "Backed up existing file: $file"
    fi
}

enable_ipv4_forwarding() {
    sysctl -w net.ipv4.ip_forward=1 >/dev/null
    mkdir -p /etc/sysctl.d
    cat >/etc/sysctl.d/99-wg-phantun.conf <<'EOF_SYSCTL'
net.ipv4.ip_forward=1
EOF_SYSCTL
}

ensure_service_active() {
    local service=$1
    sleep 1
    if ! systemctl is-active --quiet "$service"; then
        systemctl status "$service" --no-pager -l || true
        die "Service ${service} is not active."
    fi
}

WG_CONF="/etc/wireguard/${IFACE}.conf"
WG_PRIVATE_KEY_FILE="/etc/wireguard/${IFACE}_privatekey"
WG_PUBLIC_KEY_FILE="/etc/wireguard/${IFACE}_publickey"
WG_SERVICE="wg-quick@${IFACE}.service"
PHANTUN_SERVER_SERVICE="wg-phantun-server-${IFACE}.service"
STATE_DIR="${STATE_ROOT}/${IFACE}"

ensure_deps
systemctl stop "$PHANTUN_SERVER_SERVICE" >/dev/null 2>&1 || true
systemctl stop "$WG_SERVICE" >/dev/null 2>&1 || true
wg-quick down "$IFACE" >/dev/null 2>&1 || true
if tcp_port_in_use "$PHANTUN_TCP_PORT"; then
    die "B TCP port ${PHANTUN_TCP_PORT} is already in use. Change --phantun-port."
fi
if udp_port_in_use "$WG_PORT"; then
    die "B UDP port ${WG_PORT} is already in use. Change --wg-port."
fi
install_phantun
enable_ipv4_forwarding

mkdir -p /etc/wireguard "$STATE_DIR"
umask 077
if [[ ! -f "$WG_PRIVATE_KEY_FILE" ]]; then
    wg genkey | tee "$WG_PRIVATE_KEY_FILE" | wg pubkey >"$WG_PUBLIC_KEY_FILE"
    chmod 600 "$WG_PRIVATE_KEY_FILE" "$WG_PUBLIC_KEY_FILE"
    ok "Generated B WireGuard key pair."
else
    ok "Reusing existing B WireGuard key pair."
fi
B_PRIVATE_KEY=$(<"$WG_PRIVATE_KEY_FILE")
B_PUBLIC_KEY=$(<"$WG_PUBLIC_KEY_FILE")

backup_if_exists "$WG_CONF"
cat >"$WG_CONF" <<EOF_WG_B
[Interface]
# Generated by wg-phantun-tunnel.sh on server B
PrivateKey = ${B_PRIVATE_KEY}
Address = ${B_WG_IP}/24
ListenPort = ${WG_PORT}
MTU = ${WG_MTU}
PreUp = sysctl -w net.ipv4.ip_forward=1

[Peer]
PublicKey = ${A_PUBLIC_KEY}
AllowedIPs = ${A_WG_IP}/32
EOF_WG_B
chmod 600 "$WG_CONF"

if [[ -z "$B_OUTER_IFACE" ]]; then
    B_OUTER_IFACE=$(detect_default_iface)
fi
[[ -n "$B_OUTER_IFACE" ]] || die "Cannot detect B outbound interface. Use --b-outer-iface."

tun_name=$(safe_tun_name "ptns_" "$IFACE")
tun_local="172.30.110.1"
tun_peer="172.30.110.2"

cat >"${STATE_DIR}/phantun-server-iptables-up.sh" <<EOF_UP
#!/usr/bin/env bash
while iptables -w -t nat -D PREROUTING -p tcp -i ${B_OUTER_IFACE} --dport ${PHANTUN_TCP_PORT} -j DNAT --to-destination ${tun_peer} -m comment --comment wg-phantun-server-${IFACE} 2>/dev/null; do :; done
while iptables -w -D FORWARD -i ${B_OUTER_IFACE} -o ${tun_name} -p tcp --dport ${PHANTUN_TCP_PORT} -d ${tun_peer}/32 -m comment --comment wg-phantun-server-${IFACE} -j ACCEPT 2>/dev/null; do :; done
while iptables -w -D FORWARD -i ${tun_name} -o ${B_OUTER_IFACE} -s ${tun_peer}/32 -m comment --comment wg-phantun-server-${IFACE} -j ACCEPT 2>/dev/null; do :; done
iptables -w -t nat -A PREROUTING -p tcp -i ${B_OUTER_IFACE} --dport ${PHANTUN_TCP_PORT} -j DNAT --to-destination ${tun_peer} -m comment --comment wg-phantun-server-${IFACE}
iptables -w -I FORWARD 1 -i ${B_OUTER_IFACE} -o ${tun_name} -p tcp --dport ${PHANTUN_TCP_PORT} -d ${tun_peer}/32 -m comment --comment wg-phantun-server-${IFACE} -j ACCEPT
iptables -w -I FORWARD 1 -i ${tun_name} -o ${B_OUTER_IFACE} -s ${tun_peer}/32 -m comment --comment wg-phantun-server-${IFACE} -j ACCEPT
EOF_UP
chmod +x "${STATE_DIR}/phantun-server-iptables-up.sh"

cat >"${STATE_DIR}/phantun-server-iptables-down.sh" <<EOF_DOWN
#!/usr/bin/env bash
while iptables -w -t nat -D PREROUTING -p tcp -i ${B_OUTER_IFACE} --dport ${PHANTUN_TCP_PORT} -j DNAT --to-destination ${tun_peer} -m comment --comment wg-phantun-server-${IFACE} 2>/dev/null; do :; done
while iptables -w -D FORWARD -i ${B_OUTER_IFACE} -o ${tun_name} -p tcp --dport ${PHANTUN_TCP_PORT} -d ${tun_peer}/32 -m comment --comment wg-phantun-server-${IFACE} -j ACCEPT 2>/dev/null; do :; done
while iptables -w -D FORWARD -i ${tun_name} -o ${B_OUTER_IFACE} -s ${tun_peer}/32 -m comment --comment wg-phantun-server-${IFACE} -j ACCEPT 2>/dev/null; do :; done
EOF_DOWN
chmod +x "${STATE_DIR}/phantun-server-iptables-down.sh"

cat >"/etc/systemd/system/${PHANTUN_SERVER_SERVICE}" <<EOF_SERVICE
[Unit]
Description=Phantun server for ${IFACE} WireGuard tunnel
Requires=${WG_SERVICE}
After=network-online.target ${WG_SERVICE}
Wants=network-online.target

[Service]
Type=simple
Environment=RUST_LOG=warn
ExecStartPre=${STATE_DIR}/phantun-server-iptables-up.sh
ExecStart=${INSTALL_DIR}/phantun_server --local ${PHANTUN_TCP_PORT} --remote 127.0.0.1:${WG_PORT} --tun ${tun_name} --tun-local ${tun_local} --tun-peer ${tun_peer} -4
ExecStopPost=${STATE_DIR}/phantun-server-iptables-down.sh
Restart=always
RestartSec=5
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF_SERVICE

systemctl daemon-reload
systemctl stop "$PHANTUN_SERVER_SERVICE" >/dev/null 2>&1 || true
systemctl stop "$WG_SERVICE" >/dev/null 2>&1 || true
wg-quick down "$IFACE" >/dev/null 2>&1 || true
systemctl enable "$WG_SERVICE" >/dev/null
systemctl restart "$WG_SERVICE"
ensure_service_active "$WG_SERVICE"
systemctl enable "$PHANTUN_SERVER_SERVICE" >/dev/null
systemctl restart "$PHANTUN_SERVER_SERVICE"
ensure_service_active "$PHANTUN_SERVER_SERVICE"

if [[ -z "$B_ENDPOINT_HOST" ]]; then
    B_ENDPOINT_HOST=$(detect_public_ipv4 || true)
fi
if [[ -z "$B_ENDPOINT_HOST" ]]; then
    die "Cannot auto-detect B public IPv4. Re-run with --b-endpoint <B_PUBLIC_IPV4_OR_DOMAIN>."
fi
validate_ipv4_or_domain "$B_ENDPOINT_HOST" "B endpoint host"
warn_if_non_public_endpoint "$B_ENDPOINT_HOST"

ok "Server B services are running."
echo "__WGPT_B_PUBLIC__=${B_PUBLIC_KEY}"
echo "__WGPT_B_ENDPOINT_HOST__=${B_ENDPOINT_HOST}"
echo "__WGPT_B_OUTER_IFACE__=${B_OUTER_IFACE}"
REMOTE_B_SETUP
)
    rc=$?
    if [[ -n "$B_PASSWORD" ]]; then
        unset SSHPASS
    fi
    set -e

    echo "$output"
    if [[ "$rc" -ne 0 ]]; then
        die_with_next_steps "Remote deployment on server B failed."
    fi

    B_PUBLIC_KEY=$(awk -F= '/^__WGPT_B_PUBLIC__=/{print substr($0, index($0, "=") + 1)}' <<<"$output" | tail -n1)
    DEPLOYED_B_ENDPOINT_HOST=$(awk -F= '/^__WGPT_B_ENDPOINT_HOST__=/{print substr($0, index($0, "=") + 1)}' <<<"$output" | tail -n1)
    DEPLOYED_B_OUTER_IFACE=$(awk -F= '/^__WGPT_B_OUTER_IFACE__=/{print substr($0, index($0, "=") + 1)}' <<<"$output" | tail -n1)

    [[ -n "$B_PUBLIC_KEY" ]] || die "Could not parse B WireGuard public key from remote output."
    [[ -n "$DEPLOYED_B_ENDPOINT_HOST" ]] || die "Could not determine B endpoint host."
    ok "Remote B deployment finished."
}

remote_simple_cmd() {
    local command=$1
    build_ssh_base
    if [[ -n "$B_PASSWORD" ]]; then
        SSHPASS="$B_PASSWORD" "${SSH_BASE[@]}" "$(ssh_target)" "$command"
    else
        "${SSH_BASE[@]}" "$(ssh_target)" "$command"
    fi
}

remote_admin_cmd() {
    local command=$1 rc
    local runner=(bash -s)
    if [[ "$USE_SUDO" == "y" ]]; then
        runner=(sudo -n bash -s)
    fi

    build_ssh_base
    set +e
    if [[ -n "$B_PASSWORD" ]]; then
        export SSHPASS="$B_PASSWORD"
    fi
    printf '%s\n' "$command" | "${SSH_BASE[@]}" "$(ssh_target)" "${runner[@]}"
    rc=$?
    if [[ -n "$B_PASSWORD" ]]; then
        unset SSHPASS
    fi
    set -e
    return "$rc"
}

remote_status() {
    [[ -n "$B_HOST" ]] || return 0
    info "Collecting server B status..."
    remote_simple_cmd "IFACE='$IFACE'; WG_SERVICE='wg-quick@${IFACE}.service'; PHANTUN_SERVER_SERVICE='wg-phantun-server-${IFACE}.service'; echo '== Server B remote status =='; echo \"Interface: \$IFACE\"; systemctl is-active \"\$PHANTUN_SERVER_SERVICE\" >/dev/null 2>&1 && echo 'Phantun server: active' || echo 'Phantun server: inactive'; systemctl is-active \"\$WG_SERVICE\" >/dev/null 2>&1 && echo 'WireGuard: active' || echo 'WireGuard: inactive'; echo; systemctl status \"\$PHANTUN_SERVER_SERVICE\" --no-pager -l 2>/dev/null || true; echo; systemctl status \"\$WG_SERVICE\" --no-pager -l 2>/dev/null || true; echo; wg show \"\$IFACE\" 2>/dev/null || true"
}

diagnose_local() {
    wg_paths
    echo "== Server A diagnostics =="
    echo "Script version: ${SCRIPT_VERSION}"
    echo "Date: $(date -Is 2>/dev/null || date)"
    echo "Kernel: $(uname -a)"
    echo
    echo "== Commands =="
    for cmd in wg wg-quick ip iptables ss systemctl journalctl curl unzip; do
        command -v "$cmd" 2>/dev/null || true
    done
    echo
    echo "== Services =="
    systemctl status "$PHANTUN_CLIENT_SERVICE" --no-pager -l 2>/dev/null || true
    echo
    systemctl status "$WG_SERVICE" --no-pager -l 2>/dev/null || true
    echo
    echo "== Journals =="
    journalctl -u "$PHANTUN_CLIENT_SERVICE" -n 120 --no-pager 2>/dev/null || true
    echo
    journalctl -u "$WG_SERVICE" -n 120 --no-pager 2>/dev/null || true
    echo
    echo "== WireGuard =="
    wg show "$IFACE" 2>/dev/null || true
    echo
    echo "== Addresses and routes =="
    ip addr 2>/dev/null || true
    echo
    ip route 2>/dev/null || true
    echo
    echo "== Sockets =="
    ss -lntup 2>/dev/null || true
    echo
    echo "== Managed iptables rules =="
    iptables -t nat -S 2>/dev/null | grep -F "wg-phantun" || true
    iptables -S 2>/dev/null | grep -F "wg-phantun" || true
    echo
    echo "== Config preview =="
    if [[ -f "$WG_CONF" ]]; then
        sed -E 's/^(PrivateKey[[:space:]]*=[[:space:]]*).*/\1<redacted>/' "$WG_CONF"
    fi
}

diagnose_remote_b() {
    [[ -n "$B_HOST" ]] || return 0
    info "Collecting server B diagnostics..."
    build_ssh_base
    remote_runner_args "$IFACE"
    if [[ -n "$B_PASSWORD" ]]; then
        export SSHPASS="$B_PASSWORD"
    fi
    "${SSH_BASE[@]}" "$(ssh_target)" "${REMOTE_RUNNER[@]}" <<'REMOTE_B_DIAG'
set -euo pipefail
IFACE=$1
WG_SERVICE="wg-quick@${IFACE}.service"
PHANTUN_SERVER_SERVICE="wg-phantun-server-${IFACE}.service"
WG_CONF="/etc/wireguard/${IFACE}.conf"
echo "== Server B diagnostics =="
echo "Date: $(date -Is 2>/dev/null || date)"
echo "Kernel: $(uname -a)"
echo
echo "== Commands =="
for cmd in wg wg-quick ip iptables ss systemctl journalctl curl unzip; do
    command -v "$cmd" 2>/dev/null || true
done
echo
echo "== Services =="
systemctl status "$PHANTUN_SERVER_SERVICE" --no-pager -l 2>/dev/null || true
echo
systemctl status "$WG_SERVICE" --no-pager -l 2>/dev/null || true
echo
echo "== Journals =="
journalctl -u "$PHANTUN_SERVER_SERVICE" -n 120 --no-pager 2>/dev/null || true
echo
journalctl -u "$WG_SERVICE" -n 120 --no-pager 2>/dev/null || true
echo
echo "== WireGuard =="
wg show "$IFACE" 2>/dev/null || true
echo
echo "== Addresses and routes =="
ip addr 2>/dev/null || true
echo
ip route 2>/dev/null || true
echo
echo "== Sockets =="
ss -lntup 2>/dev/null || true
echo
echo "== Managed iptables rules =="
iptables -t nat -S 2>/dev/null | grep -F "wg-phantun" || true
iptables -S 2>/dev/null | grep -F "wg-phantun" || true
echo
echo "== Config preview =="
if [[ -f "$WG_CONF" ]]; then
    sed -E 's/^(PrivateKey[[:space:]]*=[[:space:]]*).*/\1<redacted>/' "$WG_CONF"
fi
REMOTE_B_DIAG
    if [[ -n "$B_PASSWORD" ]]; then
        unset SSHPASS
    fi
}

cleanup_remote_b() {
    [[ -n "$B_HOST" ]] || return 0
    confirm_or_exit "Remove remote B services/config for ${IFACE}?"
    info "Cleaning remote B services/config for ${IFACE}..."
    build_ssh_base
    remote_runner_args "$IFACE" "$KEEP_KEYS"
    if [[ -n "$B_PASSWORD" ]]; then
        export SSHPASS="$B_PASSWORD"
    fi
    "${SSH_BASE[@]}" "$(ssh_target)" "${REMOTE_RUNNER[@]}" <<'REMOTE_B_CLEAN'
set -euo pipefail
IFACE=$1
KEEP_KEYS=$2
WG_CONF="/etc/wireguard/${IFACE}.conf"
WG_PRIVATE_KEY_FILE="/etc/wireguard/${IFACE}_privatekey"
WG_PUBLIC_KEY_FILE="/etc/wireguard/${IFACE}_publickey"
WG_SERVICE="wg-quick@${IFACE}.service"
PHANTUN_SERVER_SERVICE="wg-phantun-server-${IFACE}.service"
STATE_DIR="/etc/wg-phantun/${IFACE}"
systemctl disable --now "$PHANTUN_SERVER_SERVICE" >/dev/null 2>&1 || true
systemctl disable --now "$WG_SERVICE" >/dev/null 2>&1 || true
wg-quick down "$IFACE" >/dev/null 2>&1 || true
if [[ -x "${STATE_DIR}/phantun-server-iptables-down.sh" ]]; then
    "${STATE_DIR}/phantun-server-iptables-down.sh" || true
fi
rm -f "/etc/systemd/system/${PHANTUN_SERVER_SERVICE}"
rm -rf "$STATE_DIR"
rm -f "$WG_CONF"
if [[ "$KEEP_KEYS" != "y" ]]; then
    rm -f "$WG_PRIVATE_KEY_FILE" "$WG_PUBLIC_KEY_FILE"
fi
systemctl daemon-reload >/dev/null 2>&1 || true
echo "[B OK] Remote B cleanup finished."
REMOTE_B_CLEAN
    if [[ -n "$B_PASSWORD" ]]; then
        unset SSHPASS
    fi
}

wait_for_ping() {
    local target=$1 tries=${2:-15}
    local i
    for ((i=1; i<=tries; i++)); do
        if ping -c 1 -W 2 "$target" >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done
    return 1
}

test_tunnel() {
    local latest_handshake now age
    info "Checking A -> B Phantun TCP reachability ($(format_host_port "$DEPLOYED_B_ENDPOINT_HOST" "$PHANTUN_TCP_PORT"))..."
    if tcp_probe_host_port "$DEPLOYED_B_ENDPOINT_HOST" "$PHANTUN_TCP_PORT" 3; then
        ok "A can reach B Phantun TCP port."
    else
        warn "A cannot confirm B Phantun fake-TCP port with a plain TCP probe. If WireGuard ping fails, check B cloud firewall TCP ${PHANTUN_TCP_PORT}."
    fi

    info "Testing A -> B WireGuard connectivity (${B_WG_IP})..."
    if ! wait_for_ping "$B_WG_IP" 20; then
        print_local_diagnostics
        die_with_next_steps "A cannot ping B over WireGuard. Check B cloud firewall allows TCP ${PHANTUN_TCP_PORT}."
    fi
    ping -c 3 -W 2 "$B_WG_IP"
    ok "A can ping B over the WireGuard-over-Phantun tunnel."

    info "Testing B -> A WireGuard connectivity (${A_WG_IP})..."
    if ! remote_simple_cmd "ping -c 3 -W 2 ${A_WG_IP}"; then
        print_local_diagnostics
        die_with_next_steps "B cannot ping A over WireGuard. A->B works, but the reverse tunnel test failed."
    fi
    ok "B can ping A over the WireGuard-over-Phantun tunnel."

    latest_handshake=$(wg show "$IFACE" latest-handshakes 2>/dev/null | awk '{print $2; exit}' || true)
    if [[ "$latest_handshake" =~ ^[0-9]+$ && "$latest_handshake" -gt 0 ]]; then
        now=$(date +%s)
        age=$((now - latest_handshake))
        if (( age <= 120 )); then
            ok "WireGuard latest handshake is fresh (${age}s ago)."
        else
            warn "WireGuard latest handshake is old (${age}s ago), but ping test succeeded."
        fi
    else
        warn "WireGuard latest-handshakes did not report a timestamp, but ping test succeeded."
    fi
}

ensure_local_iperf3() {
    if has_cmd iperf3; then
        return 0
    fi
    info "Installing iperf3 on server A..."
    if has_cmd apt-get; then
        pkg_install iperf3
    elif has_cmd dnf || has_cmd yum; then
        pkg_install iperf3
    else
        die "iperf3 is required. Install it manually on server A."
    fi
}

ensure_remote_iperf3() {
    info "Checking iperf3 on server B..."
    if remote_simple_cmd "command -v iperf3 >/dev/null 2>&1" >/dev/null 2>&1; then
        ok "iperf3 exists on server B."
        return 0
    fi
    info "Installing iperf3 on server B..."
    remote_admin_cmd 'if command -v apt-get >/dev/null 2>&1; then DEBIAN_FRONTEND=noninteractive apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y iperf3; elif command -v dnf >/dev/null 2>&1; then dnf install -y iperf3; elif command -v yum >/dev/null 2>&1; then yum install -y iperf3; else exit 127; fi' \
        || die "Could not install iperf3 on server B. Install it manually or fix package repository access."
}

start_remote_iperf3_server() {
    remote_admin_cmd "pkill -x iperf3 2>/dev/null || true; nohup iperf3 -s -B '${B_WG_IP}' >/tmp/wg-phantun-iperf3.log 2>&1 < /dev/null & sleep 1; pgrep -x iperf3 >/dev/null" \
        || die "Could not start iperf3 server on B (${B_WG_IP})."
}

stop_remote_iperf3_server() {
    remote_admin_cmd "pkill -x iperf3 2>/dev/null || true" >/dev/null 2>&1 || true
}

parse_iperf_sender_summary() {
    awk '
        /sender$/ {
            value=$(NF-3)
            unit=$(NF-2)
            retr=$(NF-1)
        }
        END {
            if (value == "") {
                print "0.00 0"
            } else {
                mult=1
                if (unit ~ /^Kbits/) mult=0.001
                if (unit ~ /^Gbits/) mult=1000
                printf "%.2f %s\n", value * mult, retr
            }
        }
    '
}

run_speed_test() {
    validate_all
    ensure_sshpass_if_needed
    precheck_ssh
    precheck_remote_privilege
    ensure_local_iperf3
    ensure_remote_iperf3

    info "Starting iperf3 server on B (${B_WG_IP})..."
    start_remote_iperf3_server
    trap stop_remote_iperf3_server RETURN

    echo "== A -> B TCP =="
    iperf3 -c "$B_WG_IP" -t 10 -O 1
    echo
    echo "== B -> A TCP reverse =="
    iperf3 -c "$B_WG_IP" -R -t 10 -O 1
    echo
    wg show "$IFACE" latest-handshakes 2>/dev/null || true
    stop_remote_iperf3_server
    trap - RETURN
}

set_runtime_mtu_both() {
    local mtu=$1
    ip link set dev "$IFACE" mtu "$mtu"
    remote_admin_cmd "ip link set dev '${IFACE}' mtu '${mtu}'"
}

restore_runtime_mtu_both() {
    local local_mtu=${1:-} remote_mtu=${2:-}
    [[ -n "$local_mtu" ]] && ip link set dev "$IFACE" mtu "$local_mtu" 2>/dev/null || true
    [[ -n "$remote_mtu" ]] && remote_admin_cmd "ip link set dev '${IFACE}' mtu '${remote_mtu}'" >/dev/null 2>&1 || true
}

persist_mtu_both() {
    local mtu=$1
    backup_if_exists "$WG_CONF"
    if grep -Eq '^MTU[[:space:]]*=' "$WG_CONF"; then
        sed -i -E "s/^MTU[[:space:]]*=.*/MTU = ${mtu}/" "$WG_CONF"
    else
        sed -i "/^Address[[:space:]]*=/a MTU = ${mtu}" "$WG_CONF"
    fi
    remote_admin_cmd "WG_CONF='/etc/wireguard/${IFACE}.conf'; cp -a \"\$WG_CONF\" \"\$WG_CONF.bak.\$(date +%Y%m%d%H%M%S)\" 2>/dev/null || true; if grep -Eq '^MTU[[:space:]]*=' \"\$WG_CONF\"; then sed -i -E 's/^MTU[[:space:]]*=.*/MTU = ${mtu}/' \"\$WG_CONF\"; else sed -i '/^Address[[:space:]]*=/a MTU = ${mtu}' \"\$WG_CONF\"; fi"
    set_runtime_mtu_both "$mtu"
}

recommend_mtu_from_results() {
    local file=$1
    awk '
        NR > 1 {
            mtu[NR]=$1; fwd[NR]=$2; fretr[NR]=$3; rev[NR]=$4; rretr[NR]=$5
            if ($2 > best) best=$2
        }
        END {
            threshold=best*0.85
            picked=""
            bestscore=-999999
            for (i in mtu) {
                if (fwd[i] >= threshold && fretr[i] <= 100) {
                    score=fwd[i]+rev[i]-(rretr[i]*0.05)
                    if (score > bestscore) {
                        bestscore=score
                        picked=mtu[i]
                    }
                }
            }
            if (picked == "") {
                for (i in mtu) {
                    score=fwd[i]+rev[i]-(fretr[i]*0.02)-(rretr[i]*0.05)
                    if (score > bestscore) {
                        bestscore=score
                        picked=mtu[i]
                    }
                }
            }
            print picked
        }
    ' "$file"
}

tune_mtu() {
    local candidates=(1428 1360 1320 1280 1240 1200 1160 1120 1100 1080 1000)
    local current_mtu remote_current_mtu results mtu fwd_output rev_output fwd_mbps fwd_retr rev_mbps rev_retr recommended
    validate_all
    ensure_sshpass_if_needed
    precheck_ssh
    precheck_remote_privilege
    ensure_local_iperf3
    ensure_remote_iperf3

    current_mtu=$(ip -o link show "$IFACE" 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="mtu") {print $(i+1); exit}}')
    remote_current_mtu=$(remote_simple_cmd "ip -o link show '${IFACE}' 2>/dev/null | awk '{for(i=1;i<=NF;i++) if(\$i==\"mtu\") {print \$(i+1); exit}}'" 2>/dev/null || true)
    results=$(mktemp)
    trap 'trap - RETURN; rm -f "$results"; stop_remote_iperf3_server; restore_runtime_mtu_both "$current_mtu" "$remote_current_mtu"' RETURN

    printf "MTU\tA->B Mbps\tA->B Retr\tB->A Mbps\tB->A Retr\n" | tee "$results"
    for mtu in "${candidates[@]}"; do
        info "Testing MTU ${mtu}..."
        set_runtime_mtu_both "$mtu" >/dev/null
        start_remote_iperf3_server
        fwd_output=$(iperf3 -c "$B_WG_IP" -t 6 -O 1 2>&1 || true)
        read -r fwd_mbps fwd_retr <<<"$(printf '%s\n' "$fwd_output" | parse_iperf_sender_summary)"
        rev_output=$(iperf3 -c "$B_WG_IP" -R -t 6 -O 1 2>&1 || true)
        read -r rev_mbps rev_retr <<<"$(printf '%s\n' "$rev_output" | parse_iperf_sender_summary)"
        stop_remote_iperf3_server
        printf "%s\t%s\t%s\t%s\t%s\n" "$mtu" "$fwd_mbps" "$fwd_retr" "$rev_mbps" "$rev_retr" | tee -a "$results"
    done

    recommended=$(recommend_mtu_from_results "$results")
    echo
    ok "Recommended MTU: ${recommended}"
    if ask_yes_no "Apply MTU ${recommended} to both running interfaces and WireGuard configs?"; then
        persist_mtu_both "$recommended"
        ok "Applied MTU ${recommended} on A and B."
        current_mtu=""
        remote_current_mtu=""
    else
        warn "MTU recommendation was not applied. Existing runtime MTU values will be restored."
    fi
}

collect_interactive_inputs() {
    if [[ "$YES" == "y" || ! -t 0 ]]; then
        return 0
    fi

    local ask_password=${1:-y}
    local input
    if [[ -z "$B_HOST" ]]; then
        read -r -p "B server SSH host/IP: " B_HOST
    else
        read -r -p "B server SSH host/IP [${B_HOST}]: " input
        B_HOST=${input:-$B_HOST}
    fi

    read -r -p "B server SSH user [${B_USER}]: " input
    B_USER=${input:-$B_USER}

    read -r -p "B server SSH port [${B_SSH_PORT}]: " input
    B_SSH_PORT=${input:-$B_SSH_PORT}

    if [[ -z "$B_ENDPOINT_HOST" ]]; then
        read -r -p "B public endpoint host/IP [auto-detect]: " input
        B_ENDPOINT_HOST=${input:-$B_ENDPOINT_HOST}
    else
        read -r -p "B public endpoint host/IP [${B_ENDPOINT_HOST}]: " input
        B_ENDPOINT_HOST=${input:-$B_ENDPOINT_HOST}
    fi

    if [[ "$ask_password" == "y" && -z "$B_PASSWORD" && -z "$B_PASSWORD_ENV" ]]; then
        read -r -s -p "B server SSH password [empty = SSH key]: " B_PASSWORD
        echo
    fi
}

validate_all() {
    validate_iface "$IFACE"
    validate_ipv4 "$A_WG_IP" "A WireGuard IP"
    validate_ipv4 "$B_WG_IP" "B WireGuard IP"
    [[ "$A_WG_IP" != "$B_WG_IP" ]] || die "A and B WireGuard IPs cannot be the same."
    validate_port "$WG_PORT" "WireGuard UDP port"
    validate_port "$PHANTUN_TCP_PORT" "Phantun TCP port"
    validate_port "$PHANTUN_CLIENT_UDP_PORT" "A local Phantun UDP port"
    validate_port "$B_SSH_PORT" "B SSH port"
    validate_mtu "$WG_MTU"
    validate_release_tag "$PHANTUN_VERSION"
    validate_url_prefix "$GITHUB_MIRROR_ARG"
    validate_host "$B_HOST" "B SSH host"
    validate_host "$B_USER" "B SSH user"
    [[ -z "$B_ENDPOINT_HOST" ]] || validate_ipv4_or_domain "$B_ENDPOINT_HOST" "B endpoint host"
    [[ -z "$A_OUTER_IFACE" ]] || validate_iface "$A_OUTER_IFACE"
    [[ -z "$B_OUTER_IFACE" ]] || validate_iface "$B_OUTER_IFACE"
}

validate_common() {
    validate_iface "$IFACE"
    validate_port "$B_SSH_PORT" "B SSH port"
    validate_release_tag "$PHANTUN_VERSION"
    validate_url_prefix "$GITHUB_MIRROR_ARG"
    [[ -z "$B_HOST" ]] || validate_host "$B_HOST" "B SSH host"
    [[ -z "$B_USER" ]] || validate_host "$B_USER" "B SSH user"
}

self_test() {
    local script_path=${BASH_SOURCE[0]}
    local tmpdir remote_setup remote_diag remote_clean
    tmpdir=$(mktemp -d)
    remote_setup="${tmpdir}/remote-b-setup.sh"
    remote_diag="${tmpdir}/remote-b-diag.sh"
    remote_clean="${tmpdir}/remote-b-clean.sh"
    trap 'rm -rf "$tmpdir"' RETURN

    bash -n "$script_path"
    awk '/^set -euo pipefail$/{if(++n==2) cap=1} cap{print} /^REMOTE_B_SETUP$/{exit}' "$script_path" | sed '$d' >"$remote_setup"
    bash -n "$remote_setup"
    awk '/^set -euo pipefail$/{n++; if(n==3) cap=1} cap{print} /^REMOTE_B_DIAG$/{exit}' "$script_path" | sed '$d' >"$remote_diag"
    bash -n "$remote_diag"
    awk '/^set -euo pipefail$/{n++; if(n==4) cap=1} cap{print} /^REMOTE_B_CLEAN$/{exit}' "$script_path" | sed '$d' >"$remote_clean"
    bash -n "$remote_clean"

    parse_b_ssh "admin@example.com:2222"
    [[ "$B_USER" == "admin" && "$B_HOST" == "example.com" && "$B_SSH_PORT" == "2222" ]] || die "Self-test failed: --b-ssh parser"
    parse_b_ssh "root@[2001:db8::1]:2222"
    [[ "$B_USER" == "root" && "$B_HOST" == "2001:db8::1" && "$B_SSH_PORT" == "2222" ]] || die "Self-test failed: bracketed IPv6 --b-ssh parser"
    [[ "$(ssh_target)" == "root@[2001:db8::1]" ]] || die "Self-test failed: IPv6 ssh target formatter"
    B_HOST=""
    [[ "$(next_step_ssh_target)" == "<user@B_HOST>" ]] || die "Self-test failed: next-step fallback target"
    parse_b_ssh "root@[2001:db8::1]:2222"
    [[ "$(format_host_port "2001:db8::1" "4567")" == "[2001:db8::1]:4567" ]] || die "Self-test failed: IPv6 host:port formatter"
    [[ "$(unbracket_host "[2001:db8::1]")" == "2001:db8::1" ]] || die "Self-test failed: bracketed host normalizer"
    tcp_probe_host_port "127.0.0.1" "9" "1" || true
    validate_iface "wgpt0"
    validate_ipv4 "10.66.66.1" "self-test IPv4"
    validate_host "203.0.113.10" "self-test IPv4 host"
    validate_host "example.com" "self-test domain host"
    validate_host "2001:db8::1" "self-test IPv6 host"
    validate_host "[2001:db8::1]" "self-test bracketed IPv6 host"
    validate_ipv4_or_domain "203.0.113.10" "self-test endpoint host"
    validate_ipv4_or_domain "example.com" "self-test endpoint domain"
    is_non_public_ipv4 "10.0.0.1" || die "Self-test failed: private IPv4 detector"
    is_non_public_ipv4 "192.168.1.1" || die "Self-test failed: private IPv4 detector"
    is_non_public_ipv4 "100.64.0.1" || die "Self-test failed: CGNAT IPv4 detector"
    is_non_public_ipv4 "203.0.113.10" || die "Self-test failed: documentation IPv4 detector"
    if ( validate_ipv4_or_domain "999.999.999.999" "self-test invalid endpoint" ) >/dev/null 2>&1; then
        die "Self-test failed: invalid IPv4 endpoint should be rejected"
    fi
    if ( validate_ipv4_or_domain "[2001:db8::1]" "self-test endpoint IPv6" ) >/dev/null 2>&1; then
        die "Self-test failed: IPv6 endpoint should be rejected"
    fi
    validate_port "4567" "self-test port"
    validate_release_tag "$PHANTUN_VERSION_DEFAULT"
    parse_args --dry-run --b-ssh root@203.0.113.10 --yes
    [[ "$MODE" == "dry-run" && "$B_HOST" == "203.0.113.10" && "$YES" == "y" ]] || die "Self-test failed: dry-run parser"
    PHANTUN_VERSION="$PHANTUN_VERSION_DEFAULT"
    GITHUB_MIRROR_ARG=""
    [[ "$(phantun_download_url "x86_64-unknown-linux-gnu")" == "https://github.com/dndx/phantun/releases/download/${PHANTUN_VERSION_DEFAULT}/phantun_x86_64-unknown-linux-gnu.zip" ]] || die "Self-test failed: Phantun URL builder"
    if printf '%s\n' "$(awk '/Cannot auto-detect B public IPv4/{print; exit}' "$script_path")" | grep -q 'hostname -I'; then
        die "Self-test failed: B endpoint fallback must not use hostname -I"
    fi

    ok "Self-test passed."
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --iface) require_value "$1" "${2-}"; IFACE=$2; shift 2 ;;
            --a-ip) require_value "$1" "${2-}"; A_WG_IP=$2; shift 2 ;;
            --b-ip) require_value "$1" "${2-}"; B_WG_IP=$2; shift 2 ;;
            --wg-port) require_value "$1" "${2-}"; WG_PORT=$2; shift 2 ;;
            --phantun-port) require_value "$1" "${2-}"; PHANTUN_TCP_PORT=$2; shift 2 ;;
            --local-port) require_value "$1" "${2-}"; PHANTUN_CLIENT_UDP_PORT=$2; shift 2 ;;
            --mtu) require_value "$1" "${2-}"; WG_MTU=$2; shift 2 ;;
            --b-host) require_value "$1" "${2-}"; B_HOST=$2; shift 2 ;;
            --b-user) require_value "$1" "${2-}"; B_USER=$2; shift 2 ;;
            --b-ssh) require_value "$1" "${2-}"; parse_b_ssh "$2"; shift 2 ;;
            --b-ssh-port) require_value "$1" "${2-}"; B_SSH_PORT=$2; shift 2 ;;
            --b-password) require_value "$1" "${2-}"; B_PASSWORD=$2; shift 2 ;;
            --b-password-env) require_value "$1" "${2-}"; B_PASSWORD_ENV=$2; shift 2 ;;
            --b-endpoint) require_value "$1" "${2-}"; B_ENDPOINT_HOST=$2; shift 2 ;;
            --sudo) USE_SUDO="y"; shift ;;
            --a-outer-iface) require_value "$1" "${2-}"; A_OUTER_IFACE=$2; shift 2 ;;
            --b-outer-iface) require_value "$1" "${2-}"; B_OUTER_IFACE=$2; shift 2 ;;
            --phantun-version) require_value "$1" "${2-}"; PHANTUN_VERSION=$2; shift 2 ;;
            --github-mirror) require_value "$1" "${2-}"; GITHUB_MIRROR_ARG=$2; shift 2 ;;
            --copy-phantun) AUTO_COPY_PHANTUN="y"; shift ;;
            --no-copy-phantun) AUTO_COPY_PHANTUN="n"; shift ;;
            --status) MODE="status"; shift ;;
            --diagnose) MODE="diagnose"; shift ;;
            --cleanup) MODE="cleanup"; shift ;;
            --speed-test) MODE="speed-test"; shift ;;
            --tune-mtu) MODE="tune-mtu"; shift ;;
            --dry-run) MODE="dry-run"; shift ;;
            --check-download) MODE="check-download"; shift ;;
            --self-test) MODE="self-test"; shift ;;
            --keep-keys) KEEP_KEYS="y"; shift ;;
            --remove-keys) KEEP_KEYS="n"; shift ;;
            -y|--yes) YES="y"; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done
}

load_password_env() {
    if [[ -n "$B_PASSWORD_ENV" ]]; then
        B_PASSWORD=${!B_PASSWORD_ENV:-}
        [[ -n "$B_PASSWORD" ]] || die "Environment variable ${B_PASSWORD_ENV} is empty or not set."
    fi
}

main() {
    parse_args "$@"
    if [[ "$MODE" == "self-test" ]]; then
        self_test
        exit 0
    fi
    if [[ "$MODE" == "dry-run" ]]; then
        load_password_env
        collect_interactive_inputs n
        load_password_env
        validate_all
        print_deploy_plan
        exit 0
    fi
    if [[ "$MODE" == "check-download" ]]; then
        validate_release_tag "$PHANTUN_VERSION"
        validate_url_prefix "$GITHUB_MIRROR_ARG"
        check_phantun_download
        exit 0
    fi

    need_root
    load_password_env
    wg_paths

    case "$MODE" in
        status)
            validate_common
            ensure_sshpass_if_needed
            status_local
            if [[ -n "$B_HOST" ]]; then
                precheck_ssh
                precheck_remote_privilege
                remote_status
            fi
            exit 0
            ;;
        cleanup)
            validate_common
            ensure_sshpass_if_needed
            if [[ -n "$B_HOST" ]]; then
                precheck_ssh
                precheck_remote_privilege
                cleanup_remote_b
            fi
            cleanup_local
            exit 0
            ;;
        diagnose)
            validate_common
            ensure_sshpass_if_needed
            diagnose_local
            if [[ -n "$B_HOST" ]]; then
                precheck_ssh
                precheck_remote_privilege
                diagnose_remote_b
            fi
            exit 0
            ;;
        speed-test)
            collect_interactive_inputs
            load_password_env
            validate_all
            run_speed_test
            exit 0
            ;;
        tune-mtu)
            collect_interactive_inputs
            load_password_env
            validate_all
            tune_mtu
            exit 0
            ;;
        deploy)
            collect_interactive_inputs
            load_password_env
            validate_all
            ;;
        *)
            die "Unknown mode: $MODE"
            ;;
    esac

    if [[ -z "$A_OUTER_IFACE" ]]; then
        A_OUTER_IFACE=$(detect_default_iface)
    fi
    [[ -n "$A_OUTER_IFACE" ]] || die "Cannot detect A outbound interface. Use --a-outer-iface."

    print_deploy_plan deploy
    confirm_or_exit "Proceed with deployment?"

    phase "Checking local dependencies on server A"
    ensure_local_deps
    phase "Checking local ports on server A"
    precheck_local_ports
    phase "Preparing SSH password helper if needed"
    ensure_sshpass_if_needed
    phase "Checking SSH access to server B"
    precheck_ssh
    phase "Checking remote privilege on server B"
    precheck_remote_privilege
    phase "Enabling IPv4 forwarding on server A"
    enable_ipv4_forwarding
    phase "Generating or reusing A WireGuard keys"
    generate_local_wg_key
    phase "Installing or reusing Phantun on server A"
    install_phantun
    phase "Copying Phantun to B when needed"
    copy_phantun_to_remote_b
    phase "Deploying WireGuard and Phantun on server B"
    deploy_remote_b
    phase "Writing and starting server A services"
    write_local_wireguard_config "$B_PUBLIC_KEY"
    write_local_phantun_client_service "$DEPLOYED_B_ENDPOINT_HOST" "$A_OUTER_IFACE"
    start_local_services
    phase "Testing tunnel connectivity"
    test_tunnel

    echo
    ok "Deployment complete."
    cat <<EOF_SUMMARY

Tunnel summary:
  A WireGuard IP:       ${A_WG_IP}
  B WireGuard IP:       ${B_WG_IP}
  Interface:            ${IFACE}
  B Phantun endpoint:   $(format_host_port "$DEPLOYED_B_ENDPOINT_HOST" "$PHANTUN_TCP_PORT")
  A local WG endpoint:  127.0.0.1:${PHANTUN_CLIENT_UDP_PORT}
  A services:           ${PHANTUN_CLIENT_SERVICE}, ${WG_SERVICE}
  B service:            wg-phantun-server-${IFACE}.service, ${WG_SERVICE}

Useful checks:
  wg show ${IFACE}
  systemctl status ${WG_SERVICE} ${PHANTUN_CLIENT_SERVICE}
  ssh -p ${B_SSH_PORT} $(ssh_target) 'wg show ${IFACE}'
EOF_SUMMARY
}

main "$@"
