# doco-cd

[doco-cd](https://github.com/kimdre/doco-cd) is a lightweight GitOps agent for Docker Compose.
It polls a Git repository and applies Docker Compose changes to the host.

## How It Works

- Polls this repository (`refs/heads/main`) every **180 seconds**
- Each server has a **profile** (donkey or elizabeth) that determines which services to manage
- The bootstrap script detects the hostname and starts the matching profile
- Docker Compose stacks under `docker/<profile>/` are auto-discovered (depth 1)
- Secrets are decrypted at deploy time using SOPS + Age

## Profiles

| Profile   | Config file              | Working directory   |
|-----------|--------------------------|---------------------|
| donkey    | `.doco-cd.yaml`          | `docker/donkey/`    |
| elizabeth | `.doco-cd.elizabeth.yaml`| `docker/elizabeth/` |

## Prerequisites

- Docker and Docker Compose installed on the host
- A GitHub personal access token with repo read access
- The SOPS Age decryption key

## Bootstrap

First run — provide credentials:

```sh
./docker/doco-cd/bootstrap.sh --age-key "AGE-SECRET-KEY-1..." --token "ghp_..."
```

Subsequent runs — saved credentials are reused automatically:

```sh
./docker/doco-cd/bootstrap.sh
```

The script will:

1. Detect the hostname and map it to a profile (donkey or elizabeth)
2. Save the age key to `.age.key` and the token to `.env` (if provided)
3. Verify Docker is installed and credentials are present
4. Start the doco-cd container with `docker compose up -d`

## Configuration

### Poll configuration

- `poll-donkey.yaml` — polls `refs/heads/main`, interval 180s
- `poll-elizabeth.yaml` — polls `refs/heads/main`, interval 180s, target `elizabeth`

### Project configuration

- `.doco-cd.yaml` (repo root) — auto-discovers stacks in `docker/donkey/` at depth 1,
  uses `secrets.enc.env` for encrypted environment variables
- `.doco-cd.elizabeth.yaml` (repo root) — auto-discovers stacks in `docker/elizabeth/` at depth 1

### Adding a new service

1. Create a new directory under `docker/<profile>/<service>/`
2. Add a `docker-compose.yaml` inside it
3. Commit and push — doco-cd picks it up within 180 seconds
