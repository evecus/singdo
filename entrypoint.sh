#!/bin/bash

# --- 辅助变量 ---
generate_random_string() { tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 12; }
RAND_PORT=$((RANDOM % 45535 + 10000))
RAND_PASS=$(generate_random_string)
RAND_UUID=$(cat /proc/sys/kernel/random/uuid)
IP=$(curl -s https://api.ipify.org || echo "YOUR_SERVER_IP")

# 初始化配置
CONFIG='{"log":{"level":"warn"},"inbounds":[],"outbounds":[{"type":"direct"}]}'

# --- 证书生成 (Hy2 / TUIC / VLESS 共用) ---
openssl req -x509 -nodes -newkey rsa:2048 -keyout /tmp/server.key -out /tmp/server.crt -days 3650 -subj "/CN=www.bing.com" > /dev/null 2>&1

# --- 逻辑判断 ---

# 1. Hysteria2
if [[ "$SELECTS" == *"hysteria2"* ]] || [[ -z "$SELECTS" ]]; then
    P_PASS=${PASSWORD:-$RAND_PASS}
    P_PORT=${HPORT:-${PORT:-$RAND_PORT}}
    HY2_INBOUND=$(jq -n --arg pass "$P_PASS" --argjson port "$P_PORT" \
        '{"type":"hysteria2","tag":"hy2-in","listen":"::","listen_port":$port,"users":[{"password":$pass}],"tls":{"enabled":true,"certificate_path":"/tmp/server.crt","key_path":"/tmp/server.key"}}')
    CONFIG=$(echo "$CONFIG" | jq --argjson in "$HY2_INBOUND" '.inbounds += [$in]')
    HY2_LINK="hysteria2://${P_PASS}@${IP}:${P_PORT}?insecure=1&sni=www.bing.com#Hy2_Direct"
fi

# 2. TUIC (逻辑与 Hy2 类似)
if [[ "$SELECTS" == *"tuic"* ]]; then
    T_PASS=${PASSWORD:-$RAND_PASS}
    T_PORT=${PORT:-$RAND_PORT}
    T_UUID=${UUID:-$RAND_UUID}
    TUIC_INBOUND=$(jq -n --arg uuid "$T_UUID" --arg pass "$T_PASS" --argjson port "$T_PORT" \
        '{"type":"tuic","tag":"tuic-in","listen":"::","listen_port":$port,"users":[{"uuid":$uuid,"password":$pass}],"congestion_control":"bbr","tls":{"enabled":true,"certificate_path":"/tmp/server.crt","key_path":"/tmp/server.key"}}')
    CONFIG=$(echo "$CONFIG" | jq --argjson in "$TUIC_INBOUND" '.inbounds += [$in]')
    TUIC_LINK="tuic://${T_UUID}:${T_PASS}@${IP}:${T_PORT}?insecure=1&sni=www.bing.com&congestion_control=bbr&alpn=h3#TUIC_Direct"
fi

# 3. VLESS + Argo
if [[ "$SELECTS" == *"vless"* ]] && [[ "$SELECTS" != *"reality"* ]]; then
    V_PORT=${LPORT:-${PORT:-1080}}
    V_UUID=${UUID:-$RAND_UUID}
    V_INBOUND=$(jq -n --arg uuid "$V_UUID" --argjson port "$V_PORT" \
        '{"type":"vless","tag":"vless-argo","listen":"::","listen_port":$port,"users":[{"uuid":$uuid}],"transport":{"type":"ws","path":"/vless-argo"}}')
    CONFIG=$(echo "$CONFIG" | jq --argjson in "$V_INBOUND" '.inbounds += [$in]')
    VLESS_LINK="vless://${V_UUID}@www.visa.com:443?encryption=none&security=tls&sni=${DOMAIN}&type=ws&host=${DOMAIN}&path=%2Fvless-argo#VLESS_Argo"
fi

# 4. VMess + Argo
if [[ "$SELECTS" == *"vmess"* ]]; then
    M_PORT=${MPORT:-${PORT:-8001}}
    M_UUID=${UUID:-$RAND_UUID}
    VM_INBOUND=$(jq -n --arg uuid "$M_UUID" --argjson port "$M_PORT" \
        '{"type":"vmess","tag":"vmess-argo","listen":"::","listen_port":$port,"users":[{"uuid":$uuid}],"transport":{"type":"ws","path":"/vmess-argo"}}')
    CONFIG=$(echo "$CONFIG" | jq --argjson in "$VM_INBOUND" '.inbounds += [$in]')
    VM_JSON=$(jq -n --arg id "$M_UUID" --arg host "$DOMAIN" \
        '{"v":"2","ps":"VMess_Argo","add":"www.visa.com","port":"443","id":$id,"aid":"0","scy":"auto","net":"ws","type":"none","host":$host,"path":"/vmess-argo","tls":"tls","sni":$host}')
    VMESS_LINK="vmess://$(echo -n "$VM_JSON" | base64 -w 0)"
fi

# 5. Reality
if [[ "$SELECTS" == *"reality"* ]]; then
    R_PORT=${PORT:-443}
    R_UUID=${UUID:-$RAND_UUID}
    KEYS=$(sing-box generate reality-keypair)
    PRIV=$(echo "$KEYS" | grep "PrivateKey" | awk '{print $2}')
    PUB=$(echo "$KEYS" | grep "PublicKey" | awk '{print $2}')
    SID=$(openssl rand -hex 8)
    REAL_IN=$(jq -n --arg uuid "$R_UUID" --argjson port "$R_PORT" --arg priv "$PRIV" --arg sid "$SID" \
        '{"type":"vless","tag":"reality-in","listen":"::","listen_port":$port,"users":[{"uuid":$uuid}],"tls":{"enabled":true,"server_name":"www.apple.com","reality":{"enabled":true,"handshake":{"server":"www.apple.com","server_port":443},"private_key":$priv,"short_id":[$sid]}}}')
    CONFIG=$(echo "$CONFIG" | jq --argjson in "$REAL_IN" '.inbounds += [$in]')
    REALITY_LINK="vless://${R_UUID}@${IP}:${R_PORT}?encryption=none&security=reality&sni=www.apple.com&fp=chrome&pbk=${PUB}&sid=${SID}#VLESS_Reality"
fi

# --- 运行服务 ---
echo "$CONFIG" > /etc/sing-box.json
[ -n "$TOKEN" ] && cloudflared tunnel --no-autoupdate run --token ${TOKEN} > /dev/null 2>&1 &
sing-box run -c /etc/sing-box.json > /dev/null 2>&1 &

# --- 输出 ---
echo "✅ 服务已就绪！"
[ -n "$HY2_LINK" ] && echo -e "Hysteria2:\n${HY2_LINK}"
[ -n "$TUIC_LINK" ] && echo -e "TUIC v5:\n${TUIC_LINK}"
[ -n "$VLESS_LINK" ] && echo -e "VLESS Argo:\n${VLESS_LINK}"
[ -n "$VMESS_LINK" ] && echo -e "VMess Argo:\n${VMESS_LINK}"
[ -n "$REALITY_LINK" ] && echo -e "Reality:\n${REALITY_LINK}"

wait
