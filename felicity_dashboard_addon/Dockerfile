# https://developers.home-assistant.io/docs/apps/configuration#app-dockerfile
ARG BUILD_FROM=ghcr.io/home-assistant/base:3.23
FROM ${BUILD_FROM}

ARG BUILD_VERSION
ARG BUILD_ARCH

ENV FELICITY_APP_VERSION=${BUILD_VERSION}

RUN apk add --no-cache python3 py3-pip \
    && python3 -m venv /opt/felicity-venv

WORKDIR /app
COPY app/requirements.txt /app/requirements.txt
RUN /opt/felicity-venv/bin/pip install --no-cache-dir -r /app/requirements.txt

COPY app /app
COPY rootfs /

RUN chmod a+x \
    /etc/services.d/felicity-dashboard/run \
    /etc/services.d/felicity-dashboard/finish

LABEL \
    io.hass.version="${BUILD_VERSION}" \
    io.hass.type="app" \
    io.hass.arch="${BUILD_ARCH}" \
    org.opencontainers.image.title="Home Assistant App: Felicity Energy Dashboard" \
    org.opencontainers.image.source="https://github.com/PHASEONE-big/felicity-dashboard"
