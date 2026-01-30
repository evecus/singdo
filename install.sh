#!/bin/bash

# ====================================================
# Sing-box 全能管理脚本 (支持 VLESS-WS, HY2, Reality)
# 支持旧配置读取与 sb 命令交互
# ====================================================

NODE_FILE="/opt/sing-box/节点.txt"
CONFIG_FILE="/opt/sing-box/config.json"
SB_BIN="/usr/local/bin/sing-box"
SCRIPT_PATH=$(readlink -f "$0")

# --- 核心安装函数 ---
install_singbox() {
    clear
    echo "正在开始安装/部署 Sing-box..."
    
    # 权限与依赖检查
    [[ $EUID -ne 0 ]] && echo "请使用 root 权限运行。" && exit 1
    
    # 尝试读取旧配置
    if [[ -f $CONFIG_FILE ]]; then
        OLD_UUID=$(jq -r '.inbounds[0].users[0].uuid' $CONFIG_FILE)
        OLD_V_PORT=$(jq -r '.inbounds | .[] | select(.tag=="vless-ws-in") | .listen_port' $CONFIG_FILE)
        OLD_SNI=$(jq -r '.inbounds | .[] | select(.tag=="vless-ws-in") | .tls.server_name' $CONFIG_FILE)
        OLD_HY2_PORT=$(jq -r '.inbounds | .[] | select(.tag=="hy2-in") | .listen_port' $CONFIG_FILE)
        OLD_R_PORT=$(jq -r '.inbounds | .[] | select(.tag=="vless-reality-in") | .listen_port' $CONFIG_FILE)
        echo "检测到旧配置，输入时直接回车可保留原设定。"
    fi

    # 开启 BBR
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
    fi

    apt-get update && apt-get install -y curl jq openssl tar wget

    # 下载安装二进制文件
    LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
    ARCH=$(uname -m)
    [[ "$ARCH" == "x86_64" ]] && ARCH="amd64" || ARCH="arm64"
    
    DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${ARCH}.tar.gz"
    wget -O sing-box.tar.gz "$DOWNLOAD_URL"
    tar -zxvf sing-box.tar.gz
    cp sing-box-*/sing-box /usr/local/bin/
    chmod +x /usr/local/bin/sing-box
    rm -rf sing-box*

    mkdir -p /opt/sing-box

    # --- 交互输入部分 ---
    IP=$(curl -s ifconfig.me)
    
    read -p "UUID [当前: ${OLD_UUID:-随机}]: " VLESS_UUID
    [[ -z "$VLESS_UUID" ]] && VLESS_UUID=${OLD_UUID:-$(cat /proc/sys/kernel/random/uuid)}

    echo ">>> 配置 VLESS + WS"
    read -p "端口 [当前: ${OLD_V_PORT:-30001}]: " VLESS_PORT
    [[ -z "$VLESS_PORT" ]] && VLESS_PORT=${OLD_V_PORT:-30001}
    read -p "TLS 域名 (SNI) [当前: ${OLD_SNI:-无}]: " VLESS_SNI
    [[ -z "$VLESS_SNI" ]] && VLESS_SNI=$OLD_SNI
    read -p "证书(CRT)路径: " VLESS_CERT
    read -p "私钥(KEY)路径: " VLESS_KEY
    read -p "WS 路径 (默认 /video): " WS_PATH
    [[ -z "$WS_PATH" ]] && WS_PATH="/video"

    echo ">>> 配置 Hysteria2"
    read -p "端口 [当前: ${OLD_HY2_PORT:-30002}]: " HY2_PORT
    [[ -z "$HY2_PORT" ]] && HY2_PORT=${OLD_HY2_PORT:-30002}
    read -p "密码 (留空随机): " HY2_PASS
    [[ -z "$HY2_PASS" ]] && HY2_PASS=$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 16)

    echo ">>> 配置 VLESS + Reality"
    read -p "端口 [当前: ${OLD_R_PORT:-30003}]: " REALITY_PORT
    [[ -z "$REALITY_PORT" ]] && REALITY_PORT=${OLD_R_PORT:-30003}
    read -p "目标网站 (默认 www.google.com): " REALITY_DEST
    [[ -z "$REALITY_DEST" ]] && REALITY_DEST="www.google.com"

    # 生成 Reality 密钥对
    REALITY_KEYS=$($SB_BIN generate reality-keypair)
    REALITY_PRIV=$(echo "$REALITY_KEYS" | grep "Private key" | awk '{print $3}')
    REALITY_PUB=$(echo "$REALITY_KEYS" | grep "Public key" | awk '{print $3}')
    REALITY_SID=$(openssl rand -hex 8)

    # 写入 JSON
    cat <<EOF > $CONFIG_FILE
{
  "log": { "level": "info" },
  "inbounds": [
    {
      "type": "vless", "tag": "vless-ws-in", "listen": "::", "listen_port": $VLESS_PORT,
      "users": [{ "uuid": "$VLESS_UUID" }],
      "tls": { "enabled": true, "server_name": "$VLESS_SNI", "certificate_path": "$VLESS_CERT", "key_path": "$VLESS_KEY" },
      "transport": { "type": "ws", "path": "$WS_PATH" }
    },
    {
      "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": $HY2_PORT,
      "users": [{ "password": "$HY2_PASS" }],
      "tls": { "enabled": true, "server_name": "www.bing.com", "certificate_path": "/opt/sing-box/hy2.crt", "key_path": "/opt/sing-box/hy2.key" }
    },
    {
      "type": "vless", "tag": "vless-reality-in", "listen": "::", "listen_port": $REALITY_PORT,
      "users": [{ "uuid": "$VLESS_UUID" }],
      "tls": {
        "enabled": true, "server_name": "$REALITY_DEST",
        "reality": {
          "enabled": true,
          "handshake": { "server": "$REALITY_DEST", "server_port": 443 },
          "private_key": "$REALITY_PRIV",
          "short_id": ["$REALITY_SID"]
        }
      }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF

    # 生成自签名证书供 HY2 使用（简单化处理）
    openssl req -x509 -nodes -newkey rsa:2048 -keyout /opt/sing-box/hy2.key -out /opt/sing-box/hy2.crt -subj "/CN=www.bing.com" -days 3650 > /dev/null 2>&1

    # Systemd 服务
    cat <<EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box service
After=network.target nss-lookup.target
[Service]
ExecStart=$SB_BIN run -c $CONFIG_FILE
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable --now sing-box

    # 生成节点链接
    V_LINK="vless://$VLESS_UUID@$www.visa.com:$443?encryption=none&security=tls&sni=$VLESS_SNI&type=ws&host=$VLESS_SNI&path=$(echo $WS_PATH | sed 's/\//%2F/g')#VLESS_WS"
    H_LINK="hy2://$HY2_PASS@$IP:$HY2_PORT?sni=www.bing.com&insecure=1#HY2_Node"
    R_LINK="vless://$VLESS_UUID@$IP:$REALITY_PORT?encryption=none&security=reality&sni=$REALITY_DEST&fp=chrome&pbk=$REALITY_PUB&sid=$REALITY_SID#Reality_Node"

    cat <<EOF > $NODE_FILE
VLESS+WS: $V_LINK
Hysteria2: $H_LINK
Reality: $R_LINK
EOF
    create_sb_tool
    echo "部署完成！输入 sb 管理。"
    cat $NODE_FILE
}

# --- 管理工具 ---
create_sb_tool() {
    cat <<EOF > /usr/local/bin/sb
#!/bin/bash
case \$1 in
    -s) systemctl status sing-box ;;
    -l) journalctl -u sing-box --no-pager -n 50 ;;
    *)
        clear
        echo "1. 查看节点"
        echo "2. 重新安装/修改配置"
        echo "3. 重启服务"
        echo "4. 卸载"
        read -p "选择: " opt
        case \$opt in
            1) cat $NODE_FILE ;;
            2) bash $SCRIPT_PATH ;;
            3) systemctl restart sing-box && echo "已重启" ;;
            4) 
               systemctl disable --now sing-box
               rm -rf /opt/sing-box /usr/local/bin/sing-box /etc/systemd/system/sing-box.service /usr/local/bin/sb
               echo "已卸载" ;;
        esac
        ;;
esac
EOF
    chmod +x /usr/local/bin/sb
}

install_singbox
