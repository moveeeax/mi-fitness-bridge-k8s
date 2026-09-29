# syntax=docker/dockerfile:1
ARG PYTHON_VERSION=3.12
ARG BRIDGE_REF=096f2bc

FROM python:${PYTHON_VERSION}-slim AS build
ARG BRIDGE_REF
RUN apt-get update \
 && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*
RUN python -m venv /opt/venv
ENV PATH=/opt/venv/bin:$PATH
# keyrings.alt: containers have no OS keychain, the passToken lives on the volume.
# mcp-proxy: the bridge only speaks stdio, this puts it on HTTP.
RUN pip install --no-cache-dir \
      "git+https://github.com/shkyyy18/mi_fitness_data_bridge.git@${BRIDGE_REF}" \
      "keyrings.alt==5.0.2" \
      "mcp-proxy==0.12.0"

FROM python:${PYTHON_VERSION}-slim
ARG BRIDGE_REF
LABEL org.opencontainers.image.title="mi-fitness-bridge" \
      org.opencontainers.image.description="Mi Fitness Data Bridge packaged for Kubernetes: sync CronJob plus stdio MCP over HTTP" \
      org.opencontainers.image.source="https://github.com/moveeeax/mi-fitness-bridge-k8s" \
      org.opencontainers.image.licenses="AGPL-3.0-only" \
      me.tarassov.bridge-upstream="https://github.com/shkyyy18/mi_fitness_data_bridge@${BRIDGE_REF}"
COPY --from=build /opt/venv /opt/venv
COPY bridge_entrypoint.py /opt/venv/bin/bridge-entrypoint
RUN chmod 0755 /opt/venv/bin/bridge-entrypoint \
 && useradd --uid 1000 --create-home --home-dir /home/bridge bridge
ENV PATH=/opt/venv/bin:$PATH \
    PYTHONUNBUFFERED=1 \
    PYTHON_KEYRING_BACKEND=keyrings.alt.file.PlaintextKeyring \
    HOME=/data \
    XDG_DATA_HOME=/data \
    XDG_CONFIG_HOME=/data/config \
    MI_FITNESS_DB_PATH=/data/mi_fitness.db
USER 1000:1000
ENTRYPOINT ["bridge-entrypoint"]
CMD ["sync-window"]
