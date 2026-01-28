bash <(curl -Ls https://raw.githubusercontent.com/evecus/singdo/refs/heads/main/install.sh)

Multi-Protocol Sing-Box & Cloudflared Docker这是一个功能强大的多协议代理容器，支持 VLESS, VMess, Hysteria2, TUIC v5 和 Reality。容器能够自动识别架构（amd64 / arm64），并集成了 Cloudflare Argo Tunnel。✨ 特性多架构支持：原生支持 x86_64 和 aarch64 (ARM64) 架构。灵活协议切换：通过 SELECTS 环境变量自由组合所需协议 。Argo 隧道集成：支持通过 Cloudflare 隧道穿透内网 。Reality 支持：内置 Reality 密钥对生成，支持直连 VLESS 协议。自动容错：若未设置变量，系统将自动生成随机凭据搭建 Hysteria2 服务。智能节点输出：启动时自动打印所有已配置协议的节点链接。🛠 环境变量说明变量说明示例SELECTS选择协议 (可用 + 连接)vless+tuic+hysteria2UUIDVLESS/VMess/TUIC 的用户 ID550e8400-e29b-41d4-a716-446655440000PASSWORDHy2 或 TUIC 的密码your_secure_passwordDOMAINArgo 隧道绑定的域名proxy.yourdomain.comTOKENCloudflare Tunnel TokeneyJhIjoi...PORT通用端口 (若未指定具体端口则生效)443HPORT / LPORT / MPORTHy2 / VLESS / VMess 的独立端口8888 / 1080 / 8001🚀 快速开始方式一：Docker CLI部署一个带有 Argo 隧道的 VLESS + Hy2 直连服务：Bashdocker run -d \
  --name my-proxy \
  -e SELECTS="vless+hysteria2" \
  -e UUID="你的UUID" \
  -e DOMAIN="你的域名" \
  -e TOKEN="Argo-Token" \
  -e PASSWORD="你的密码" \
  -e LPORT=1080 \
  -e HPORT=8888 \
  -p 1080:1080 -p 8888:8888/udp \
  your-username/your-repo-name
方式二：Docker ComposeYAMLservices:
  proxy:
    image: your-username/your-repo-name
    container_name: proxy-service
    environment:
      - SELECTS=reality
      - UUID=550e8400-e29b-41d4-a716-446655440000
      - PORT=443
    ports:
      - "443:443"
    restart: always
🔍 查看节点链接容器启动后，运行以下命令获取生成的节点配置：Bashdocker logs -f my-proxy
⚠️ 注意事项UDP 放行：使用 Hysteria2 或 TUIC 时，请确保防火墙已开启 UDP 端口。安全性：对于直连协议，容器会自动生成自签名证书。如果追求更高安全性，建议使用 Reality 协议。Argo 性能：Argo 隧道节点（VLESS/VMess）的延迟取决于 Cloudflare 网络的连接情况。
