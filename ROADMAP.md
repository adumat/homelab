# Homelab Roadmap

## Roadmap

Sei fasi, in ordine. Ognuna riceve un piano esecutivo in `docs/superpowers/plans/`
**quando ci si arriva**, non prima: così ogni piano nasce con lo stato reale del repo
davanti invece che con quello previsto settimane prima.

### Fase 1 — CI in cluster: konflate, runner, image-pull

Sostituire la validazione Flux e portare la CI dentro il cluster.

- [ ] Rimuovere `flux-local` da `.github/workflows/` e da `.mise.toml` — il progetto è
      **archiviato** e la sua stessa descrizione indica `flate` e `konflate` come
      sostituti. È l'unico punto del repo che dipende da software non più mantenuto
- [ ] Aggiungere `flate` (`github:home-operations/flate`) come CLI, verificando prima in
      locale con `flate test all`: è più severo di `flux-local` sulle variabili non
      risolte, quindi può far emergere problemi latenti. Meglio scoprirli con calma che
      su una PR rossa
- [ ] Deployare `konflate` (`oci://ghcr.io/home-operations/charts/konflate`) — valida le
      PR in cluster, pubblica status check e commenta il diff renderizzato
- [ ] Deployare `actions-runner-controller` con una GitHub App dedicata
- [ ] Aggiungere il workflow `image-pull`: estrae le immagini nuove con
      `flate diff images -o json` e le pre-scarica sui nodi con `talosctl image pull`.
      Elimina i timeout HelmRelease su immagini grosse — problema già visto con romm

**Rischio da valutare prima di partire:** il runner monta un talosconfig ed esegue codice
proveniente da PR, e la GitHub App richiede permessi di amministrazione sul repo. Se non
convince, i primi due punti chiudono comunque il gap urgente da soli.

### Fase 2 — AGENTS.md

- [ ] Scrivere `AGENTS.md` a root: stack, layout, pattern delle app, componenti,
      networking, gestione dei secret, convenzioni
- [ ] La sezione trappole è dove sta il valore: doppia variabile `APP`+`OIDC_ROUTE` che
      se incompleta produce una SecurityPolicy muta, `enableServiceLinks: false`
      obbligatorio per Authelia, niente `readOnlyRootFilesystem` su Authelia,
      `${VAR:=x}` inutilizzabile nei campi validati da pattern CRD, `unavailable: "0"`
      da quotare, riavvio di `envoy-internal`/`envoy-external` oltre a `envoy-gateway`,
      `talenv.secrets.yaml.j2` come sorgente di verità, etcd a 2 membri
- [ ] **Verificare ogni affermazione contro il repo prima di scriverla.** Una trappola
      sbagliata in `AGENTS.md` istruisce male ogni agente futuro per mesi

### Fase 3 — miroir, poi kopiur

La fase più rischiosa. **Ordine obbligato: storage prima, backup poi.**

Stato attuale: 12 volumi su `ceph-block`, 7 su `openebs-hostpath` (immich, jellyfin, i
cluster CNPG), 18 app protette da VolSync.

- [ ] Installare miroir (`miroir-system`) e creare le storage class `miroir-local` e
      `miroir-replicated`
- [ ] Migrare **un solo volume non critico** da `openebs-hostpath` a `miroir-local` per
      validare il meccanismo end-to-end prima di dipenderci
- [ ] Migrare i restanti volumi `openebs-hostpath` → `miroir-local` e rimuovere OpenEBS
- [ ] Installare kopiur con la cache del mover su `miroir-local` e migrare i backup
      **app per app**, non in blocco
- [ ] Ritirare VolSync solo dopo che tutte e 18 le app sono stabili su kopiur
- [ ] **Fase separata, da misurare:** spostare un sottoinsieme di app da `ceph-block` a
      `miroir-replicated` e confrontare consumo di memoria e latenza, per decidere con
      dati se Ceph è sovradimensionato per 3 M720Q. Non è una migrazione decisa, è un
      esperimento

**Due rischi espliciti, da non trattare come note a piè di pagina:**

1. **kopiur è `v1alpha1` e si muove in fretta.** Sei release in tre settimane
   (0.8.0 → 0.9.3). La documentazione del progetto elenca CRD — `BackupConfig`, `Backup`,
   `BackupSchedule`, `Maintenance` — **diverse** da quelle in uso nella 0.9.3
   (`SnapshotPolicy`, `SnapshotSchedule`). Portarci 18 app significa mettere in conto una
   migrazione di rinomina a breve
2. **Il restore verso una storage class diversa da quella di origine non è documentato.**
   Sarebbe il meccanismo elegante per spostare openebs→miroir, ma va verificato su un
   volume solo prima di costruirci sopra la migrazione

### Fase 4 — `just merge` e componente gpu

- [ ] Aggiungere la ricetta `just merge <digest|patch|minor|major>`: merge in blocco
      delle PR Renovate per label, saltando quelle etichettate `hold`
- [ ] Fattorizzare i `ResourceClaimTemplate` di frigate e jellyfin in un
      `components/gpu`. **Non è una capacità nuova**: DRA (`resource.k8s.io/v1`) è già in
      uso in entrambe le app. Il guadagno è togliere la duplicazione
- [ ] Valutando la fattorizzazione, verificare se servono `adminAccess: true` e
      `allocationMode: All`, oggi non impostati

### Fase 5 — l'osservabilità che manca

Hardware già in casa, metriche assenti.

- [ ] `kromgo` — badge da PromQL.
      ⚠️ **Decidere prima l'esposizione:** i badge nel README rendono il dominio pubblico
      e indicizzato, e oggi il dominio non compare in nessun file tracciato. Se la
      risposta è no, kromgo resta su `envoy-internal` senza badge
- [ ] `snmp-exporter` — switch HPE OfficeConnect 1820 e UPS, oggi invisibili
- [ ] `drm-exporter` — utilizzo della GPU Intel, oggi invisibile nonostante frigate e
      jellyfin ci transcodifichino sopra
- [ ] Valutare NUT **in cluster**: oggi il server gira su donkey via Docker e in cluster
      c'è solo l'exporter
- [ ] Riprendere lo scrape delle metriche MinIO da elizabeth (vedi Follow-ups): è la
      stessa lacuna, ed è quella che ha costretto a diagnosticare le failure CNPG
      interrogando VictoriaLogs a mano

### Fase 6 — stack \*arr

Solo torrent, niente usenet. `tqm` è già presente come cronjob orario.

- [ ] `qui` (`ghcr.io/autobrr/qui`) — WebUI alternativa per qbittorrent. Attenzione: la
      WebUI integrata è quella oggi protetta da OIDC, quindi la protezione va spostata
- [ ] `autobrr` — announce IRC e RSS dei tracker → grab automatico verso qbittorrent.
      È il pezzo che dà più valore sul torrent
- [ ] `recyclarr` — sincronizza profili qualità e custom format TRaSH dentro radarr e
      sonarr via CronJob
- [ ] `bazarr` — sottotitoli, integrato con radarr/sonarr e jellyfin
- [ ] Sostituire lo script `xseed.sh` con l'app `cross-seed`
      (`ghcr.io/cross-seed/cross-seed`): più capace e mantenuta da altri

## MCP in cluster

I server MCP vanno **deployati nel cluster ed esposti su `envoy-internal`**, così sono
consumabili da Claude Code su questa macchina, da altre macchine in LAN, e dalle app LLM
in cluster. Non come processi `uvx` locali.

Oggi `.mcp.json` punta a `uvx mcp-proxy` contro l'endpoint `/api/mcp` di Home Assistant.
Il file è correttamente in `.gitignore` — contiene un token HA a lunga scadenza e il
dominio in chiaro — e ci deve restare.

### Decisioni da prendere prima di deployare

- [ ] **Come autenticare gli endpoint MCP.** Un MCP di Home Assistant non autenticato
      sulla LAN è un telecomando per la casa. L'OIDC non è utilizzabile: i client MCP non
      sono browser e non seguono redirect. La strada verificata è
      `SecurityPolicy.apiKeyAuth` di Envoy Gateway, che estrae la chiave da un header:

      ```yaml
      apiKeyAuth:
        credentialRefs:
          - {group: "", kind: Secret, name: mcp-apikeys}
        extractFrom:
          - headers: [x-api-key]
      ```

      Nota verificata: se si estrae da `Authorization`, il valore nel Secret **non** deve
      includere il prefisso `Bearer`, perché Envoy confronta la stringa così com'è
- [ ] **Con quale meccanismo deployarli.** Due strade: HelmRelease app-template normali
      con HTTPRoute, oppure `litellm-operator` con risorse `LiteLLMMCPServer`
      (`litellm.home-operations.com/v1alpha1`). La seconda li registra automaticamente
      come tool dentro LiteLLM, che è già deployato qui — quindi diventano disponibili
      anche a open-webui e non solo a Claude Code
- [ ] Decidere se creare un namespace `ai/` dedicato

### Server da deployare

- [ ] **ha-mcp** (`ghcr.io/homeassistant-ai/ha-mcp`) — server dedicato con superficie di
      tool più ricca dell'`/api/mcp` integrato di Home Assistant; sostituisce il bridge
      `mcp-proxy` attuale. È la priorità. L'autenticazione propria del server non è
      documentata, quindi va protetto al gateway
- [ ] **Grafana MCP** (`grafana/mcp-grafana`) — query su Prometheus, Loki, dashboard e
      alert; richiede `GRAFANA_URL` e `GRAFANA_SERVICE_ACCOUNT_TOKEN`. Risponde
      direttamente a un dolore già registrato qui sotto: le failure CNPG settimanali sono
      state diagnosticate interrogando VictoriaLogs a mano

### Da esplorare

Candidati non ancora verificati. Ogni voce va chiusa con "esiste e serve" oppure "non
esiste", non lasciata aperta.

- [ ] **kubesearch** — verificare se esiste un server MCP per kubesearch.dev; darebbe
      accesso ai pattern di deploy della community durante l'aggiunta di app nuove
- [ ] **context7** — documentazione aggiornata delle librerie. Valutare se serve in un
      repo che è quasi tutto YAML
- [ ] **Kubernetes** — utile solo se offre qualcosa che `kubectl` via shell non dà già
- [ ] **Paperless / Immich / Karakeep / Jellyfin** — app self-hosted qui presenti che
      potrebbero avere un MCP ufficiale o community. Da verificare una per una: un MCP su
      paperless renderebbe interrogabili i documenti, che è vicino alla voce "catalogare
      i documenti con AI" già in TODO
- [ ] **CNPG / Postgres** — interrogare i database del cluster. Valutare con attenzione:
      darebbe a un agente accesso in lettura a tutti i dati applicativi

## TODO

- [ ] Investigate the issue caused by exposing both external and internal gateways simultaneously — appears to cause problems in Chrome (e.g., mixed routing, cookie conflicts, or certificate mismatches between the two gateways)

- [ ] Improve Home Assistant dashboard
- [ ] Add Syncthing
- [ ] Find a way to use AI to automatically catalog documents in Paperless-ngx
- [ ] Review and merge `mise-upgrade-dependencies` branch (mise upgrades + Romm removal)

## Follow-ups

- [ ] NFS canary reliability — Unraid disrupts NFS connections when the mover runs, canary doesn't handle it well
- [ ] Scrape MinIO metrics from elizabeth into Prometheus — currently zero MinIO metrics exist, so restarts, latency and S3 error rates are invisible from the cluster. This is what forced the weekly CNPG backup failures to be diagnosed by hand-querying VictoriaLogs for `IncompleteBody` instead of a single query
- [ ] Enable syslog mirroring on elizabeth **to a share, not to flash** — the 5 parity sync errors of 2026-08-02 could not be investigated per-sector because syslog had already rotated and nothing is persisted. Without this, the next array incident is equally unexplainable
- [ ] Plan replacement of the parity disk `sdf` (WD100EFAX) — 57,077 power-on hours (~6.5 years), 1 ATA error logged, recorded max temp 60 °C. SMART still PASSED and it was not implicated in the sync errors, but it is by far the oldest device in the array (the two data disks are at 12,009h)
