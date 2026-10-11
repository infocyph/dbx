ARG DBX_BASE_IMAGE=t8y2/dbx:latest
FROM ${DBX_BASE_IMAGE}

LABEL org.opencontainers.image.source="https://github.com/infocyph/dbx"
LABEL org.opencontainers.image.description="DBX with LocalDevStack database and local AI defaults"
LABEL org.opencontainers.image.licenses="MIT"

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl jq \
    && rm -rf /var/lib/apt/lists/*

COPY --chmod=755 scripts/dbx-entrypoint.sh /usr/local/bin/lds-dbx-entrypoint

ENTRYPOINT ["/usr/local/bin/lds-dbx-entrypoint"]
CMD ["dbx-web"]
