FROM alpine:3.20

# Download MediaMTX
ARG MEDIAMTX_VERSION=1.9.3
RUN apk add --no-cache wget tar && \
    wget -O /tmp/mediamtx.tar.gz \
    "https://github.com/bluenviron/mediamtx/releases/download/v${MEDIAMTX_VERSION}/mediamtx_v${MEDIAMTX_VERSION}_linux_amd64.tar.gz" && \
    tar -xzf /tmp/mediamtx.tar.gz -C /usr/local/bin/ mediamtx && \
    rm /tmp/mediamtx.tar.gz && \
    chmod +x /usr/local/bin/mediamtx

COPY mediamtx.yml /etc/mediamtx/mediamtx.yml
COPY start.sh /start.sh
RUN chmod +x /start.sh

# Create recordings directory
RUN mkdir -p /recordings

# HLS port (public, for web player + recordings)
EXPOSE 8888
# RTMP port (use Railway TCP Proxy for OBS)
EXPOSE 1935

CMD ["/start.sh"]
