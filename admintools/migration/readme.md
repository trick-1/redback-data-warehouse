# Docker Migration Script

This repository contains a Bash-based Docker container migration helper. It inventories Docker containers on a source host, copies container data to a destination layout, and generates Docker Compose migration artifacts that make it easier to recreate the workloads on another host.

The script is designed for two common cases:

1. **Docker Compose projects** — containers that were started by Compose and have Compose labels.
2. **Standalone containers** — containers started directly with `docker run` or another non-Compose method.

It can copy Docker volumes, bind mounts, Compose files, `.env` files, build contexts, and optionally changed files from a container writable layer.

---

## What the script does

At a high level, the script:

- Scans all Docker containers on the current machine.
- Groups Compose-managed containers by Compose project.
- Detects standalone containers separately.
- Inspects container metadata, including:
  - image
  - restart policy
  - network mode
  - environment variables
  - port bindings
  - mounts
  - Docker Compose labels
- Copies Docker volumes and bind mounts into a new destination directory tree.
- Converts volume mounts into explicit host bind mounts in generated Compose output.
- Optionally copies:
  - original Compose files
  - `.env` files
  - Compose working directories / build contexts
  - writable-layer changes from `docker diff`
- Generates migration reports for each project and container.
- Generates a certificate/security hints report by looking for certificate-like paths, filenames, and environment variables.
- Adds a default Docker JSON log cap unless disabled:
  - `max-size: 10m`
  - `max-file: 3`
- Can perform text replacements across copied text files, useful for changing hostnames, IPs, paths, or domains during migration.
- Can copy data either locally or to a remote destination over SSH using `rsync` or `scp`.

---

## Important safety notes

This script helps prepare a migration, but it does **not** guarantee that the migrated containers will run without review.

Before starting the migrated stack, review:

- generated `docker-compose.yml`
- generated `docker-compose.migration.override.yml`
- copied `.env` files
- `report.txt`
- `certificates-report.txt`
- file ownership and permissions on the destination
- application-specific secrets and certificates
- external networks that may need to be recreated manually

If `--stop-containers` or `--final-sync-stop` is used, containers are stopped for consistency. The script does **not** restart them automatically afterwards.

Use `--include-writable-layer` carefully. Writable layers can contain runtime cache, temporary files, logs, secrets, or state that should really live in volumes.

---

## Requirements

Run the script on the source Docker host.

Required commands:

```bash
docker
jq
find
grep
awk
readlink
python3
file
sed
sha256sum
```

For remote transfers:

```bash
ssh
rsync    # when using --transfer rsync
scp      # when using --transfer scp
```

For generated migrated Compose merging:

```bash
python3-yaml
```

On Debian/Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y docker.io jq rsync openssh-client python3 python3-yaml file coreutils sed grep gawk
```

You must have permission to inspect Docker containers and read Docker volume data. In practice, run as root or a user in the `docker` group.

---

## Basic usage

```bash
chmod +x containermig.sh

./containermig.sh \
  --dest-base /opt/redback/migrated \
  --sync-data
```

This performs a local migration into:

```text
/opt/redback/migrated/
```

and writes local review artifacts under:

```text
./docker-migration-output/
```

---

## Remote migration example

Copy all detected containers to another host:

```bash
./containermig.sh \
  --dest-host new-docker-host.example.com \
  --dest-user root \
  --dest-base /opt/redback/stacks \
  --transfer rsync \
  --sync-data \
  --sync-compose-files \
  --sync-build-context
```

This copies data over SSH and writes project directories under:

```text
/opt/redback/stacks/<project>/
```

on the destination host.

---

## Recommended full migration command

For a Compose-heavy Docker host, this is the most useful starting point:

```bash
./containermig.sh \
  --dest-host new-docker-host.example.com \
  --dest-user root \
  --dest-base /opt/redback/stacks \
  --transfer rsync \
  --sync-data \
  --sync-compose-files \
  --sync-build-context \
  --final-sync \
  --final-sync-stop \
  --verbose
```

This will:

- copy data
- copy Compose files
- copy build context directories
- stop containers during final sync
- generate final validation reports
- generate merged Compose files where possible

---

## Options

### Core options

| Option | Description |
|---|---|
| `--dest-host HOST` | Remote destination host. If omitted, files are copied locally. |
| `--dest-user USER` | SSH username for the destination host. |
| `--dest-base PATH` | Required. Base destination path for migrated projects and standalone containers. |
| `--transfer rsync\|scp` | Transfer method. Default: `rsync`. |
| `--sync-data` | Actually copy files and directories. Without this, copy operations are skipped and the script mainly produces reports/artifacts. |
| `--csv FILE` | Process only containers listed in a CSV file. |
| `--verbose` | Enable debug output. |

### Migration behavior

| Option | Description |
|---|---|
| `--include-writable-layer` | Capture changed files from container writable layers using `docker diff` and `docker cp`. |
| `--stop-containers` | Stop selected containers before capturing their data. |
| `--sync-compose-files` | Copy original Compose files and `.env` files. Also automatically enables migrated Compose generation. |
| `--sync-build-context` | Copy the Compose working directory/build context, excluding common heavy/generated directories. |
| `--generate-migrated-compose` | Generate a merged `docker-compose.yml` using the original Compose file plus generated migration override. |
| `--final-sync` | Produce final sync validation reports. |
| `--final-sync-stop` | Stop containers during the final sync phase. |
| `--no-log-cap` | Disable automatic Docker JSON log capping in generated Compose output. |

### Text replacement options

| Option | Description |
|---|---|
| `--replace-text OLD=NEW` | Replace text in copied text files. Can be repeated. |
| `--replace-file FILE` | Load replacement pairs from a file, one `OLD=NEW` pair per line. Lines beginning with `#` are ignored. |

Example:

```bash
./containermig.sh \
  --dest-base /opt/redback/stacks \
  --sync-data \
  --sync-compose-files \
  --replace-text old.example.com=new.example.com \
  --replace-text 192.168.1.10=10.10.20.10
```

Replacement file example:

```text
# hostname changes
old.example.com=new.example.com

# IP changes
192.168.1.10=10.10.20.10
```

Use it with:

```bash
./containermig.sh \
  --dest-base /opt/redback/stacks \
  --sync-data \
  --sync-compose-files \
  --replace-file replacements.txt
```

### SSH options

| Option | Description |
|---|---|
| `--ssh-key PATH` | SSH private key to use. |
| `--ssh-control-persist DURATION` | SSH ControlPersist value. Default: `10m`. |

Example:

```bash
./containermig.sh \
  --dest-host new-docker-host.example.com \
  --dest-user root \
  --ssh-key ~/.ssh/id_ed25519 \
  --dest-base /opt/redback/stacks \
  --sync-data
```

### Output options

| Option | Description |
|---|---|
| `--output-dir PATH` | Local output directory. Default: `./docker-migration-output`. |

---

## CSV container selection

Use `--csv FILE` to migrate only selected containers.

The script skips the first line, so include a header row.

Expected columns:

```csv
container,include_writable_layer,stop_container
```

Example:

```csv
container,include_writable_layer,stop_container
nextcloud,1,1
postgres,0,1
redis,0,0
```

The `container` field can be a container name or ID.

Boolean values accepted:

```text
1, true, yes, y, on
0, false, no, n, off
```

CSV values override the global `--include-writable-layer` and `--stop-containers` options for the listed containers.

Run with:

```bash
./containermig.sh \
  --dest-host new-docker-host.example.com \
  --dest-user root \
  --dest-base /opt/redback/stacks \
  --sync-data \
  --csv containers.csv
```

---

## Destination layout

For Compose projects, the destination layout is:

```text
<dest-base>/<project>/
  docker-compose.orig.yml
  docker-compose.yml
  .env
  working_dir/
  migration/
    report.txt
    certificates-report.txt
    docker-compose.migration.override.yml
    final-sync-report.txt
  data/
    <service>/
      volumes/
      binds/
      writable/
```

For standalone containers, the destination layout is:

```text
<dest-base>/standalone/<container>/
  compose.generated.yml
  report.txt
  certificates-report.txt
```

Local review output is also written to:

```text
docker-migration-output/
  migration-inventory.txt
  projects/
    <project>/
  standalone/
    <container>/
  containers/
    <container>/
      <run-id>/
  staging/
```

---

## Generated Compose behavior

For Compose projects, the script creates a migration override file:

```text
docker-compose.migration.override.yml
```

This override replaces Docker named volumes and bind mounts with explicit host paths under the destination data directory.

When `--generate-migrated-compose` is enabled, the script merges:

```text
docker-compose.orig.yml
docker-compose.migration.override.yml
```

into:

```text
docker-compose.yml
```

The merged file:

- updates services with migrated bind mount paths
- adds log capping unless disabled
- removes unused top-level named volumes where possible

For standalone containers, the script generates:

```text
compose.generated.yml
```

This includes:

- image
- restart policy
- network mode
- environment variables
- port bindings
- logging cap, unless disabled

Standalone generated Compose should be reviewed carefully because not every `docker run` option can be reconstructed from inspection data.

---

## Build context copying

When `--sync-build-context` is enabled, the script copies the Compose project working directory to:

```text
<dest-base>/<project>/working_dir/
```

The following directories are excluded when using `rsync`:

```text
.git
.svn
.hg
node_modules
__pycache__
.venv
venv
.mypy_cache
.pytest_cache
.cache
dist
build
.idea
.vscode
```

In `scp` mode, these excludes are not applied; the whole working directory is copied.

---

## Certificate and secret hints

The script writes a certificate/security hints report:

```text
certificates-report.txt
```

It looks for hints in:

- environment variable names
- environment variable values
- mount paths
- Compose files
- `.env` files
- certificate-like filenames under the working directory

Detected hints include terms such as:

```text
CERT
CERTIFICATE
TLS
SSL
KEY
KEYSTORE
TRUSTSTORE
CA_BUNDLE
CLIENT_CERT
CLIENT_KEY
```

and file extensions such as:

```text
.crt
.cer
.pem
.key
.p12
.pfx
.jks
.keystore
.csr
.der
```

This report is informational only. You still need to review whether secrets should be copied, rotated, or handled through a secrets manager.

---

## Final sync mode

`--final-sync` writes extra validation information, including source and destination size comparisons for copied mounts.

Use it with `--final-sync-stop` for a more consistent final copy:

```bash
./containermig.sh \
  --dest-host new-docker-host.example.com \
  --dest-user root \
  --dest-base /opt/redback/stacks \
  --sync-data \
  --sync-compose-files \
  --sync-build-context \
  --final-sync \
  --final-sync-stop
```

The final sync report is written to:

```text
<dest-base>/<project>/migration/final-sync-report.txt
```

and local review copies are placed under:

```text
docker-migration-output/
```

---

## Typical migration workflow

### 1. Run an inventory/report-only pass

```bash
./containermig.sh \
  --dest-base /tmp/docker-migration-review \
  --verbose
```

Review:

```text
docker-migration-output/migration-inventory.txt
docker-migration-output/projects/
docker-migration-output/standalone/
docker-migration-output/containers/
```

### 2. Run the real data sync

```bash
./containermig.sh \
  --dest-host new-docker-host.example.com \
  --dest-user root \
  --dest-base /opt/redback/stacks \
  --transfer rsync \
  --sync-data \
  --sync-compose-files \
  --sync-build-context
```

### 3. Review generated files on the destination

On the destination host:

```bash
cd /opt/redback/stacks/<project>
ls -la
cat migration/report.txt
cat migration/certificates-report.txt
docker compose config
```

### 4. Run a final stopped sync

```bash
./containermig.sh \
  --dest-host new-docker-host.example.com \
  --dest-user root \
  --dest-base /opt/redback/stacks \
  --transfer rsync \
  --sync-data \
  --sync-compose-files \
  --sync-build-context \
  --final-sync \
  --final-sync-stop
```

### 5. Start the migrated stack

On the destination host:

```bash
cd /opt/redback/stacks/<project>
docker compose up -d
docker compose ps
docker compose logs --tail=100
```

---

## Troubleshooting

### `--dest-base is required`

Always provide a destination base path:

```bash
--dest-base /opt/redback/stacks
```

### `Required command not found: jq`

Install missing dependencies:

```bash
sudo apt-get install -y jq
```

### `PyYAML is required for --generate-migrated-compose`

Install Python YAML support:

```bash
sudo apt-get install -y python3-yaml
```

### Remote SSH copy fails

Test SSH manually:

```bash
ssh user@host 'hostname && mkdir -p /tmp/migration-test'
```

If using a key:

```bash
ssh -i ~/.ssh/id_ed25519 user@host 'hostname'
```

Then retry with:

```bash
--ssh-key ~/.ssh/id_ed25519
```

### Generated Compose references missing paths

Check whether `--sync-data` was used. Without `--sync-data`, the script does not actually copy directories or files.

### Containers were stopped and not restarted

This is expected. Restart source containers manually if needed:

```bash
docker start <container>
```

or for Compose projects:

```bash
docker compose up -d
```

### `scp` copied too much build context

Use the default `rsync` mode if you want the build context excludes to apply:

```bash
--transfer rsync
```

---

## Example: migrate one Compose project by selecting containers

Create `containers.csv`:

```csv
container,include_writable_layer,stop_container
nextcloud-app,0,1
nextcloud-db,0,1
nextcloud-redis,0,1
```

Run:

```bash
./containermig.sh \
  --dest-host new-docker-host.example.com \
  --dest-user root \
  --dest-base /opt/redback/stacks \
  --transfer rsync \
  --sync-data \
  --sync-compose-files \
  --sync-build-context \
  --final-sync \
  --final-sync-stop \
  --csv containers.csv
```

---

## Example: local migration with hostname replacement

```bash
./containermig.sh \
  --dest-base /opt/redback/stacks \
  --sync-data \
  --sync-compose-files \
  --sync-build-context \
  --replace-text old-hostname.local=new-hostname.local \
  --replace-text 192.168.1.50=10.0.20.50
```

---

## Notes and limitations

- The script relies heavily on Docker inspection metadata.
- It cannot perfectly reconstruct every option used in an original `docker run` command.
- Compose-managed containers produce better migration output than standalone containers.
- The script does not recreate external Docker networks automatically.
- The script does not recreate Docker secrets or Swarm-specific configuration.
- The script does not restart containers it stops.
- Some applications require clean shutdowns or application-level backup/restore instead of filesystem copying.
- Database containers should ideally be migrated using database-native dump/restore or stopped during final sync.
- File ownership, SELinux labels, AppArmor profiles, and custom capabilities may need manual review.
- Writable-layer capture is a recovery aid, not a replacement for proper volume design.

---

## Quick command reference

```bash
# Help
./containermig.sh --help

# Local migration
./containermig.sh --dest-base /opt/redback/stacks --sync-data

# Remote migration with rsync
./containermig.sh \
  --dest-host new-host \
  --dest-user root \
  --dest-base /opt/redback/stacks \
  --sync-data

# Remote migration with Compose files and build context
./containermig.sh \
  --dest-host new-host \
  --dest-user root \
  --dest-base /opt/redback/stacks \
  --sync-data \
  --sync-compose-files \
  --sync-build-context

# Select containers by CSV
./containermig.sh \
  --dest-base /opt/redback/stacks \
  --sync-data \
  --csv containers.csv

# Capture writable layer changes
./containermig.sh \
  --dest-base /opt/redback/stacks \
  --sync-data \
  --include-writable-layer

# Disable generated Docker log caps
./containermig.sh \
  --dest-base /opt/redback/stacks \
  --sync-data \
  --no-log-cap
```
