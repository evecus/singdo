#!/bin/sh
# =============================================================================
# Sing-box 一键部署脚本 (优化版)
# 支持: Alpine (musl) / Debian / Ubuntu (glibc)
# 协议: Hysteria2 + TLS(自签) & VLESS + WS + 无TLS
# =============================================================================

set -e

# ── 颜色 ─────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { printf "${GREEN}[INFO]${NC} %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
error()   { printf "${RED}[ERROR]${NC} %s\n" "$*"; exit 1; }
section() { printf "\n${BOLD}${CYAN}=== %s ===${NC}\n" "$*"; }

# ── 常量 ─────────────────────────────────────────────────────────────────────
SINGBOX_VERSION="1.13.11"
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONF_DIR="/etc/sing-box"
SINGBOX_CONF="${SINGBOX_CONF_DIR}/config.json"
NODE_INFO_FILE="/etc/sing-box/node_info.txt"
CERT_DIR="/etc/sing-box/certs"

# 随机端口
gen_random_port() {
    while true; do
        port=$(( ($(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 4001) + 1000 ))
        if command -v ss >/dev/null 2>&1; then
            ss -lnp 2>/dev/null | grep -q ":${port} " || { echo "$port"; return; }
        else
            echo "$port"; return
        fi
    done
}

HY2_PORT=$(gen_random_port)
while true; do
    VLESS_PORT=$(gen_random_port)
    [ "$VLESS_PORT" != "$HY2_PORT" ] && break
done

SNI_LIST="www.microsoft.com www.apple.com www.amazon.com www.cloudflare.com www.fastly.com cdn.jsdelivr.net"

# ── 工具函数 ──────────────────────────────────────────────────────────────────
random_pick() {
    set -- $1
    idx=$(( ($(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % $#) + 1 ))
    eval echo \${$idx}
}

gen_uuid() {
    cat /proc/sys/kernel/random/uuid 2>/dev/null || od -x /dev/urandom | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}' | head -c 36
}

gen_password() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

get_public_ip() {
    for url in "https://api.ipify.org" "https://ifconfig.me/ip"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        [ -n "$ip" ] && echo "$ip" && return
    done
    echo "127.0.0.1"
}

# ── 系统检测 & 版本判定 ────────────────────────────────────────────────────────
detect_system() {
    section "系统检测"
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID}"
    elif [ -f /etc/alpine-release ]; then
        OS_ID="alpine"
    else
        error "不支持的系统"
    fi

    # 架构检测
    ARCH_RAW=$(uname -m)
    case "$ARCH_RAW" in
        x86_64)   SB_ARCH="amd64" ;;
        aarch64)  SB_ARCH="arm64" ;;
        *)        error "不支持的架构: ${ARCH_RAW}" ;;
    esac

    # C库判定：Alpine 使用 musl，Debian/Ubuntu 使用 glibc
    if [ "$OS_ID" = "alpine" ]; then
        PKG_MGR="apk"
        # Alpine 下载文件名包含 -musl
        SB_SUFFIX="musl"
        info "检测到 Alpine 系统，将使用 musl 版本"
    else
        PKG_MGR="apt"
        # Debian/Ubuntu 默认下载不带后缀的版本 (即 glibc)
        SB_SUFFIX=""
        info "检测到 ${OS_ID} 系统，将使用 glibc 版本"
    fi
}

install_deps() {
    section "安装依赖"
    if [ "$PKG_MGR" = "apk" ]; then
        apk update -q && apk add --no-cache curl openssl wget tar ca-certificates >/dev/null
    else
        apt-get update -qq && apt-get install -y -qq curl openssl wget tar ca-certificates >/dev/null
    fi
}

install_singbox() {
    section "下载并安装 sing-box"
    
    # 构造文件名逻辑
    if [ -n "$SB_SUFFIX" ]; then
        # 类似: sing-box-1.13.11-linux-amd64-musl.tar.gz
        ARCHIVE="sing-box-${SINGBOX_VERSION}-linux-${SB_ARCH}-${SB_SUFFIX}.tar.gz"
    else
        # 类似: sing-box-1.13.11-linux-amd64.tar.gz (这是 glibc 版本)
        ARCHIVE="sing-box-${SINGBOX_VERSION}-linux-${SB_ARCH}.tar.gz"
    fi

    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${ARCHIVE}"
    
    info "正在下载: ${ARCHIVE}"
    TMP_DIR=$(mktemp -d)
    curl -L --retry 3 -o "${TMP_DIR}/${ARCHIVE}" "$DOWNLOAD_URL"
    tar -xzf "${TMP_DIR}/${ARCHIVE}" -C "$TMP_DIR"
    
    EXTRACTED_BIN=$(find "$TMP_DIR" -name "sing-box" -type f | head -1)
    install -m 755 "$EXTRACTED_BIN" "$SINGBOX_BIN"
    rm -rf "$TMP_DIR"
    
    info "安装完成: $("$SINGBOX_BIN" version | head -n 1)"
}

gen_certs() {
    section "配置 TLS 证书" >&2
    mkdir -p "$CERT_DIR"
    PICKED_SNI=$(random_pick "$SNI_LIST")
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -keyout "${CERT_DIR}/private.key" -out "${CERT_DIR}/cert.pem" -days 3650 -nodes -subj "/CN=${PICKED_SNI}" -addext "subjectAltName=DNS:${PICKED_SNI}" 2>/dev/null
    chmod 600 "${CERT_DIR}/private.key"
    echo "$PICKED_SNI"
}

gen_config() {
    section "生成配置文件"
    mkdir -p "$SINGBOX_CONF_DIR"
    CFG_HY2_PASSWORD=$(gen_password)
    CFG_VLESS_UUID=$(gen_uuid)
    CFG_SNI=$(gen_certs)
    CFG_WS_PATH="/$(gen_password | head -c 12)"

    cat > "$SINGBOX_CONF" <<EOF
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "vless", "tag": "vless-ws", "listen": "::", "listen_port": ${VLESS_PORT},
      "users": [{ "uuid": "${CFG_VLESS_UUID}" }],
      "transport": { "type": "ws", "path": "${CFG_WS_PATH}" }
    },
    {
      "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": ${HY2_PORT},
      "users": [{ "password": "${CFG_HY2_PASSWORD}" }],
      "tls": {
        "enabled": true, "server_name": "${CFG_SNI}",
        "certificate_path": "${CERT_DIR}/cert.pem", "key_path": "${CERT_DIR}/private.key"
      }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF
}

setup_service() {
    section "设置自启动"
    if [ "$PKG_MGR" = "apk" ]; then
        cat > /etc/init.d/sing-box <<'INITEOF'
#!/sbin/openrc-run
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
pidfile="/run/sing-box.pid"
command_background=true
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"
depend() { need net; after firewall; }
INITEOF
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default >/dev/null 2>&1
        rc-service sing-box restart
    else
        cat > /etc/systemd/system/sing-box.service <<UNITEOF
[Unit]
Description=Sing-box Service
After=network.target
[Service]
ExecStart=${SINGBOX_BIN} run -c ${SINGBOX_CONF}
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNITEOF
        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box
    fi
}

output_node_info() {
    section "部署完成 - 节点信息"
    IP=$(get_public_ip)
    HY2="hysteria2://${CFG_HY2_PASSWORD}@${IP}:${HY2_PORT}?insecure=1&sni=${CFG_SNI}#HY2-${IP}"
    VLESS="vless://${CFG_VLESS_UUID}@${IP}:${VLESS_PORT}?encryption=none&security=none&type=ws&host=${CFG_SNI}&path=$(echo ${CFG_WS_PATH} | sed 's|/|%2F|g')#VLESS-${IP}"
    
    echo "----------------------------------------------------------------"
    echo "Hysteria2 (TLS自签):"
    echo "$HY2"
    echo "----------------------------------------------------------------"
    echo "VLESS (WS无TLS):"
    echo "$VLESS"
    echo "----------------------------------------------------------------"
}

main() {
    [ "$(id -u)" -ne 0 ] && error "请使用 root 运行"
    detect_system
    install_deps
    install_singbox
    gen_config
    setup_service
    output_node_info
}

main "$@"
