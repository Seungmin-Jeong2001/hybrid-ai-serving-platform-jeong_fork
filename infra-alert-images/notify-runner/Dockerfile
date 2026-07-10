FROM alpine:3.20

RUN apk add --no-cache \
    curl \
    jq \
    ca-certificates \
    tzdata \
    && update-ca-certificates

COPY notify.sh /usr/local/bin/notify.sh
RUN chmod +x /usr/local/bin/notify.sh

ENTRYPOINT ["/usr/local/bin/notify.sh"]