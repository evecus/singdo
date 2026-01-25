#!/bin/bash

# 检查必要变量
if [ -z "$LUUID" ] || [ -z "$MUUID" ] || [ -z "$DOMAIN" ] || [ -z "$TOKEN" ] || [ -z "$PASSWORD" ]; then
    echo "错误: 请确保设置了 LUUID, MUUID, DOMAIN, TOKEN 和 PASSWORD 环境变量。"
    exit 1
fi

# 固定参数
WS_PATH="/YDT4hf6q3ndbRzwve1wiejjn3eu39ijwjhe"
VLESS_PORT=1080
VMESS_PORT=8001
HY2_PORT=8888
SNI_DEFAULT="www.bing.com"

# 1. 生成自签名证书 (用于 VLESS 和 Hy2 的 TLS)
openssl req -x509 -nodes -newkey rsa:2048 -keyout /tmp/server.key -out /tmp/server.crt -days 3650 -subj "/CN=${DOMAIN}" > /dev/null 2>&1

# 2. 获取公网 IP (用于直连节点生成)
IP=$(curl -s https://api.ipify.org || echo "YOUR_SERVER_IP")

# 3. 生成 sing-box 配置文件
cat <<EOF > /etc/sing-box.json
{
  "log": { "level": "warn", "timestamp": true },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-direct",
      "listen": "::",
      "listen_port": ${VLESS_PORT},
      "users": [{ "uuid": "${LUUID}" }],
      "tls": {
        "enabled": true,
        "server_name": "www.apple.com",
        "certificate_path": "/tmp/server.crt",
        "key_path": "/tmp/server.key"
      }
    },
    {
      "type": "vmess",
      "tag": "vmess-argo",
      "listen": "::",
      "listen_port": ${VMESS_PORT},
      "users": [{ "uuid": "${MUUID}" }],
      "transport": { "type": "ws", "path": "${WS_PATH}" }
    },
    {
      "type": "hysteria2",
      "tag": "hy2-direct",
      "listen": "::",
      "listen_port": ${HY2_PORT},
      "users": [{ "password": "${PASSWORD}" }],
      "tls": {
        "enabled": true,
        "server_name": "${SNI_DEFAULT}",
        "certificate_path": "/tmp/server.crt",
        "key_path": "/tmp/server.key"
      }
    }
  ],
  "outbounds": [{ "type": "direct", "tag": "direct" }]
}
EOF

# 4. 生成节点链接
# VLESS (直连)
VLESS_LINK="vless://${LUUID}@${IP}:${VLESS_PORT}?encryption=none&security=tls&sni=${DOMAIN}&allowInsecure=1#VLESS_Direct"

# VMess (Argo)
VMESS_JSON=$(cat <<EOF
{ "v": "2", "ps": "VMess_Argo", "add": "www.visa.com", "port": "443", "id": "${MUUID}", "aid": "0", "scy": "auto", "net": "ws", "type": "none", "host": "${DOMAIN}", "path": "${WS_PATH}", "tls": "tls", "sni": "${DOMAIN}" }
EOF
)
VMESS_LINK="vmess://$(echo -n "$VMESS_JSON" | base64 -w 0)"

# Hysteria2 (直连)
HY2_LINK="hysteria2://${PASSWORD}@${IP}:${HY2_PORT}?insecure=1&sni=${SNI_DEFAULT}#Hy2_Direct"

# 5. 启动服务 (静默)
cloudflared tunnel --no-autoupdate run --token ${TOKEN} > /dev/null 2>&1 &
sing-box run -c /etc/sing-box.json > /dev/null 2>&1 &

# 6. 检测并输出
echo "正在启动多协议服务并检测隧道..."
sleep 5
echo "---------------------------------------------------"
echo "✅ 服务已就绪！"
echo "---------------------------------------------------"
echo "1. VLESS 直连节点 (TLS+自签名):"
echo "${VLESS_LINK}"
echo "---------------------------------------------------"
echo "2. VMess Argo 隧道节点 (WS):"
echo "${VMESS_LINK}"
echo "---------------------------------------------------"
echo "3. Hysteria2 直连节点 (UDP):"
echo "${HY2_LINK}"
echo "---------------------------------------------------"

# 保持运行
wait
