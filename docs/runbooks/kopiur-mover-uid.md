# A root mover is not more privileged than a uid-1000 one — it is usually less

`kopia snapshot create` fails `PermissionDenied` when the app writes files the mover cannot read.
romm failed this way on exactly 29 files. The first diagnosis was that romm "runs as root and
writes its game-save uploads mode 0600, so a mover as 1000 cannot read them", and the fix applied
was `KOPIUR_PUID/PGID: "0"` plus the namespace opt-in kopiur demands for an elevated mover.

**That was backwards, and it is what kept romm's backup broken for two days.** Measured on the
live volume:

```
   8522 1000:1000 644
   1150 1000:1000 664
    461 1000:1000 2755   <- setgid dirs
    125 1000:1000 2775
     29 1000:1000 600    <- exactly the "29 fatal error(s)" the mover reported
```

Every file and directory is owned by **1000:1000**; not one belongs to root. A mover running as
1000 therefore **is the owner** of all 29 and can open them. A mover running as root cannot,
because kopiur's mover container is:

```yaml
runAsUser: 0
capabilities: {drop: ["ALL"]}
allowPrivilegeEscalation: false
```

**UID 0 with no capabilities does not bypass file permissions.** Root's ability to ignore `0600`
comes from `CAP_DAC_OVERRIDE`, which is dropped here. So `runAsUser: 0` throws away the owner
match and gains nothing in exchange. Proven both ways on the same volume and policy, minutes
apart:

| mover | result |
| --- | --- |
| `runAsUser: 0` | `Failed`, `PermissionDenied`, 29 fatal errors |
| `runAsUser: 1000` | `Succeeded`, 212,918,436 bytes |

So: **read the ownership before choosing a mover UID**, and never infer it from what UID the
app's *container* runs as. romm's container genuinely is root, yet every file is 1000:1000 — the
app drops privileges, and the setgid bit on the parents supplies the group.

```sh
kubectl exec -n <ns> <pod> -- sh -c \
  'find <pvc-mountpaths> \( -type f -o -type d \) -exec stat -c "%u:%g %a" {} \; | sort | uniq -c | sort -rn'
```

Beware `-xdev`: romm mounts NFS *inside* the same tree, so `find -xdev /romm` stops at the mount
boundary and reported 5 paths instead of 10,287. Scan the PVC's actual `subPath` mountpoints.

The failure names each file it could not open, so read it rather than theorising:

```sh
kubectl get snapshot <name> -n <ns> -o json | jq -r '.status.failure.message'
```

**`fsGroup` cannot rescue a genuine mismatch, whatever `fsGroupChangePolicy` says.** The mover
snapshots a staged clone mounted **read-only**, so Kubernetes cannot chmod it. Verified with
`Always`.

If the files really are root-owned and `0600`, an elevated mover is the only option — and note
it needs a capability, not just the UID. kopiur gates it behind a namespace opt-in:

```yaml
# <app>/ks.yaml
      KOPIUR_PUID: "0"
      KOPIUR_PGID: "0"
```

```yaml
# apps/<namespace>/kustomization.yaml - kopiur refuses an elevated mover otherwise
patches:
  - target: {kind: Namespace}
    patch: |-
      - op: add
        path: /metadata/annotations/kopiur.home-operations.com~1privileged-movers
        value: "true"
```

The gate is deliberate: anyone with access to the namespace could reuse the minted
`kopiur-mover` ServiceAccount at that privilege. Grant it per namespace, never cluster-wide,
and prefer fixing the app's file modes where that is possible.

⚠️ When checking which namespaces carry an annotation, **do not use `grep -B`** on rendered
output — it straddles document boundaries and will name the wrong namespace. Parse the
documents:

```sh
mise exec -- flate build ks 2>/dev/null > /tmp/ks.yaml
python3 -c "import io,re;print([re.search(r'^  name: (\S+)',d,re.M).group(1) for d in io.open('/tmp/ks.yaml').read().split('\n---\n') if re.search(r'^kind: Namespace$',d,re.M) and 'privileged-movers' in d])"
```
