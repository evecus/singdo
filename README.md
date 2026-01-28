bash <(curl -Ls https://raw.githubusercontent.com/evecus/singdo/refs/heads/main/install.sh)

SELECTS 是...,搭建的协议,必填的环境变量
vless,VLESS + Argo 隧道,"UUID, DOMAIN, TOKEN, PORT"
vmess,VMess + Argo 隧道,"UUID, DOMAIN, TOKEN, PORT"
hysteria2,Hy2 直连,"PASSWORD, PORT"
tuic,TUIC v5 直连,"PASSWORD, PORT (可选 UUID)"
vless+hysteria2,Hy2 直连 + VLESS Argo,"PASSWORD, HPORT, LPORT, UUID, DOMAIN, TOKEN"
vmess+hysteria2,Hy2 直连 + VMess Argo,"PASSWORD, HPORT, MPORT, UUID, DOMAIN, TOKEN"
reality,VLESS + Reality 直连,"UUID, PORT (SNI 固定为 apple)"
(留空),默认搭建 Hy2,无（端口、密码、SNI 全部自动随机生成）      

evecus/singdo:latest
