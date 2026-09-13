#!/usr/bin/env bash
set -euo pipefail

: "${GH_TOKEN:?GitHub token is required}"
: "${GH_REPO:?GitHub repository is required}"
: "${RELEASE_TAG:?Release tag is required}"
: "${RELEASE_VERSION:?Package version is required}"

if [[ "$RELEASE_TAG" != "v$RELEASE_VERSION" ]]; then
  printf 'Release tag does not match the package version.\n' >&2
  exit 1
fi

assets=(
  "release/ssh-switch-$RELEASE_VERSION.zip"
  "release/ssh-switch-$RELEASE_VERSION-source.zip"
  "release/ssh-switch-mount-windows.zip"
  "release/ssh-switch-mount-linux.zip"
  "release/ssh-switch-mount-macos.zip"
  "release/SHA256SUMS"
)
for asset in "${assets[@]}"; do
  if [[ ! -f "$asset" ]]; then
    printf 'Missing release asset: %s\n' "$asset" >&2
    exit 1
  fi
done

if draft="$(gh release view "$RELEASE_TAG" --repo "$GH_REPO" --json isDraft --jq .isDraft 2>/dev/null)"; then
  if [[ "$draft" != true ]]; then
    printf 'Release %s is already published; its assets will not be replaced.\n' "$RELEASE_TAG"
    exit 0
  fi
else
  gh release create "$RELEASE_TAG" --repo "$GH_REPO" --verify-tag --draft \
    --title "SSH Switch $RELEASE_TAG" --generate-notes
fi

# Upload before publishing, including on repositories with immutable releases.
# A rerun can finish an interrupted draft without replacing a published release.
gh release upload "$RELEASE_TAG" "${assets[@]}" --repo "$GH_REPO" --clobber
options=(--draft=false)
if [[ "$RELEASE_VERSION" == *-* ]]; then
  options+=(--prerelease --latest=false)
else
  options+=(--prerelease=false)
fi
gh release edit "$RELEASE_TAG" --repo "$GH_REPO" "${options[@]}"
