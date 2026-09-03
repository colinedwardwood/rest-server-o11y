# rest-server-o11y

Observability stack for monitoring a restic rest-server: Alloy module, Grafana dashboards, alert rules, SLOs.

> **2026-09-03 — metric source changed.** `ngosang/restic-exporter` (:8001)
> could not serve the rest-server's `--private-repos` layout and errored
> every scrape. It is retired. Snapshot metrics now come from
> `restic-snapshot-metrics`, a per-repo Prometheus **textfile collector**
> deployed by `ansible` `roles/rest-server` (`tasks/prune.yml`). Alloy still
> labels them `job="custom/restic_exporter"`, so the live Grafana "Backup
> Infrastructure" alerts keep working, but the **metric names differ** from
> what parts of this repo still document:
>
> | old (dead) | current |
> |---|---|
> | `restic_snapshots_group_latest_timestamp` | `restic_last_snapshot_timestamp{repo}` |
> | `restic_stats_total_size_bytes` | `restic_last_snapshot_size_bytes{repo}` |
> | `restic_stats_total_file_count` | `restic_last_snapshot_files{repo}` |
> | `restic_check_success` | *(not collected — `restic check` isn't run per scrape)* |
> | `up{job="custom/restic_exporter"}` | still valid (the textfile scrape target) |
>
> `alerts/rules.yml` and `dashboards/*.json` still reference the old names
> and need a pass. The live Grafana rules (created by hand in folder
> `storage-backup`) already use the current names.

## What gets monitored

| Signal | Source | Key metrics |
|--------|--------|-------------|
| Drive space | node_exporter (linux.alloy) | `node_filesystem_avail_bytes`, `node_filesystem_size_bytes` |
| Backup snapshots | restic-snapshot-metrics (textfile) | `restic_snapshots_total{repo}`, `restic_last_snapshot_timestamp{repo}` |
| Backup size / files | restic-snapshot-metrics (textfile) | `restic_last_snapshot_size_bytes{repo}`, `restic_last_snapshot_files{repo}` |
| REST HTTP traffic | rest-server (:8000/metrics) | HTTP request counts, durations, Go runtime |
| Repo health | restic-exporter (:8001) | `restic_check_success` |
| Service health | systemd journal (linux.alloy) | `rest-server.service`, `restic-exporter.service` logs |

## Components

### Alloy module

`alloy/modules/restserver.alloy` — scrapes both rest-server and restic-exporter Prometheus endpoints. Copy this into your o11y repo and add `restserver` to the host's `alloy_modules` list.

### Grafana dashboards

Import these into Grafana Cloud (or any Grafana instance):

- `dashboards/backup-server-overview.json` — system-level view: disk space, HTTP traffic, service health, system resources
- `dashboards/backup-status.json` — backup-specific: snapshot count, last backup age, repo size growth, per-client breakdown

### Alert rules

`alerts/rules.yml` — Prometheus-compatible alerting rules for Grafana Cloud Mimir. Upload with `mimirtool` or through the Grafana Cloud ruler API.

| Alert | Severity | Trigger |
|-------|----------|---------|
| BackupDriveSpaceCritical | critical | < 10% free on /backups for 15m |
| BackupDriveSpaceWarning | warning | < 20% free on /backups for 30m |
| BackupStale | warning | No backup in 25 hours |
| BackupStaleCritical | critical | No backup in 48 hours |
| RestServerDown | critical | rest-server unreachable for 5m |
| ResticExporterDown | warning | restic-exporter unreachable for 10m |
| ResticCheckFailed | warning | `restic check` reports failure for 1h |

### SLO definitions

`slos/definitions.json` — Grafana Cloud SLO definitions. Create via the Grafana SLO API or UI.

| SLO | Target | Window | SLI |
|-----|--------|--------|-----|
| Backup Freshness | 99% | 28 days | Most recent backup < 25 hours old |
| REST Server Availability | 99.5% | 28 days | rest-server responding to scrapes |
| Backup Drive Capacity | 99% | 28 days | /backups has > 10% free space |

### Restic exporter

Ansible role and standalone install scripts for [ngosang/restic-exporter](https://github.com/ngosang/restic-exporter).

## Setup

### 1. Deploy the exporter

```bash
# With Ansible — copy the role and run the playbook
cp -r ansible/roles/restic-exporter ~/Code/GitHub/ansible/roles/
ansible-playbook ansible/playbooks/restic-exporter.yml -l backup-pi -K

# Or standalone — run the install script directly
export RESTIC_REPOSITORY=/backups
export RESTIC_PASSWORD='your-repo-encryption-password'
sudo -E ./scripts/install-restic-exporter.sh --write-env
```

### 2. Add the Alloy module

Copy the module into your o11y repo:

```bash
cp alloy/modules/restserver.alloy ~/Code/GitHub/o11y/alloy/modules/
```

Add `restserver` to the host's alloy_modules in your ansible inventory:

```yaml
# inventory/host_vars/backup-pi/alloy.yml
alloy_modules:
  - compliance
  - restserver
```

### 3. Import dashboards

In Grafana Cloud, go to Dashboards → Import and upload each JSON file from `dashboards/`.

### 4. Upload alert rules

```bash
mimirtool rules load alerts/rules.yml \
  --address=https://prometheus-us-central1.grafana.net \
  --id=655559 \
  --key=glc_...
```

### 5. Create SLOs

Import the SLO definitions from `slos/definitions.json` through the Grafana Cloud SLO UI or API.

## Vault secrets

The restic-exporter needs the repository encryption password:

```bash
ansible-vault encrypt_string 'your-restic-repo-password' \
  --name vault_restic_password >> ~/Code/GitHub/ansible/inventory/group_vars/all/vault.yml
```
