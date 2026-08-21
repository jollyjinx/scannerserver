---
title: scannerserver agent documentation
description: Routing index for the Swift service architecture, compatibility contract, deployment, protocol, configuration, and validation guidance.
type: index
audience: agents and maintainers
status: current
last_updated: 2026-08-21
---

# Agent documentation

Use [docs/index.md](../docs/index.md) as the authoritative documentation map. This `AI/` entry point makes the established front-matter documentation discoverable to repository-wide tooling without duplicating the detailed references.

## Routing

| Topic | Read first |
| --- | --- |
| Operator setup and first scan | [README.md](../README.md) |
| Current architecture, package boundaries, compatibility, and validation | [docs/architecture.md](../docs/architecture.md) |
| Environment variables, filenames, modes, and post-processing | [docs/configuration.md](../docs/configuration.md) |
| Change the OCR HTTP/OpenAPI interface or add an LLM/MCP adapter | [scannerserver-ocr-api skill](skills/scannerserver-ocr-api/SKILL.md), then [docs/ocr-api.md](../docs/ocr-api.md) |
| Built-in and distributed OCR worker setup, scheduling, operation, and protocol | [docs/ocr-workers.md](../docs/ocr-workers.md) |
| Images, host networking, Compose, builds, and publishing | [docs/deployment.md](../docs/deployment.md) |
| Versioning, release validation, Git tags, GitHub Releases, and GHCR promotion | [docs/releasing.md](../docs/releasing.md) |
| ScanSnap iX500 discovery, pairing, transport, and button behavior | [docs/protocol.md](../docs/protocol.md) |
| Real-hardware acceptance | [docs/swift-hardware-validation.md](../docs/swift-hardware-validation.md) |

## Current State And Scope

The Python-to-Swift service migration is complete. Read the current architecture document before
broad implementation changes.

If a request's premise conflicts with the current tree, verify recent history and report the
mismatch before changing code. An unqualified cleanup is behavior-preserving and does not authorize
runtime redesign, public-API contraction, protocol changes, or replacement of working subsystems.

## Project shape

`scannerserver` is a Swift 6.3, Linux-first service packaged with SwiftPM and deployed as a multi-stage container image. `Sources/scannerserver` is the thin ArgumentParser entry point. `Sources/ScannerServerCore` owns the HTTP application, settings, document and preview operations, scan/OCR pipeline, ScanSnap networking, and long-lived runtime actors. Swift Testing coverage lives under `tests/ScannerServerCoreTests`.

The runtime implements ScanSnap acquisition and raw PDF assembly in Swift. It invokes native tools
for OCR, later PDF/image processing, metadata, and optional SANE compatibility. Treat those command
dependencies and the SwiftPM resource bundle as part of the container contract.

## Compatibility boundaries

Preserve the published image name, host-network assumptions, ports `80` and `8080`, arbitrary non-root UID/GID operation, the `/scans` volume, documented environment variables, persisted JSON schemas, output filenames, `.previews`, HTTP workflows, and ScanSnap protocol behavior unless a breaking change is explicitly authorized.

Hardware-dependent tests must remain opt-in. Do not infer protocol changes from unit tests alone; use the hardware checklist before publishing scanner-session, discovery, pairing, or button-runtime changes.

## Validation baseline

Run the checks appropriate to the changed layer:

```sh
swift build
swift test
docker build --tag scannerserver:local .
CONTAINER_COMMAND=docker ./scripts/smoke_swift_container.sh scannerserver:local
```

Documentation-only changes also require valid YAML front matter and resolvable local links. Container or hardware validation may be omitted only when the changed files cannot affect those layers; state the limitation explicitly.
