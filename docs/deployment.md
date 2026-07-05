# Deployment and Builds

## Published Image

The normal install path is the prebuilt image:

```text
ghcr.io/jollyjinx/scannerserver:latest
```

It supports `linux/amd64` and `linux/arm64`, so it works on x86 Linux hosts and Raspberry Pi systems.

## Docker Run

Use host networking so ScanSnap UDP discovery reaches the local network:

```bash
mkdir -p scans
docker run -d \
  --name scannerserver \
  --restart unless-stopped \
  --network host \
  --user "$(id -u):$(id -g)" \
  -e TZ=Europe/Berlin \
  -e WEB_PORT=80 \
  -v "$PWD/scans:/scans" \
  ghcr.io/jollyjinx/scannerserver:latest
```

Using only `-p 8080:8080` puts the container on a bridge network. The web UI is reachable that way, but ScanSnap UDP discovery usually searches the container network instead of the scanner LAN.

## Docker Compose

The repository includes a simple host-network `compose.yaml`:

```bash
git clone https://github.com/jollyjinx/scannerserver.git
cd scannerserver
mkdir -p scans
docker compose up -d
```

## Raspberry Pi Macvlan Example

`deploy/raspberry-pi/compose.yaml` is an example service for a Raspberry Pi macvlan deployment.

Example values:

```text
container IP:     ${NETWORK_PREFIX}.10.6
container MAC:    da:e0:c0:24:d4:f8
macvlan network:  aservice1010
```

Set the network prefix in the environment used by Compose:

```text
NETWORK_PREFIX=10.112
```

`SCANNER_IP` and `SCANSNAP_PAIRING_KEY` are optional if you use the web setup.

If you already have a larger home-lab Compose file, copy only the scanner service into it instead of replacing your stack.

```bash
docker compose config --quiet
docker compose up -d --no-deps scansnap
```

## Updating

Standalone `docker run`:

```bash
docker pull ghcr.io/jollyjinx/scannerserver:latest
docker stop scannerserver
docker rm scannerserver
# rerun the docker run command
```

Compose:

```bash
git pull
docker compose pull
docker compose up -d
```

## Build From Source

Local builds are only needed when changing the app or testing Dockerfile changes.

With Compose, add `compose.override.yaml`:

```yaml
services:
  scansnap:
    build: .
    image: scannerserver:local
```

Then run:

```bash
docker compose up -d --build
```

## Build And Push Development ARM64

For Raspberry Pi testing:

```bash
./scripts/build_push_development_arm64.sh
```

By default it builds and pushes:

```text
ghcr.io/jollyjinx/scannerserver:development-arm64
```

The script uses Docker Buildx:

```bash
docker buildx build --platform linux/arm64 --push ...
```

Override the target if needed:

```bash
IMAGE=ghcr.io/your-user/scannerserver TAG=test-arm64 ./scripts/build_push_development_arm64.sh
```

If Docker reports `Structure needs cleaning`, prune the builder cache and rerun:

```bash
docker buildx prune --all --force
docker builder prune --all --force
./scripts/build_push_development_arm64.sh
```
