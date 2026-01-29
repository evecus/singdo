#!/bin/bash

# ====================================================
# Sing-box 全能管理脚本 (支持 sb 命令交互)
# ====================================================

NODE_FILE="/opt/sing-box/节点.txt"
CONFIG_FILE="/opt/sing-box/config.json"
SB_BIN="/usr/local/bin/sb"

# --- 核心安装函数 ---
install_singbox() {
    clear
    echo "正在开始安装/重装 Sing-box..."
    
    # 权限与依赖检查
    [[ $EUID -ne 0 ]] && echo "请使用 root 权限运行。" && exit 1
    
    # 开启 BBR
    if ! sysctl net.ipv4.tcp_congestion_control | grep -q "bbr"; then
        echo "net.core.default_qdisc=fq" >> /etc/sysctl.conf
        echo "net.ipv4.tcp_congestion_control=bbr" >> /etc/sysctl.conf
        sysctl -p > /dev/null 2>&1
    fi

    apt-get update && apt-get install -y curl jq openssl tar wget

    # 下载安装
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

    # 节点配置逻辑 (此处复用之前优化的随机端口、路径检查逻辑)
    echo ">>> 配置 VLESS 节点"
    read -p "UUID (留空随机): " VLESS_UUID
    [[ -z "$VLESS_UUID" ]] && VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)
    read -p "VLESS 端口 (留空随机): " VLESS_PORT
    [[ -z "$VLESS_PORT" ]] && VLESS_PORT=$((RANDOM % 20001 + 30000))
    read -p "WS 路径: " WS_PATH
    [[ -z "$WS_PATH" ]] && WS_PATH="/$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 8)"
    read -p "TLS 域名 (SNI): " VLESS_SNI
    while true; do
        read -p "证书(CRT)路径: " VLESS_CERT
        read -p "私钥(KEY)路径: " VLESS_KEY
        [[ -f "$VLESS_CERT" && -f "$VLESS_KEY" ]] && break
        echo "文件不存在，请重新输入！"
    done

    echo ">>> 配置 Hysteria2 节点"
    read -p "HY2 密码 (留空随机): " HY2_PASS
    [[ -z "$HY2_PASS" ]] && HY2_PASS=$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 20)
    read -p "HY2 端口 (留空随机): " HY2_PORT
    [[ -z "$HY2_PORT" ]] && HY2_PORT=$((RANDOM % 20001 + 30000))
    
    read -p "是否随机生成 HY2 证书? (y/n): " GEN_CERT
    if [[ "$GEN_CERT" == "n" ]]; then
        read -p "HY2 域名: " HY2_SNI
        read -p "CRT路径: " HY2_CERT
        read -p "KEY路径: " HY2_KEY
    else
        HY2_SNI="www.bing.com"
        HY2_CERT="/opt/sing-box/hy2_cert.pem"; HY2_KEY="/opt/sing-box/hy2_key.pem"
        openssl req -x509 -nodes -newkey rsa:2048 -keyout "$HY2_KEY" -out "$HY2_CERT" -subj "/CN=$HY2_SNI" -days 3650
    fi

    # 生成 Config
    cat <<EOF > $CONFIG_FILE
{
  "log": { "disabled": true, "level": "panic" },
  "inbounds": [
    {
      "type": "vless", "tag": "vless-in", "listen": "::", "listen_port": $VLESS_PORT,
      "users": [{ "uuid": "$VLESS_UUID" }],
      "tls": { "enabled": true, "server_name": "$VLESS_SNI", "certificate_path": "$VLESS_CERT", "key_path": "$VLESS_KEY" },
      "transport": { "type": "ws", "path": "$WS_PATH" }
    },
    {
      "type": "hysteria2", "tag": "hy2-in", "listen": "::", "listen_port": $HY2_PORT,
      "users": [{ "password": "$HY2_PASS" }],
      "tls": { "enabled": true, "server_name": "$HY2_SNI", "certificate_path": "$HY2_CERT", "key_path": "$HY2_KEY" }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF

    # Systemd 服务
    cat <<EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box service
After=network.target nss-lookup.target
[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/local/bin/sing-box run -c $CONFIG_FILE
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity
[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload && systemctl enable --now sing-box


    # 保存节点信息
    IP=$(curl -s ifconfig.me)
    V_LINK="vless://$VLESS_UUID@104.16.200.250:443?encryption=none&security=tls&sni=$VLESS_SNI&type=ws&host=$VLESS_SNI&path=$(echo $WS_PATH | sed 's/\//%2F/g')#VLESS_Node"
    H_LINK="hy2://$HY2_PASS@$IP:$HY2_PORT?sni=$HY2_SNI&insecure=1#HY2_Node"

    cat <<EOF > $NODE_FILE
VLESS 节点链接:
$V_LINK

Hysteria2 节点链接:
$H_LINK
EOF
    create_sb_tool
    echo "安装完成！输入 sb 即可管理。"
}

# --- 创建 sb 管理工具 ---
create_sb_tool() {
    cat <<'EOF' > /usr/local/bin/sb
#!/bin/bash
case $1 in
    -s) systemctl status sing-box ;;
    -t) systemctl start sing-box && echo "sing-box已启动" ;;
    -e) systemctl enable sing-box && echo "sing-box已设置开机自启" ;;
    -en) systemctl enable --now sing-box && echo "sing-box已设置开机自启并立即启动" ;;
    -p) systemctl stop sing-box && echo "sing-box已停止" ;;
    -dn) systemctl disable --now sing-box && echo "sing-box已禁止开机自启并立即停止" ;;
    -l) journalctl -u sing-box --no-pager ;;
    *)
        clear
        echo "=============================="
        echo "    Sing-box 管理工具 (sb)"
        echo "=============================="
        echo "用法: sb [-s status] [-t start] [-p stop] [-l log]"
        echo "------------------------------"
        echo "1. 查看节点信息"
        echo "2. 重新安装并部署"
        echo "3. 更新 Sing-box 版本"
        echo "4. 卸载 Sing-box"
        echo "5. 退出"
        read -p "请选择 [1-5]: " opt
        case $opt in
            1) cat /opt/sing-box/节点.txt && exit ;;
            2) 
                systemctl stop sing-box
                rm -rf /opt/sing-box /etc/systemd/system/sing-box.service
                # 重新调用主脚本的安装逻辑 (这里建议将主脚本下载到本地)
                bash <(curl -Ls https://raw.githubusercontent.com/evecus/singdo/refs/heads/main/install.sh) # 或者是脚本自身的重入逻辑
                ;;
            3)
                OLD_V=$(/usr/local/bin/sing-box version | head -n1 | awk '{print $3}')
                NEW_V=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
                echo "当前版本: $OLD_V, 最新版本: $NEW_V"
                if [ "$OLD_V" != "$NEW_V" ]; then
                   # 执行更新替换二进制文件
                   ARCH=$(uname -m); [[ "$ARCH" == "x86_64" ]] && ARCH="amd64" || ARCH="arm64"
                   wget -O sb_new.tar.gz "https://github.com/SagerNet/sing-box/releases/download/v${NEW_V}/sing-box-${NEW_V}-linux-${ARCH}.tar.gz"
                   tar -zxvf sb_new.tar.gz && cp sing-box-*/sing-box /usr/local/bin/ && rm -rf sing-box* sb_new.tar.gz
                   systemctl restart sing-box && echo "更新完成！"
                else
                   echo "已是最新版本。"
                fi
                ;;
            4)
                systemctl disable --now sing-box
                rm -rf /opt/sing-box /usr/local/bin/sing-box /etc/systemd/system/sing-box.service /usr/local/bin/sb
                echo "清理完毕，sb 命令已移除。"
                exit
                ;;
            5) exit ;;
        esac
        ;;
esac
EOF
    chmod +x /usr/local/bin/sb
}

# 第一次运行脚本时执行安装
install_singbox
