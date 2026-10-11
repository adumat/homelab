# Migrating a PVC: three things that will bite

Learned the hard way while migrating apps off VolSync, one of which cost ~7 hours of radarr
metadata.

**1. A blocked `delete pvc` is armed, not cancelled.** `kubectl delete pvc` against a volume a
running pod is using does not fail — it sets `deletionTimestamp` and waits behind the
`kubernetes.io/pvc-protection` finalizer. It then fires **the moment the consumer stops**, which
may be minutes later in a different operation. Always check before starting:

```sh
kubectl get pvc <app> -n <ns> -o jsonpath='{.metadata.deletionTimestamp}'   # must be empty
```

**2. KEDA restarts the app even with the HelmRelease suspended.** Sixteen apps carry
`components/nfs-scaler`, whose `ScaledObject` (min 0 / max 1) will scale a Deployment back to 1
regardless of `flux suspend hr`. That both bypasses any verification gate and holds the PVC open
so it cannot be deleted. Pause it explicitly, and unpause on every exit path:

```sh
kubectl annotate scaledobject <app> -n <ns> autoscaling.keda.sh/paused-replicas="0" --overwrite
kubectl annotate scaledobject <app> -n <ns> autoscaling.keda.sh/paused-replicas-
```

Affected: every app with `components/nfs-scaler` in its `ks.yaml`
(`grep -l 'components/nfs-scaler$' kubernetes/apps/*/*/ks.yaml`).

**3. Verify with a per-file checksum manifest, and wait for the pod to finish.** A `du` total or
a directory listing proves nothing — a populator PVC binds and mounts happily while empty. Run
`find . -type f | sort` with `md5sum` per file in a `restartPolicy: Never` pod, wait for phase
**`Succeeded`**, *then* read the logs. Breaking on the first non-empty `kubectl logs` captures
partial output from a still-running pod: it silently truncated a 5510-file baseline to 493.

Expect exactly one benign difference: the app's **own log file**. The CSI snapshot is
crash-consistent, so its tail can differ between the snapshot instant and the live read. Ignore
`*/log/*` paths and abort on anything else.

**4. The `flux reconcile` that recreates the PVC un-pauses KEDA.** Pausing the `ScaledObject`
(trap 2) is not sufficient on its own, because recreating the PVC *requires*
`flux reconcile ks <app>` — and that re-applies the `ScaledObject` **from git**, where the pause
annotation does not exist. KEDA then scales the app back up, typically within a minute.

frigate restarted two minutes into its own verification, opened its SQLite database and
checkpointed the WAL into it. The after-manifest then "differed" from the baseline on
`frigate.db`, while `frigate.db-shm` and `frigate.db-wal` had vanished entirely. A textbook false
positive: the restore was perfect and the *proof* was what got destroyed. Re-assert the freeze
after every reconcile, and again periodically while the checksum pod runs.

Once a verification has been contaminated this way, **do not re-run the in-place check** — the
volume has already been mutated, so it can never match again. Restore the same snapshot into a
**scratch PVC** and diff that against the baseline. It leaves the app running and it tests the
thing that actually matters, the snapshot → restore path:

```yaml
apiVersion: kopiur.home-operations.com/v1alpha1
kind: Restore
metadata: {name: <app>-verify}
spec:
  credentialProjection: {enabled: true}
  policy: {onMissingSnapshot: Fail}        # Fail, not Continue: an empty volume must not "pass"
  source: {fromPolicy: {name: <app>, offset: 0}}   # offset 0 = newest, i.e. the quiesced one
  target: {populator: {}}
```

plus a PVC whose `dataSourceRef` points at it. frigate came back byte-identical on all 4 files.

⚠️ **`grep` in this repo's shell is `ugrep`**, and it does not match `^[<>]` on diff output the
way GNU grep does — it reported a real one-file difference as zero. Use `/usr/bin/grep` and
`/usr/bin/diff` when the answer matters. It has also silently returned nothing for
`ls -a | grep -i just`, and `grep -B` straddles YAML document boundaries.

⚠️ **The shell is zsh: brace a variable before a colon.** `$R:charmander` expands as `$R` with
the `:c` modifier and passes a mangled name; `drbdadm` then reports the resource as "not
defined" while the real one is fine. Write `"${R}:charmander"`.
