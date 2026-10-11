#!/usr/bin/env bash
set -euo pipefail

if [[ "${1:-}" != dbx-web ]]; then
  exec "$@"
fi

data_dir="${DBX_DATA_DIR:-/app/data}"
marker="$data_dir/.lds-ai-configured"
seed_ai=0
if [[ "${LDS_DBX_AI_PRECONFIGURE:-1}" != 0 && ! -f "$marker" ]]; then
  seed_ai=1
fi
# Profiles cover configured services even while they are starting. DNS also
# discovers services enabled through Compose's --profile CLI option.
databases=()
if [[ "${LDS_DBX_DB_PRECONFIGURE:-1}" != 0 ]]; then
  selection=",${LDS_DBX_DATABASES:-auto},"
  profiles=",${LDS_DBX_PROFILES:-},"
  for service in postgres mysql mariadb elasticsearch redis mongodb; do
    [[ -f "$data_dir/.lds-db-$service-configured" ]] && continue
    profile="$service"
    [[ "$service" == postgres ]] && profile=postgresql
    if [[ "$selection" == *,"$service",* || "$selection" == *,"$profile",* ]] ||
      { [[ "$selection" == *,auto,* ]] &&
        { [[ "$profiles" == *,"$profile",* ]] || getent hosts "$service" >/dev/null; }; }; then
      databases+=("$service")
    fi
  done
fi
if ((seed_ai == 0 && ${#databases[@]} == 0)); then
  exec "$@"
fi

tmp="$(mktemp -d)"
bootstrap_pid=""
cleanup() {
  if [[ -n "$bootstrap_pid" ]]; then
    kill -TERM "$bootstrap_pid" 2>/dev/null || true
    wait "$bootstrap_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 143' TERM
trap 'exit 130' INT

# Seed through DBX itself so its storage and encryption stay application-owned.
# The temporary server is unreachable from the container network.
DBX_DISABLE_PASSWORD=1 DBX_BIND_ADDR=127.0.0.1 DBX_PORT=4224 DBX_PUBLIC_BASE_PATH=/ \
  "$@" >"$tmp/bootstrap.log" 2>&1 &
bootstrap_pid=$!

ready=0
for ((attempt = 0; attempt < 30; attempt++)); do
  if curl --noproxy '*' -fsS --max-time 2 http://127.0.0.1:4224/api/auth/check \
    >"$tmp/status.json" 2>/dev/null; then
    ready=1
    break
  fi
  if ! kill -0 "$bootstrap_pid" 2>/dev/null; then
    printf 'DBX bootstrap server exited before becoming ready.\n' >&2
    exit 1
  fi
  sleep 1
done
if ((ready == 0)); then
  printf 'DBX bootstrap timed out.\n' >&2
  exit 1
fi

if ((seed_ai)); then
  status="$(curl --noproxy '*' -sS --max-time 10 -o "$tmp/configs.json" -w '%{http_code}' \
    http://127.0.0.1:4224/api/ai/configs)"
  case "$status" in
  200)
    jq -e 'type == "array"' "$tmp/configs.json" >/dev/null
    if [[ "$(jq 'length' "$tmp/configs.json")" == 0 ]]; then
      jq -n --arg model "${LDS_AI_MODEL:-qwen3.5:9b}" --arg think "${LDS_AI_THINK:-}" '
        {config: {
          id: "localdevstack", name: "LocalDevStack", isDefault: true,
          provider: "openai-compatible", apiStyle: "completions", authMethod: "bearer",
          apiKey: "", endpoint: "http://llm:11434/v1", model: $model
        }}
        | if $think == "true" then .config.enableThinking = true
          elif $think == "false" then .config.enableThinking = false
          else . end
      ' >"$tmp/config.json"
      curl --noproxy '*' -fsS --max-time 10 -H 'Content-Type: application/json' \
        --data-binary "@$tmp/config.json" http://127.0.0.1:4224/api/ai/config-item >/dev/null
      printf 'DBX: configured the LocalDevStack AI provider.\n'
    fi
    touch "$marker"
    ;;
  423)
    # Existing data may need DBX's interactive security migration before API writes.
    printf 'DBX: AI preconfiguration deferred until the data migration is completed.\n' >&2
    ;;
  *)
    printf 'DBX AI configuration request failed (HTTP %s).\n' "$status" >&2
    exit 1
    ;;
  esac
fi

if ((${#databases[@]})); then
  status="$(curl --noproxy '*' -sS --max-time 10 -o "$tmp/connections.json" -w '%{http_code}' \
    http://127.0.0.1:4224/api/connection/list)"
  case "$status" in
  200)
    jq -e 'type == "array"' "$tmp/connections.json" >/dev/null
    for service in "${databases[@]}"; do
      # Match both our stable ID and an existing connection to this server.
      if ! jq -e --arg id "localdevstack-$service" --arg host "$service" \
        'any(.[]; .id == $id or .host == $host)' "$tmp/connections.json" >/dev/null; then
        url_params=""
        case "$service" in
        postgres)
          name=PostgreSQL port=5432 db_type=postgres
          username="${POSTGRES_USER:-postgres}" password="${POSTGRES_PASSWORD:-postgres}"
          database="${POSTGRES_DATABASE:-postgres}"
          ;;
        mysql)
          name=MySQL port=3306 db_type=mysql
          username="${MYSQL_USER:-infocyph}" password="${MYSQL_PASSWORD:-12345}"
          database="${MYSQL_DATABASE:-localdb}"
          ;;
        mariadb)
          name=MariaDB port=3306 db_type=mysql
          username="${MARIADB_USER:-infocyph}" password="${MARIADB_PASSWORD:-12345}"
          database="${MARIADB_DATABASE:-localdb}"
          ;;
        elasticsearch)
          name=Elasticsearch port=9200 db_type=elasticsearch
          username="" password="" database=""
          ;;
        redis)
          name=Redis port=6379 db_type=redis
          username="" password="" database=0
          ;;
        mongodb)
          name=MongoDB port=27017 db_type=mongodb
          username="${MONGODB_ROOT_USERNAME:-root}" password="${MONGODB_ROOT_PASSWORD:-12345}"
          database=admin url_params=authSource=admin
          ;;
        esac
        # Use environment variables so credentials never appear in process arguments.
        export DBX_SEED_PASSWORD="$password"
        jq -n --arg id "localdevstack-$service" --arg name "LocalDevStack $name" \
          --arg type "$db_type" --arg profile "$service" --arg driver_label "$name" --arg host "$service" --argjson port "$port" \
          --arg username "$username" --arg database "$database" --arg url_params "$url_params" \
          --slurpfile saved "$tmp/connections.json" '
          {configs: ($saved[0] + [{id: $id, name: $name, db_type: $type, host: $host,
            port: $port, driver_profile: $profile, driver_label: $driver_label,
            username: $username, password: env.DBX_SEED_PASSWORD,
            database: (if $database == "" then null else $database end),
            url_params: (if $url_params == "" then null else $url_params end),
            save_password: true}])}
        ' >"$tmp/connection.json"
        unset DBX_SEED_PASSWORD
        curl --noproxy '*' -fsS --max-time 10 -H 'Content-Type: application/json' \
          --data-binary "@$tmp/connection.json" http://127.0.0.1:4224/api/connection/save >/dev/null
        jq '.configs' "$tmp/connection.json" >"$tmp/connections.json"
        printf 'DBX: configured the LocalDevStack %s connection.\n' "$name"
      fi
      touch "$data_dir/.lds-db-$service-configured"
    done
    ;;
  423)
    printf 'DBX: database preconfiguration deferred until the data migration is completed.\n' >&2
    ;;
  *)
    printf 'DBX connection configuration request failed (HTTP %s).\n' "$status" >&2
    exit 1
    ;;
  esac
fi

cleanup
bootstrap_pid=""
trap - EXIT TERM INT
exec "$@"
