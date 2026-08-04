# Homelab Roadmap

## TODO

- [ ] Investigate the issue caused by exposing both external and internal gateways simultaneously — appears to cause problems in Chrome (e.g., mixed routing, cookie conflicts, or certificate mismatches between the two gateways)

- [ ] Improve Home Assistant dashboard
- [ ] Add Syncthing
- [ ] Find a way to use AI to automatically catalog documents in Paperless-ngx
- [ ] Review and merge `mise-upgrade-dependencies` branch (mise upgrades + Romm removal)

## Follow-ups

- [ ] NFS canary reliability — Unraid disrupts NFS connections when the mover runs, canary doesn't handle it well
- [ ] Scrape MinIO metrics from elizabeth into Prometheus — currently zero MinIO metrics exist, so restarts, latency and S3 error rates are invisible from the cluster. This is what forced the weekly CNPG backup failures to be diagnosed by hand-querying VictoriaLogs for `IncompleteBody` instead of a single query. Prerequisite for confirming whether elizabeth's saturation window lines up with the mover / kopia full maintenance
- [ ] Stagger the nightly backup schedules — 19 VolSync ReplicationSources on `0 0 * * *` plus both CNPG ScheduledBackups on `@daily` all hit elizabeth at exactly 00:00. VolSync retries and survives; a CNPG `ScheduledBackup` does not, so it loses roughly one backup a week
