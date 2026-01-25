FROM alpine:latest AS builder
RUN apk add --no-cache curl unzip
RUN SB_VERSION=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/v//') && \
    curl -Lo /tmp/sing-box.tar.gz https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/sing-box-${SB_VERSION}-linux-amd64.tar.gz && \
    tar -xzf /tmp/sing-box.tar.gz -C /tmp && \
    mv /tmp/sing-box-*/sing-box /usr/local/bin/
RUN curl -Lo /usr/local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && \
    chmod +x /usr/local/bin/cloudflared

FROM alpine:latest
RUN apk add --no-cache bash curl openssl ca-certificates
COPY --from=builder /usr/local/bin/sing-box /usr/local/bin/
COPY --from=builder /usr/local/bin/cloudflared /usr/local/bin/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# 环境变量占位
ENV LUUID="" MUUID="" DOMAIN="" TOKEN="" PASSWORD=""

ENTRYPOINT ["/bin/bash", "/entrypoint.sh"]
