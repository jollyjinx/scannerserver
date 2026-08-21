---
title: Documentation Index
description: Navigation map and front-matter conventions for the scannerserver documentation.
type: index
audience: users, operators, maintainers, and agents
status: current
---

# Documentation Index

Use this page as the entry point for repository documentation. The root [`README.md`](../README.md) is the human-facing GitHub project overview; it intentionally uses ordinary Markdown without YAML front matter.

## Find The Right Document

| Document | Use it for | Primary audience |
| --- | --- | --- |
| [`../AI/README.md`](../AI/README.md) | Agent routing, package shape, compatibility boundaries, and validation baseline | Agents |
| [`architecture.md`](architecture.md) | Current Swift architecture, scope guardrails, compatibility contracts, and validation | Maintainers and agents |
| [`configuration.md`](configuration.md) | Environment variables, scan modes, output names, OCR, blank-page removal, and cropping | Operators |
| [`ocr-api.md`](ocr-api.md) | OpenAPI-described PDF OCR jobs for LLM tools and service integrations | Integrators and operators |
| [`ocr-workers.md`](ocr-workers.md) | Remote OCR worker registration, approval, status, and distributed-execution roadmap | Operators and maintainers |
| [`deployment.md`](deployment.md) | Published images, host networking, Compose, local builds, and image publishing | Operators |
| [`protocol.md`](protocol.md) | ScanSnap iX500 discovery, pairing, directed port map, startup advertisements, heartbeat, and physical-button session lifecycle | Maintainers |
| [`swift-hardware-validation.md`](swift-hardware-validation.md) | Manual acceptance testing with a real scanner | Maintainers |
| [`history/swift-migration.md`](history/swift-migration.md) | Completed Python-to-Swift migration evidence and historical milestones | Maintainers |
| [`../AGENTS.md`](../AGENTS.md) | Repository-wide instructions that coding agents must follow | Agents |

## Front Matter Convention

Maintained topic documentation under `docs/` and `AI/` begins with YAML front matter. The root `README.md` is the human-facing exception because GitHub presents it directly. `AGENTS.md` may use skill-compatible `name` and `description` front matter when it is intended to act as repository-local agent guidance.

Topic documentation must provide these fields:

| Field | Purpose |
| --- | --- |
| `title` | Human-readable document title |
| `description` | One-sentence summary that lets an agent judge relevance without reading the body |
| `type` | Document role, such as `index`, `guide`, `reference`, `plan`, or `instructions` |
| `audience` | Primary readers, such as `users`, `operators`, `maintainers`, or `agents` |
| `status` | Lifecycle state, normally `current` for maintained documentation and `historical` for archived records |

Use this template for new documentation:

```markdown
---
title: Document Title
description: One sentence explaining what the document contains.
type: guide
audience: maintainers
status: current
---

# Document Title
```

Keep the description specific and put the document's navigation purpose near the beginning. When adding, moving, or removing documentation, update the table on this page so agents retain one reliable map of the repository.
