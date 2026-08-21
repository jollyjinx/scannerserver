---
title: Releasing scannerserver
description: Maintainer checklist for validating, tagging, publishing, and verifying a GitHub release and GHCR image.
type: guide
audience: maintainers
status: current
---

# Releasing scannerserver

Releases use a SemVer Git tag such as `3.1.0` and a matching GitHub Release. The public container is
published as `ghcr.io/jollyjinx/scannerserver:<tag>`. The `latest` tag follows the default `main`
branch rather than the GitHub Release event, so the release commit must reach `main` before it is
tagged.

The version shown by the web UI and `/version` is intentionally different from the SemVer release
tag. It is the tagged commit's Git timestamp in `YYYY.MM.DD.HHMMSS` form, which also becomes the OCI
image version label. The full commit SHA is recorded as the OCI revision.

## 1. Choose the version and prepare notes

Inspect changes since the newest release tag:

```bash
git fetch --tags jnxpublic
git fetch --tags github
previous_tag="$(git tag --sort=-version:refname | head -n 1)"
git log --reverse --format='- %s (%h)' "${previous_tag}..HEAD"
git diff --stat "${previous_tag}..HEAD"
```

Choose the next SemVer version from the public impact:

- increment the patch version for compatible fixes only;
- increment the minor version for compatible user-facing capabilities;
- increment the major version for an intentional compatibility break.

Release notes should lead with operator-visible changes and call out new settings, endpoints,
container behavior, migration steps, compatibility changes, and known limitations. Internal
refactors belong in a short maintenance section unless they materially change reliability or
performance.

## 2. Validate the release candidate

Start from a clean worktree on the exact commit intended for `main`. Run the package and container
baseline:

```bash
swift build
swift test
docker build --tag scannerserver:release-candidate .
CONTAINER_COMMAND=docker \
  ./scripts/smoke_swift_container.sh scannerserver:release-candidate
```

Also run the checks required by the changed contract:

- use [`swift-hardware-validation.md`](swift-hardware-validation.md) for ScanSnap transport,
  discovery, pairing, acquisition, physical-button, or native image-processing changes;
- exercise a remote worker for worker protocol, lease, scheduling, or worker-image changes;
- submit, poll, download, cancel, and delete a job for OCR API changes;
- verify both `linux/amd64` and `linux/arm64` when the Dockerfile, packaged tools, or platform
  dependencies changed.

Record any intentionally omitted hardware or platform check in the GitHub release notes.

## 3. Publish `main` and the tag

The repository's `all` remote pushes to both Gitmaster and GitHub. After the reviewed release
commit is on `main`, create an annotated tag on that exact commit and publish both refs:

```bash
version="3.1.0" # replace with the selected version
git switch main
git merge --ff-only jnxpublic/main
git merge --ff-only github/main
git merge --ff-only development
git tag -a "${version}" -m "scannerserver ${version}"
git push all main "${version}"
```

The two remote-main merges verify that Gitmaster and GitHub have not diverged before the release.
Stop and reconcile them if either merge cannot fast-forward. Do not move or reuse a published
release tag. If publication fails before a release becomes public, diagnose which remote received
each ref before deciding on a corrective tag.

The GitHub tag push starts the container workflow. It runs Swift tests, builds and smoke-tests the
container, and publishes the multi-platform GHCR image with the matching tag. The `main` push also
updates `latest` after its workflow succeeds.

## 4. Create the GitHub Release

Review the generated notes before publication, then create the release from the existing tag:

```bash
gh release create "${version}" \
  --repo jollyjinx/scannerserver \
  --verify-tag \
  --title "scannerserver ${version}" \
  --generate-notes
```

For curated notes, add `--notes-file /absolute/path/to/release-notes.md` instead of
`--generate-notes`. Do not place credentials, scanner addresses, worker tokens, customer document
names, or private registry URLs in public notes.

Publishing the GitHub Release emits another supported workflow event for the same commit. Treat the
tag-triggered workflow as the image publication gate; the release page can be corrected without
moving the Git tag.

## 5. Verify the published release

Wait for the GitHub Actions run to succeed, then verify the release, manifest, and runtime metadata:

```bash
gh release view "${version}" --repo jollyjinx/scannerserver
docker buildx imagetools inspect "ghcr.io/jollyjinx/scannerserver:${version}"
docker pull "ghcr.io/jollyjinx/scannerserver:${version}"
docker run --rm "ghcr.io/jollyjinx/scannerserver:${version}" --version
```

The manifest must include `linux/amd64` and `linux/arm64`. Confirm that the release page points to
the intended tag, `/version` matches `./scripts/git_commit_version.sh <tag>`, and the UI header links
to the GitHub Releases page. Finally, verify that `latest` resolves to the released `main` commit
before announcing the release to users.

If the release changes scanner or processing behavior, perform the applicable deployed smoke or
hardware check against the tagged image—not only the locally built candidate.
