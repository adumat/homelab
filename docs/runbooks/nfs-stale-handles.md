# NFS from Unraid: stale handles — **open problem**

The most annoying recurring failure in the cluster, and it is **not solved**. You need to
recognise it, because it shows up disguised as something else.

**What happens.** `/mnt/user` is shfs, Unraid's FUSE layer, and it does not hand out stable
inode numbers. When shfs reassigns the fileid for a path an NFS client has cached, the client
invalidates the handle and every later operation returns `ESTALE`. The trigger is shfs's
`remember=330` (Unraid's `fuse_remember` tunable): it forgets a path's inode after 330 s idle
and issues a new one on the next lookup. `-1` (never forget) would stop it, at the cost of
unbounded shfs memory on an 8 GB host — rejected. It **does not heal on its own**. The mounts are `soft` (see below), so I/O returns an error rather than hanging forever,
but the mount stays poisoned.

The kernel says so outright, and this is the line to grep for:

```
NFS: server elizabeth.lan error: fileid changed
```

⚠️ **A remount does not fix it, and neither does deleting the pod.** The poison is the node's
NFS client state for that server, not the mount: verified 2026-09-21 by deleting the consumer,
watching kubelet unmount, and finding the freshly-created mount stale on its first `stat`. Only
a reboot of that node clears it.

**It is per-node, not per-export.** Diagnosed 2026-09-21 on charmander, which had 13 `fileid
changed` errors while every other node had zero. One maintenance Job proved it in a single run:
pod `…-f9jhx` on charmander died on a stale handle, pod `…-ml8rm` on magikarp completed, same
export, minutes apart. Two subdirectories of the same export on the same node disagreed too —
`backups/volsync` served kopia fine while `backups/kopiur` was dead. So before blaming the
server, find out whether *another node* can read it:

```bash
mise exec -- talosctl -n <node-ip> dmesg | grep -c 'fileid changed'
```

⚠️ **Probe read-write, not read-only.** On 2026-10-03 charmander and magikarp mounted the
kopiur export `readOnly: true` cleanly while every read-write mount of the same export died
with `stale file handle` at container creation. A read-only probe pod proves nothing about a
writer.

⚠️ **kopiur's own message misdiagnoses this.** It reports `ProbeDeadlineExceeded` and advises
raising `spec.bootstrap.failurePolicy.activeDeadlineSeconds`. The backend is not slow; the
mover never started. Read the mover pod's events, not the ClusterRepository condition.

⚠️ **The movers are Jobs, so `nfs-scaler` cannot cover them.** KEDA scales Deployments to zero;
a Job has nothing to scale. The 14 scaler-covered apps self-heal, Jobs do not. This is why the
kopiur repository moved to garage S3 (`ClusterRepository/garage`) on 2026-10-03; `nas` is the
retired NFS one. Any other Job that mounts NFS still needs the manual recovery: cordon the bad
node and reboot it.

**How it presents.** Almost never as an "NFS error":

- pods stuck in `Terminating`, because the kubelet cannot unmount
- applications that start but see no files, or crash-loop reading `/media`
- a recurring `KubeJobFailed` on `qbittorrent-tools`: that is a **symptom, not the cause**
  — it means qbittorrent is down on a stale handle. Fix qbittorrent, not the job

**How to diagnose.**

```bash
mise exec -- kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded
mise exec -- kubectl describe pod <pod> -n <ns> | grep -iA3 'mount\|stale'
mise exec -- kubectl logs <pod> -n <ns> --previous | grep -i 'stale\|input/output error'
```

NFS health as seen from the cluster comes from **`nfs-stale-exporter`**
(`observability/nfs-stale-exporter`, own public repo + Helm chart). A DaemonSet statfs's every
kubelet NFS **volume root** on each node and exports `nfs_mount_stale{pod_uid,...}` plus
`nfs_server_reachable{server}`. A TCP probe on port 2049 is not enough on its own: the server
answers while the handle is dead, which is the whole failure mode. It replaced `nfs-canary` on
2026-08-22 (single replica, segfaulted 41 times in 22h, and blind to per-pod staleness).

Prometheus joins the pod UID to an app (`nfs:mount_stale:app`) and alerts with
`NfsMountStale` (2m, expected to self-resolve) and `NfsMountStaleUnrecovered` (20m, pages).

**How to recover today.** Recreate the pod so the kubelet remounts:

```bash
mise exec -- kubectl delete pod <pod> -n <ns>
# if it hangs in Terminating because the unmount blocks:
mise exec -- kubectl delete pod <pod> -n <ns> --force --grace-period=0
```

This works for the common case, where only that pod's mount is affected. It does **not** work
once the node's NFS client state is poisoned — see the `fileid changed` case above, where the
replacement pod's fresh mount is stale on its first `stat`. Then the sequence is: cordon the
node so the workload lands elsewhere, confirm it succeeds there, and reboot the bad node.

**Recovery is automatic.** The `nfs-scaler` component — now on **all 14** NFS consumers, not
8 — scales an app to zero when either elizabeth is unreachable or that app's own mount has been
stale for 5 minutes, then back up, which is what forces a clean remount. Scaling to zero *is*
the pod deletion above, so no controller holds delete permissions.

⚠️ The trigger's two terms default in opposite directions on purpose: reachability fails
**open** (`or vector(1)`), staleness fails **closed** (`or vector(0)`). Treating absent
reachability as "server down" would park the apps, unmount their volumes, remove the series
cluster-wide, and nothing could scale them back.

`NfsScalerCoverageGap` fires when an app mounts NFS but has no ScaledObject — the August 2026
incident hit metube and pyload-ng precisely because nobody had opted them in.

**Mount configuration.** `/etc/nfsmount.conf` is globally overwritten by
`kubernetes/talos/patches/global/machine-files.yaml`: `nfsvers=4.2`, `soft`, `timeo=50`,
`retrans=3`, `nconnect=8`, `noatime`, `rsize`/`wsize` at 1 MiB. Changes to `machine.files`
require a **reboot per node**, and Flux does not apply them.

Pinning `nfsvers=4.2` is not cosmetic: Unraid stopped serving minor version 4.0, and with
that pinned **every** mount fails with `mount.nfs: Protocol not supported`. Inline
`type: nfs` volumes die, PVs with explicit `mountOptions` survive, and `showmount`/`rpcinfo`
look perfectly healthy.

Nine apps mount NFS inline with `type: nfs` (frigate, home-assistant, kopia, qbittorrent,
radarr, sonarr, filebrowser, jellyfin, romm): those are the exposed ones.

A structural fix is on the roadmap. Until it lands, this section is the procedure.
