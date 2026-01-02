# Airflow Hetzner (LocalExecutor) Setup

Production-style single-server Airflow 2.10 on Ubuntu 24.04 with native install and push-based DAG deploys.

## Quick start
```bash
cp .env.example .env
editor .env
sudo ./install_airflow_hetzner.sh
```

After install, the web UI is available on port `8080`.

## Services
Start/stop/status:
```bash
sudo systemctl status airflow-webserver
sudo systemctl status airflow-scheduler

sudo systemctl restart airflow-webserver airflow-scheduler
sudo systemctl stop airflow-webserver airflow-scheduler
sudo systemctl start airflow-webserver airflow-scheduler
```

Logs:
```bash
sudo journalctl -u airflow-webserver -f
sudo journalctl -u airflow-scheduler -f
```

Airflow logs:
- `/opt/airflow/logs`

## DAG deployment (push-based)
The install sets up a bare repo at `/opt/airflow/dags.git` with a post-receive hook.
Push a new commit to update DAGs without restarting any services.

```bash
git remote add hetzner airflow@your-server:/opt/airflow/dags.git
git push hetzner main
```

## Defaults
- Airflow home: `/opt/airflow`
- Dags: `/opt/airflow/dags`
- Logs: `/opt/airflow/logs`
- Executor: `LocalExecutor`
- DB: Postgres on localhost
- Webserver port: `8080`

## Notes
- If you change DB credentials in `.env`, rerun the install script to reconfigure.
- Add HTTPS later by placing a reverse proxy in front of the webserver.
