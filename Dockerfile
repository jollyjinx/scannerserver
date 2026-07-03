FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1

RUN apt-get update && apt-get install -y --no-install-recommends \
    avahi-daemon \
    avahi-utils \
    dbus \
    img2pdf \
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

WORKDIR /app

COPY app.py /app/app.py
COPY config/topics.json /app/config/topics.json
COPY scripts/entrypoint.sh /usr/local/bin/scansnap-entrypoint
COPY scripts/scan_once.sh /usr/local/bin/scan-once
COPY scripts/list_devices.sh /usr/local/bin/list-scanners
COPY scripts/classify_scan.py /usr/local/bin/classify-scan

RUN chmod +x /usr/local/bin/scansnap-entrypoint /usr/local/bin/scan-once /usr/local/bin/list-scanners /usr/local/bin/classify-scan

EXPOSE 8080

ENTRYPOINT ["scansnap-entrypoint"]
CMD ["python3", "/app/app.py"]
