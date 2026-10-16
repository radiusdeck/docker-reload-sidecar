#!/usr/bin/env bash
set -euo pipefail

# Update the version and archive checksum together from the official release:
# https://github.com/aquasecurity/trivy/releases/tag/v0.76.0
TRIVY_VERSION="0.76.0"
TRIVY_SHA256="e24b1c51293c1b15e4ba8d45bbc7891ba053f90278ec2698f3562c993e145fe7"

if [[ "$(uname -s)" != Linux || "$(uname -m)" != x86_64 ]]; then
  echo "This installer requires a Linux x86_64 runner." >&2
  exit 1
fi

: "${RUNNER_TEMP:?RUNNER_TEMP must be set}" "${GITHUB_PATH:?GITHUB_PATH must be set}"
download_dir=$(mktemp -d "$RUNNER_TEMP/trivy-download.XXXXXX")
trap 'rm -rf "$download_dir"' EXIT
archive="trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz"
install_dir="$RUNNER_TEMP/trivy-bin"

curl --fail --silent --show-error --location --retry 3 \
  "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/${archive}" \
  --output "$download_dir/$archive"
printf '%s  %s\n' "$TRIVY_SHA256" "$download_dir/$archive" | sha256sum --check --strict
tar -xzf "$download_dir/$archive" -C "$download_dir" trivy
mkdir -p "$install_dir"
install -m 0755 "$download_dir/trivy" "$install_dir/trivy"
printf '%s\n' "$install_dir" >> "$GITHUB_PATH"
"$install_dir/trivy" --version
