#!/bin/sh
# =============================================================================
# Sing-box v1.12.24 一键部署脚本
# 支持: Alpine / Debian / Ubuntu
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
SINGBOX_VERSION="1.12.24"
SINGBOX_BIN="/usr/local/bin/sing-box"
SINGBOX_CONF_DIR="/etc/sing-box"
SINGBOX_CONF="${SINGBOX_CONF_DIR}/config.json"
NODE_INFO_FILE="/etc/sing-box/node_info.txt"
CERT_DIR="/etc/sing-box/certs"
SERVICE_NAME="sing-box"

# 随机端口生成（范围 1000-5000，确保两个端口不重复且未被占用）
gen_random_port() {
    while true; do
        port=$(( ($(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % 4001) + 1000 ))
        # 检查端口是否已被占用
        if command -v ss >/dev/null 2>&1; then
            ss -lnp 2>/dev/null | grep -q ":${port} " || { echo "$port"; return; }
        elif command -v netstat >/dev/null 2>&1; then
            netstat -lnp 2>/dev/null | grep -q ":${port} " || { echo "$port"; return; }
        else
            echo "$port"; return
        fi
    done
}

HY2_PORT=$(gen_random_port)
# 循环直到生成与 HY2_PORT 不同的端口
while true; do
    VLESS_PORT=$(gen_random_port)
    [ "$VLESS_PORT" != "$HY2_PORT" ] && break
done

# 随机 SNI 列表（大厂域名）
SNI_LIST="www.microsoft.com www.apple.com www.amazon.com www.cloudflare.com \
          www.fastly.com cdn.jsdelivr.net www.akamai.com \
          www.youtube.com www.netflix.com"

# ── 工具函数 ──────────────────────────────────────────────────────────────────
random_pick() {
    # 从空格分隔列表随机取一个
    set -- $1
    idx=$(( ($(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % $#) + 1 ))
    eval echo \${$idx}
}

gen_uuid() {
    if command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    elif [ -f /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    else
        od -x /dev/urandom | head -1 | awk '{OFS="-"; print $2$3,$4,$5,$6,$7$8$9}' | head -c 36
    fi
}

gen_password() {
    tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24
}

get_public_ip() {
    for url in "https://api.ipify.org" "https://ifconfig.me/ip" "https://icanhazip.com"; do
        ip=$(curl -s --max-time 5 "$url" 2>/dev/null | tr -d '[:space:]')
        if echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$|^[0-9a-fA-F:]+$'; then
            echo "$ip"; return
        fi
    done
    # 回退到本机 IP
    ip route get 8.8.8.8 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1
}

# ── 系统检测 ──────────────────────────────────────────────────────────────────
detect_system() {
    section "系统检测"

    # OS
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS_ID="${ID}"
        OS_VERSION="${VERSION_ID:-}"
    elif [ -f /etc/alpine-release ]; then
        OS_ID="alpine"
    else
        error "无法识别操作系统，仅支持 Alpine / Debian / Ubuntu"
    fi

    case "$OS_ID" in
        alpine)  PKG_MGR="apk";  OS_LABEL="Alpine" ;;
        debian)  PKG_MGR="apt";  OS_LABEL="Debian" ;;
        ubuntu)  PKG_MGR="apt";  OS_LABEL="Ubuntu" ;;
        *)       error "不支持的系统: ${OS_ID}，仅支持 Alpine / Debian / Ubuntu" ;;
    esac

    # 架构 → sing-box 下载文件名后缀
    ARCH_RAW=$(uname -m)
    case "$ARCH_RAW" in
        x86_64)           ARCH_LABEL="amd64";   SB_ARCH="amd64" ;;
        aarch64|arm64)    ARCH_LABEL="arm64";   SB_ARCH="arm64" ;;
        armv7*|armhf)     ARCH_LABEL="armv7";   SB_ARCH="armv7" ;;
        s390x)            ARCH_LABEL="s390x";   SB_ARCH="s390x" ;;
        riscv64)          ARCH_LABEL="riscv64"; SB_ARCH="riscv64" ;;
        *)                error "不支持的 CPU 架构: ${ARCH_RAW}" ;;
    esac

    info "操作系统 : ${OS_LABEL} ${OS_VERSION}"
    info "CPU 架构  : ${ARCH_RAW} (${ARCH_LABEL})"
}

# ── 依赖安装 ──────────────────────────────────────────────────────────────────
install_deps() {
    section "安装依赖"
    case "$PKG_MGR" in
        apk)
            apk update -q
            apk add --no-cache curl openssl wget tar ca-certificates >/dev/null
            ;;
        apt)
            export DEBIAN_FRONTEND=noninteractive
            apt-get update -qq
            apt-get install -y -qq curl openssl wget tar ca-certificates >/dev/null
            ;;
    esac
    info "依赖安装完成"
}

# ── 下载 sing-box ──────────────────────────────────────────────────────────────
install_singbox() {
    section "安装 sing-box v${SINGBOX_VERSION}"

    # 构造下载文件名
    # 格式: sing-box-1.12.24-linux-amd64.tar.gz
    ARCHIVE="sing-box-${SINGBOX_VERSION}-linux-${SB_ARCH}.tar.gz"
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${SINGBOX_VERSION}/${ARCHIVE}"

    info "下载地址: ${DOWNLOAD_URL}"

    TMP_DIR=$(mktemp -d)
    trap 'rm -rf "$TMP_DIR"' EXIT

    if ! curl -L --retry 3 --retry-delay 3 -o "${TMP_DIR}/${ARCHIVE}" "$DOWNLOAD_URL"; then
        error "下载失败，请检查网络或版本号是否正确"
    fi

    tar -xzf "${TMP_DIR}/${ARCHIVE}" -C "$TMP_DIR"
    EXTRACTED_BIN=$(find "$TMP_DIR" -name "sing-box" -type f | head -1)
    [ -z "$EXTRACTED_BIN" ] && error "解压后未找到 sing-box 二进制文件"

    install -m 755 "$EXTRACTED_BIN" "$SINGBOX_BIN"
    info "sing-box 已安装至 ${SINGBOX_BIN}"
    "$SINGBOX_BIN" version
}

# ── 生成自签证书 ───────────────────────────────────────────────────────────────
gen_certs() {
    section "生成自签 TLS 证书"
    mkdir -p "$CERT_DIR"

    SNI=$(random_pick "$SNI_LIST")
    info "使用 SNI: ${SNI}"

    openssl req -x509 -newkey ec \
        -pkeyopt ec_paramgen_curve:P-256 \
        -keyout "${CERT_DIR}/private.key" \
        -out    "${CERT_DIR}/cert.pem" \
        -days 3650 -nodes \
        -subj "/CN=${SNI}" \
        -addext "subjectAltName=DNS:${SNI}" \
        2>/dev/null

    chmod 600 "${CERT_DIR}/private.key"
    info "证书生成完毕 (有效期 10 年)"
    echo "$SNI"   # 返回 SNI 供调用者使用
}

# ── 生成配置 ──────────────────────────────────────────────────────────────────
gen_config() {
    section "生成 sing-box 配置"

    mkdir -p "$SINGBOX_CONF_DIR"

    HY2_PASSWORD=$(gen_password)
    VLESS_UUID=$(gen_uuid)
    SNI=$(gen_certs)
    WS_PATH="/$(gen_password | head -c 12)"

    # 保存变量供后续使用
    CFG_HY2_PASSWORD="$HY2_PASSWORD"
    CFG_VLESS_UUID="$VLESS_UUID"
    CFG_SNI="$SNI"
    CFG_WS_PATH="$WS_PATH"

    cat > "$SINGBOX_CONF" <<EOF
{
  "log": {
    "level": "warn",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless", "tag": "vless-ws-in", "listen": "::", "listen_port": ${VLESS_PORT},
      "users": [{ "uuid": "${VLESS_UUID}" }],
      "transport": { "type": "ws", "path": "${WS_PATH}" }
    },
    {
      "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": ${HY2_PORT},
      "users": [{ "password": "${HY2_PASSWORD}" }],
      "tls": { "enabled": true, "server_name": "${SNI}", "certificate_path": "${CERT_DIR}/cert.pem", "key_path": "${CERT_DIR}/private.key" }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF

    info "配置文件已写入: ${SINGBOX_CONF}"
}

# ── 系统服务 ──────────────────────────────────────────────────────────────────
setup_service() {
    section "配置自启服务"

    # --- Alpine (OpenRC) ---
    if [ "$PKG_MGR" = "apk" ]; then
        cat > /etc/init.d/sing-box <<'INITEOF'
#!/sbin/openrc-run
name="sing-box"
description="Sing-box universal proxy platform"
command="/usr/local/bin/sing-box"
command_args="run -c /etc/sing-box/config.json"
pidfile="/run/sing-box.pid"
command_background=true
output_log="/var/log/sing-box.log"
error_log="/var/log/sing-box.log"

depend() {
    need net
    after firewall
}
INITEOF
        chmod +x /etc/init.d/sing-box
        rc-update add sing-box default >/dev/null 2>&1
        rc-service sing-box restart
        info "OpenRC 服务已配置并启动"

    # --- Debian / Ubuntu (systemd) ---
    else
        cat > /etc/systemd/system/sing-box.service <<UNITEOF
[Unit]
Description=Sing-box Universal Proxy Platform
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
Type=simple
User=root
ExecStart=${SINGBOX_BIN} run -c ${SINGBOX_CONF}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
UNITEOF
        systemctl daemon-reload
        systemctl enable sing-box >/dev/null 2>&1
        systemctl restart sing-box
        info "systemd 服务已配置并启动"
    fi
}

# ── Crontab（每天凌晨 3 点重启）────────────────────────────────────────────────
setup_crontab() {
    section "配置 Crontab 定时任务"

    if [ "$PKG_MGR" = "apk" ]; then
        RESTART_CMD="rc-service sing-box restart"
    else
        RESTART_CMD="systemctl restart sing-box"
    fi

    CRON_JOB="0 3 * * * ${RESTART_CMD} >> /var/log/sing-box-cron.log 2>&1"

    # 幂等写入：先删除旧条目再追加
    (crontab -l 2>/dev/null | grep -v "sing-box"; echo "$CRON_JOB") | crontab -

    info "Crontab 已设置: 每天 03:00 自动重启 sing-box"
}

# ── 输出节点信息 ───────────────────────────────────────────────────────────────
output_node_info() {
    section "节点信息"

    PUBLIC_IP=$(get_public_ip)
    [ -z "$PUBLIC_IP" ] && PUBLIC_IP="<YOUR_SERVER_IP>"

    # Hysteria2 链接
    HY2_LINK="hysteria2://${CFG_HY2_PASSWORD}@${PUBLIC_IP}:${HY2_PORT}?insecure=1&sni=${CFG_SNI}#HY2-${PUBLIC_IP}"

    # VLESS WS 链接
    VLESS_LINK="vless://${CFG_VLESS_UUID}@${PUBLIC_IP}:${VLESS_PORT}?encryption=none&security=none&type=ws&host=${CFG_SNI}&path=$(echo "${CFG_WS_PATH}" | sed 's|/|%2F|g')#VLESS-WS-${PUBLIC_IP}"

    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    INFO_TEXT="
================================================================
  Sing-box v${SINGBOX_VERSION} 节点信息  [ ${TIMESTAMP} ]
================================================================

【Hysteria2 + TLS (自签)】
  服务器    : ${PUBLIC_IP}
  端口      : ${HY2_PORT}
  密码      : ${CFG_HY2_PASSWORD}
  SNI       : ${CFG_SNI}
  跳过验证  : true (自签证书)
  分享链接  : ${HY2_LINK}

----------------------------------------------------------------

【VLESS + WebSocket (无TLS)】
  服务器    : ${PUBLIC_IP}
  端口      : ${VLESS_PORT}
  UUID      : ${CFG_VLESS_UUID}
  传输      : ws
  WS Path   : ${CFG_WS_PATH}
  Host头    : ${CFG_SNI}
  TLS       : 无
  分享链接  : ${VLESS_LINK}

================================================================
  证书路径  : ${CERT_DIR}/cert.pem
  配置路径  : ${SINGBOX_CONF}
  节点文件  : ${NODE_INFO_FILE}
  日志      : /var/log/sing-box.log
  Crontab   : 每天 03:00 自动重启
================================================================
"

    printf "%s\n" "$INFO_TEXT"

    # 保存到文件
    printf "%s\n" "$INFO_TEXT" > "$NODE_INFO_FILE"
    chmod 600 "$NODE_INFO_FILE"
    info "节点信息已保存至: ${NODE_INFO_FILE}"
}

# ── 验证服务状态 ───────────────────────────────────────────────────────────────
verify_service() {
    section "验证服务状态"
    sleep 2

    if [ "$PKG_MGR" = "apk" ]; then
        if rc-service sing-box status 2>&1 | grep -q "started"; then
            info "sing-box 服务运行正常 ✓"
        else
            warn "服务状态异常，请执行: rc-service sing-box status"
        fi
    else
        if systemctl is-active --quiet sing-box; then
            info "sing-box 服务运行正常 ✓"
        else
            warn "服务状态异常，请执行: systemctl status sing-box"
        fi
    fi

    # 端口监听检查
    for port in "$HY2_PORT" "$VLESS_PORT"; do
        if command -v ss >/dev/null 2>&1; then
            if ss -lnp 2>/dev/null | grep -q ":${port}"; then
                info "端口 ${port} 监听正常 ✓"
            else
                warn "端口 ${port} 未检测到监听，请检查防火墙或配置"
            fi
        fi
    done
}

# ── 主流程 ────────────────────────────────────────────────────────────────────
main() {
    # 必须 root
    [ "$(id -u)" -ne 0 ] && error "请以 root 权限运行此脚本"

    printf "${BOLD}${CYAN}"
    printf "╔══════════════════════════════════════════════════╗\n"
    printf "║   Sing-box v%-6s 一键部署脚本                  ║\n" "${SINGBOX_VERSION}"
    printf "║   协议: Hysteria2+TLS  &  VLESS+WS              ║\n"
    printf "╚══════════════════════════════════════════════════╝\n"
    printf "${NC}\n"

    detect_system
    install_deps
    install_singbox
    gen_config       # 内部调用 gen_certs，CFG_* 变量在此设置
    setup_service
    setup_crontab
    verify_service
    output_node_info

    printf "\n${GREEN}${BOLD}✓ 部署完成！${NC}\n\n"
    printf "  查看节点信息: ${CYAN}cat ${NODE_INFO_FILE}${NC}\n"
    printf "  重启服务:     "
    if [ "$PKG_MGR" = "apk" ]; then
        printf "${CYAN}rc-service sing-box restart${NC}\n"
    else
        printf "${CYAN}systemctl restart sing-box${NC}\n"
    fi
    printf "\n"
}

main "$@"
