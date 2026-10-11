#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
image="${1:-infocyph/dbx:ci}"
suffix="${RANDOM}-$$"
client="dbx-connections-$suffix"
network="dbx-connections-$suffix"
volume="dbx-connections-$suffix"
profiles_volume="dbx-profiles-$suffix"
pg="dbx-postgres-$suffix"
mysql="dbx-mysql-$suffix"
maria="dbx-mariadb-$suffix"
cleanup() {
  docker rm -f -v "$client" "$pg" "$mysql" "$maria" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
  docker volume rm "$volume" "$profiles_volume" >/dev/null 2>&1 || true
}
trap cleanup EXIT
if [[ "${DBX_SMOKE_SKIP_BUILD:-0}" != 1 ]]; then
  docker build -q -t "$image" "$ROOT" >/dev/null
fi
docker network create "$network" >/dev/null
docker volume create "$volume" >/dev/null
docker volume create "$profiles_volume" >/dev/null
start_client() {
  docker rm -f "$client" >/dev/null 2>&1 || true
  docker run -d --name "$client" --network "$network" -p 127.0.0.1::4224 \
    -v "${test_volume:-$volume}:/app/data" -e DBX_PASSWORD=dbx-smoke-password \
    -e POSTGRES_USER=fixture -e POSTGRES_PASSWORD=fixture-password -e POSTGRES_DATABASE=fixturedb \
    -e MYSQL_USER=fixture -e MYSQL_PASSWORD=fixture-password -e MYSQL_DATABASE=fixturedb \
    -e MARIADB_USER=fixture -e MARIADB_PASSWORD=fixture-password -e MARIADB_DATABASE=fixturedb \
    "$@" "$image" >/dev/null
  port="$(docker port "$client" 4224/tcp | sed 's/.*://')"
  export DBX_TEST_URL="http://127.0.0.1:$port"
  for _ in {1..60}; do
    if curl -fsS --max-time 2 "$DBX_TEST_URL/api/auth/check" >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  docker logs "$client" >&2
  return 1
}
check_api() {
  DBX_TEST_PHASE="$1" python3 - <<'PY'
import http.cookiejar, json, os, urllib.request
http = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
def api(path, body=None):
    return json.load(http.open(urllib.request.Request(os.environ['DBX_TEST_URL'] + path,
        data=None if body is None else json.dumps(body).encode(),
        headers={'Content-Type': 'application/json'}), timeout=40))
api('/api/auth/login', {'password': 'dbx-smoke-password'})
configs = api('/api/connection/list')
by_id = {c['id']: c for c in configs}
phase = os.environ['DBX_TEST_PHASE']
if phase == 'empty':
    assert configs == [], 'inactive services should not be added'
    assert len(api('/api/ai/configs')) == 1
    api('/api/connection/save', {'configs': [{'id': 'manual', 'name': 'Manual connection',
        'db_type': 'postgres', 'host': 'elsewhere', 'port': 5432, 'username': 'user',
        'password': '', 'database': 'manualdb'}]})
elif phase in ('postgres', 'preserved', 'all'):
    expected = {'manual', 'localdevstack-postgres'}
    if phase == 'all': expected |= {'localdevstack-mysql', 'localdevstack-mariadb'}
    assert set(by_id) == expected, list(by_id)
    assert by_id['manual']['name'] == 'Manual connection'
    for service in ('postgres', 'mysql', 'mariadb') if phase == 'all' else ('postgres',):
        c = by_id['localdevstack-' + service]
        assert c['host'] == service and c['database'] == 'fixturedb'
        assert c['username'] == 'fixture' and c['save_password'] is True
        assert c['db_type'] == ('postgres' if service == 'postgres' else 'mysql')
        assert c['driver_profile'] == service
        api('/api/connection/connect', {'config': c})
        names = [item['name'] for item in api('/api/schema/databases?connection_id=' + c['id'])]
        assert 'fixturedb' in names and 'dbx_extra' in names, (service, names)
    if phase == 'postgres':
        c = by_id['localdevstack-postgres']
        c['name'] = 'My PostgreSQL'
        api('/api/connection/save', {'configs': configs})
    else:
        assert by_id['localdevstack-postgres']['name'] == 'My PostgreSQL'
    if phase == 'all':
        api('/api/connection/save', {'configs': [by_id['manual']],
            'removedIds': ['localdevstack-postgres', 'localdevstack-mysql', 'localdevstack-mariadb']})
elif phase == 'deleted':
    assert set(by_id) == {'manual'}, list(by_id)
elif phase == 'profiles':
    assert set(by_id) == {'localdevstack-postgres', 'localdevstack-mysql', 'localdevstack-mariadb'}, list(by_id)
elif phase == 'optout':
    assert set(by_id) == {'manual'}, list(by_id)
print('PASS: database initialization phase ' + phase)
PY
}

# No SQL service is running; AI initialization must not add offline defaults.
start_client
check_api empty
# Configured profiles should be saved even before those containers exist.
test_volume="$profiles_volume" start_client -e LDS_DBX_PROFILES=postgresql,mysql,mariadb
check_api profiles

docker run -d --name "$pg" --network "$network" --network-alias postgres \
  -e POSTGRES_USER=fixture -e POSTGRES_PASSWORD=fixture-password -e POSTGRES_DB=fixturedb \
  postgres:18-alpine >/dev/null
ready=0
for _ in {1..90}; do
  if docker exec "$pg" pg_isready -h 127.0.0.1 -U fixture -d fixturedb >/dev/null 2>&1; then ready=1; break; fi
  sleep 1
done
((ready)) || { docker logs "$pg" >&2; exit 1; }
docker exec "$pg" psql -U fixture -d fixturedb -c 'CREATE DATABASE dbx_extra' >/dev/null
# Independent opt-outs: turning AI initialization off must still seed databases.
start_client -e LDS_DBX_AI_PRECONFIGURE=0
check_api postgres
start_client -e POSTGRES_PASSWORD=changed-stack-password
check_api preserved

for service in mysql mariadb; do
  if [[ "$service" == mysql ]]; then db="$mysql"; db_image=mysql:9.7; else db="$maria"; db_image=mariadb:12.3; fi
  docker run -d --name "$db" --network "$network" --network-alias "$service" \
    -e MYSQL_ROOT_PASSWORD=root-fixture-password -e MYSQL_USER=fixture \
    -e MYSQL_PASSWORD=fixture-password -e MYSQL_DATABASE=fixturedb "$db_image" >/dev/null
  ready=0
  for _ in {1..120}; do
    if docker exec -e MYSQL_PWD=fixture-password "$db" "$service" -h 127.0.0.1 -u fixture \
      -D fixturedb -e 'SELECT 1' >/dev/null 2>&1; then ready=1; break; fi
    sleep 1
  done
  ((ready)) || { docker logs "$db" >&2; exit 1; }
  docker exec -e MYSQL_PWD=root-fixture-password "$db" "$service" -u root \
    -e "CREATE DATABASE dbx_extra; GRANT ALL ON dbx_extra.* TO 'fixture'@'%';" >/dev/null
done
# Newly started services must be added even though AI and PostgreSQL are marked.
start_client
check_api all
start_client
check_api deleted
# Simulate a preexisting volume without our markers and verify opt-out wins.
docker exec "$client" sh -c 'rm /app/data/.lds-db-*-configured'
start_client -e LDS_DBX_DB_PRECONFIGURE=0
check_api optout
# Existing connections to a service should win over creating duplicates.
# Here the manually saved connection uses the same hostname as PostgreSQL.
DBX_TEST_URL="$DBX_TEST_URL" python3 - <<'PY'
import http.cookiejar, json, os, urllib.request
http = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
base = os.environ['DBX_TEST_URL']
def api(path, body=None):
    return json.load(http.open(urllib.request.Request(base + path,
        data=None if body is None else json.dumps(body).encode(),
        headers={'Content-Type': 'application/json'}), timeout=10))
api('/api/auth/login', {'password': 'dbx-smoke-password'})
c = api('/api/connection/list')[0]
c['host'] = 'postgres'
api('/api/connection/save', {'configs': [c]})
PY
start_client -e LDS_DBX_DATABASES=postgres
check_api optout
printf 'Database connection integration checks passed.\n'
