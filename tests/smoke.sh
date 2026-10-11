#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="${1:-infocyph/dbx:ci}"
suffix="${RANDOM}-$$"
client="lds-dbx-ai-$suffix"
provider="lds-dbx-ai-provider-$suffix"
network="lds-dbx-ai-$suffix"
volume="lds-dbx-ai-$suffix"
existing_volume="lds-dbx-ai-existing-$suffix"
cleanup() {
  docker rm -f "$client" "$provider" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker volume rm "$volume" "$existing_volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if [[ "${DBX_SMOKE_SKIP_BUILD:-0}" != 1 ]]; then
  docker build -q -t "$image" "$ROOT" >/dev/null
fi
docker build -q -t infocyph-dbx-mock-llm:ci "$ROOT/tests/fixtures/mock-llm" >/dev/null
docker network create "$network" >/dev/null
docker volume create "$volume" >/dev/null
docker volume create "$existing_volume" >/dev/null
docker run -d --name "$provider" --network "$network" --network-alias llm infocyph-dbx-mock-llm:ci >/dev/null

start_client() {
  local data_volume="$1"
  shift
  docker rm -f "$client" >/dev/null 2>&1 || true
  docker run -d --name "$client" --network "$network" -p 127.0.0.1::4224 \
    -v "$data_volume:/app/data" "$@" "$image" >/dev/null
  port="$(docker port "$client" 4224/tcp | sed 's/.*://')"
  export DBX_TEST_URL="http://127.0.0.1:$port"
  for _ in {1..60}; do
    if curl -fsS --max-time 2 "$DBX_TEST_URL/api/auth/check" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  docker logs "$client" >&2
  printf 'DBX did not become ready.\n' >&2
  return 1
}

# No preset web password: bootstrap must preserve DBX's first-run login setup.
start_client "$volume" -e LDS_AI_MODEL=fixture-model -e LDS_AI_THINK=false
docker logs "$client" 2>&1 | grep -Fq 'DBX: configured the LocalDevStack AI provider.'
python3 - <<'PY'
import http.cookiejar, json, os, urllib.error, urllib.request
base = os.environ['DBX_TEST_URL']
cookies = http.cookiejar.CookieJar()
http = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookies))
def api(path, body=None):
    payload = None if body is None else json.dumps(body).encode()
    return json.load(http.open(urllib.request.Request(base + path, data=payload,
        headers={'Content-Type': 'application/json'}), timeout=30))
assert api('/api/auth/check')['setup_required'] is True
try:
    api('/api/ai/configs')
    raise AssertionError('AI settings exposed without login')
except urllib.error.HTTPError as error:
    assert error.code in (401, 403), error.code
api('/api/auth/setup', {'password': 'dbx-smoke-password'})
assert api('/api/auth/check')['authenticated'] is True
configs = api('/api/ai/configs')
assert len(configs) == 1, configs
c = configs[0]
assert c['id'] == 'localdevstack' and c['name'] == 'LocalDevStack'
assert c['isDefault'] is True
assert c['provider'] == 'openai-compatible' and c['apiStyle'] == 'completions'
assert c['endpoint'] == 'http://llm:11434/v1' and c['apiKey'] == ''
assert c['model'] == 'fixture-model' and c['enableThinking'] is False
result = api('/api/ai/test-connection', {'config': c})
assert result['success'] is True, result
c['name'] = 'My saved configuration'
c['model'] = 'user-selected-model'
api('/api/ai/config-item', {'config': c})
print('PASS: DBX seeds local AI, retains login protection, and calls the common LLM API')
PY

# Recreate with a changed model; saved DBX choices must win.
start_client "$volume" -e LDS_AI_MODEL=new-stack-model
python3 - <<'PY'
import http.cookiejar, json, os, urllib.request
http = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
def api(path, body=None):
    return json.load(http.open(urllib.request.Request(os.environ['DBX_TEST_URL'] + path,
        data=None if body is None else json.dumps(body).encode(),
        headers={'Content-Type': 'application/json'}), timeout=10))
assert api('/api/auth/check')['required'] is True
api('/api/auth/login', {'password': 'dbx-smoke-password'})
configs = api('/api/ai/configs')
assert len(configs) == 1
assert configs[0]['name'] == 'My saved configuration'
assert configs[0]['model'] == 'user-selected-model'
api('/api/ai/configs', {'configs': []})
print('PASS: DBX login and user AI settings survive recreation')
PY

start_client "$volume"
python3 - <<'PY'
import http.cookiejar, json, os, urllib.request
http = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
http.open(urllib.request.Request(os.environ['DBX_TEST_URL'] + '/api/auth/login',
    data=json.dumps({'password': 'dbx-smoke-password'}).encode(),
    headers={'Content-Type': 'application/json'}), timeout=10).close()
assert json.load(http.open(os.environ['DBX_TEST_URL'] + '/api/ai/configs', timeout=10)) == []
print('PASS: deliberately deleted AI settings are not restored on restart')
PY

# Existing volumes without the marker must also retain their AI settings.
start_client "$existing_volume" -e LDS_DBX_AI_PRECONFIGURE=0 -e DBX_PASSWORD=dbx-smoke-password
python3 - <<'PY'
import http.cookiejar, json, os, urllib.request
http = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
def api(path, body=None):
    return json.load(http.open(urllib.request.Request(os.environ['DBX_TEST_URL'] + path,
        data=None if body is None else json.dumps(body).encode(),
        headers={'Content-Type': 'application/json'}), timeout=10))
assert api('/api/auth/check')['required'] is True
api('/api/auth/login', {'password': 'dbx-smoke-password'})
assert api('/api/ai/configs') == []
api('/api/ai/config-item', {'config': {'id': 'existing', 'name': 'Existing AI',
    'provider': 'openai-compatible', 'endpoint': 'http://llm:11434/v1',
    'model': 'existing-model', 'isDefault': True}})
print('PASS: AI preconfiguration can be disabled without disabling web login')
PY

start_client "$existing_volume" -e DBX_PASSWORD=dbx-smoke-password
python3 - <<'PY'
import http.cookiejar, json, os, urllib.request
http = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
http.open(urllib.request.Request(os.environ['DBX_TEST_URL'] + '/api/auth/login',
    data=json.dumps({'password': 'dbx-smoke-password'}).encode(),
    headers={'Content-Type': 'application/json'}), timeout=10).close()
configs = json.load(http.open(os.environ['DBX_TEST_URL'] + '/api/ai/configs', timeout=10))
assert len(configs) == 1 and configs[0]['id'] == 'existing'
assert configs[0]['model'] == 'existing-model' and configs[0]['isDefault'] is True
print('PASS: existing AI configurations are preserved before the first bootstrap')
PY
