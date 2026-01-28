FROM alpine:latest AS builder
RUN apk add --no-cache curl unzip

# 自动识别架构并下载对应的二进制文件 
RUN ARCH=$(uname -m) && \
    if [ "$ARCH" = "x86_64" ]; then \
        SB_ARCH="linux-amd64"; CF_ARCH="amd64"; \
    elif [ "$ARCH" = "aarch64" ]; then \
        SB_ARCH="linux-arm64"; CF_ARCH="arm64"; \
    fi && \
    # 下载 sing-box 
    SB_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/v//') && \
    curl -Lo /tmp/sing-box.tar.gz https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-${SB_ARCH}.tar.gz && \
    tar -xzf /tmp/sing-box.tar.gz -C /tmp && \
    mv /tmp/sing-box-*/sing-box /usr/local/bin/ && \
    # 下载 cloudflared 
    curl -Lo /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CF_ARCH} && \
    chmod +x /usr/local/bin/cloudflared

FROM alpine:latest
RUN apk add --no-cache bash curl openssl ca-certificates jq
COPY --from=builder /usr/local/bin/sing-box /usr/local/bin/
COPY --from=builder /usr/local/bin/cloudflared /usr/local/bin/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 环境变量占位 
ENV SELECTS="" UUID="" DOMAIN="" TOKEN="" PORT="" PASSWORD="" HPORT="" LPORT="" MPORT=""

ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
