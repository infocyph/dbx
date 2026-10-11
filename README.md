# DBX for LocalDevStack

Custom Docker image based on [upstream DBX](https://github.com/t8y2/dbx), with a
saved database connections and an AI configuration for LocalDevStack's local model service.

Images: `docker.io/infocyph/dbx:latest` and `ghcr.io/infocyph/dbx:latest`.
The publish workflow targets `linux/amd64` and `linux/arm64`.

## What the image adds

Before exposing the web service, a startup wrapper launches a temporary DBX API
bound to `127.0.0.1`. It seeds a default configuration named `LocalDevStack` using
OpenAI Compatible, Chat Completions, `http://llm:11434/v1`, and an empty API key.
It then stops that server and starts DBX with its normal login protection.

Configuration is written through DBX's API, so DBX owns persistence and encryption.
Existing AI configurations are preserved. A marker in the data volume prevents
later restarts from overwriting edits or restoring configurations you deleted.
If DBX requires an interactive data security migration, seeding is deferred until
you complete that migration and restart the container.

The image supplies the database assistant; the model server runs separately.
DBX and LocalDevStack's `llm` service must share a Docker network. The common
`llm:11434` endpoint works with either Ollama or FastFlow.

The wrapper also saves PostgreSQL, MySQL, and MariaDB connections with the stack's
configured credentials and internal ports (5432/3306). In automatic mode it selects
services in `LDS_DBX_PROFILES` or available through Docker DNS on the shared network.
Each service has its own initialization marker: new services are added on a later
restart without changing existing connections or restoring ones you deleted.
A previously saved connection to the same hostname is preserved instead of duplicated.
DBX lists the databases and schemas the account can access when you connect or refresh.
MySQL and MariaDB use application users, whose database permissions apply.

Adding a container after DBX starts requires restarting DBX to add the connection.
Configured services may appear offline while starting. Updating environment credentials
after initialization does not change saved connections; edit them in DBX instead.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `LDS_DBX_DB_PRECONFIGURE` | `1` | Set to `0` to disable database connection initialization. |
| `LDS_DBX_DATABASES` | `auto` | Automatic selection or a comma-separated subset of `postgres,mysql,mariadb`. |
| `LDS_DBX_PROFILES` | unset | In automatic mode, SQL profiles selected in Compose (`postgresql,mysql,mariadb`). |
| `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DATABASE` | `postgres`, `postgres`, `postgres` | Initial PostgreSQL connection credentials and database. |
| `MYSQL_USER`, `MYSQL_PASSWORD`, `MYSQL_DATABASE` | `infocyph`, `12345`, `localdb` | Initial MySQL connection credentials and database. |
| `MARIADB_USER`, `MARIADB_PASSWORD`, `MARIADB_DATABASE` | `infocyph`, `12345`, `localdb` | Initial MariaDB connection credentials and database. |
| `LDS_DBX_AI_PRECONFIGURE` | `1` | Set to `0` to disable initial AI configuration. |
| `LDS_AI_MODEL` | `qwen3.5:9b` | Initial model; later edits belong to DBX settings. |
| `LDS_AI_THINK` | unset | Initial thinking override: `true` or `false`; unset retains DBX's default. |
| `DBX_PASSWORD` | unset | Optional web login password; unset retains first-run setup or the saved password. |
| `DBX_DATA_DIR` | `/app/data` | Persistent settings and connections, including the seeding marker. |

Upstream DBX environment variables remain available. Preserve `/app/data` across
container recreation. Database credentials are separate from the web login password.

## Build and run locally

```bash
docker build --pull -t infocyph/dbx:latest .
docker run --rm --name dbx -p 127.0.0.1:4224:4224 \
  -v dbx-data:/app/data infocyph/dbx:latest
```

Open `http://localhost:4224` and choose a web login password on first launch.
For AI use, attach the container to the same network as your local model service.
LocalDevStack supplies that network and exposes DBX at `https://db.localhost`.

## Validation and publication

```bash
bash tests/static.sh
bash tests/smoke.sh
bash tests/connections-smoke.sh
```

The smoke test uses isolated containers and a mock LLM to check AI initialization,
real API calls, web authentication, persistence, preserving existing settings,
and respecting deliberately deleted configurations. It requires Docker, Python 3,
and curl on the host; it does not require AI hardware or a downloaded model.
The database smoke test runs real PostgreSQL, MySQL, and MariaDB servers on an isolated
network. It verifies credential forwarding, database enumeration, later service
activation, preserving manual connections and edits, opt-outs, and deletion persistence.

The Check workflow validates both supported architectures. Docker Publish runs on
a published stable release, manual dispatch, and weekly refresh. Manual/scheduled
runs use the latest stable release source and update only `latest`; release tags
are immutable. Published release names are preserved as image tags, including
versions such as `0.01`; tags must satisfy Docker's image tag format. Both architecture candidates pass the smoke test before publication.
The upstream DBX image is resolved to one digest for the whole publish run.

Configure repository secrets `DOCKER_USERNAME` and `DOCKER_PASSWORD` for Docker Hub.
GHCR uses the workflow's `GITHUB_TOKEN`. Both registries must resolve to the same
published manifest digest. No image is published by a pull-request check.

The wrapper is MIT-licensed. The underlying DBX application retains its upstream
license and notices.
