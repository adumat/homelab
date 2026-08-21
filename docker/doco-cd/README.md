# doco-cd

[doco-cd](https://github.com/kimdre/doco-cd) is a lightweight GitOps agent for Docker Compose.
It polls a Git repository and applies Docker Compose changes to the host.

## How It Works

- Polls this repository (`refs/heads/main`) every **180 seconds**
- Each server has a **profile** (donkey, elizabeth or navi) that determines which services to manage
- The bootstrap script detects the hostname and starts the matching profile
- Docker Compose stacks under `docker/<profile>/` are auto-discovered (depth 1), and
  `auto_discovery.delete: true` means removing a stack directory removes it from the host
- Secrets come from **Bitwarden Secrets Manager** at deploy time (`SECRET_PROVIDER: bitwarden_sm`),
  resolved per profile from the `external_secrets:` map in that profile's config file

## Profiles

| Profile   | Config file              | Working directory   |
|-----------|--------------------------|---------------------|
| donkey    | `.doco-cd.yaml`          | `docker/donkey/`    |
| elizabeth | `.doco-cd.elizabeth.yaml`| `docker/elizabeth/` |
| navi      | `.doco-cd.navi.yaml`     | `docker/navi/`      |

## Prerequisites

- Docker **and Docker Compose** on the host. Check both — `bootstrap.sh` runs
  `docker compose ... up -d`, and `docker` being present says nothing about the compose plugin.
  On Unraid, install the **Compose Manager** plugin: the root filesystem runs from RAM, so a
  binary dropped into `/usr/libexec/docker/cli-plugins/` disappears on reboot.
- A GitHub personal access token with repo read access. Optional while the repository is public —
  doco-cd clones anonymously, and `GIT_ACCESS_TOKEN` may be left empty.
- A Bitwarden Secrets Manager access token, with access to the projects holding the secrets that
  profile's `external_secrets:` map references.

## Bootstrap

First run — provide credentials:

```sh
./docker/doco-cd/bootstrap.sh --bws-token "0.xxxx..." --token "ghp_..."
```

Subsequent runs — saved credentials are reused automatically:

```sh
./docker/doco-cd/bootstrap.sh
```

The script will:

1. Detect the hostname, **lowercased**, and map it to a profile. The lowercasing matters: Unraid
   reports a capitalised hostname, so `Elizabeth` would otherwise fail to match.
2. Write both tokens to `docker/doco-cd/.env`, preserving any value not passed this time
3. Verify Docker is installed
4. Start the matching profile with `docker compose --profile <name> up -d`

To avoid the token appearing in the host's process list, write `.env` directly instead of passing
`--bws-token`, then run the script with no arguments:

```sh
ssh root@host 'umask 077; cat > /path/to/docker/doco-cd/.env' <<EOF
GIT_ACCESS_TOKEN=
BWS_ACCESS_TOKEN=${BWS_ACCESS_TOKEN}
EOF
```

## Configuration

### Poll configuration

- `poll-donkey.yaml` — polls `refs/heads/main`, interval 180s
- `poll-elizabeth.yaml` — polls `refs/heads/main`, interval 180s, target `elizabeth`

### Project configuration

Each profile has its own file in the repo root, all with the same shape: `working_dir`,
`auto_discovery`, and an optional `external_secrets:` map.

- `.doco-cd.yaml` → `docker/donkey/`
- `.doco-cd.elizabeth.yaml` → `docker/elizabeth/`
- `.doco-cd.navi.yaml` → `docker/navi/`

`external_secrets:` maps an environment variable name to a Bitwarden secret **UUID**, and those
variables are what `${VAR}` references in a compose file resolve to:

```yaml
external_secrets:
  SOME_TOKEN: 7e666c97-687d-4685-b563-b4ac015ffbb4 # gitleaks:allow
```

The `# gitleaks:allow` marker is needed because a UUID next to a key containing `TOKEN`/`SECRET`
looks like a credential to the pre-commit secret scanner. It is marked per line rather than
allowlisting the file, so a genuinely pasted secret would still be caught. Note
`.doco-cd.yaml` predates the hook and will need the same treatment when next edited.

### Adding a new service

1. Create a new directory under `docker/<profile>/<service>/`
2. Add a `docker-compose.yaml` inside it
3. If it needs secrets, add them to that profile's `external_secrets:` map and reference them as
   `${VAR}`
4. Commit and push — doco-cd picks it up within 180 seconds

A missing `working_dir` is an **error**, not an empty result: doco-cd logs
`failed to auto-discover deployment configurations: lstat .../docker/<profile>: no such file or
directory` and the poll fails until the directory exists.
