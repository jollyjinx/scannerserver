FROM ubuntu:24.04 AS scansnap_wifi_build

ARG SCANSNAP_WIFI_REF=814c0987c9c294f27b18f1835c3c69174889de11

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git clone https://github.com/bramheerink/scansnap.git . \
    && git checkout "${SCANSNAP_WIFI_REF}" \
    && gcc -std=c17 -Wall -Wextra -Wpedantic -Wformat-security -fstack-protector-strong -O2 -D_GNU_SOURCE -Wno-error=unused-result \
      -o /usr/local/bin/scansnap-wifi scansnap.c -lpthread

FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    SANE_CONFIG_DIR=/app/sane.d

ARG APP_UID=1000
ARG APP_GID=1000

RUN apt-get update && apt-get install -y --no-install-recommends \
    avahi-daemon \
    avahi-utils \
    dbus \
    img2pdf \
    iproute2 \
    ocrmypdf \
    python3 \
    python3-flask \
    sane-airscan \
    sane-utils \
    tesseract-ocr-deu \
    tesseract-ocr-eng \
    tesseract-ocr-osd \
    tzdata \
    && rm -rf /var/lib/apt/lists/*

ENV HOME=/home/scansnap

WORKDIR /app

RUN mkdir -p /app/sane.d /scans /home/scansnap \
    && cp -a /etc/sane.d/. /app/sane.d/ \
    && setcap cap_net_bind_service=+ep "$(readlink -f /usr/bin/python3)" \
    && chown -R "${APP_UID}:${APP_GID}" /app /scans /home/scansnap

COPY --from=scansnap_wifi_build /usr/local/bin/scansnap-wifi /usr/local/bin/scansnap-wifi
COPY app.py /app/app.py
COPY config/topics.json /app/config/topics.json
COPY scripts/entrypoint.sh /usr/local/bin/scansnap-entrypoint
COPY scripts/scan_once.sh /usr/local/bin/scan-once
COPY scripts/scansnap_button_arm.py /usr/local/bin/scansnap-button-arm
COPY scripts/list_devices.sh /usr/local/bin/list-scanners
COPY scripts/classify_scan.py /usr/local/bin/classify-scan

RUN chmod +x /usr/local/bin/scansnap-entrypoint /usr/local/bin/scan-once /usr/local/bin/scansnap-button-arm /usr/local/bin/list-scanners /usr/local/bin/classify-scan

EXPOSE 8080
EXPOSE 80

USER ${APP_UID}:${APP_GID}
ENTRYPOINT ["scansnap-entrypoint"]
CMD ["python3", "/app/app.py"]
