#!/bin/bash

# ====================================================
# Sing-box 一键部署脚本 (VLESS+WS+TLS & Hy2)
# ====================================================

# 1. 权限与依赖检查
[[ $EUID -ne 0 ]] && echo "请使用 root 权限运行此脚本。" && exit 1
apt-get update && apt-get install -y curl jq openssl tar wget

# 2. 下载并安装最新版 Sing-box
echo "--- 正在获取最新版 Sing-box ---"
LATEST_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r .tag_name | sed 's/v//')
ARCH=$(uname -m)
case $ARCH in
    x86_64) ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    *) echo "不支持的架构: $ARCH"; exit 1 ;;
esac

DOWNLOAD_URL="https://github.com/SagerNet/sing-box/releases/download/v${LATEST_VERSION}/sing-box-${LATEST_VERSION}-linux-${ARCH}.tar.gz"
wget -O sing-box.tar.gz "$DOWNLOAD_URL"
tar -zxvf sing-box.tar.gz
cp sing-box-*/sing-box /usr/local/bin/
chmod +x /usr/local/bin/sing-box
rm -rf sing-box*

# 创建工作目录和配置目录
mkdir -p /opt/sing-box
cd /opt/sing-box

# 3. 部署 VLESS 节点
echo ""
echo ">>> 开始部署 VLESS 节点 (CDN+WS+TLS)"
read -p "请输入 UUID (留空随机生成): " VLESS_UUID
[[ -z "$VLESS_UUID" ]] && VLESS_UUID=$(cat /proc/sys/kernel/random/uuid)

read -p "请输入节点监听端口 (30000-50000, 留空随机): " VLESS_PORT
[[ -z "$VLESS_PORT" ]] && VLESS_PORT=$((RANDOM % 20001 + 30000))

read -p "请输入 WebSocket 路径 (例: /chat, 留空随机): " WS_PATH
[[ -z "$WS_PATH" ]] && WS_PATH="/$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 8)"

read -p "请输入 TLS 域名 (Server Name): " VLESS_SNI
read -p "请输入证书公钥 (CRT) 绝对路径: " VLESS_CERT
read -p "请输入证书私钥 (KEY) 绝对路径: " VLESS_KEY

# 4. 部署 Hysteria2 节点
echo ""
echo ">>> 开始部署 Hysteria2 节点"
read -p "请输入 HY2 密码 (留空随机生成 20 位): " HY2_PASS
[[ -z "$HY2_PASS" ]] && HY2_PASS=$(head /dev/urandom | tr -dc 'a-zA-Z0-9' | head -c 20)

read -p "请输入节点监听端口 (30000-50000, 留空随机): " HY2_PORT
[[ -z "$HY2_PORT" ]] && HY2_PORT=$((RANDOM % 20001 + 30000))

read -p "是否随机生成 TLS 证书? (y/n, 留空回车默认随机生成): " GEN_CERT
if [[ "$GEN_CERT" == "n" ]]; then
    read -p "请输入 HY2 TLS 域名 (Server Name): " HY2_SNI
    read -p "请输入证书公钥 (CRT) 绝对路径: " HY2_CERT
    read -p "请输入证书私钥 (KEY) 绝对路径: " HY2_KEY
else
    HY2_SNI="www.bing.com"
    HY2_CERT="/opt/sing-box/hy2_cert.pem"
    HY2_KEY="/opt/sing-box/hy2_key.pem"
    openssl req -x509 -nodes -newkey rsa:2048 -keyout "$HY2_KEY" -out "$HY2_CERT" -subj "/CN=$HY2_SNI" -days 3650
    echo "已生成自签名证书 (SNI: $HY2_SNI)"
fi

# 5. 生成 config.json 到 /opt/sing-box/
cat <<EOF > /opt/sing-box/config.json
{
  "log": { "disabled": true, "level": "panic" },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $VLESS_PORT,
      "users": [{ "uuid": "$VLESS_UUID" }],
      "tls": {
        "enabled": true,
        "server_name": "$VLESS_SNI",
        "certificate_path": "$VLESS_CERT",
        "key_path": "$VLESS_KEY"
      },
      "transport": {
        "type": "ws",
        "path": "$WS_PATH"
      }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-in",
      "listen": "::",
      "listen_port": $HY2_PORT,
      "users": [{ "password": "$HY2_PASS" }],
      "tls": {
        "enabled": true,
        "server_name": "$HY2_SNI",
        "certificate_path": "$HY2_CERT",
        "key_path": "$HY2_KEY"
      }
    }
  ],
  "outbounds": [
    { "type": "direct", "tag": "direct" }
  ]
}
EOF

# 6. 设置 Systemd 服务并开机自启
cat <<EOF > /etc/systemd/system/sing-box.service
[Unit]
Description=sing-box service
Documentation=https://sing-box.sagernet.org
After=network.target nss-lookup.target

[Service]
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE CAP_NET_RAW
ExecStart=/usr/local/bin/sing-box run -c /opt/sing-box/config.json
Restart=on-failure
RestartSec=10s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable sing-box
systemctl restart sing-box

# 7. 生成链接并写入文件
IP=$(curl -s ifconfig.me)
WS_PATH_ENC=$(echo $WS_PATH | sed 's/\//%2F/g')

VLESS_LINK="vless://$VLESS_UUID@www.visa.com:443?encryption=none&security=tls&sni=$VLESS_SNI&type=ws&host=$VLESS_SNI&path=$WS_PATH_ENC#VLESS_CDN"
HY2_LINK="hy2://$HY2_PASS@$IP:$HY2_PORT?sni=$HY2_SNI&insecure=1#HY2_Node"

# 导入到指定文件
cat <<EOF > /opt/sing-box/sing.txt
VLESS 节点链接:
$VLESS_LINK

Hysteria2 节点链接:
$HY2_LINK
EOF

# 8. 输出结果到屏幕
echo ""
echo "=================================================="
echo "singbox 正在运行"
echo "配置文件: /opt/sing-box/config.json"
echo "节点保存: /opt/sing-box/sing.txt"
echo "如果配置了防火墙，请开放$VLESS_PORT端口和$HY2_PORT端口"
echo "=================================================="
echo "节点 1 (VLESS+WS+TLS):"
echo "$VLESS_LINK"
echo "--------------------------------------------------"
echo "节点 2 (Hysteria2):"
echo "$HY2_LINK"
echo "=================================================="
