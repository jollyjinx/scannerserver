# syntax=docker/dockerfile:1

FROM swift:6.3.2-noble AS swift_build

WORKDIR /swift
ARG TARGETARCH
COPY Package.swift Package.resolved ./
RUN --mount=type=cache,id=scannerserver-swift-build-${TARGETARCH},target=/swift/.build,sharing=locked \
    --mount=type=cache,id=scannerserver-swiftpm-${TARGETARCH},target=/root/.cache,sharing=locked \
    --mount=type=cache,id=scannerserver-swiftpm-config-${TARGETARCH},target=/root/.swiftpm,sharing=locked \
    swift package resolve

COPY Sources Sources
COPY tests/ScannerServerCoreTests tests/ScannerServerCoreTests
RUN --mount=type=cache,id=scannerserver-swift-build-${TARGETARCH},target=/swift/.build,sharing=locked \
    --mount=type=cache,id=scannerserver-swiftpm-${TARGETARCH},target=/root/.cache,sharing=locked \
    --mount=type=cache,id=scannerserver-swiftpm-config-${TARGETARCH},target=/root/.swiftpm,sharing=locked \
    swift build -c release --jobs 1 --product scannerserver \
        -Xswiftc -num-threads -Xswiftc 1 \
    && swift build -c release --jobs 1 --product scannerserver-worker \
        -Xswiftc -num-threads -Xswiftc 1 \
    && binary_path="$(find /swift/.build -path '*/release/scannerserver' -type f | head -n 1)" \
    && worker_binary_path="$(find /swift/.build -path '*/release/scannerserver-worker' -type f | head -n 1)" \
    && test -n "${binary_path}" \
    && test -n "${worker_binary_path}" \
    && install -Dm755 "${binary_path}" /out/scannerserver \
    && install -Dm755 "${worker_binary_path}" /out/scannerserver-worker
RUN --mount=type=cache,id=scannerserver-swift-build-${TARGETARCH},target=/swift/.build,sharing=locked \
    resource_path="$(find /swift/.build -type d -name '*_ScannerServerCore.resources' | head -n 1)" \
    && test -n "${resource_path}" \
    && cp -R "${resource_path}" /out/ScannerServer_ScannerServerCore.resources

FROM swift:6.3.2-noble-slim

ARG APP_UID=1000
ARG APP_GID=1000
ARG VCS_REF=unknown
ARG SCANNERSERVER_VERSION=development
ARG OCRMYPDF_VERSION=17.8.1

LABEL org.opencontainers.image.title="scannerserver" \
    org.opencontainers.image.version="${SCANNERSERVER_VERSION}" \
    org.opencontainers.image.revision="${VCS_REF}"

ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/scansnap \
    SANE_CONFIG_DIR=/app/sane.d \
    TZ=Europe/Berlin \
    SCANNERSERVER_VERSION=${SCANNERSERVER_VERSION} \
    SCANNERSERVER_REVISION=${VCS_REF} \
    OCRMYPDF_VERSION=${OCRMYPDF_VERSION}

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
        fonts-noto-core \
        img2pdf \
        iproute2 \
        libcap2-bin \
        libimage-exiftool-perl \
        libvips-tools \
        ocrmypdf \
        poppler-utils \
        python3-venv \
        qpdf \
        sane-airscan \
        sane-utils \
        tesseract-ocr-deu \
        tesseract-ocr-eng \
        tesseract-ocr-osd \
        tzdata \
    && rm -rf /var/lib/apt/lists/*

RUN python3 -m venv /opt/ocrmypdf \
    && /opt/ocrmypdf/bin/python -m pip install \
        --disable-pip-version-check \
        --no-cache-dir \
        --retries 5 \
        "ocrmypdf==${OCRMYPDF_VERSION}" \
    && test "$(/opt/ocrmypdf/bin/ocrmypdf --version 2>&1)" = "${OCRMYPDF_VERSION}" \
    && install -d /usr/local/bin \
    && ln -sf /opt/ocrmypdf/bin/ocrmypdf /usr/local/bin/ocrmypdf

WORKDIR /app

RUN mkdir -p /app/sane.d /opt/scannerserver /scans \
        /home/scansnap/.config/scannerserver-worker \
        /home/scansnap/.cache/scannerserver-worker/jobs \
    && cp -a /etc/sane.d/. /app/sane.d/ \
    && chown -R "${APP_UID}:${APP_GID}" /app /scans /home/scansnap

COPY --from=swift_build /out/scannerserver /opt/scannerserver/scannerserver
COPY --from=swift_build /out/scannerserver-worker /opt/scannerserver/scannerserver-worker
COPY --from=swift_build /out/ScannerServer_ScannerServerCore.resources /opt/scannerserver/ScannerServer_ScannerServerCore.resources
COPY scripts/entrypoint.sh /usr/local/bin/scansnap-entrypoint

RUN chmod +x /usr/local/bin/scansnap-entrypoint \
    && setcap cap_net_bind_service=+ep /opt/scannerserver/scannerserver

ENV PATH="/opt/ocrmypdf/bin:${PATH}:/opt/scannerserver"
ENV SCANNERSERVER_WORKER_DIRECT=true

EXPOSE 8080
EXPOSE 80

USER ${APP_UID}:${APP_GID}
ENTRYPOINT ["scansnap-entrypoint"]
CMD ["scannerserver"]
