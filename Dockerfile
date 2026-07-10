# syntax=docker/dockerfile:1

FROM ubuntu:24.04 AS scansnap_wifi_build

ARG SCANSNAP_WIFI_REF=814c0987c9c294f27b18f1835c3c69174889de11

RUN sed -i 's/ noble-backports//g' /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-upgrade --no-install-recommends \
        build-essential \
        ca-certificates \
        git \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN mkdir -p /out \
    && git clone https://github.com/bramheerink/scansnap.git . \
    && git checkout "${SCANSNAP_WIFI_REF}" \
    && gcc -std=c17 -Wall -Wextra -Wpedantic -Wformat-security \
        -fstack-protector-strong -O2 -D_GNU_SOURCE \
        -Wno-error=unused-result \
        -o /out/scansnap-wifi scansnap.c -lpthread

FROM swift:6.3.2-noble AS swift_build

WORKDIR /swift
COPY Package.swift Package.resolved ./
RUN swift package resolve

COPY Sources Sources
COPY tests/ScannerServerCoreTests tests/ScannerServerCoreTests
RUN swift build -c release --jobs 1 --product scannerserver \
        -Xswiftc -num-threads -Xswiftc 1 \
    && binary_path="$(find /swift/.build -path '*/release/scannerserver' -type f | head -n 1)" \
    && test -n "${binary_path}" \
    && install -Dm755 "${binary_path}" /out/scannerserver
RUN resource_path="$(find /swift/.build -type d -name '*_ScannerServerCore.resources' | head -n 1)" \
    && test -n "${resource_path}" \
    && cp -R "${resource_path}" /out/ScannerServer_ScannerServerCore.resources

FROM swift:6.3.2-noble-slim

LABEL org.opencontainers.image.title="scannerserver"

ARG APP_UID=1000
ARG APP_GID=1000
ARG VCS_REF=unknown

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/scansnap \
    SANE_CONFIG_DIR=/app/sane.d \
    SCANNERSERVER_VERSION=${VCS_REF}

RUN sed -i \
        -e 's/ noble-backports//g' \
        -e 's|http://ports.ubuntu.com/ubuntu-ports/|https://ports.ubuntu.com/ubuntu-ports/|g' \
        -e 's|http://archive.ubuntu.com/ubuntu/|https://archive.ubuntu.com/ubuntu/|g' \
        -e 's|http://security.ubuntu.com/ubuntu/|https://security.ubuntu.com/ubuntu/|g' \
        /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get -o Acquire::Retries=5 update \
    && apt-get -o Acquire::Retries=5 install -y --no-upgrade --no-install-recommends \
        avahi-daemon \
        avahi-utils \
        dbus \
        img2pdf \
        iproute2 \
        libcap2-bin \
        libimage-exiftool-perl \
        libvips-tools \
        ocrmypdf \
        poppler-utils \
        qpdf \
        sane-airscan \
        sane-utils \
        tesseract-ocr-deu \
        tesseract-ocr-eng \
        tesseract-ocr-osd \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

RUN mkdir -p /app/sane.d /opt/scannerserver /scans /home/scansnap \
    && cp -a /etc/sane.d/. /app/sane.d/ \
    && chown -R "${APP_UID}:${APP_GID}" /app /scans /home/scansnap

COPY --from=scansnap_wifi_build /out/scansnap-wifi /usr/local/bin/scansnap-wifi
COPY --from=swift_build /out/scannerserver /opt/scannerserver/scannerserver
COPY --from=swift_build /out/ScannerServer_ScannerServerCore.resources /opt/scannerserver/ScannerServer_ScannerServerCore.resources
COPY scripts/entrypoint.sh /usr/local/bin/scansnap-entrypoint

RUN chmod +x /usr/local/bin/scansnap-entrypoint \
    && setcap cap_net_bind_service=+ep /opt/scannerserver/scannerserver

ENV PATH="${PATH}:/opt/scannerserver"

EXPOSE 8080
EXPOSE 80

USER ${APP_UID}:${APP_GID}
ENTRYPOINT ["scansnap-entrypoint"]
CMD ["scannerserver"]
