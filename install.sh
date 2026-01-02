#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${AIRFLOW_ENV_FILE:-${SCRIPT_DIR}/.env}"

if [ -f "${ENV_FILE}" ]; then
  set -a
  # shellcheck disable=SC1090
  . "${ENV_FILE}"
  set +a
fi

if [ "${EUID}" -ne 0 ]; then
  echo "Run this script with sudo or as root."
  exit 1
fi

AIRFLOW_USER="${AIRFLOW_USER:-airflow}"
AIRFLOW_HOME="${AIRFLOW_HOME:-/opt/airflow}"
AIRFLOW_VENV="${AIRFLOW_VENV:-/opt/airflow/venv}"
AIRFLOW_VERSION="${AIRFLOW_VERSION:-2.10.4}"

AIRFLOW_DB_USER="${AIRFLOW_DB_USER:-airflow}"
AIRFLOW_DB_PASS="${AIRFLOW_DB_PASS:-CHANGE_ME}"
AIRFLOW_DB_NAME="${AIRFLOW_DB_NAME:-airflow}"
AIRFLOW_DB_HOST="${AIRFLOW_DB_HOST:-localhost}"

AIRFLOW_ADMIN_USER="${AIRFLOW_ADMIN_USER:-admin}"
AIRFLOW_ADMIN_PASS="${AIRFLOW_ADMIN_PASS:-admin}"
AIRFLOW_ADMIN_EMAIL="${AIRFLOW_ADMIN_EMAIL:-admin@example.com}"
AIRFLOW_ADMIN_FIRSTNAME="${AIRFLOW_ADMIN_FIRSTNAME:-Admin}"
AIRFLOW_ADMIN_LASTNAME="${AIRFLOW_ADMIN_LASTNAME:-User}"

AIRFLOW_GIT_BARE="${AIRFLOW_GIT_BARE:-/opt/airflow/dags.git}"
AIRFLOW_DAGS="${AIRFLOW_DAGS:-/opt/airflow/dags}"

if [ "${AIRFLOW_DB_PASS}" = "CHANGE_ME" ]; then
  echo "Set AIRFLOW_DB_PASS to a strong password before using this in production."
fi

apt update
apt install -y python3-venv python3-dev build-essential libpq-dev git postgresql

if ! id "${AIRFLOW_USER}" >/dev/null 2>&1; then
  useradd --system --home "${AIRFLOW_HOME}" --shell /bin/bash "${AIRFLOW_USER}"
fi

mkdir -p "${AIRFLOW_HOME}"/{dags,logs,plugins}
chown -R "${AIRFLOW_USER}":"${AIRFLOW_USER}" "${AIRFLOW_HOME}"

if [ ! -d "${AIRFLOW_VENV}" ]; then
  sudo -u "${AIRFLOW_USER}" python3 -m venv "${AIRFLOW_VENV}"
fi

sudo -u "${AIRFLOW_USER}" "${AIRFLOW_VENV}/bin/pip" install --upgrade pip setuptools wheel

PY_VER="$("${AIRFLOW_VENV}/bin/python" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
CONSTRAINTS_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PY_VER}.txt"

sudo -u "${AIRFLOW_USER}" "${AIRFLOW_VENV}/bin/pip" install \
  "apache-airflow[postgres]==${AIRFLOW_VERSION}" \
  --constraint "${CONSTRAINTS_URL}"

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='${AIRFLOW_DB_USER}'" | grep -q 1; then
  sudo -u postgres psql -c "CREATE USER ${AIRFLOW_DB_USER} WITH PASSWORD '${AIRFLOW_DB_PASS}'"
fi

if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname='${AIRFLOW_DB_NAME}'" | grep -q 1; then
  sudo -u postgres psql -c "CREATE DATABASE ${AIRFLOW_DB_NAME} OWNER ${AIRFLOW_DB_USER}"
fi

SQL_ALCHEMY_CONN="postgresql+psycopg2://${AIRFLOW_DB_USER}:${AIRFLOW_DB_PASS}@${AIRFLOW_DB_HOST}/${AIRFLOW_DB_NAME}"

export AIRFLOW_HOME
export AIRFLOW__DATABASE__SQL_ALCHEMY_CONN="${SQL_ALCHEMY_CONN}"
export AIRFLOW__CORE__EXECUTOR="LocalExecutor"
export AIRFLOW__CORE__DAGS_FOLDER="${AIRFLOW_DAGS}"
export AIRFLOW__CORE__LOAD_EXAMPLES="False"
export AIRFLOW__SCHEDULER__MIN_FILE_PROCESS_INTERVAL="30"
export AIRFLOW__SCHEDULER__DAG_DIR_LIST_INTERVAL="60"

sudo -u "${AIRFLOW_USER}" env \
  AIRFLOW__DATABASE__SQL_ALCHEMY_CONN="${SQL_ALCHEMY_CONN}" \
  AIRFLOW__CORE__EXECUTOR="LocalExecutor" \
  AIRFLOW__CORE__DAGS_FOLDER="${AIRFLOW_DAGS}" \
  AIRFLOW__CORE__LOAD_EXAMPLES="False" \
  AIRFLOW__SCHEDULER__MIN_FILE_PROCESS_INTERVAL="30" \
  AIRFLOW__SCHEDULER__DAG_DIR_LIST_INTERVAL="60" \
  "${AIRFLOW_VENV}/bin/airflow" db migrate

if ! sudo -u "${AIRFLOW_USER}" env AIRFLOW__DATABASE__SQL_ALCHEMY_CONN="${SQL_ALCHEMY_CONN}" \
  "${AIRFLOW_VENV}/bin/airflow" users list | awk '{print $2}' | grep -qx "${AIRFLOW_ADMIN_USER}"; then
  sudo -u "${AIRFLOW_USER}" env AIRFLOW__DATABASE__SQL_ALCHEMY_CONN="${SQL_ALCHEMY_CONN}" \
    "${AIRFLOW_VENV}/bin/airflow" users create \
    --username "${AIRFLOW_ADMIN_USER}" \
    --firstname "${AIRFLOW_ADMIN_FIRSTNAME}" \
    --lastname "${AIRFLOW_ADMIN_LASTNAME}" \
    --role Admin \
    --email "${AIRFLOW_ADMIN_EMAIL}" \
    --password "${AIRFLOW_ADMIN_PASS}"
fi

sudo -u "${AIRFLOW_USER}" env \
  AIRFLOW_CFG_SQL_ALCHEMY_CONN="${SQL_ALCHEMY_CONN}" \
  AIRFLOW_CFG_DAGS_FOLDER="${AIRFLOW_DAGS}" \
  "${AIRFLOW_VENV}/bin/python" <<'PY'
import configparser
import os
from pathlib import Path

cfg_path = Path("/opt/airflow/airflow.cfg")
cfg = configparser.ConfigParser()
cfg.read(cfg_path)

cfg.setdefault("core", {})
cfg.setdefault("database", {})
cfg.setdefault("scheduler", {})

cfg["core"]["executor"] = "LocalExecutor"
cfg["core"]["dags_folder"] = os.environ["AIRFLOW_CFG_DAGS_FOLDER"]
cfg["core"]["load_examples"] = "False"
cfg["database"]["sql_alchemy_conn"] = os.environ["AIRFLOW_CFG_SQL_ALCHEMY_CONN"]
cfg["scheduler"]["min_file_process_interval"] = "30"
cfg["scheduler"]["dag_dir_list_interval"] = "60"

with cfg_path.open("w") as f:
  cfg.write(f)
PY

cat >/etc/systemd/system/airflow-webserver.service <<'SERVICE'
[Unit]
Description=Airflow Webserver
After=network.target postgresql.service

[Service]
User=airflow
Group=airflow
Environment="AIRFLOW_HOME=/opt/airflow"
ExecStart=/opt/airflow/venv/bin/airflow webserver
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
SERVICE

cat >/etc/systemd/system/airflow-scheduler.service <<'SERVICE'
[Unit]
Description=Airflow Scheduler
After=network.target postgresql.service

[Service]
User=airflow
Group=airflow
Environment="AIRFLOW_HOME=/opt/airflow"
ExecStart=/opt/airflow/venv/bin/airflow scheduler
Restart=always
RestartSec=5s

[Install]
WantedBy=multi-user.target
SERVICE

systemctl daemon-reload
systemctl enable --now airflow-webserver airflow-scheduler

if [ ! -d "${AIRFLOW_GIT_BARE}" ]; then
  sudo -u "${AIRFLOW_USER}" git init --bare "${AIRFLOW_GIT_BARE}"
fi

sudo -u "${AIRFLOW_USER}" tee "${AIRFLOW_GIT_BARE}/hooks/post-receive" >/dev/null <<'SH'
#!/bin/bash
set -euo pipefail
TARGET=/opt/airflow/dags
TMP=/opt/airflow/dags_tmp
GIT_DIR=/opt/airflow/dags.git

rm -rf "$TMP"
mkdir -p "$TMP"
git --work-tree="$TMP" --git-dir="$GIT_DIR" checkout -f

if [ -d "$TARGET" ]; then
  rm -rf "${TARGET}.prev"
  mv "$TARGET" "${TARGET}.prev"
fi

mv "$TMP" "$TARGET"
rm -rf "${TARGET}.prev"
SH

chmod +x "${AIRFLOW_GIT_BARE}/hooks/post-receive"

echo "Done."
echo "Push DAGs: git remote add hetzner airflow@your-server:${AIRFLOW_GIT_BARE}"
