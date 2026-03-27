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

# RTMP port (for OBS ingest)
EXPOSE 1935
# HLS port (for web player)
EXPOSE 8888

CMD ["mediamtx", "/etc/mediamtx/mediamtx.yml"]
