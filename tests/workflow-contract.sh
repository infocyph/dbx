#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Execute the workflow's actual resolver so this covers changes to CI itself.
extract_step() {
  awk -v step_name="$1" '
    $0 == "      - name: " step_name { step=1; next }
    step && /^        run: \|$/ { script=1; next }
    script && /^          / { sub(/^          /, ""); print; next }
    script && /^$/ { print; next }
    script { exit }
  ' "$ROOT/.github/workflows/docker.publish.yml" >"$2"
  [[ -s "$2" ]]
}
extract_step 'Resolve stable release source' "$tmp/resolve.sh"
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

# Reproduce a producer that keeps writing after the digest line. Piping this
# directly to an early-exiting awk causes a broken pipe under `pipefail`.
extract_step 'Pin upstream DBX for this publish run' "$tmp/pin.sh"
extract_step 'Verify registry digests' "$tmp/verify.sh"
docker() {
  [[ "$*" == 'buildx imagetools inspect '* ]] || return 1
  if [[ "${MOCK_INSPECT_FAILURE:-0}" == 1 ]]; then return 42; fi
  python3 - <<'PY'
import os, sys
try:
    print('Name: fixture/dbx:latest', flush=True)
    print('Digest: ' + os.environ['MOCK_MANIFEST_DIGEST'], flush=True)
    sys.stdout.write('  Platform: linux/arm64\n' * 8192)
    sys.stdout.flush()
except BrokenPipeError:
    os._exit(255)
PY
}
export -f docker
MOCK_MANIFEST_DIGEST="sha256:$(printf '%064d' 0)"
export MOCK_MANIFEST_DIGEST
export EXPECTED_DIGEST="$MOCK_MANIFEST_DIGEST"
export GITHUB_STEP_SUMMARY="$tmp/summary"
export DBX_SOURCE_TAG=0.01
export DBX_BASE_IMAGE="t8y2/dbx@$MOCK_MANIFEST_DIGEST"
bash "$tmp/pin.sh"
grep -Fxq "DBX_BASE_IMAGE=$DBX_BASE_IMAGE" "$GITHUB_ENV"
bash "$tmp/verify.sh"
if EXPECTED_DIGEST=sha256:wrong bash "$tmp/verify.sh" >"$tmp/out" 2>"$tmp/err"; then
  printf 'Registry verification accepted a mismatched digest.\n' >&2
  exit 1
fi
for step in pin verify; do
  if MOCK_INSPECT_FAILURE=1 bash "$tmp/$step.sh" >"$tmp/out" 2>"$tmp/err"; then
    printf 'Workflow ignored an inspection failure in %s.\n' "$step" >&2
    exit 1
  fi
done
printf 'Publish digest inspection checks passed.\n'
