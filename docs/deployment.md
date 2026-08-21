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

The GitHub Actions workflow publishes this multi-architecture image to GHCR.

Every branch push to Gitmaster runs the tests, builds and smoke-tests an ARM64 image on the
Apple Silicon runner, and then publishes the verified image to Gitmaster's container registry:

```text
gitmaster.jinx.eu/jnxpublic/scannerserver:<branch-tag>
```

Ordinary branch names are used directly after conversion to lowercase. Characters that Docker
tags cannot contain are replaced with `-`, so `feature/scanner-ui` is published as
`gitmaster.jinx.eu/jnxpublic/scannerserver:feature-scanner-ui`. A dedicated Gitea access token
with only `write:package` scope is stored as the repository Actions secret `REGISTRY_TOKEN` and
authenticates the push.

For example:

```bash
docker pull gitmaster.jinx.eu/jnxpublic/scannerserver:development
```

The image packages both executable products. Its default command runs `scannerserver`; overriding
the command with `scannerserver-worker` starts a direct, non-privileged OCR worker from the same
image without mounting the Docker socket.

Gitmaster executes workflow steps inside a Linux job container while Docker Desktop runs the
Docker daemon on the Mac host. Paths such as `/workspace/...` therefore exist only inside the
job container and cannot be used as host bind mounts. The workflow copies Swift sources through
the Docker client and uses Docker-managed volumes for runtime smoke fixtures. Runtime HTTP checks
use `host.docker.internal` because Docker publishes the application port on the Mac host rather
than inside the Linux job container.

## Container Run

Use host networking so ScanSnap UDP discovery reaches the local network. Host networking and restart policies require options unavailable in Apple’s `container` CLI, so this deployment command uses Docker:

```bash
mkdir -p scans
docker run -d \
  --name scannerserver \
  --restart unless-stopped \
  --network host \
  --user "$(id -u):$(id -g)" \
  -e WEB_PORT=80 \
  -e TZ="${TZ:-Europe/Berlin}" \
  -v "$PWD/scans:/scans" \
  ghcr.io/jollyjinx/scannerserver:latest
```

The image defaults to `Europe/Berlin`. Set `TZ` to another IANA time-zone name on hosts in a
different region; that value controls both scan filenames and times shown in the web UI.

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

The service derives its container IP from the macvlan interface. Scanner selection and pairing
are handled by the first-run web setup.

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
export SCANNERSERVER_VERSION="$(./scripts/git_commit_version.sh)"
export VCS_REF="$(git rev-parse HEAD)"
docker compose build \
  --build-arg "SCANNERSERVER_VERSION=${SCANNERSERVER_VERSION}" \
  --build-arg "VCS_REF=${VCS_REF}"
docker compose up -d
```

`git_commit_version.sh` formats the commit timestamp recorded by Git as `YYYY.MM.DD.HHMMSS`.
The image exposes that value in the web page header, at `/version`, through
`SCANNERSERVER_VERSION`, and in the OCI image version label. The header version links to the
project's [GitHub releases](https://github.com/jollyjinx/scannerserver/releases), while `/version`
remains a plain-text endpoint for scripts and health tooling. The full commit SHA remains available
as `SCANNERSERVER_REVISION` and in the OCI revision label. Automated GitHub, Gitmaster, and
`build_and_push_image.sh` builds set both values.

## Build And Push An Image

Select exactly one registry. With no architecture option, the script builds and pushes both AMD64
and ARM64 under one multi-platform tag:

```bash
./scripts/build_and_push_image.sh --github
./scripts/build_and_push_image.sh --gitmaster
```

The default tag is the current branch name, normalized with the same rules as the Gitmaster
workflow. For example, running from `development` publishes one of:

```text
ghcr.io/jollyjinx/scannerserver:development
gitmaster.jinx.eu/jnxpublic/scannerserver:development
```

Use `--tag` to override it:

```bash
./scripts/build_and_push_image.sh --github --tag jinx
```

For a faster native-architecture build, select only one platform:

```bash
./scripts/build_and_push_image.sh --gitmaster --arm64 --tag jinx
./scripts/build_and_push_image.sh --github --amd64 --tag test-amd64
```

Single-platform publication replaces the selected registry tag with a single-platform manifest. Use
an architecture-specific tag when existing consumers of the same tag still need the other
architecture.

On macOS, the script uses Apple Container to build locally and then push the resulting image. On
other hosts it uses Docker Buildx and pushes directly from the builder. Registry login remains an
operator prerequisite: use `container registry login` on macOS or `docker login` elsewhere.

The Swift build stage keeps per-architecture BuildKit cache mounts for `/swift/.build`, SwiftPM
downloads, and SwiftPM configuration. After the first image build, unchanged dependencies and
Swift source files reuse their Linux release artifacts; only invalidated sources are recompiled.
The host package's `.build` directory is intentionally not mounted because macOS objects cannot be
used in a Linux image and ARM64/AMD64 build products must remain isolated.

The runtime stage retains Ubuntu Noble's OCRmyPDF package for native dependencies and installs the
application's pinned OCRmyPDF `17.8.1` into `/opt/ocrmypdf`. The isolated executable takes
precedence on `PATH`; `OCRMYPDF_VERSION` exposes the selected build version, and the container smoke
test verifies it. A development build can temporarily test another release with
`--build-arg OCRMYPDF_VERSION=<version>`, but the checked-in pin remains the supported version.

Run `--help` for the complete interface:

```bash
./scripts/build_and_push_image.sh --help
```

Publishing a numbered project release also requires validation, an annotated Git tag, a GitHub
Release, and verification of the multi-platform GHCR manifest. Follow the
[maintainer release checklist](releasing.md) instead of using this development-image script as the
release procedure.

If Docker reports `Structure needs cleaning`, `input/output error`, `read-only file system`,
`metadata_v2.db`, or `UNEXPECTED INCONSISTENCY`, its VM filesystem is unhealthy. Free host disk
space first, restart Docker Desktop, and follow Docker Desktop's backup and recovery workflow. A
Docker Desktop Clean / Purge operation deletes local containers, images, and volumes and should
only be used after preserving required data.
