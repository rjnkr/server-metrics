FROM alpine:3.20

RUN apk add --no-cache curl jq

WORKDIR /app
COPY --chmod=755 metrics.sh .

ENV HOST_NAME=""
ENV SEQ_URL=http://seq:5341
ENV SEQ_API_KEY=""
ENV INTERVAL=60
ENV WARN_PERCENT=90
ENV DISK_PATH=/host
ENV DOCKER_URL=""

CMD ["./metrics.sh"]
