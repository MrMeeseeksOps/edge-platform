# Custom Dagster image, built for ARM64 - see docs/architecture.md
# "Platform workloads" for why: the upstream dagster/dagster-celery-k8s
# image the Helm chart defaults to (used for both the webserver and the
# daemon) is published amd64-only. This mirrors what that upstream
# image actually contains for a K8sRunLauncher deployment with no
# Celery and no bundled user code - just Dagster's core Python packages
# on a slim base.
#
# Built and imported by ansible/playbooks/platform.yml
# (tag: dagster-image) - never pushed to a registry, since it's
# imported directly into each node's containerd via `k3s ctr images
# import`.
#
# Dagster's packages release in lockstep (same patch/build number every
# release) but on two different major.minor tracks: `dagster` and
# `dagster-webserver` carry the "1.x" branding, while older companion
# libraries like `dagster-postgres` and `dagster-k8s` stayed on their
# pre-1.0 "0.x" numbering. Both ARGs below must be bumped together,
# matching ansible/inventory/group_vars/platform.yml's
# dagster_chart_version / dagster_libs_version - verify the pairing on
# PyPI (the patch number, "20" as of this writing, must match) before
# changing either.

FROM python:3.11-slim

ARG DAGSTER_VERSION=1.13.20
ARG DAGSTER_LIBS_VERSION=0.29.20

RUN pip install --no-cache-dir \
    "dagster==${DAGSTER_VERSION}" \
    "dagster-webserver==${DAGSTER_VERSION}" \
    "dagster-postgres==${DAGSTER_LIBS_VERSION}" \
    "dagster-k8s==${DAGSTER_LIBS_VERSION}"

ENV DAGSTER_HOME=/opt/dagster/dagster_home
RUN mkdir -p "$DAGSTER_HOME"
WORKDIR /opt/dagster/app
