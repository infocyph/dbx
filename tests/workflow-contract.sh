#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Execute the workflow's actual resolver so this covers changes to CI itself.
awk '
  /^      - name: Resolve stable release source$/ { step=1; next }
  step && /^        run: \|$/ { script=1; next }
  script && /^          / { sub(/^          /, ""); print; next }
  script && /^$/ { print; next }
  script { exit }
' "$ROOT/.github/workflows/docker.publish.yml" >"$tmp/resolve.sh"
[[ -s "$tmp/resolve.sh" ]]
gh() {
  [[ "$*" == 'api repos/fixture/dbx/releases/latest' ]] || return 1
  printf '%s\n' "$MOCK_RELEASE_JSON"
}
export -f gh
export GITHUB_REPOSITORY=fixture/dbx
export GITHUB_ENV="$tmp/env"
export EVENT_RELEASE_DRAFT=false EVENT_RELEASE_PRERELEASE=false
export MOCK_RELEASE_JSON='{"tag_name":"0.01","draft":false,"prerelease":false}'

accept() {
  local event="$1" tag="$2" immutable="$3"
  : >"$GITHUB_ENV"
  EVENT_NAME="$event" EVENT_RELEASE_TAG="$tag" bash "$tmp/resolve.sh"
  grep -Fxq 'DBX_SOURCE_TAG=0.01' "$GITHUB_ENV"
  grep -Fxq 'VERSION_TAG=0.01' "$GITHUB_ENV"
  grep -Fxq "PUBLISH_RELEASE_TAG=$immutable" "$GITHUB_ENV"
}
accept release 0.01 true
accept workflow_dispatch '' false
accept schedule '' false
for tag in v1.2.3 release-2026.10; do
  EVENT_NAME=release EVENT_RELEASE_TAG="$tag" bash "$tmp/resolve.sh"
  grep -Fxq "VERSION_TAG=$tag" "$GITHUB_ENV"
done
reject() {
  if EVENT_NAME=release EVENT_RELEASE_TAG="$1" bash "$tmp/resolve.sh" >"$tmp/out" 2>"$tmp/err"; then
    printf 'Resolver accepted invalid or unstable release: %s\n' "$1" >&2
    exit 1
  fi
}
for tag in '' 'invalid/tag' '.invalid' 'invalid tag'; do reject "$tag"; done
printf -v long_tag '%129s' ''
reject "${long_tag// /a}"
EVENT_RELEASE_DRAFT=true reject 0.01
EVENT_RELEASE_PRERELEASE=true reject 0.01
MOCK_RELEASE_JSON='{"tag_name":"0.01","draft":false,"prerelease":true}'
if EVENT_NAME=workflow_dispatch EVENT_RELEASE_TAG='' bash "$tmp/resolve.sh" >"$tmp/out" 2>"$tmp/err"; then
  printf 'Resolver accepted a prerelease for a manual refresh.\n' >&2
  exit 1
fi
printf 'Publish resolver checks passed.\n'
