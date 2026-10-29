FROM alpine:3.20

# Install nginx + wget + openssl (per-brand publisher credentials) + acme.sh (RTMPS certificate)
RUN apk add --no-cache wget tar nginx openssl acme.sh

# Download MediaMTX
# 1.19.1 (from 1.9.3) — security fixes since: hook command injection (1.18.1),
# directory traversal (1.17.1), auth brute-force delay (1.19.1). Config migrated
# to the new keys (hlsAllowOrigins, pathDefaults.record*) + MoQ disabled.
ARG MEDIAMTX_VERSION=1.19.1
RUN wget -O /tmp/mediamtx.tar.gz \
    "https://github.com/bluenviron/mediamtx/releases/download/v${MEDIAMTX_VERSION}/mediamtx_v${MEDIAMTX_VERSION}_linux_amd64.tar.gz" && \
    tar -xzf /tmp/mediamtx.tar.gz -C /usr/local/bin/ mediamtx && \
    rm /tmp/mediamtx.tar.gz && \
    chmod +x /usr/local/bin/mediamtx

COPY mediamtx.yml /etc/mediamtx/mediamtx.yml
COPY nginx.conf /etc/nginx/nginx.conf
COPY start.sh /start.sh
COPY notify.sh /notify.sh
RUN chmod +x /start.sh /notify.sh

# Create recordings directory (will be mounted as Railway Volume)
RUN mkdir -p /recordings

# Single public port: nginx routes HLS + playback + recordings
EXPOSE 8888
# RTMP port (Railway TCP Proxy for OBS)
EXPOSE 1935
# RTMPS port (second Railway TCP proxy)
EXPOSE 1936

CMD ["/start.sh"]
