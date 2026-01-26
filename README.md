docker run -d \
  --name all-in-one-proxy \
  --restart always \
  -p 1080:1080 \
  -p 8888:8888 \
  -e LUUID="你的VLESS-UUID" \
  -e MUUID="你的VMess-UUID" \
  -e DOMAIN="你的域名" \
  -e TOKEN="Argo隧道Token" \   #vmess-port=8001
  -e PASSWORD="Hy2密码" \
  ghcr.io/evecus/singdo:latest


bash <(curl -Ls https://raw.githubusercontent.com/evecus/singdo/refs/heads/main/sing-vps.sh)
