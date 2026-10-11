# A rolling upgrade can leave nodes falsely tainted DiskPressure

After a reboot a node may come back asserting `DiskPressure` with its `NoSchedule` taint, and
it does not always self-heal. This is worse here than it sounds: **Rook pins each mon and OSD
to its node with `nodeSelector`**, so one tainted node keeps that mon and OSD `Pending`
forever, Ceph never returns to `HEALTH_OK`, and `HEALTH_OK` is exactly what tuppr's health
check gates on — the rollout parks partway rather than finishing.

Ask kubelet for the numbers, not the node. `talosctl usage /var` and kubelet's `statfs`
disagreed by ~12 GB, so trust:

```sh
kubectl get --raw /api/v1/nodes/<node>/proxy/stats/summary | jq '.node.fs, .node.runtime.imageFs'
```

Thresholds are stock: `nodefs.available` 10%, `imagefs.available` 15%.

- **Above the thresholds → the condition is stale.** `talosctl -n <ip> service kubelet restart`
  clears it in seconds and does not disturb running containers. Do not read a stale condition
  `lastHeartbeatTime` as a dead kubelet — node *conditions* refresh every ~5 min while
  liveness rides on the `Lease` in `kube-node-lease`
- **Below them → it is real, and the fix is deleting terminal pods.** kubelet's log states
  the deadlock outright: GC runs, then `must evict pod(s) to reclaim` → every remaining pod
  is critical → `unable to evict any pods from the node`. It never self-heals

**A drain leaves behind terminal pods that pin containerd space, and they are the actual
cause.** After this rolling upgrade there were **75** of them. On the worst node containerd
held **35.5 GB** (23.7 GB overlayfs snapshots + 11.8 GB content blobs) while only **5.5 GB of
live images** existed — the remainder was pinned by dead pod objects, which image GC cannot
reclaim at all. Clearing them took that node from 4 GB free / 9% imagefs to **40 GB / 75%**,
and the taint then cleared on its own.

Why a dead Pod costs disk: while the Pod object exists kubelet must keep its containers, each
container owns a writable overlayfs snapshot *and* pins the image it ran from, and image GC
refuses to delete a pinned image. A ReplicaSet never deletes its own terminal pods — it just
creates a replacement alongside.

```sh
# BOTH phases. A drained pod usually ends up Succeeded (shown as "Completed"),
# so filtering on Failed alone silently leaves most of them behind.
kubectl delete pods -A --field-selector status.phase=Succeeded
kubectl delete pods -A --field-selector status.phase=Failed
```

Deleting a terminal pod is safe — its controller already replaced it, and fluent-bit has
shipped the logs off-node.

**This is now automatic:** `terminated-pod-gc-threshold: "30"` in
[cluster.yaml](../../kubernetes/talos/patches/controller/cluster.yaml). PodGC deletes oldest-first
only once the count *exceeds* the threshold, so the number must sit **below** the garbage
level to do anything — the default 12500 never fires on five nodes, and 50 would have deleted
4 of 54. `NodeVarSpaceLow` warns at 20% free, ahead of the 15% eviction line.

Why the margin is thin at all: `/var` is capped at 50 GiB and containerd stores each image
**twice**, unpacked snapshots *and* content blobs, because spegel needs
`discard_unpacked_layers = false`.

⚠️ **Do not trust `talosctl usage /var` here.** It reported 36.8 GB while `statfs` said
49 GB used — it does not see space pinned by dead containers. Use kubelet's summary API.
