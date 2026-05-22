#!/usr/bin/env bash
set -Euo pipefail

SCRIPT_NAME="$(basename "$0")"
OUTPUT_DIR="${PWD}/docker-migration-output"
RUN_ID="$(date +%Y-%m-%dT%H-%M-%S)"

DEST_HOST=""
DEST_USER=""
DEST_BASE=""
TRANSFER_METHOD="rsync"

SYNC_DATA=0
INCLUDE_WRITABLE=0
STOP_CONTAINERS=0
VERBOSE=0
CSV_FILE=""

SYNC_COMPOSE_FILES=0
SYNC_BUILD_CONTEXT=0
GENERATE_MIGRATED_COMPOSE=0
FINAL_SYNC=0
FINAL_SYNC_STOP=0
ENABLE_LOG_CAP=1

SSH_KEY=""
SSH_CONTROL_PERSIST="10m"
REPLACE_FILE=""

WRITABLE_EXCLUDE_REGEX='^/(dev|proc|sys|run|tmp|var/run|var/tmp|etc/hosts|/etc/hostname|/etc/resolv\.conf|/.dockerenv)($|/)'
CERT_FILE_REGEX='.*\.(crt|cer|pem|key|p12|pfx|jks|keystore|csr|ca-bundle|der)$'
CERT_PATH_HINT_REGEX='(cert|certs|certificate|certificates|ssl|tls|pki|letsencrypt|truststore|keystore)'
CERT_ENV_HINT_REGEX='(CERT|CERTIFICATE|TLS|SSL|KEY|KEYSTORE|TRUSTSTORE|CA_BUNDLE|CA_CERT|CLIENT_CERT|CLIENT_KEY)'

BUILD_CONTEXT_EXCLUDES=(
  ".git"
  ".svn"
  ".hg"
  "node_modules"
  "__pycache__"
  ".venv"
  "venv"
  ".mypy_cache"
  ".pytest_cache"
  ".cache"
  "dist"
  "build"
  ".idea"
  ".vscode"
)

TEXT_FILE_EXTENSIONS_REGEX='(\.ya?ml|\.json|\.conf|\.cfg|\.ini|\.env|\.properties|\.txt|\.xml|\.sh|\.py|\.js|\.ts|\.md|Dockerfile)$'

declare -A CSV_CONTAINER_INCLUDE_WRITABLE=()
declare -A CSV_CONTAINER_STOP=()
declare -A CSV_SELECTED_CONTAINERS=()
declare -a REPLACEMENTS=()

usage() {
  cat <<EOF
Usage: $SCRIPT_NAME [options]

Core options:
  --dest-host HOST
  --dest-user USER
  --dest-base PATH
  --transfer rsync|scp                Default: rsync
  --sync-data
  --csv FILE
  --verbose

Migration behavior:
  --include-writable-layer
  --stop-containers
  --sync-compose-files
  --sync-build-context
  --generate-migrated-compose
  --final-sync
  --final-sync-stop
  --no-log-cap                        Disable automatic Docker log capping

Text replacement:
  --replace-text OLD=NEW              Repeatable
  --replace-file FILE                 One OLD=NEW pair per line, # comments allowed

SSH:
  --ssh-key PATH
  --ssh-control-persist DURATION      Default: 10m

Output:
  --output-dir PATH                   Default: ./docker-migration-output

Help:
  -h, --help

Destination layout:
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

EOF
}

log() { echo "[INFO] $*"; }
warn() { echo "[WARN] $*" >&2; }
err() { echo "[ERROR] $*" >&2; }
vlog() { [[ "$VERBOSE" -eq 1 ]] && echo "[DEBUG] $*"; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    err "Required command not found: $1"
    exit 1
  }
}

trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  echo "$s"
}

lower() {
  echo "$1" | tr '[:upper:]' '[:lower:]'
}

bool_from_string() {
  local v
  v="$(lower "$(trim "${1:-}")")"
  case "$v" in
    1|true|yes|y|on) echo "1" ;;
    0|false|no|n|off|"") echo "0" ;;
    *) warn "Unrecognised boolean value '$1', treating as false"; echo "0" ;;
  esac
}

safe_name() {
  local s="$1"
  s="${s#/}"
  s="${s//\//_}"
  s="${s//:/_}"
  s="${s// /_}"
  s="${s//[^A-Za-z0-9._-]/_}"
  echo "$s"
}

ssh_target() {
  if [[ -n "$DEST_USER" ]]; then
    echo "${DEST_USER}@${DEST_HOST}"
  else
    echo "${DEST_HOST}"
  fi
}

build_ssh_opts_array() {
  local -n _out="$1"
  _out=(
    -o ControlMaster=auto
    -o "ControlPersist=${SSH_CONTROL_PERSIST}"
    -o "ControlPath=${HOME}/.ssh/cm-%r@%h:%p"
  )
  if [[ -n "$SSH_KEY" ]]; then
    _out+=(
      -i "$SSH_KEY"
      -o IdentitiesOnly=yes
    )
  fi
}

ssh_cmd() {
  local target="$1"
  shift
  local opts=()
  build_ssh_opts_array opts
  ssh -n "${opts[@]}" "$target" "$@"
}

scp_cmd() {
  local src="$1"
  local dst="$2"
  local opts=()
  build_ssh_opts_array opts
  scp "${opts[@]}" "$src" "$dst" < /dev/null
}

rsync_rsh() {
  local opts=()
  build_ssh_opts_array opts
  local cmd="ssh"
  local o
  for o in "${opts[@]}"; do
    cmd+=" $(printf '%q' "$o")"
  done
  echo "$cmd"
}

container_is_running() {
  local c="$1"
  docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null | grep -qi '^true$'
}

container_name() {
  local c="$1"
  docker inspect -f '{{.Name}}' "$c" | sed 's#^/##'
}

container_image() {
  local c="$1"
  docker inspect -f '{{.Config.Image}}' "$c"
}

container_restart_policy() {
  local c="$1"
  docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c"
}

container_network_mode() {
  local c="$1"
  docker inspect -f '{{.HostConfig.NetworkMode}}' "$c"
}

container_ports_json() {
  local c="$1"
  docker inspect "$c" | jq '.[0].HostConfig.PortBindings // {}'
}

container_env_json() {
  local c="$1"
  docker inspect "$c" | jq '.[0].Config.Env // []'
}

container_mounts_json() {
  local c="$1"
  docker inspect "$c" | jq '.[0].Mounts // []'
}

container_compose_project() {
  local c="$1"
  docker inspect "$c" | jq -r '.[0].Config.Labels["com.docker.compose.project"] // empty'
}

container_compose_service() {
  local c="$1"
  docker inspect "$c" | jq -r '.[0].Config.Labels["com.docker.compose.service"] // empty'
}

container_compose_workdir() {
  local c="$1"
  docker inspect "$c" | jq -r '.[0].Config.Labels["com.docker.compose.project.working_dir"] // empty'
}

container_compose_files() {
  local c="$1"
  docker inspect "$c" | jq -r '.[0].Config.Labels["com.docker.compose.project.config_files"] // empty'
}

resolve_container_identifier() {
  local ident="$1"

  if docker inspect "$ident" >/dev/null 2>&1; then
    echo "$ident"
    return 0
  fi

  local found=""
  found="$(docker ps -a --format '{{.ID}} {{.Names}}' | awk -v q="$ident" '$2 == q {print $1; exit}')"
  [[ -n "$found" ]] && { echo "$found"; return 0; }

  return 1
}

project_root_path() {
  local project="$1"
  echo "${DEST_BASE}/${project}"
}

project_data_root() {
  local project="$1"
  echo "${DEST_BASE}/${project}/data"
}

project_migration_root() {
  local project="$1"
  echo "${DEST_BASE}/${project}/migration"
}

container_output_root() {
  local c="$1"
  local cname
  cname="$(container_name "$c")"
  echo "${OUTPUT_DIR}/containers/${cname}/${RUN_ID}"
}

remote_mkdir() {
  local path="$1"
  if [[ -n "$DEST_HOST" ]]; then
    ssh_cmd "$(ssh_target)" "mkdir -p '$path'"
  else
    mkdir -p "$path"
  fi
}

remote_test_exists() {
  local path="$1"
  if [[ -n "$DEST_HOST" ]]; then
    ssh_cmd "$(ssh_target)" "test -e '$path'"
  else
    test -e "$path"
  fi
}

remote_du_bytes() {
  local path="$1"
  if [[ -n "$DEST_HOST" ]]; then
    ssh_cmd "$(ssh_target)" "du -sb '$path' 2>/dev/null | awk '{print \$1}'"
  else
    du -sb "$path" 2>/dev/null | awk '{print $1}'
  fi
}

copy_dir() {
  local src="$1"
  local dst="$2"

  [[ "$SYNC_DATA" -eq 1 ]] || { vlog "Skipping copy (no --sync-data): $src -> $dst"; return 0; }
  [[ -e "$src" ]] || { warn "Source does not exist, skipping copy: $src"; return 0; }

  if [[ -n "$DEST_HOST" ]]; then
    remote_mkdir "$dst"
    log "Copying directory: $src -> $(ssh_target):$dst"
    case "$TRANSFER_METHOD" in
      rsync)
        rsync -aHAX --numeric-ids --info=progress2 -e "$(rsync_rsh)" "$src"/ "$(ssh_target):$dst"/ < /dev/null
        ;;
      scp)
        tar -C "$src" -cf - . | ssh_cmd "$(ssh_target)" "tar -C '$dst' -xf -"
        ;;
      *)
        err "Unsupported transfer method: $TRANSFER_METHOD"
        return 1
        ;;
    esac
  else
    mkdir -p "$dst"
    log "Copying directory locally: $src -> $dst"
    case "$TRANSFER_METHOD" in
      rsync) rsync -aHAX --numeric-ids "$src"/ "$dst"/ ;;
      scp) cp -a "$src"/. "$dst"/ ;;
      *) err "Unsupported transfer method: $TRANSFER_METHOD"; return 1 ;;
    esac
  fi
}

copy_file() {
  local src="$1"
  local dst="$2"

  [[ "$SYNC_DATA" -eq 1 ]] || { vlog "Skipping file copy (no --sync-data): $src -> $dst"; return 0; }
  [[ -e "$src" ]] || { warn "Source file does not exist, skipping copy: $src"; return 0; }

  if [[ -n "$DEST_HOST" ]]; then
    remote_mkdir "$(dirname "$dst")"
    log "Copying file: $src -> $(ssh_target):$dst"
    case "$TRANSFER_METHOD" in
      rsync)
        rsync -aHAX --numeric-ids -e "$(rsync_rsh)" "$src" "$(ssh_target):$dst" < /dev/null
        ;;
      scp)
        scp_cmd "$src" "$(ssh_target):$dst"
        ;;
      *)
        err "Unsupported transfer method: $TRANSFER_METHOD"
        return 1
        ;;
    esac
  else
    mkdir -p "$(dirname "$dst")"
    log "Copying file locally: $src -> $dst"
    cp -a "$src" "$dst"
  fi
}

copy_dir_filtered() {
  local src="$1"
  local dst="$2"

  [[ "$SYNC_DATA" -eq 1 ]] || { vlog "Skipping filtered copy (no --sync-data): $src -> $dst"; return 0; }
  [[ -d "$src" ]] || { warn "Build context directory does not exist, skipping: $src"; return 0; }

  if [[ -n "$DEST_HOST" ]]; then
    remote_mkdir "$dst"
    log "Copying build context: $src -> $(ssh_target):$dst"
    case "$TRANSFER_METHOD" in
      rsync)
        local args=( -aHAX --numeric-ids --info=progress2 )
        local ex
        for ex in "${BUILD_CONTEXT_EXCLUDES[@]}"; do args+=( --exclude "$ex" ); done
        rsync "${args[@]}" -e "$(rsync_rsh)" "$src"/ "$(ssh_target):$dst"/ < /dev/null
        ;;
      scp)
        warn "scp mode does not support excludes; copying whole working directory"
        tar -C "$src" -cf - . | ssh_cmd "$(ssh_target)" "tar -C '$dst' -xf -"
        ;;
      *)
        err "Unsupported transfer method: $TRANSFER_METHOD"
        return 1
        ;;
    esac
  else
    mkdir -p "$dst"
    log "Copying build context locally: $src -> $dst"
    case "$TRANSFER_METHOD" in
      rsync)
        local args=( -aHAX --numeric-ids )
        local ex
        for ex in "${BUILD_CONTEXT_EXCLUDES[@]}"; do args+=( --exclude "$ex" ); done
        rsync "${args[@]}" "$src"/ "$dst"/
        ;;
      scp) cp -a "$src"/. "$dst"/ ;;
      *) err "Unsupported transfer method: $TRANSFER_METHOD"; return 1 ;;
    esac
  fi
}

record_inventory_header() {
  local f="$1"
  cat > "$f" <<EOF
Docker migration inventory
Generated: $(date -Is)
Run ID: $RUN_ID

EOF
}

write_final_sync_report_header() {
  local f="$1"
  cat > "$f" <<EOF
Final sync report
Generated: $(date -Is)
Run ID: $RUN_ID

EOF
}

file_is_probably_text() {
  local f="$1"
  [[ -f "$f" ]] || return 1

  local mime
  mime="$(file -b --mime-type "$f" 2>/dev/null || true)"
  case "$mime" in
    text/*|application/json|application/xml|application/x-yaml|application/javascript|application/x-sh)
      return 0
      ;;
  esac

  local base
  base="$(basename "$f")"
  if [[ "$base" =~ $TEXT_FILE_EXTENSIONS_REGEX ]]; then
    return 0
  fi

  return 1
}

escape_sed_replacement() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

apply_replacements_to_file() {
  local f="$1"
  local report_file="${2:-}"

  [[ "${#REPLACEMENTS[@]}" -gt 0 ]] || return 0
  [[ -f "$f" ]] || return 0
  file_is_probably_text "$f" || return 0

  local before_hash after_hash
  before_hash="$(sha256sum "$f" | awk '{print $1}')"

  local pair old new old_esc new_esc
  for pair in "${REPLACEMENTS[@]}"; do
    old="${pair%%=*}"
    new="${pair#*=}"
    old_esc="$(escape_sed_replacement "$old")"
    new_esc="$(escape_sed_replacement "$new")"
    sed -i "s/${old_esc}/${new_esc}/g" "$f"
  done

  after_hash="$(sha256sum "$f" | awk '{print $1}')"
  if [[ "$before_hash" != "$after_hash" && -n "$report_file" ]]; then
    {
      echo "Text replacements applied:"
      echo "  file: $f"
      local p
      for p in "${REPLACEMENTS[@]}"; do
        echo "  replace: $p"
      done
      echo
    } >> "$report_file"
  fi
}

apply_replacements_to_tree() {
  local dir="$1"
  local report_file="${2:-}"
  [[ "${#REPLACEMENTS[@]}" -gt 0 ]] || return 0
  [[ -d "$dir" ]] || return 0

  while IFS= read -r -d '' f; do
    apply_replacements_to_file "$f" "$report_file"
  done < <(find "$dir" -type f -print0)
}

apply_replacements_remote_file() {
  local remote_path="$1"
  local report_file="${2:-}"

  [[ "${#REPLACEMENTS[@]}" -gt 0 ]] || return 0
  [[ -n "$DEST_HOST" ]] || return 0

  local before after
  before="$(ssh_cmd "$(ssh_target)" "test -f '$remote_path' && sha256sum '$remote_path' | awk '{print \$1}'" 2>/dev/null || true)"
  [[ -n "$before" ]] || return 0

  local script=""
  local pair old new old_esc new_esc
  for pair in "${REPLACEMENTS[@]}"; do
    old="${pair%%=*}"
    new="${pair#*=}"
    old_esc="$(printf '%s' "$old" | sed "s/'/'\\\\''/g")"
    new_esc="$(printf '%s' "$new" | sed "s/'/'\\\\''/g")"
    script+="perl -0pi -e 's/\\Q${old_esc}\\E/${new_esc}/g' '$remote_path'; "
  done

  ssh_cmd "$(ssh_target)" "$script"

  after="$(ssh_cmd "$(ssh_target)" "test -f '$remote_path' && sha256sum '$remote_path' | awk '{print \$1}'" 2>/dev/null || true)"

  if [[ -n "$report_file" && "$before" != "$after" ]]; then
    {
      echo "Remote text replacements applied:"
      echo "  file: $remote_path"
      local p
      for p in "${REPLACEMENTS[@]}"; do
        echo "  replace: $p"
      done
      echo
    } >> "$report_file"
  fi
}

apply_replacements_any_file() {
  local path="$1"
  local report_file="${2:-}"

  if [[ -n "$DEST_HOST" ]]; then
    apply_replacements_remote_file "$path" "$report_file"
  else
    apply_replacements_to_file "$path" "$report_file"
  fi
}

apply_replacements_remote_tree() {
  local remote_dir="$1"
  local report_file="${2:-}"

  [[ "${#REPLACEMENTS[@]}" -gt 0 ]] || return 0
  [[ -n "$DEST_HOST" ]] || return 0

  local files
  files="$(ssh_cmd "$(ssh_target)" "find '$remote_dir' -type f 2>/dev/null" || true)"
  [[ -n "$files" ]] || return 0

  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    case "$f" in
      *.yml|*.yaml|*.json|*.conf|*.cfg|*.ini|*.env|*.properties|*.txt|*.xml|*.sh|*.py|*.js|*.ts|*.md|*/Dockerfile|*Dockerfile)
        apply_replacements_remote_file "$f" "$report_file"
        ;;
    esac
  done <<< "$files"
}

apply_replacements_any_tree() {
  local path="$1"
  local report_file="${2:-}"

  if [[ -n "$DEST_HOST" ]]; then
    apply_replacements_remote_tree "$path" "$report_file"
  else
    apply_replacements_to_tree "$path" "$report_file"
  fi
}

load_replacements_file() {
  [[ -n "$REPLACE_FILE" ]] || return 0
  [[ -f "$REPLACE_FILE" ]] || { err "Replacement file not found: $REPLACE_FILE"; exit 1; }

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    local line
    line="$(echo "$raw_line" | tr -d '\r')"
    line="$(trim "$line")"
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^# ]] && continue
    [[ "$line" == *"="* ]] || { warn "Skipping invalid replacement line (missing '='): $line"; continue; }
    REPLACEMENTS+=("$line")
  done < "$REPLACE_FILE"
}

generate_bind_mount_line_rw() {
  local host_path="$1"
  local container_path="$2"
  local rw="$3"

  if [[ "$rw" == "false" ]]; then
    echo "      - ${host_path}:${container_path}:ro"
  else
    echo "      - ${host_path}:${container_path}"
  fi
}

generate_logging_override_block() {
  cat <<'EOF'
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF
}

render_ports_yaml() {
  local c="$1"
  local ports
  ports="$(container_ports_json "$c")"
  [[ "$ports" == "{}" ]] && return 0

  echo "    ports:"
  echo "$ports" | jq -r '
    to_entries[]
    | .key as $container_port
    | (.value // [])
    | .[]
    | "      - \"" + ((.HostIp // "") | if . == "" then "" else . + ":" end) + (.HostPort // "") + ":" + $container_port + "\""
  '
}

render_env_yaml() {
  local c="$1"
  local envj
  envj="$(container_env_json "$c")"
  [[ "$envj" == "[]" ]] && return 0

  echo "    environment:"
  echo "$envj" | jq -r '.[] | "      - " + .'
}

render_restart_yaml() {
  local c="$1"
  local rp
  rp="$(container_restart_policy "$c")"
  [[ -n "$rp" && "$rp" != "no" ]] && echo "    restart: $rp"
}

render_network_mode_yaml() {
  local c="$1"
  local nm
  nm="$(container_network_mode "$c")"
  [[ -n "$nm" && "$nm" != "default" ]] && echo "    network_mode: $nm"
}

inspect_env_for_cert_hints() {
  local c="$1"
  local cert_report="$2"

  while IFS= read -r envline; do
    [[ -z "$envline" ]] && continue
    local k="${envline%%=*}"
    local v="${envline#*=}"

    if [[ "$k" =~ $CERT_ENV_HINT_REGEX ]] || [[ "$v" =~ $CERT_PATH_HINT_REGEX ]] || [[ "$v" =~ $CERT_FILE_REGEX ]]; then
      {
        echo "Environment hint:"
        echo "  container: $(container_name "$c")"
        echo "  variable: $k"
        echo "  value: $v"
        echo
      } >> "$cert_report"
    fi
  done < <(container_env_json "$c" | jq -r '.[]')
}

inspect_mounts_for_cert_hints() {
  local c="$1"
  local cert_report="$2"

  while IFS= read -r m; do
    local type source dest
    type="$(jq -r '.Type // ""' <<<"$m")"
    source="$(jq -r '.Source // ""' <<<"$m")"
    dest="$(jq -r '.Destination // ""' <<<"$m")"

    if [[ "$source" =~ $CERT_PATH_HINT_REGEX ]] || [[ "$dest" =~ $CERT_PATH_HINT_REGEX ]] || [[ "$source" =~ $CERT_FILE_REGEX ]] || [[ "$dest" =~ $CERT_FILE_REGEX ]]; then
      {
        echo "Mount hint:"
        echo "  container: $(container_name "$c")"
        echo "  type: $type"
        echo "  source: $source"
        echo "  dest: $dest"
        echo
      } >> "$cert_report"
    fi
  done < <(container_mounts_json "$c" | jq -c '.[]')
}

scan_directory_for_cert_files() {
  local dir="$1"
  local cert_report="$2"
  local heading="$3"

  [[ -d "$dir" ]] || return 0

  local found=0
  while IFS= read -r f; do
    if [[ "$found" -eq 0 ]]; then
      echo "$heading" >> "$cert_report"
      found=1
    fi
    echo "  $f" >> "$cert_report"
  done < <(find "$dir" -type f \( \
      -iname '*.crt' -o -iname '*.cer' -o -iname '*.pem' -o -iname '*.key' -o \
      -iname '*.p12' -o -iname '*.pfx' -o -iname '*.jks' -o -iname '*.keystore' -o \
      -iname '*.csr' -o -iname '*.der' \
    \) 2>/dev/null)

  [[ "$found" -eq 1 ]] && echo >> "$cert_report"
}

scan_text_file_for_cert_hints() {
  local file="$1"
  local cert_report="$2"
  local heading="$3"

  [[ -f "$file" ]] || return 0

  local matches
  matches="$(grep -Ein 'cert|certificate|ssl|tls|key|keystore|truststore|letsencrypt|ca_bundle|ca_cert|client_cert|client_key' "$file" 2>/dev/null || true)"
  if [[ -n "$matches" ]]; then
    {
      echo "$heading"
      echo "$matches"
      echo
    } >> "$cert_report"
  fi
}

load_csv_selection() {
  [[ -n "$CSV_FILE" ]] || return 0
  [[ -f "$CSV_FILE" ]] || { err "CSV file not found: $CSV_FILE"; exit 1; }

  log "Loading container selection CSV: $CSV_FILE"

  local requested_count=0
  local matched_count=0
  local line_no=1

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    line_no=$((line_no + 1))
    local line
    line="$(echo "$raw_line" | tr -d '\r')"

    [[ -z "$(trim "$line")" ]] && continue
    [[ "$(trim "$line")" =~ ^# ]] && continue

    requested_count=$((requested_count + 1))

    IFS=',' read -r col1 col2 col3 extra <<< "$line"

    local container include_writable stop_container resolved cname
    container="$(trim "${col1:-}")"
    include_writable="$(trim "${col2:-}")"
    stop_container="$(trim "${col3:-}")"

    [[ -n "$container" ]] || { warn "Skipping CSV line $line_no with empty container field"; continue; }

    if ! resolved="$(resolve_container_identifier "$container")"; then
      warn "Container from CSV not found, skipping: $container"
      continue
    fi

    cname="$(container_name "$resolved")"
    CSV_SELECTED_CONTAINERS["$resolved"]=1
    CSV_SELECTED_CONTAINERS["$cname"]=1
    matched_count=$((matched_count + 1))

    [[ -n "$include_writable" ]] && {
      CSV_CONTAINER_INCLUDE_WRITABLE["$resolved"]="$(bool_from_string "$include_writable")"
      CSV_CONTAINER_INCLUDE_WRITABLE["$cname"]="$(bool_from_string "$include_writable")"
    }

    [[ -n "$stop_container" ]] && {
      CSV_CONTAINER_STOP["$resolved"]="$(bool_from_string "$stop_container")"
      CSV_CONTAINER_STOP["$cname"]="$(bool_from_string "$stop_container")"
    }
  done < <(tail -n +2 "$CSV_FILE")

  log "CSV requested containers: $requested_count"
  log "CSV matched containers: $matched_count"

  [[ "$matched_count" -gt 0 ]] || { err "CSV matched zero containers. Nothing will be processed."; exit 1; }
}

is_container_selected() {
  local c="$1"
  [[ -z "$CSV_FILE" ]] && return 0
  local cname
  cname="$(container_name "$c")"
  [[ -n "${CSV_SELECTED_CONTAINERS[$c]:-}" || -n "${CSV_SELECTED_CONTAINERS[$cname]:-}" ]]
}

container_include_writable() {
  local c="$1"
  local cname
  cname="$(container_name "$c")"

  [[ -n "${CSV_CONTAINER_INCLUDE_WRITABLE[$c]:-}" ]] && { echo "${CSV_CONTAINER_INCLUDE_WRITABLE[$c]}"; return; }
  [[ -n "${CSV_CONTAINER_INCLUDE_WRITABLE[$cname]:-}" ]] && { echo "${CSV_CONTAINER_INCLUDE_WRITABLE[$cname]}"; return; }
  echo "$INCLUDE_WRITABLE"
}

container_should_stop() {
  local c="$1"
  local cname
  cname="$(container_name "$c")"

  [[ -n "${CSV_CONTAINER_STOP[$c]:-}" ]] && { echo "${CSV_CONTAINER_STOP[$c]}"; return; }
  [[ -n "${CSV_CONTAINER_STOP[$cname]:-}" ]] && { echo "${CSV_CONTAINER_STOP[$cname]}"; return; }
  echo "$STOP_CONTAINERS"
}

stop_container_if_requested() {
  local c="$1"
  local stop_flag
  stop_flag="$(container_should_stop "$c")"

  if [[ "$FINAL_SYNC" -eq 1 && "$FINAL_SYNC_STOP" -eq 1 ]]; then
    stop_flag=1
  fi

  if [[ "$stop_flag" -eq 1 ]] && container_is_running "$c"; then
    log "Stopping container for consistent capture: $(container_name "$c")"
    docker stop "$c" >/dev/null
  fi
}

is_subpath_of() {
  local child="$1"
  local parent="$2"

  [[ -n "$child" && -n "$parent" ]] || return 1
  [[ -e "$child" && -e "$parent" ]] || return 1

  local child_real parent_real
  child_real="$(readlink -f -- "$child" 2>/dev/null || true)"
  parent_real="$(readlink -f -- "$parent" 2>/dev/null || true)"

  [[ -n "$child_real" && -n "$parent_real" ]] || return 1

  case "$child_real" in
    "$parent_real"|"$parent_real"/*) return 0 ;;
    *) return 1 ;;
  esac
}

validate_project_destination() {
  local project="$1"
  local report_file="$2"

  local project_root migrated_compose original_compose override_file
  project_root="$(project_root_path "$project")"
  migrated_compose="${project_root}/docker-compose.yml"
  original_compose="${project_root}/docker-compose.orig.yml"
  override_file="${project_root}/migration/docker-compose.migration.override.yml"

  {
    echo "Validation for project: $project"
    echo "  project_root: $project_root"
  } >> "$report_file"

  if remote_test_exists "$project_root"; then
    echo "  project_root_exists: yes" >> "$report_file"
  else
    echo "  project_root_exists: no" >> "$report_file"
  fi

  if remote_test_exists "$original_compose"; then
    echo "  original_compose_exists: yes" >> "$report_file"
  else
    echo "  original_compose_exists: no" >> "$report_file"
  fi

  if [[ "$GENERATE_MIGRATED_COMPOSE" -eq 1 ]]; then
    if remote_test_exists "$migrated_compose"; then
      echo "  migrated_compose_exists: yes" >> "$report_file"
    else
      echo "  migrated_compose_exists: no" >> "$report_file"
    fi
  else
    if remote_test_exists "$override_file"; then
      echo "  override_exists: yes" >> "$report_file"
    else
      echo "  override_exists: no" >> "$report_file"
    fi
  fi

  echo >> "$report_file"
}

validate_mount_copy() {
  local source_path="$1"
  local dest_path="$2"
  local label="$3"
  local report_file="$4"

  local src_bytes dst_bytes
  src_bytes=""
  dst_bytes=""

  if [[ -e "$source_path" ]]; then
    src_bytes="$(du -sb "$source_path" 2>/dev/null | awk '{print $1}')"
  fi
  if remote_test_exists "$dest_path"; then
    dst_bytes="$(remote_du_bytes "$dest_path" || true)"
  fi

  {
    echo "Mount validation:"
    echo "  label: $label"
    echo "  source: $source_path"
    echo "  destination: $dest_path"
    echo "  source_bytes: ${src_bytes:-unknown}"
    echo "  destination_bytes: ${dst_bytes:-missing}"
  } >> "$report_file"

  if [[ -n "$src_bytes" && -n "$dst_bytes" ]]; then
    if [[ "$src_bytes" == "$dst_bytes" ]]; then
      echo "  size_match: yes" >> "$report_file"
    else
      echo "  size_match: no" >> "$report_file"
    fi
  else
    echo "  size_match: unknown" >> "$report_file"
  fi

  echo >> "$report_file"
}

copy_stack_files_for_project() {
  local project="$1"
  local example_container="$2"
  local report_file="$3"
  local cert_report="$4"

  [[ "$SYNC_COMPOSE_FILES" -eq 1 || "$SYNC_BUILD_CONTEXT" -eq 1 ]] || return 0

  local workdir config_files
  workdir="$(container_compose_workdir "$example_container")"
  config_files="$(container_compose_files "$example_container")"

  local project_root
  project_root="$(project_root_path "$project")"

  {
    echo "Stack file sync:"
    echo "  project: $project"
    echo "  working_dir: ${workdir:-unknown}"
    echo "  compose_files: ${config_files:-unknown}"
    echo
  } >> "$report_file"

  if [[ "$SYNC_COMPOSE_FILES" -eq 1 ]]; then
    if [[ -n "$config_files" ]]; then
      IFS=',' read -ra cfarr <<< "$config_files"
      local cf
      for cf in "${cfarr[@]}"; do
        cf="$(trim "$cf")"
        [[ -z "$cf" ]] && continue

        local src_cf="$cf"
        if [[ ! -f "$src_cf" && -n "$workdir" && -f "$workdir/$cf" ]]; then
          src_cf="$workdir/$cf"
        fi

        if [[ -f "$src_cf" ]]; then
          local dst_cf="${project_root}/docker-compose.orig.yml"
          copy_file "$src_cf" "$dst_cf" || warn "Failed copying compose file: $src_cf"
          echo "Copied compose file: $src_cf -> $dst_cf" >> "$report_file"
          scan_text_file_for_cert_hints "$src_cf" "$cert_report" "Compose file security hints: $src_cf"
          apply_replacements_any_file "$dst_cf" "$report_file"
          break
        else
          echo "Compose file not found: $cf" >> "$report_file"
        fi
      done
    fi

    if [[ -n "$workdir" && -f "$workdir/.env" ]]; then
      local dst_env="${project_root}/.env"
      copy_file "$workdir/.env" "$dst_env" || warn "Failed copying env file: $workdir/.env"
      echo "Copied env file: $workdir/.env -> $dst_env" >> "$report_file"
      scan_text_file_for_cert_hints "$workdir/.env" "$cert_report" "Environment file security hints: $workdir/.env"
      apply_replacements_any_file "$dst_env" "$report_file"
    fi
  fi

  if [[ -n "$workdir" && -d "$workdir" ]]; then
    scan_directory_for_cert_files "$workdir" "$cert_report" "Certificate-like files under working dir: $workdir"
  fi

  if [[ "$SYNC_BUILD_CONTEXT" -eq 1 ]]; then
    if [[ -n "$workdir" && -d "$workdir" ]]; then
      copy_dir_filtered "$workdir" "${project_root}/working_dir" || warn "Failed copying working dir: $workdir"
      echo "Copied working directory: $workdir -> ${project_root}/working_dir" >> "$report_file"
      apply_replacements_any_tree "${project_root}/working_dir" "$report_file"
    else
      echo "Working directory unavailable for build-context copy" >> "$report_file"
    fi
  fi
}

capture_mounts_for_container() {
  local c="$1"
  local project_slug="$2"
  local service_slug="$3"
  local report_file="$4"
  local override_file="$5"
  local cert_report="$6"
  local project_workdir="$7"
  local final_sync_report="${8:-}"

  local mounts_json
  mounts_json="$(container_mounts_json "$c")"

  inspect_mounts_for_cert_hints "$c" "$cert_report"

  {
    echo "  - raw mounts json:"
    echo "$mounts_json" | jq .
  } >> "$report_file"

  if [[ "$mounts_json" == "[]" ]]; then
    echo "  - no mounts detected" >> "$report_file"
    return 1
  fi

  local tmp_vols
  tmp_vols="$(mktemp)"
  echo "    volumes:" > "$tmp_vols"

  local data_root
  data_root="$(project_data_root "$project_slug")"

  while IFS= read -r m; do
    local type source dest name rw
    type="$(jq -r '.Type // ""' <<<"$m")"
    source="$(jq -r '.Source // ""' <<<"$m")"
    dest="$(jq -r '.Destination // ""' <<<"$m")"
    name="$(jq -r '.Name // ""' <<<"$m")"
    rw="$(jq -r '.RW' <<<"$m")"

    [[ -n "$dest" ]] || continue

    local mount_slug rel_dir final_host_path
    mount_slug="$(safe_name "$dest")"

    log "Inspecting mount for $(container_name "$c"): type=$type source=$source dest=$dest"

    case "$type" in
      bind)
        if [[ -n "$project_workdir" && "$SYNC_BUILD_CONTEXT" -eq 1 ]] && is_subpath_of "$source" "$project_workdir"; then
          local rel_from_workdir
          if [[ "$source" == "$project_workdir" ]]; then
            rel_from_workdir="."
          else
            rel_from_workdir="${source#"$project_workdir"/}"
          fi

          final_host_path="$(project_root_path "$project_slug")/working_dir/${rel_from_workdir}"

          {
            echo "  - bind mount already covered by working_dir copy:"
            echo "      container: $(container_name "$c")"
            echo "      dest: $dest"
            echo "      source: $source"
            echo "      rw: $rw"
            echo "      migrated_to: $final_host_path"
          } >> "$report_file"

          generate_bind_mount_line_rw "$final_host_path" "$dest" "$rw" >> "$tmp_vols"

          if [[ "$FINAL_SYNC" -eq 1 && -n "$final_sync_report" ]]; then
            validate_mount_copy "$source" "$final_host_path" "bind-covered:${dest}" "$final_sync_report"
          fi
        else
          rel_dir="${data_root}/${service_slug}/binds/${mount_slug}"

          if [[ -d "$source" ]]; then
            final_host_path="$rel_dir"
            {
              echo "  - bind mount (directory):"
              echo "      container: $(container_name "$c")"
              echo "      dest: $dest"
              echo "      source: $source"
              echo "      rw: $rw"
              echo "      migrated_to: $final_host_path"
            } >> "$report_file"

            copy_dir "$source" "$final_host_path" || warn "Failed copying bind directory: $source"
            generate_bind_mount_line_rw "$final_host_path" "$dest" "$rw" >> "$tmp_vols"

            if [[ "$FINAL_SYNC" -eq 1 && -n "$final_sync_report" ]]; then
              validate_mount_copy "$source" "$final_host_path" "bind:${dest}" "$final_sync_report"
            fi
          elif [[ -f "$source" ]]; then
            final_host_path="${rel_dir}/$(basename "$source")"
            {
              echo "  - bind mount (file):"
              echo "      container: $(container_name "$c")"
              echo "      dest: $dest"
              echo "      source: $source"
              echo "      rw: $rw"
              echo "      migrated_to: $final_host_path"
            } >> "$report_file"

            copy_file "$source" "$final_host_path" || warn "Failed copying bind file: $source"
            generate_bind_mount_line_rw "$final_host_path" "$dest" "$rw" >> "$tmp_vols"

            if [[ "$FINAL_SYNC" -eq 1 && -n "$final_sync_report" ]]; then
              validate_mount_copy "$source" "$final_host_path" "bind-file:${dest}" "$final_sync_report"
            fi
          else
            {
              echo "  - bind mount (missing source):"
              echo "      container: $(container_name "$c")"
              echo "      dest: $dest"
              echo "      source: $source"
              echo "      rw: $rw"
              echo "      action: left unchanged because source path was not found"
            } >> "$report_file"

            generate_bind_mount_line_rw "$source" "$dest" "$rw" >> "$tmp_vols"
          fi
        fi
        ;;

      volume)
        rel_dir="${data_root}/${service_slug}/volumes/${mount_slug}"

        if [[ -d "$source" ]]; then
          final_host_path="$rel_dir"
          {
            echo "  - docker volume:"
            echo "      container: $(container_name "$c")"
            echo "      dest: $dest"
            echo "      volume_name: $name"
            echo "      source: $source"
            echo "      rw: $rw"
            echo "      migrated_to: $final_host_path"
          } >> "$report_file"

          copy_dir "$source" "$final_host_path" || warn "Failed copying volume directory: $source"
          generate_bind_mount_line_rw "$final_host_path" "$dest" "$rw" >> "$tmp_vols"

          if [[ "$FINAL_SYNC" -eq 1 && -n "$final_sync_report" ]]; then
            validate_mount_copy "$source" "$final_host_path" "volume:${name:-$dest}" "$final_sync_report"
          fi
        elif [[ -f "$source" ]]; then
          final_host_path="${rel_dir}/$(basename "$source")"
          {
            echo "  - docker volume (file):"
            echo "      container: $(container_name "$c")"
            echo "      dest: $dest"
            echo "      volume_name: $name"
            echo "      source: $source"
            echo "      rw: $rw"
            echo "      migrated_to: $final_host_path"
          } >> "$report_file"

          copy_file "$source" "$final_host_path" || warn "Failed copying volume file: $source"
          generate_bind_mount_line_rw "$final_host_path" "$dest" "$rw" >> "$tmp_vols"

          if [[ "$FINAL_SYNC" -eq 1 && -n "$final_sync_report" ]]; then
            validate_mount_copy "$source" "$final_host_path" "volume-file:${name:-$dest}" "$final_sync_report"
          fi
        else
          {
            echo "  - volume source missing:"
            echo "      container: $(container_name "$c")"
            echo "      dest: $dest"
            echo "      volume_name: $name"
            echo "      source: $source"
            echo "      action: not copied because source path was not found"
          } >> "$report_file"
        fi
        ;;

      tmpfs)
        {
          echo "  - tmpfs mount:"
          echo "      container: $(container_name "$c")"
          echo "      dest: $dest"
          echo "      action: skipped"
        } >> "$report_file"
        ;;

      *)
        {
          echo "  - other mount:"
          echo "      container: $(container_name "$c")"
          echo "      type: $type"
          echo "      dest: $dest"
          echo "      source: $source"
          echo "      action: reported only"
        } >> "$report_file"
        ;;
    esac
  done < <(echo "$mounts_json" | jq -c '.[]')

  if grep -qE '^[[:space:]]+- ' "$tmp_vols"; then
    cat "$tmp_vols" >> "$override_file"
    rm -f "$tmp_vols"
    return 0
  else
    rm -f "$tmp_vols"
    return 1
  fi
}

capture_writable_layer() {
  local c="$1"
  local project_slug="$2"
  local service_slug="$3"
  local report_file="$4"
  local override_file="$5"
  local final_sync_report="${6:-}"

  local include_writable
  include_writable="$(container_include_writable "$c")"
  [[ "$include_writable" -eq 1 ]] || return 1

  local cname
  cname="$(container_name "$c")"

  local diff_lines
  diff_lines="$(docker diff "$c" || true)"

  if [[ -z "$diff_lines" ]]; then
    echo "  - writable-layer: no changed files detected" >> "$report_file"
    return 1
  fi

  local data_root
  data_root="$(project_data_root "$project_slug")"

  local tmp_writable
  tmp_writable="$(mktemp)"
  echo "    volumes:" > "$tmp_writable"

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue

    local action path
    action="$(awk '{print $1}' <<< "$line")"
    path="$(cut -d' ' -f2- <<< "$line")"

    [[ -n "${path:-}" ]] || continue
    [[ "$action" == "D" ]] && continue

    if [[ "$path" =~ $WRITABLE_EXCLUDE_REGEX ]]; then
      continue
    fi

    case "$path" in
      /var/log/*|/var/cache/*|/root/.cache/*|/tmp/*|/run/*) continue ;;
    esac

    local item_slug rel_dir local_stage_parent final_host_path staged_item
    item_slug="$(safe_name "$path")"
    rel_dir="${data_root}/${service_slug}/writable/${item_slug}"
    local_stage_parent="${OUTPUT_DIR}/staging/${project_slug}/${service_slug}/writable"
    final_host_path="$rel_dir"
    staged_item="${local_stage_parent}/$(basename "$path")"

    mkdir -p "$local_stage_parent"

    if docker cp "${c}:${path}" "$local_stage_parent/" >/dev/null 2>&1; then
      {
        echo "  - writable-layer:"
        echo "      container: $cname"
        echo "      path: $path"
        echo "      recovered_to: $final_host_path"
      } >> "$report_file"

      if [[ -d "$staged_item" ]]; then
        copy_dir "$staged_item" "$final_host_path" || warn "Failed copying writable dir: $staged_item"
      elif [[ -f "$staged_item" ]]; then
        copy_file "$staged_item" "$final_host_path" || warn "Failed copying writable file: $staged_item"
      fi

      echo "      - ${final_host_path}:${path}" >> "$tmp_writable"

      if [[ "$FINAL_SYNC" -eq 1 && -n "$final_sync_report" ]]; then
        validate_mount_copy "$staged_item" "$final_host_path" "writable:${path}" "$final_sync_report"
      fi
    else
      {
        echo "  - writable-layer-skip:"
        echo "      container: $cname"
        echo "      path: $path"
        echo "      reason: docker cp failed"
      } >> "$report_file"
    fi
  done < <(printf '%s\n' "$diff_lines")

  if grep -qE '^[[:space:]]+- ' "$tmp_writable"; then
    cat "$tmp_writable" >> "$override_file"
    rm -f "$tmp_writable"
    return 0
  else
    rm -f "$tmp_writable"
    return 1
  fi
}

service_has_logging_in_compose() {
  local compose_file="$1"
  local service="$2"

  [[ -f "$compose_file" ]] || return 1

  python3 - "$compose_file" "$service" <<'PY' >/dev/null 2>&1
import sys, yaml
compose_file = sys.argv[1]
service = sys.argv[2]
with open(compose_file, "r", encoding="utf-8") as f:
    data = yaml.safe_load(f) or {}
svc = ((data.get("services") or {}).get(service) or {})
sys.exit(0 if "logging" in svc else 1)
PY
}

generate_compose_override_for_service() {
  local c="$1"
  local project="$2"
  local service="$3"
  local report_file="$4"
  local override_file="$5"
  local cert_report="$6"
  local project_workdir="$7"
  local final_sync_report="${8:-}"
  local source_compose_for_logging="${9:-}"

  local tmp_service_file
  tmp_service_file="$(mktemp)"

  cat > "$tmp_service_file" <<EOF
  ${service}:
EOF

  capture_mounts_for_container "$c" "$project" "$service" "$report_file" "$tmp_service_file" "$cert_report" "$project_workdir" "$final_sync_report" || true
  capture_writable_layer "$c" "$project" "$service" "$report_file" "$tmp_service_file" "$final_sync_report" || true

  if [[ "$ENABLE_LOG_CAP" -eq 1 ]]; then
    if ! service_has_logging_in_compose "$source_compose_for_logging" "$service"; then
      generate_logging_override_block >> "$tmp_service_file"
      {
        echo "Docker log cap applied:"
        echo "  service: $service"
        echo "  max-size: 10m"
        echo "  max-file: 3"
        echo
      } >> "$report_file"
    else
      {
        echo "Docker log cap skipped because logging already defined:"
        echo "  service: $service"
        echo
      } >> "$report_file"
    fi
  fi

  if grep -qE '^[[:space:]]+(volumes:|logging:)' "$tmp_service_file"; then
    cat "$tmp_service_file" >> "$override_file"
  else
    vlog "No override content for service '$service'; skipping empty block"
  fi

  rm -f "$tmp_service_file"
}

copy_project_migration_artifacts() {
  local project="$1"
  local report_file="$2"
  local cert_report="$3"
  local override_file="$4"

  local mig_root
  mig_root="$(project_migration_root "$project")"

  copy_file "$report_file" "${mig_root}/report.txt" || true
  copy_file "$cert_report" "${mig_root}/certificates-report.txt" || true
  copy_file "$override_file" "${mig_root}/docker-compose.migration.override.yml" || true
}

copy_final_sync_report() {
  local project="$1"
  local local_report="$2"
  local dest_report
  dest_report="$(project_migration_root "$project")/final-sync-report.txt"
  copy_file "$local_report" "$dest_report" || true
}

generate_migrated_compose_file() {
  local project="$1"
  local example_container="$2"
  local override_file="$3"
  local report_file="$4"

  [[ "$GENERATE_MIGRATED_COMPOSE" -eq 1 ]] || return 0

  local config_files workdir project_root migrated_compose src_compose
  config_files="$(container_compose_files "$example_container")"
  workdir="$(container_compose_workdir "$example_container")"
  project_root="$(project_root_path "$project")"
  migrated_compose="${project_root}/docker-compose.yml"

  src_compose=""
  if [[ -f "${project_root}/docker-compose.orig.yml" ]]; then
    src_compose="${project_root}/docker-compose.orig.yml"
  elif [[ -n "$config_files" ]]; then
    IFS=',' read -ra cfarr <<< "$config_files"
    local cf
    for cf in "${cfarr[@]}"; do
      cf="$(trim "$cf")"
      [[ -z "$cf" ]] && continue

      if [[ -f "$cf" ]]; then
        src_compose="$cf"
        break
      elif [[ -n "$workdir" && -f "$workdir/$cf" ]]; then
        src_compose="$workdir/$cf"
        break
      fi
    done
  fi

  if [[ -z "$src_compose" || ! -f "$src_compose" ]]; then
    err "Could not locate source compose file for project '$project'"
    echo "Migrated compose generation failed: source compose file not found" >> "$report_file"
    return 1
  fi

  if [[ ! -f "$override_file" ]]; then
    err "Override file missing for project '$project'"
    echo "Migrated compose generation failed: override file not found" >> "$report_file"
    return 1
  fi

  python3 - <<'PY' >/dev/null 2>&1
import yaml
PY
  if [[ $? -ne 0 ]]; then
    err "PyYAML is required for --generate-migrated-compose. Install with: apt-get install -y python3-yaml"
    echo "Migrated compose generation failed: PyYAML missing" >> "$report_file"
    return 1
  fi

  remote_mkdir "$project_root"

  local tmp_py local_out
  tmp_py="$(mktemp)"
  local_out="${OUTPUT_DIR}/projects/${project}/docker-compose.yml"
  mkdir -p "$(dirname "$local_out")"

  cat > "$tmp_py" <<'PY'
import sys
from pathlib import Path
import yaml

src_compose = Path(sys.argv[1])
override_file = Path(sys.argv[2])
out_file = Path(sys.argv[3])

with src_compose.open("r", encoding="utf-8") as f:
    base = yaml.safe_load(f) or {}

with override_file.open("r", encoding="utf-8") as f:
    override = yaml.safe_load(f) or {}

base_services = base.get("services", {}) or {}
override_services = override.get("services", {}) or {}
named_volumes_to_prune = set()

def is_named_volume_ref(vol_entry):
    if not isinstance(vol_entry, str):
        return None
    parts = vol_entry.split(":")
    if not parts:
        return None
    lhs = parts[0]
    if lhs.startswith("/") or lhs.startswith("./") or lhs.startswith("../") or lhs.startswith("~"):
        return None
    return lhs

for svc_name, ov_svc in override_services.items():
    if svc_name not in base_services:
        base_services[svc_name] = {}
    base_svc = base_services[svc_name]

    if "volumes" in ov_svc:
        for old_vol in base_svc.get("volumes", []) or []:
            named = is_named_volume_ref(old_vol)
            if named:
                named_volumes_to_prune.add(named)
        base_svc["volumes"] = ov_svc["volumes"]

    for key, value in ov_svc.items():
        if key == "volumes":
            continue
        base_svc[key] = value

base["services"] = base_services
top_vols = base.get("volumes", {}) or {}

still_referenced = set()
for svc in base_services.values():
    for vol in svc.get("volumes", []) or []:
        named = is_named_volume_ref(vol)
        if named:
            still_referenced.add(named)

for v in list(named_volumes_to_prune):
    if v not in still_referenced and v in top_vols:
        del top_vols[v]

if top_vols:
    base["volumes"] = top_vols
elif "volumes" in base:
    del base["volumes"]

with out_file.open("w", encoding="utf-8") as f:
    yaml.safe_dump(base, f, sort_keys=False, default_flow_style=False)
PY

  python3 "$tmp_py" "$src_compose" "$override_file" "$local_out"
  local rc=$?
  rm -f "$tmp_py"

  if [[ $rc -ne 0 || ! -f "$local_out" ]]; then
    err "Failed generating merged docker-compose.yml for project '$project'"
    echo "Migrated compose generation failed for project '$project'" >> "$report_file"
    return 1
  fi

  copy_file "$local_out" "$migrated_compose"
  if [[ $? -ne 0 ]]; then
    err "Failed copying merged docker-compose.yml to destination for project '$project'"
    echo "Migrated compose copy failed for project '$project'" >> "$report_file"
    return 1
  fi

  if ! remote_test_exists "$migrated_compose"; then
    err "Merged docker-compose.yml not found on destination for project '$project'"
    echo "Migrated compose missing on destination for project '$project'" >> "$report_file"
    return 1
  fi

  echo "Generated migrated compose: $local_out -> $migrated_compose" >> "$report_file"
  log "Generated merged docker-compose.yml: $migrated_compose"
  return 0
}

write_container_metadata() {
  local c="$1"
  local project="$2"
  local service="$3"
  local image="$4"
  local workdir="$5"
  local config_files="$6"
  local out_file="$7"

  cat > "$out_file" <<EOF
run_id=$RUN_ID
timestamp=$(date -Is)
container=$(container_name "$c")
project=$project
service=$service
image=$image
workdir=$workdir
compose_files=$config_files
include_writable_layer=$(container_include_writable "$c")
stop_container=$(container_should_stop "$c")
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dest-host) DEST_HOST="$2"; shift 2 ;;
      --dest-user) DEST_USER="$2"; shift 2 ;;
      --dest-base) DEST_BASE="$2"; shift 2 ;;
      --transfer) TRANSFER_METHOD="$2"; shift 2 ;;
      --sync-data) SYNC_DATA=1; shift ;;
      --include-writable-layer) INCLUDE_WRITABLE=1; shift ;;
      --stop-containers) STOP_CONTAINERS=1; shift ;;
      --csv) CSV_FILE="$2"; shift 2 ;;
      --sync-compose-files) SYNC_COMPOSE_FILES=1; shift ;;
      --sync-build-context) SYNC_BUILD_CONTEXT=1; shift ;;
      --generate-migrated-compose) GENERATE_MIGRATED_COMPOSE=1; shift ;;
      --final-sync) FINAL_SYNC=1; shift ;;
      --final-sync-stop) FINAL_SYNC_STOP=1; shift ;;
      --no-log-cap) ENABLE_LOG_CAP=0; shift ;;
      --ssh-key) SSH_KEY="$2"; shift 2 ;;
      --ssh-control-persist) SSH_CONTROL_PERSIST="$2"; shift 2 ;;
      --replace-text) REPLACEMENTS+=("$2"); shift 2 ;;
      --replace-file) REPLACE_FILE="$2"; shift 2 ;;
      --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
      --verbose) VERBOSE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) err "Unknown argument: $1"; usage; exit 1 ;;
    esac
  done

  [[ -n "$DEST_BASE" ]] || { err "--dest-base is required"; exit 1; }

  if [[ -n "$DEST_HOST" ]]; then
    require_cmd ssh
    case "$TRANSFER_METHOD" in
      rsync) require_cmd rsync ;;
      scp) require_cmd scp ;;
      *) err "Invalid --transfer value: $TRANSFER_METHOD"; exit 1 ;;
    esac
  fi

  load_replacements_file

  local pair
  for pair in "${REPLACEMENTS[@]}"; do
    [[ "$pair" == *"="* ]] || { err "Invalid --replace-text value, expected OLD=NEW: $pair"; exit 1; }
  done

  if [[ "$SYNC_COMPOSE_FILES" -eq 1 && "$GENERATE_MIGRATED_COMPOSE" -eq 0 ]]; then
    log "Enabling --generate-migrated-compose automatically (because --sync-compose-files is set)"
    GENERATE_MIGRATED_COMPOSE=1
  fi

  if [[ "$SYNC_COMPOSE_FILES" -eq 0 && "$GENERATE_MIGRATED_COMPOSE" -eq 0 ]]; then
    warn "Compose files will NOT be merged. Only docker-compose.orig.yml and migration override will be created."
  fi
}

main() {
  parse_args "$@"

  require_cmd docker
  require_cmd jq
  require_cmd find
  require_cmd grep
  require_cmd awk
  require_cmd readlink
  require_cmd python3
  require_cmd file
  require_cmd sed
  require_cmd sha256sum
  if [[ "${#REPLACEMENTS[@]}" -gt 0 && -n "$DEST_HOST" ]]; then
    require_cmd perl
  fi

  mkdir -p "$OUTPUT_DIR" "$OUTPUT_DIR/staging" "$OUTPUT_DIR/projects" "$OUTPUT_DIR/standalone" "$OUTPUT_DIR/containers"

  load_csv_selection

  local inventory_file="${OUTPUT_DIR}/migration-inventory.txt"
  record_inventory_header "$inventory_file"

  if [[ "${#REPLACEMENTS[@]}" -gt 0 ]]; then
    {
      echo "Text replacements:"
      local rp
      for rp in "${REPLACEMENTS[@]}"; do
        echo "  $rp"
      done
      echo
    } >> "$inventory_file"
  fi

  {
    echo "Docker log cap enabled: $ENABLE_LOG_CAP"
    if [[ "$ENABLE_LOG_CAP" -eq 1 ]]; then
      echo "Docker log cap policy: max-size=10m, max-file=3"
    fi
    echo
  } >> "$inventory_file"

  local all_containers
  mapfile -t all_containers < <(docker ps -a --format '{{.ID}}')
  [[ "${#all_containers[@]}" -gt 0 ]] || { warn "No containers found."; exit 0; }

  declare -A PROJECT_CONTAINERS=()
  declare -A PROJECT_FIRST_CONTAINER=()
  declare -A PROJECT_WORKDIR=()
  declare -A PROJECT_SOURCE_COMPOSE=()
  declare -a STANDALONE_CONTAINERS=()
  local selected_count=0

  local c
  for c in "${all_containers[@]}"; do
    if ! is_container_selected "$c"; then
      continue
    fi

    selected_count=$((selected_count + 1))

    local project
    project="$(container_compose_project "$c")"
    if [[ -n "$project" ]]; then
      PROJECT_CONTAINERS["$project"]+="${c} "
      [[ -z "${PROJECT_FIRST_CONTAINER[$project]:-}" ]] && PROJECT_FIRST_CONTAINER["$project"]="$c"
      [[ -z "${PROJECT_WORKDIR[$project]:-}" ]] && PROJECT_WORKDIR["$project"]="$(container_compose_workdir "$c")"
    else
      STANDALONE_CONTAINERS+=("$c")
    fi
  done

  {
    echo "Run ID: $RUN_ID"
    echo "Destination base: $DEST_BASE"
    echo "Destination host: ${DEST_HOST:-local only}"
    echo "Destination user: ${DEST_USER:-default ssh user}"
    echo "Transfer method: $TRANSFER_METHOD"
    echo "Sync enabled: $SYNC_DATA"
    echo "Global include writable layer: $INCLUDE_WRITABLE"
    echo "Global stop containers: $STOP_CONTAINERS"
    echo "Sync compose files: $SYNC_COMPOSE_FILES"
    echo "Sync build context: $SYNC_BUILD_CONTEXT"
    echo "Generate migrated compose: $GENERATE_MIGRATED_COMPOSE"
    echo "Final sync: $FINAL_SYNC"
    echo "Final sync stop: $FINAL_SYNC_STOP"
    echo "Docker log cap enabled: $ENABLE_LOG_CAP"
    echo "SSH key: ${SSH_KEY:-default ssh identity}"
    echo "CSV filter: ${CSV_FILE:-none}"
    echo "Selected containers: $selected_count"
    echo
  } >> "$inventory_file"

  [[ "$selected_count" -gt 0 ]] || { err "Zero containers selected for processing."; exit 1; }

  log "Containers selected for processing: $selected_count"
  log "Processing compose projects..."

  local project
  for project in "${!PROJECT_CONTAINERS[@]}"; do
    local project_dir report_file override_file cert_report final_sync_report local_merged_compose project_root
    project_dir="${OUTPUT_DIR}/projects/${project}"
    report_file="${project_dir}/report.txt"
    override_file="${project_dir}/docker-compose.migration.override.yml"
    cert_report="${project_dir}/certificates-report.txt"
    final_sync_report="${project_dir}/final-sync-report.txt"
    local_merged_compose="${project_dir}/docker-compose.yml"
    project_root="$(project_root_path "$project")"

    mkdir -p "$project_dir"
    record_inventory_header "$report_file"
    : > "$cert_report"
    cat > "$override_file" <<'EOF'
services:
EOF

    PROJECT_SOURCE_COMPOSE["$project"]="${project_root}/docker-compose.orig.yml"

    if [[ "$FINAL_SYNC" -eq 1 ]]; then
      write_final_sync_report_header "$final_sync_report"
      validate_project_destination "$project" "$final_sync_report"
    fi

    {
      echo "Compose project: $project"
      echo
    } >> "$report_file"

    copy_stack_files_for_project "$project" "${PROJECT_FIRST_CONTAINER[$project]}" "$report_file" "$cert_report" || warn "Stack file copy encountered issues for project: $project"

    declare -A PROJECT_SEEN_SERVICES=()

    local pc
    for pc in ${PROJECT_CONTAINERS["$project"]}; do
      local cname service workdir config_files image
      cname="$(container_name "$pc")"
      service="$(container_compose_service "$pc")"
      workdir="$(container_compose_workdir "$pc")"
      config_files="$(container_compose_files "$pc")"
      image="$(container_image "$pc")"

      local service_key="${service:-$cname}"
      if [[ -n "${PROJECT_SEEN_SERVICES[$service_key]:-}" ]]; then
        warn "Skipping duplicate service entry in override for project '$project': $service_key"
        continue
      fi
      PROJECT_SEEN_SERVICES["$service_key"]=1

      local container_dir container_report container_cert_report container_final_sync_report container_meta
      container_dir="$(container_output_root "$pc")"
      mkdir -p "$container_dir"

      container_report="${container_dir}/report.txt"
      container_cert_report="${container_dir}/certificates-report.txt"
      container_final_sync_report="${container_dir}/final-sync-report.txt"
      container_meta="${container_dir}/metadata.txt"

      record_inventory_header "$container_report"
      : > "$container_cert_report"
      if [[ "$FINAL_SYNC" -eq 1 ]]; then
        write_final_sync_report_header "$container_final_sync_report"
      fi

      {
        echo "Container: $cname"
        echo "  project: $project"
        echo "  service: $service_key"
        echo "  image: $image"
        echo "  workdir: ${workdir:-unknown}"
        echo "  compose_files: ${config_files:-unknown}"
        echo "  include_writable_layer: $(container_include_writable "$pc")"
        echo "  stop_container: $(container_should_stop "$pc")"
        echo "  timestamp: $(date -Is)"
      } >> "$container_report"

      write_container_metadata "$pc" "$project" "$service_key" "$image" "${workdir:-unknown}" "${config_files:-unknown}" "$container_meta"

      inspect_env_for_cert_hints "$pc" "$container_cert_report"
      inspect_mounts_for_cert_hints "$pc" "$container_cert_report"

      stop_container_if_requested "$pc"
      generate_compose_override_for_service \
        "$pc" \
        "$project" \
        "$service_key" \
        "$container_report" \
        "$override_file" \
        "$container_cert_report" \
        "${PROJECT_WORKDIR[$project]:-}" \
        "$container_final_sync_report" \
        "${PROJECT_SOURCE_COMPOSE[$project]}"

      echo >> "$container_report"
    done

    copy_project_migration_artifacts "$project" "$report_file" "$cert_report" "$override_file"

    if [[ "$GENERATE_MIGRATED_COMPOSE" -eq 1 ]]; then
      generate_migrated_compose_file "$project" "${PROJECT_FIRST_CONTAINER[$project]}" "$override_file" "$report_file"
    fi

    if [[ "$FINAL_SYNC" -eq 1 ]]; then
      validate_project_destination "$project" "$final_sync_report"
      copy_final_sync_report "$project" "$final_sync_report"
    fi

    for pc in ${PROJECT_CONTAINERS["$project"]}; do
      local cdir
      cdir="$(container_output_root "$pc")"
      copy_file "$override_file" "${cdir}/docker-compose.migration.override.yml" || true
      [[ -f "$local_merged_compose" ]] && copy_file "$local_merged_compose" "${cdir}/docker-compose.yml" || true
      if [[ "$FINAL_SYNC" -eq 1 && -f "$final_sync_report" ]]; then
        copy_file "$final_sync_report" "${cdir}/project-final-sync-report.txt" || true
      fi
    done

    log "Wrote project report: $report_file"
    log "Wrote certificates report: $cert_report"
    log "Wrote compose override: $override_file"
    [[ "$GENERATE_MIGRATED_COMPOSE" -eq 1 ]] && log "Generated merged docker-compose.yml for project: $project"
    [[ "$FINAL_SYNC" -eq 1 ]] && log "Generated final sync report for project: $project"
  done

  log "Processing standalone containers..."
  for c in "${STANDALONE_CONTAINERS[@]}"; do
    local cname standalone_report cert_report compose_file container_dir
    cname="$(container_name "$c")"
    standalone_report="${OUTPUT_DIR}/standalone/${cname}/report.txt"
    cert_report="${OUTPUT_DIR}/standalone/${cname}/certificates-report.txt"
    compose_file="${OUTPUT_DIR}/standalone/${cname}/compose.generated.yml"
    container_dir="$(container_output_root "$c")"

    mkdir -p "${OUTPUT_DIR}/standalone/${cname}" "$container_dir"
    record_inventory_header "$standalone_report"
    : > "$cert_report"

    {
      echo "Standalone container: $cname"
      echo "Image: $(container_image "$c")"
      echo "include_writable_layer: $(container_include_writable "$c")"
      echo "stop_container: $(container_should_stop "$c")"
      echo "timestamp: $(date -Is)"
    } >> "$standalone_report"

    write_container_metadata "$c" "standalone" "standalone" "$(container_image "$c")" "n/a" "n/a" "${container_dir}/metadata.txt"

    stop_container_if_requested "$c"

    cat > "$compose_file" <<EOF
services:
  ${cname}:
    image: $(container_image "$c")
EOF
    render_restart_yaml "$c" >> "$compose_file" || true
    render_network_mode_yaml "$c" >> "$compose_file" || true
    render_env_yaml "$c" >> "$compose_file" || true
    render_ports_yaml "$c" >> "$compose_file" || true
    if [[ "$ENABLE_LOG_CAP" -eq 1 ]]; then
      generate_logging_override_block >> "$compose_file"
    fi

    inspect_env_for_cert_hints "$c" "$cert_report"
    inspect_mounts_for_cert_hints "$c" "$cert_report"

    copy_file "$compose_file" "${DEST_BASE}/standalone/${cname}/compose.generated.yml" || true
    copy_file "$standalone_report" "${DEST_BASE}/standalone/${cname}/report.txt" || true
    copy_file "$cert_report" "${DEST_BASE}/standalone/${cname}/certificates-report.txt" || true

    copy_file "$standalone_report" "${container_dir}/report.txt" || true
    copy_file "$cert_report" "${container_dir}/certificates-report.txt" || true
    copy_file "$compose_file" "${container_dir}/compose.generated.yml" || true

    log "Wrote standalone output for: $cname"
  done

  cat <<EOF

Done.

Destination project layout:
  ${DEST_BASE}/<project>/
    docker-compose.orig.yml   # preserved original, with requested text replacements applied
    docker-compose.yml        # merged migrated compose
    .env
    working_dir/
    migration/
    data/

Per-container review output:
  ${OUTPUT_DIR}/containers/<container>/${RUN_ID}/

Project compose artifacts:
  ${OUTPUT_DIR}/projects/<project>/

EOF
}

main "$@"
