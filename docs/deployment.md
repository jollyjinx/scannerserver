---
title: Deployment and Builds
description: Container image deployment, Compose usage, local builds, and development image publishing.
type: guide
audience: operators
status: current
---

# Deployment and Builds

## Published Image

The normal install path is the prebuilt image:

```text
ghcr.io/jollyjinx/scannerserver:latest
```

It supports `linux/amd64` and `linux/arm64`, so it works on x86 Linux hosts and Raspberry Pi systems.

## Container Run

Use host networking so ScanSnap UDP discovery reaches the local network. Host networking and restart policies require options unavailable in Apple’s `container` CLI, so this deployment command uses Docker:

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

## Compose

The repository includes a simple host-network `compose.yaml`:

```bash
git clone https://gitmaster.jinx.eu/jnxpublic/scannerserver.git
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

Standalone Docker deployment:

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

Local builds are only needed when changing the Swift package or testing Dockerfile changes. The checked-in Compose service already has `build: .`, so a clean checkout can be built directly:

```bash
docker compose up -d --build
```

## Build And Push Development

Build and push a development image for both AMD64 and ARM64:

```bash
./scripts/build_push_development.sh
```

By default it builds and pushes:

```text
ghcr.io/jollyjinx/scannerserver:development
```

The script uses Docker Buildx for the multi-platform registry-publishing workflow:

```bash
docker buildx build --platform linux/amd64,linux/arm64 --push ...
```

Pass a different tag as the first argument. Override the image repository with `IMAGE` if needed:

```bash
./scripts/build_push_development.sh test
IMAGE=ghcr.io/your-user/scannerserver ./scripts/build_push_development.sh test
```

`TAG` remains supported as an environment fallback when no positional tag is provided. The positional argument takes precedence.

The previous `build_push_development_arm64.sh` path remains as a compatibility wrapper and now also publishes both architectures.

The script requires at least 10 GiB of free host disk space before starting because a dual-architecture Buildx build can expand Docker Desktop's VM disk substantially. `MIN_FREE_GIB` can raise that threshold. Setting `MIN_FREE_GIB=0` bypasses the check deliberately.

If the container runtime reports `Structure needs cleaning`, prune the builder cache and rerun:

```bash
docker buildx prune --all --force
docker builder prune --all --force
./scripts/build_push_development.sh development
```

If the output instead contains `input/output error`, `read-only file system`, `metadata_v2.db`, or `UNEXPECTED INCONSISTENCY`, Docker's VM filesystem is unhealthy. Free host disk space first, restart Docker Desktop, and follow Docker Desktop's backup and recovery workflow. A Docker Desktop Clean / Purge operation deletes local containers, images, and volumes and should only be used after preserving any required data.
