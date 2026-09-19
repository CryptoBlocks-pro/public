#!/bin/bash
set -euo pipefail

###############################################################################
# Cardano Node Upgrade Script (multi-network, multi-version, multi-arch)
#
# Upgrades a Guild Operators (Koios/CNTools) managed cardano-node.
# Handles:
#   - Automatic latest version detection from GitHub
#   - Multi-architecture support (x86_64 / aarch64)
#   - System dependency installation
#   - Config/binary/DB backup
#   - Existing instance configuration preserved by default
#   - Optional official config/genesis refresh for schema-breaking upgrades
#   - Binary swap and service restart
#
# Usage:
#   ./upgrade-cardano-node.sh [--network mainnet|preprod|preview] [--version X.Y.Z] [--relay|--bp] [--dry-run]
#   ./upgrade-cardano-node.sh --relay                  # auto-detect latest
#   ./upgrade-cardano-node.sh --network preview --bp
#   ./upgrade-cardano-node.sh --network preprod --version 11.1.2 --bp
#   ./upgrade-cardano-node.sh --network mainnet --node-home /opt/cardano/lgc --version 11.1.2 --bp --dry-run
#   ./upgrade-cardano-node.sh --version 12.0.0 --relay --fresh-db
#   ./upgrade-cardano-node.sh --relay --url https://... --version 10.7.1
#
# Flags:
#   --network      Network profile: mainnet, preprod, or preview (default: mainnet)
#   --node-home    Custom Guild instance home; network still controls chain semantics
#   --service      Custom instance service override (default: <node-home basename>.service)
#   --binary-dir   Explicit custom target directory when version-path inference is ambiguous
#   --version      Target version (default: latest GitHub release)
#   --url          Custom binary download URL (overrides auto-detected URL)
#   --relay        Explicit relay role (one of --relay/--bp is required)
#   --bp           Block producer config (skip OpenBlockPerf traces)
#   --keep-config  Preserve config except Praos/P2P/BP privacy normalization (default)
#   --topology-backup PATH Explicit paired backup topology after reviewing peer changes
#   --refresh-config Download current official config/genesis files and apply local metrics
#   --fresh-db     Backup DB and deploy fresh Mithril snapshot (use for DB-breaking upgrades)
#   --ledger-backend V2InMemory|V2LSM (block producers require V2InMemory)
#   --yes          Accept recommended defaults without prompting
#   --dry-run      Stage/validate in scratch; no live changes (downloads may occur)
#
# Prerequisites:
#   - Run as the node's service user (e.g. stakeman)
#   - sudo access for systemctl and apt-get
#   - curl, python3, jq, flock, GNU coreutils and systemd available
#   - Companion upgrade-cardano-config.py beside this script
#
# Historical binary upgrades: 10.6.2 -> 10.7.1 -> 11.0.1 (Ubuntu 24.04)
# Praos planner: synthetic tests only; see upgrade-cardano-node-notes.md before rollout
###############################################################################

# --- Configuration -----------------------------------------------------------
BIN_DIR="${HOME}/.local/bin"
STAGED_BIN_DIR="${HOME}/tmp/bin"
BACKUP_BIN_DIR="${HOME}/tmp/backup-bin"

GITHUB_REPO="IntersectMBO/cardano-node"
GITHUB_API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

NETWORK="mainnet"
CNODE_HOME=""
FILES_DIR=""
DB_DIR=""
SERVICE_NAME=""
ENV_FILE=""
CONFIG_BASE_URL=""
PROM_BIND="0.0.0.0"
PROM_PORT=""
EXPECTED_NETWORK_MAGIC=""
MITHRIL_NETWORK=""

SNAPSHOT_SAFETY_GB="${SNAPSHOT_SAFETY_GB:-20}"
STARTUP_VALIDATION_TIMEOUT_SECONDS="${STARTUP_VALIDATION_TIMEOUT_SECONDS:-600}"
MITHRIL_CLIENT_BIN="${MITHRIL_CLIENT_BIN:-${BIN_DIR}/mithril-client}"
MITHRIL_RELEASE_TAG="${MITHRIL_RELEASE_TAG:-latest}"
MITHRIL_SIGNING_FPR="${MITHRIL_SIGNING_FPR:-73FC4C3DFD55DBDC428AD2B5BE043B79FDA4C2EE}"

# --- Color helpers -----------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONFIG_PLANNER="${SCRIPT_DIR}/upgrade-cardano-config.py"
WORK_DIR=""
cleanup_workspace() {
  [[ -z "${WORK_DIR}" ]] || rm -rf -- "${WORK_DIR}"
}
trap cleanup_workspace EXIT

bytes_to_gib() {
  awk -v b="$1" 'BEGIN { printf "%.2f", b/1024/1024/1024 }'
}

check_snapshot_disk_space() {
  local target_path avail_bytes db_size_bytes required_bytes safety_bytes
  target_path="$(dirname "${DB_DIR}")"
  safety_bytes=$((SNAPSHOT_SAFETY_GB * 1024 * 1024 * 1024))
  avail_bytes=$(df -B1 --output=avail "${target_path}" 2>/dev/null | tail -1 | tr -d ' ')
  [[ "${avail_bytes}" =~ ^[0-9]+$ ]] || error "Could not determine free space for ${target_path}"

  if [[ -d "${DB_DIR}" ]]; then
    db_size_bytes=$(du -s -B1 "${DB_DIR}" 2>/dev/null | awk '{print $1}')
    [[ "${db_size_bytes}" =~ ^[0-9]+$ ]] || error "Could not determine current DB size at ${DB_DIR}"
  else
    db_size_bytes=0
  fi

  required_bytes=$((db_size_bytes + safety_bytes))

  info "Disk preflight (target: ${target_path})"
  info "  Available: $(bytes_to_gib "${avail_bytes}") GiB"
  info "  Estimated required for snapshot + buffer: $(bytes_to_gib "${required_bytes}") GiB"

  if (( avail_bytes < required_bytes )); then
    error "Insufficient free space for snapshot deploy. Need at least $(bytes_to_gib "${required_bytes}") GiB free (current DB size + ${SNAPSHOT_SAFETY_GB} GiB buffer), but only $(bytes_to_gib "${avail_bytes}") GiB is available."
  fi
}

ensure_protocol_magic_id() {
  local protocol_file genesis_magic
  protocol_file="${DB_DIR}/protocolMagicId"

  if [[ -s "${protocol_file}" ]]; then
    if [[ "$(tr -d '[:space:]' < "${protocol_file}")" =~ ^[0-9]+$ ]]; then
      info "protocolMagicId already present at ${protocol_file}"
      return 0
    fi
    warn "protocolMagicId exists but is invalid, regenerating..."
  fi

  [[ -f "${FILES_DIR}/shelley-genesis.json" ]] || error "Missing genesis file: ${FILES_DIR}/shelley-genesis.json"
  genesis_magic=$(jq -r '.networkMagic' "${FILES_DIR}/shelley-genesis.json" 2>/dev/null || true)
  [[ "${genesis_magic}" =~ ^[0-9]+$ ]] || error "Could not parse networkMagic from ${FILES_DIR}/shelley-genesis.json"

  echo -n "${genesis_magic}" > "${protocol_file}"
  chmod 0644 "${protocol_file}"
  chown "$(id -u):$(id -g)" "${protocol_file}" 2>/dev/null || true

  [[ -s "${protocol_file}" ]] || error "Failed to create ${protocol_file}"
  [[ "$(tr -d '[:space:]' < "${protocol_file}")" == "${genesis_magic}" ]] || error "protocolMagicId content mismatch after write"
  info "Created ${protocol_file} with network magic ${genesis_magic} ✓"
}

resolve_mithril_release_tag() {
  if [[ "${MITHRIL_RELEASE_TAG}" != "latest" ]]; then
    echo "${MITHRIL_RELEASE_TAG}"
    return 0
  fi

  local latest_tag
  latest_tag=$(curl -fsSL "https://api.github.com/repos/input-output-hk/mithril/releases/latest" | jq -r '.tag_name')
  [[ -n "${latest_tag}" && "${latest_tag}" != "null" ]] || return 1
  echo "${latest_tag}"
}

install_mithril_client() {
  if [[ -x "${MITHRIL_CLIENT_BIN}" ]]; then
    info "mithril-client already present at ${MITHRIL_CLIENT_BIN}"
    return 0
  fi

  local mithril_arch release_tag tarball_name tarball_url tmpdir
  case "${ARCH}" in
    aarch64) mithril_arch="linux-arm64" ;;
    x86_64)  mithril_arch="linux-x64" ;;
    *)       warn "Unsupported architecture for prebuilt mithril-client: ${ARCH}"; return 1 ;;
  esac

  release_tag=$(resolve_mithril_release_tag) || {
    warn "Could not resolve latest Mithril release tag"
    return 1
  }

  tarball_name="mithril-${release_tag}-${mithril_arch}.tar.gz"
  tarball_url="https://github.com/input-output-hk/mithril/releases/download/${release_tag}/${tarball_name}"

  info "Installing official mithril-client from ${tarball_url}"
  tmpdir=$(mktemp -d)
  mkdir -p "${BIN_DIR}"
  curl -fL "${tarball_url}" -o "${tmpdir}/mithril.tar.gz"
  verify_mithril_download_signature "${release_tag}" "${tarball_name}" "${tmpdir}" || {
    rm -rf "${tmpdir}"
    warn "Skipping official mithril-client install due to signature/checksum verification failure"
    return 1
  }
  tar -xzf "${tmpdir}/mithril.tar.gz" -C "${tmpdir}"
  [[ -f "${tmpdir}/mithril-client" ]] || {
    rm -rf "${tmpdir}"
    warn "mithril-client binary not found in ${tarball_name}"
    return 1
  }

  install -m 0755 "${tmpdir}/mithril-client" "${MITHRIL_CLIENT_BIN}"
  rm -rf "${tmpdir}"

  "${MITHRIL_CLIENT_BIN}" --version >/dev/null 2>&1 || {
    warn "Installed mithril-client failed version check"
    return 1
  }
  info "Installed mithril-client at ${MITHRIL_CLIENT_BIN} ✓"
}

verify_mithril_download_signature() {
  local release_tag tarball_name tmpdir release_base checksum_url key_url checksum_file key_file
  local gnupghome key_fpr expected_sha actual_sha

  release_tag="$1"
  tarball_name="$2"
  tmpdir="$3"
  release_base="https://github.com/input-output-hk/mithril/releases/download/${release_tag}"
  checksum_url="${release_base}/CHECKSUM.asc"
  key_url="${release_base}/public-key.gpg"
  checksum_file="${tmpdir}/CHECKSUM.asc"
  key_file="${tmpdir}/public-key.gpg"

  info "Downloading Mithril checksum and signing key..."
  curl -fL "${checksum_url}" -o "${checksum_file}" || {
    warn "Failed to download CHECKSUM.asc"
    return 1
  }
  curl -fL "${key_url}" -o "${key_file}" || {
    warn "Failed to download public-key.gpg"
    return 1
  }

  gnupghome="${tmpdir}/gnupg"
  mkdir -p "${gnupghome}"
  chmod 700 "${gnupghome}"

  GNUPGHOME="${gnupghome}" gpg --batch --import "${key_file}" >/dev/null 2>&1 || {
    warn "Failed to import Mithril public key"
    return 1
  }

  key_fpr=$(GNUPGHOME="${gnupghome}" gpg --batch --with-colons --show-keys "${key_file}" 2>/dev/null | awk -F: '/^fpr:/ { print $10; exit }')
  if [[ "${key_fpr}" != "${MITHRIL_SIGNING_FPR}" ]]; then
    warn "Mithril signing key fingerprint mismatch. Expected ${MITHRIL_SIGNING_FPR}, got ${key_fpr:-unknown}"
    return 1
  fi

  GNUPGHOME="${gnupghome}" gpg --batch --verify "${checksum_file}" >/dev/null 2>&1 || {
    warn "CHECKSUM.asc signature verification failed"
    return 1
  }

  expected_sha=$(GNUPGHOME="${gnupghome}" gpg --batch --decrypt "${checksum_file}" 2>/dev/null | awk -v fn="./${tarball_name}" '$2 == fn { print $1; exit }')
  [[ "${expected_sha}" =~ ^[0-9a-f]{64}$ ]] || {
    warn "Could not extract expected checksum for ${tarball_name} from CHECKSUM.asc"
    return 1
  }

  actual_sha=$(sha256sum "${tmpdir}/mithril.tar.gz" | awk '{print $1}')
  if [[ "${actual_sha}" != "${expected_sha}" ]]; then
    warn "Tarball checksum mismatch for ${tarball_name}"
    warn "Expected: ${expected_sha}"
    warn "Actual:   ${actual_sha}"
    return 1
  fi

  info "Mithril tarball signature and checksum validated ✓"
}

deploy_snapshot_with_official_client() {
  [[ -x "${MITHRIL_CLIENT_BIN}" ]] || return 1

  local aggregator_endpoint genesis_vkey ancillary_vkey
  aggregator_endpoint="https://aggregator.${MITHRIL_NETWORK}.api.mithril.network/aggregator"

  genesis_vkey=$(curl -fsSL "https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/${MITHRIL_NETWORK}/genesis.vkey") || return 1
  ancillary_vkey=$(curl -fsSL "https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/${MITHRIL_NETWORK}/ancillary.vkey") || return 1

  info "Deploying fresh Mithril snapshot to ${DB_DIR} using official mithril-client..."
  "${MITHRIL_CLIENT_BIN}" -v \
    --aggregator-endpoint "${aggregator_endpoint}" \
    cardano-db download \
    --download-dir "$(dirname "${DB_DIR}")" \
    --genesis-verification-key "${genesis_vkey}" \
    --ancillary-verification-key "${ancillary_vkey}" \
    --include-ancillary \
    latest
}

verify_cardano_archive_checksum() {
  local archive_path archive_name checksums_url expected_sha actual_sha
  archive_path="$1"
  archive_name="cardano-node-${TARGET_VERSION}-linux-$([[ "${ARCH}" == "x86_64" ]] && echo amd64 || echo arm64).tar.gz"

  if [[ -n "${CUSTOM_URL}" ]]; then
    warn "Custom binary URL supplied; official release checksum verification skipped"
    return 0
  fi

  checksums_url="https://github.com/${GITHUB_REPO}/releases/download/${TARGET_VERSION}/cardano-node-${TARGET_VERSION}-sha256sums.txt"
  expected_sha=$(curl -fsSL "${checksums_url}" | awk -v name="${archive_name}" '$2 == name || $2 == "*" name { print $1; exit }')
  [[ "${expected_sha}" =~ ^[0-9a-fA-F]{64}$ ]] || error "Could not find ${archive_name} in official checksum file"
  actual_sha=$(sha256sum "${archive_path}" | awk '{print $1}')
  [[ "${actual_sha}" == "${expected_sha}" ]] || error "Cardano node archive checksum mismatch"
  info "Official Cardano node archive checksum verified ✓"
}

set_env_value() {
  local env_file key value
  env_file="$1"
  key="$2"
  value="$3"
  python3 - "${env_file}" "${key}" "${value}" <<'PYEOF'
import os, pathlib, re, stat, sys, tempfile

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
text = path.read_text()
replacement = f'{key}="{value}"'
pattern = re.compile(
  rf'^{re.escape(key)}\s*='
  rf'(?P<value>"[^"]*"|\'[^\']*\'|[^#\s]+)(?P<comment>\s+#.*)?$',
  re.MULTILINE,
)
matches = list(pattern.finditer(text))
if len(matches) > 1:
  raise SystemExit(f'Duplicate active {key} assignments in {path}')
if matches:
  text = pattern.sub(lambda match: replacement + (match.group('comment') or ''), text, count=1)
else:
  text = replacement + '\n' + text
metadata = path.stat()
descriptor, temporary_name = tempfile.mkstemp(prefix=f'.{path.name}.upgrade-', dir=path.parent)
temporary = pathlib.Path(temporary_name)
try:
  with os.fdopen(descriptor, 'w') as output:
    output.write(text)
    output.flush()
    os.fsync(output.fileno())
  os.chmod(temporary, stat.S_IMODE(metadata.st_mode))
  os.chown(temporary, metadata.st_uid, metadata.st_gid)
  os.replace(temporary, path)
  directory = os.open(path.parent, os.O_RDONLY)
  try:
    os.fsync(directory)
  finally:
    os.close(directory)
finally:
  temporary.unlink(missing_ok=True)
PYEOF
}

remove_legacy_tracer_keys() {
  python3 - "$1" <<'PYEOF'
import json, pathlib, sys

path = pathlib.Path(sys.argv[1])
config = json.loads(path.read_text())
changed = False
for key in ('TurnOnLogging', 'TurnOnLogMetrics', 'UseTraceDispatcher'):
  if key in config:
    del config[key]
    changed = True
if changed:
  path.write_text(json.dumps(config, indent=2) + '\n')
PYEOF
}

ROLLBACK_ARMED=false
NODE_WAS_ACTIVE=false
BINARY_BACKUP_DIR=""
DB_BACKUP=""
ENV_CHANGED=false
BINARY_CHANGED=false
declare -a CONFIG_INSTALLED_FILES=()

rollback_on_exit() {
  local status=$?
  local rollback_failed=false restored_topology_hash
  if [[ "${status}" -eq 0 || "${ROLLBACK_ARMED}" != "true" ]]; then
    cleanup_workspace
    return "${status}"
  fi
  trap cleanup_workspace EXIT
  set +e

  warn "Upgrade failed after activation began; restoring the previous installation..."
  if ! sudo systemctl stop "${SERVICE_NAME}"; then
    warn "ROLLBACK BLOCKED: could not stop service; leave files untouched and recover manually from ${FILES_DIR}-${BACKUP_SUFFIX}"
    cleanup_workspace
    exit "${status}"
  fi
  if [[ "$(systemctl show -p ActiveState --value "${SERVICE_NAME}")" != "inactive" &&
        "$(systemctl show -p ActiveState --value "${SERVICE_NAME}")" != "failed" ]]; then
    warn "ROLLBACK BLOCKED: service is not confirmed stopped; manual recovery required"
    cleanup_workspace
    exit "${status}"
  fi

  for config_name in "${CONFIG_INSTALLED_FILES[@]}"; do
    if [[ -f "${FILES_DIR}-${BACKUP_SUFFIX}/${config_name}" ]]; then
      sudo rm -f "${FILES_DIR}/${config_name}" \
        && sudo cp -a "${FILES_DIR}-${BACKUP_SUFFIX}/${config_name}" "${FILES_DIR}/${config_name}" \
        || rollback_failed=true
    else
      sudo rm -f "${FILES_DIR}/${config_name}" || rollback_failed=true
    fi
  done
  if ${ENV_CHANGED}; then
    if [[ -f "${ENV_FILE}-${BACKUP_SUFFIX}" ]]; then
      sudo cp -a "${ENV_FILE}-${BACKUP_SUFFIX}" "${ENV_FILE}" || rollback_failed=true
    else
      rollback_failed=true
    fi
  fi

  if ${BINARY_CHANGED} && [[ -d "${BINARY_BACKUP_DIR}" ]]; then
    while IFS= read -r -d '' staged_file; do
      binary_name=$(basename "${staged_file}")
      if [[ -f "${BINARY_BACKUP_DIR}/${binary_name}" ]]; then
        install -m 0755 "${BINARY_BACKUP_DIR}/${binary_name}" "${ACTIVE_BIN_DIR}/.${binary_name}.rollback" \
          && mv -f "${ACTIVE_BIN_DIR}/.${binary_name}.rollback" "${ACTIVE_BIN_DIR}/${binary_name}" \
          || rollback_failed=true
      elif ${CUSTOM_INSTANCE}; then
        warn "Retaining new custom binary after rollback for inspection: ${ACTIVE_BIN_DIR}/${binary_name}"
      else
        rm -f "${ACTIVE_BIN_DIR}/${binary_name}" || rollback_failed=true
      fi
    done < <(find "${STAGED_BIN_DIR}" -maxdepth 1 -type f -print0)
  elif ${BINARY_CHANGED}; then
    rollback_failed=true
  fi

  if [[ -n "${DB_BACKUP}" && -d "${DB_BACKUP}" ]]; then
    rm -rf "${DB_DIR}" && mv "${DB_BACKUP}" "${DB_DIR}" || rollback_failed=true
  fi

  if [[ -f "${TOPOLOGY_FILE}" ]]; then
    restored_topology_hash=$(sha256sum "${TOPOLOGY_FILE}" | awk '{print $1}')
    [[ "${restored_topology_hash}" == "${TOPOLOGY_HASH_BEFORE}" ]] \
      || rollback_failed=true
  else
    rollback_failed=true
  fi
  [[ "$(sha256sum "${FILES_DIR}/config.json" | awk '{print $1}')" == "${CONFIG_HASH_BEFORE}" ]] || rollback_failed=true
  [[ "$(sha256sum "${ENV_FILE}" | awk '{print $1}')" == "${ENV_HASH_BEFORE}" ]] || rollback_failed=true
  [[ "$(sha256sum "${CURRENT_NODE_BIN}" 2>/dev/null | awk '{print $1}')" == "${CURRENT_NODE_HASH_BEFORE}" ]] \
    || rollback_failed=true
  [[ "$(sha256sum "${CURRENT_CLI_BIN}" 2>/dev/null | awk '{print $1}')" == "${CURRENT_CLI_HASH_BEFORE}" ]] \
    || rollback_failed=true
  if ! ${rollback_failed} && [[ "${NODE_WAS_ACTIVE}" == "true" ]]; then
    sudo systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true
    sudo systemctl start "${SERVICE_NAME}" || rollback_failed=true
    systemctl is-active --quiet "${SERVICE_NAME}" || rollback_failed=true
  fi
  if ${rollback_failed}; then
    warn "ROLLBACK INCOMPLETE; manual recovery is required from backups ending ${BACKUP_SUFFIX}"
  else
    warn "Rollback completed and previous service state restored"
  fi
  cleanup_workspace
  exit "${status}"
}

# --- Parse arguments ---------------------------------------------------------
NODE_ROLE=""
TOPOLOGY_BACKUP=""
NODE_HOME_OVERRIDE=""
SERVICE_OVERRIDE=""
BINARY_DIR_OVERRIDE=""
CUSTOM_INSTANCE=false
DRY_RUN=false
TARGET_VERSION=""
CUSTOM_URL=""
KEEP_CONFIG=true
FRESH_DB=false
ASSUME_YES=false
LEDGER_BACKEND=""
LEDGER_BACKEND_EXPLICIT=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --network)
      [[ $# -ge 2 ]] || error "--network requires mainnet, preprod, or preview"
      NETWORK="$2"; shift 2 ;;
    --node-home)
      [[ $# -ge 2 ]] || error "--node-home requires an absolute path"
      NODE_HOME_OVERRIDE="$2"; shift 2 ;;
    --service)
      [[ $# -ge 2 ]] || error "--service requires a systemd service unit"
      SERVICE_OVERRIDE="$2"; shift 2 ;;
    --binary-dir)
      [[ $# -ge 2 ]] || error "--binary-dir requires an absolute path"
      BINARY_DIR_OVERRIDE="$2"; shift 2 ;;
    --version)
      [[ $# -ge 2 ]] || error "--version requires a value (e.g. --version 11.0.1)"
      TARGET_VERSION="$2"; shift 2 ;;
    --url)
      [[ $# -ge 2 ]] || error "--url requires a value"
      CUSTOM_URL="$2"; shift 2 ;;
    --relay|--bp)
      [[ -z "${NODE_ROLE}" ]] || error "Specify exactly one of --relay or --bp"
      NODE_ROLE="${1#--}"; shift ;;
    --topology-backup)
      [[ $# -ge 2 ]] || error "--topology-backup requires a paired backup topology.json path"
      TOPOLOGY_BACKUP="$2"; shift 2 ;;
    --keep-config) KEEP_CONFIG=true; shift ;;
    --refresh-config) KEEP_CONFIG=false; shift ;;
    --fresh-db)    FRESH_DB=true; shift ;;
    --ledger-backend)
      [[ $# -ge 2 ]] || error "--ledger-backend requires V2InMemory or V2LSM"
      LEDGER_BACKEND="$2"; LEDGER_BACKEND_EXPLICIT=true; shift 2 ;;
    --yes)         ASSUME_YES=true; shift ;;
    --dry-run)     DRY_RUN=true; shift ;;
    *)             error "Unknown argument: $1\nUsage: $0 [--network mainnet|preprod|preview] [--node-home PATH [--service UNIT] [--binary-dir PATH]] [--version X.Y.Z] [--url URL] [--relay|--bp] [--keep-config|--refresh-config] [--fresh-db] [--ledger-backend V2InMemory|V2LSM] [--yes] [--dry-run]" ;;
  esac
done

[[ -n "${NODE_ROLE}" ]] || error "Specify --relay or --bp explicitly; role is never guessed"
[[ -z "${SERVICE_OVERRIDE}" || -n "${NODE_HOME_OVERRIDE}" ]] \
  || error "--service is only valid with --node-home"
[[ -z "${BINARY_DIR_OVERRIDE}" || -n "${NODE_HOME_OVERRIDE}" ]] \
  || error "--binary-dir is only valid with --node-home"
[[ "${EUID}" -ne 0 ]] || error "Run as the Cardano service user, not root"
[[ -f "${CONFIG_PLANNER}" ]] || error "Missing planner: clone/update the entire repository, not only this script"
for prerequisite in python3 jq curl systemctl journalctl sha256sum flock timeout; do
  command -v "${prerequisite}" >/dev/null || error "Missing prerequisite: ${prerequisite}"
done
[[ "${STARTUP_VALIDATION_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]] \
  || error "STARTUP_VALIDATION_TIMEOUT_SECONDS must be a positive integer"
WORK_DIR=$(mktemp -d)

case "${NETWORK}" in
  mainnet)
    CNODE_HOME="/opt/cardano/cnode"
    SERVICE_NAME="cnode.service"
    PROM_PORT="11798"
    EXPECTED_NETWORK_MAGIC="764824073"
    MITHRIL_NETWORK="release-mainnet"
    ;;
  preprod)
    CNODE_HOME="/opt/cardano/preprod"
    SERVICE_NAME="preprod.service"
    PROM_PORT="12798"
    EXPECTED_NETWORK_MAGIC="1"
    MITHRIL_NETWORK="release-preprod"
    ;;
  preview)
    CNODE_HOME="/opt/cardano/preview"
    SERVICE_NAME="preview.service"
    PROM_PORT="12718"
    EXPECTED_NETWORK_MAGIC="2"
    MITHRIL_NETWORK="release-preview"
    ;;
  *)
    error "Unsupported network '${NETWORK}'. Expected mainnet, preprod, or preview."
    ;;
esac

if [[ -n "${NODE_HOME_OVERRIDE}" ]]; then
  CUSTOM_INSTANCE=true
  [[ "${NODE_HOME_OVERRIDE}" == /* ]] || error "--node-home must be an absolute path"
  [[ -d "${NODE_HOME_OVERRIDE}" && ! -L "${NODE_HOME_OVERRIDE}" ]] \
    || error "--node-home must be an existing non-symlink directory"
  CNODE_HOME=$(readlink -f -- "${NODE_HOME_OVERRIDE}")
  INSTANCE_NAME=$(basename -- "${CNODE_HOME}")
  [[ "${INSTANCE_NAME}" =~ ^[A-Za-z0-9_.@-]+$ ]] \
    || error "Cannot derive a safe service name from --node-home: ${INSTANCE_NAME}"
  SERVICE_NAME="${SERVICE_OVERRIDE:-${INSTANCE_NAME}.service}"
  [[ "${SERVICE_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_.@-]*\.service$ ]] \
    || error "Invalid service unit: ${SERVICE_NAME}"
fi
BACKUP_SCOPE="${NETWORK}"
${CUSTOM_INSTANCE} && BACKUP_SCOPE="${NETWORK}-${INSTANCE_NAME}"

FILES_DIR="${CNODE_HOME}/files"
DB_DIR="${CNODE_HOME}/db"
ENV_FILE="${CNODE_HOME}/scripts/env"
TOPOLOGY_FILE="${FILES_DIR}/topology.json"
CONFIG_BASE_URL="https://book.world.dev.cardano.org/environments/${NETWORK}"
[[ -d "${FILES_DIR}" && -f "${ENV_FILE}" && -f "${FILES_DIR}/config.json" \
  && -f "${TOPOLOGY_FILE}" && -d "${DB_DIR}" ]] \
  || error "Selected node home is missing files, scripts/env, config, topology, or database: ${CNODE_HOME}"

# Lock the node-home inode without creating or modifying a live file (also in dry-run).
exec {UPGRADE_LOCK_FD}<"${CNODE_HOME}"
flock -n "${UPGRADE_LOCK_FD}" || error "Another upgrade is operating on ${CNODE_HOME}"
SERVICE_USER=$(systemctl show -p User --value "${SERVICE_NAME}")
[[ "${SERVICE_USER}" == "$(id -un)" || "${SERVICE_USER}" == "$(id -u)" ]] \
  || error "Run as service user ${SERVICE_USER:-root}; current user is $(id -un)"
systemctl is-active --quiet "${SERVICE_NAME}" || error "Service must be active for path/role verification"
INITIAL_PID=$(systemctl show -p MainPID --value "${SERVICE_NAME}")
verify_service_process() {
  local pid="$1" expected_executable="${2:-}"
  python3 - "${pid}" "${FILES_DIR}" "${DB_DIR}" "${NODE_ROLE}" \
    "${expected_executable}" "${PROC_ROOT:-}" <<'PYEOF'
import os, pathlib, sys
pid, directory, database, role, expected_executable, proc_override = sys.argv[1:]
if not pid.isdigit() or int(pid) <= 0:
  raise SystemExit(f'Invalid service process ID: {pid}')
proc_root = pathlib.Path('/proc') if not proc_override else pathlib.Path(proc_override)
proc = proc_root / pid
if proc.stat().st_uid != os.getuid():
  raise SystemExit('Service process belongs to a different user')
args = (proc / 'cmdline').read_bytes().decode().split('\0')
def argument(name):
  for i, value in enumerate(args):
    if value == name and i + 1 < len(args):
      return args[i + 1]
    if value.startswith(name + '='):
      return value.split('=', 1)[1]
  raise SystemExit(f'Cannot establish active {name}; refusing to modify assumed paths')
for flag, name in (('--config', 'config.json'), ('--topology', 'topology.json')):
  active = pathlib.Path(argument(flag))
  if not active.is_absolute():
    active = (proc / 'cwd').resolve() / active
  if active.resolve() != (pathlib.Path(directory) / name).resolve():
    raise SystemExit(f'Unexpected active {flag}: {active}')
active_database = pathlib.Path(argument('--database-path'))
if not active_database.is_absolute():
  active_database = (proc / 'cwd').resolve() / active_database
if active_database.resolve() != pathlib.Path(database).resolve():
  raise SystemExit(f'Unexpected active --database-path: {active_database}')
forging = any(a.split('=', 1)[0] in ('--shelley-kes-key', '--shelley-vrf-key',
        '--shelley-operational-certificate', '--byron-signing-key', '--byron-delegation-certificate') for a in args)
if forging != (role == 'bp'):
  raise SystemExit('Declared role contradicts active forging arguments; inspect service invocation')
if expected_executable:
  expected = pathlib.Path(expected_executable)
  if not expected.is_absolute():
    raise SystemExit(f'Expected executable is not absolute: {expected}')
  if any(path.is_symlink() for path in (expected, *expected.parents)):
    raise SystemExit(f'Expected executable path contains a symlink: {expected}')
  actual = (proc / 'exe').resolve(strict=True)
  if actual != expected.resolve(strict=True):
    raise SystemExit(f'Unexpected active executable: {actual}')
PYEOF
}
verify_service_process "${INITIAL_PID}"
CONFIG_HASH_BEFORE=$(sha256sum "${FILES_DIR}/config.json" | awk '{print $1}')
ENV_HASH_BEFORE=$(sha256sum "${ENV_FILE}" | awk '{print $1}')
TOPOLOGY_HASH_BEFORE=$(sha256sum "${TOPOLOGY_FILE}" | awk '{print $1}')

read_env_value() {
  local key="$1"
  sed -n "s|^${key}=[\"']\{0,1\}\([^\"' #]*\).*$|\1|p" "${ENV_FILE}" | head -1
}

read_env_path() {
  local key="$1"
  python3 - "${ENV_FILE}" "${key}" "${HOME}" <<'PYEOF'
import pathlib, re, shlex, sys

env_file, key, home = sys.argv[1:]
assignments = []
pattern = re.compile(r'^' + re.escape(key) + r'\s*=\s*(.*?)\s*$')
for line in pathlib.Path(env_file).read_text().splitlines():
  if not line.strip() or line.lstrip().startswith('#'):
    continue
  match = pattern.match(line)
  if match:
    assignments.append(match.group(1))
if len(assignments) > 1:
  raise SystemExit(f'Duplicate active {key} assignments in {env_file}')
if not assignments:
  raise SystemExit(0)

raw = assignments[0]
expand_home = not raw.lstrip().startswith("'")
lexer = shlex.shlex(raw, posix=True)
lexer.whitespace_split = True
lexer.commenters = '#'
try:
  values = list(lexer)
except ValueError as exc:
  raise SystemExit(f'Invalid quoting in {key} assignment: {exc}') from exc
if len(values) != 1:
  raise SystemExit(f'{key} must contain exactly one path value')
raw = values[0]
if not raw or any(token in raw for token in ('`', '$(', ';', '|', '&', '<', '>')):
  raise SystemExit(f'Unsupported shell syntax in {key} assignment')
if expand_home:
  if raw == '$HOME' or raw == '${HOME}':
    raw = home
  elif raw.startswith('$HOME/'):
    raw = home + raw[5:]
  elif raw.startswith('${HOME}/'):
    raw = home + raw[7:]
path = pathlib.Path(raw)
if not path.is_absolute():
  raise SystemExit(f'{key} must resolve to an absolute path')
print(path)
PYEOF
}

infer_custom_binary_dir() {
  local current_binary="$1" current_version="$2" target_version="$3" explicit_dir="$4"
  python3 - "${current_binary}" "${current_version}" "${target_version}" \
  "${explicit_dir}" "${HOME}/.local/bin" "${CNODE_HOME}" "${DB_DIR}" <<'PYEOF'
import os, pathlib, sys

current, old, new, explicit, shared, node_home, database = sys.argv[1:]
if explicit:
  target = pathlib.Path(explicit)
  if not target.is_absolute():
    raise SystemExit('--binary-dir must be an absolute path')
else:
  current_path = pathlib.Path(current)
  matches = [index for index, part in enumerate(current_path.parts) if part.count(old) == 1]
  if len(matches) != 1:
    raise SystemExit('Cannot infer one target binary directory from the current version; use --binary-dir')
  parts = list(current_path.parts)
  index = matches[0]
  parts[index] = parts[index].replace(old, new, 1)
  target = pathlib.Path(*parts).parent

target = pathlib.Path(os.path.abspath(target))
shared = pathlib.Path(os.path.abspath(shared))
node_home = pathlib.Path(os.path.abspath(node_home))
database = pathlib.Path(os.path.abspath(database))
if target == shared:
  raise SystemExit(f'Custom instances may not target shared binary directory {shared}')
if target == node_home or node_home in target.parents or target == database or database in target.parents:
  raise SystemExit('Custom binary directory may not be inside the node home or database')
for candidate in (target, *target.parents):
  if candidate.is_symlink():
    raise SystemExit(f'Refusing symlinked binary path component: {candidate}')
print(target)
PYEOF
}

validate_custom_binary_target() {
  local target="$1" selected_pid="$2" proc_root="${3:-${PROC_ROOT:-/proc}}"
  python3 - "${target}" "${selected_pid}" "${proc_root}" <<'PYEOF'
import os, pathlib, sys

target, selected_pid, proc_root = pathlib.Path(sys.argv[1]), sys.argv[2], pathlib.Path(sys.argv[3])
ancestor = target
while not ancestor.exists():
  if ancestor.is_symlink():
    raise SystemExit(f'Refusing symlinked binary path component: {ancestor}')
  if ancestor == ancestor.parent:
    raise SystemExit(f'No existing ancestor for binary directory: {target}')
  ancestor = ancestor.parent
if ancestor.is_symlink() or not ancestor.is_dir():
  raise SystemExit(f'Binary path ancestor is not a real directory: {ancestor}')
stat = ancestor.stat()
if stat.st_uid != os.getuid() or not os.access(ancestor, os.W_OK | os.X_OK):
  raise SystemExit(f'Binary path ancestor is not owned and writable by the service user: {ancestor}')
if target.exists() and (target.is_symlink() or not target.is_dir() or target.stat().st_uid != os.getuid()):
  raise SystemExit(f'Existing binary target is not a service-user-owned real directory: {target}')

for proc in proc_root.iterdir():
  if not proc.name.isdigit() or proc.name == selected_pid:
    continue
  try:
    executable = (proc / 'exe').resolve(strict=True)
  except (FileNotFoundError, PermissionError, OSError):
    continue
  if executable == target / 'cardano-node' or executable.parent == target:
    raise SystemExit(f'Unrelated live process {proc.name} uses custom binary target: {executable}')
PYEOF
}

classify_custom_binary_target() {
  local target="$1" staged="$2"
  python3 - "${target}" "${staged}" <<'PYEOF'
import hashlib, pathlib, sys

target, staged = map(pathlib.Path, sys.argv[1:])
if not target.exists() or not any(target.iterdir()):
  print('new')
  raise SystemExit(0)
if target.is_symlink() or not target.is_dir():
  raise SystemExit(f'Conflicting custom binary target: {target}')

staged_files = {path.name: path for path in staged.iterdir() if path.is_file()}
target_entries = {path.name: path for path in target.iterdir()}
if set(target_entries) != set(staged_files) or any(not path.is_file() or path.is_symlink()
                           for path in target_entries.values()):
  raise SystemExit(f'Existing custom binary target does not exactly match the staged package: {target}')
digest = lambda path: hashlib.sha256(path.read_bytes()).digest()
if any(digest(source) != digest(target_entries[name]) for name, source in staged_files.items()):
  raise SystemExit(f'Existing custom binary target conflicts with the staged package: {target}')
print('reuse')
PYEOF
}

snapshot_custom_binary_target() {
  local target="$1"
  python3 - "${target}" <<'PYEOF'
import hashlib, json, pathlib, stat, sys

target = pathlib.Path(sys.argv[1])
if not target.exists():
    print('absent')
    raise SystemExit(0)
entries = []
for path in sorted(target.rglob('*')):
    metadata = path.lstat()
    kind = 'symlink' if path.is_symlink() else 'file' if path.is_file() else 'directory'
    digest = hashlib.sha256(path.read_bytes()).hexdigest() if kind == 'file' else None
    entries.append((str(path.relative_to(target)), kind, stat.S_IMODE(metadata.st_mode),
                    metadata.st_uid, metadata.st_gid, metadata.st_size, digest))
print(hashlib.sha256(json.dumps(entries, separators=(',', ':')).encode()).hexdigest())
PYEOF
}

install_custom_binaries() {
  local target="$1" staged="$2"
  python3 - "${target}" "${staged}" <<'PYEOF'
import hashlib, os, pathlib, stat, sys

target, staged = map(pathlib.Path, sys.argv[1:])
if not target.is_absolute():
  raise SystemExit('Custom binary target must be absolute')
open_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
directory_fd = os.open('/', open_flags)
created = False
try:
  for component in target.parts[1:]:
    try:
      next_fd = os.open(component, open_flags, dir_fd=directory_fd)
    except FileNotFoundError:
      parent = os.fstat(directory_fd)
      if parent.st_uid != os.getuid() or stat.S_IMODE(parent.st_mode) & 0o300 != 0o300:
        raise SystemExit(f'Cannot securely create custom binary directory below {component!r}')
      os.mkdir(component, mode=0o755, dir_fd=directory_fd)
      created = True
      next_fd = os.open(component, open_flags, dir_fd=directory_fd)
    os.close(directory_fd)
    directory_fd = next_fd

  target_stat = os.fstat(directory_fd)
  if target_stat.st_uid != os.getuid():
    raise SystemExit(f'Custom binary target is not owned by the service user: {target}')
  if os.listdir(directory_fd):
    raise SystemExit(f'Custom binary target changed or is not empty: {target}')

  staged_files = sorted(path for path in staged.iterdir() if path.is_file())
  if not staged_files:
    raise SystemExit('No staged binaries to install')
  for source in staged_files:
    source_stat = source.lstat()
    if source.is_symlink() or not stat.S_ISREG(source_stat.st_mode):
      raise SystemExit(f'Refusing non-regular staged binary: {source}')
    temporary = f'.{source.name}.upgrade-{os.getpid()}'
    source_digest = hashlib.sha256()
    output_fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                        0o755, dir_fd=directory_fd)
    try:
      with source.open('rb') as input_file, os.fdopen(output_fd, 'wb', closefd=False) as output_file:
        while chunk := input_file.read(1024 * 1024):
          source_digest.update(chunk)
          output_file.write(chunk)
        output_file.flush()
        os.fsync(output_fd)
      os.fchmod(output_fd, 0o755)
    finally:
      os.close(output_fd)
    os.rename(temporary, source.name, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
    installed_fd = os.open(source.name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory_fd)
    try:
      installed_stat = os.fstat(installed_fd)
      if not stat.S_ISREG(installed_stat.st_mode):
        raise SystemExit(f'Installed custom binary is not a regular file: {source.name}')
      installed_digest = hashlib.sha256()
      while chunk := os.read(installed_fd, 1024 * 1024):
        installed_digest.update(chunk)
      if installed_digest.digest() != source_digest.digest():
        raise SystemExit(f'Installed custom binary differs from staged content: {source.name}')
    finally:
      os.close(installed_fd)
  os.fsync(directory_fd)

  visible = target.lstat()
  if stat.S_ISLNK(visible.st_mode) or (visible.st_dev, visible.st_ino) != (target_stat.st_dev, target_stat.st_ino):
    raise SystemExit(f'Custom binary target path changed during installation: {target}')
except Exception:
  if created:
    # Keep any securely written directory for inspection; never follow or remove a replacement path.
    pass
  raise
finally:
  os.close(directory_fd)
PYEOF
}

CONFIG_PROM_LINE=$(jq -r '.TraceOptions."".backends[]? | select(startswith("PrometheusSimple"))' "${FILES_DIR}/config.json" 2>/dev/null | head -1)
CONFIG_PROM_BIND=""
CONFIG_PROM_PORT=""
if [[ -n "${CONFIG_PROM_LINE}" ]]; then
  CONFIG_PROM_BIND=$(awk '{print $(NF-1)}' <<<"${CONFIG_PROM_LINE}")
  CONFIG_PROM_PORT=$(awk '{print $NF}' <<<"${CONFIG_PROM_LINE}")
fi
ENV_PROM_BIND=$(read_env_value PROM_HOST)
ENV_PROM_PORT=$(read_env_value PROM_PORT)
PROM_BIND="${ENV_PROM_BIND:-${CONFIG_PROM_BIND:-${PROM_BIND}}}"
PROM_PORT="${ENV_PROM_PORT:-${CONFIG_PROM_PORT:-${PROM_PORT}}}"

[[ "${PROM_PORT}" =~ ^[0-9]+$ ]] || error "Could not determine existing Prometheus port from ${ENV_FILE} or config.json"

info "Network:        ${NETWORK}"
info "Node home:      ${CNODE_HOME}"
info "Service:        ${SERVICE_NAME}"

info "Topology:       preserve-first (${TOPOLOGY_HASH_BEFORE})"

# --- Resolve target version --------------------------------------------------
if [[ -z "${TARGET_VERSION}" ]]; then
  info "No --version specified. Detecting latest release from GitHub..."

  LATEST=$(curl -sf "${GITHUB_API_URL}" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null) || LATEST=""

  if [[ -n "${LATEST}" ]]; then
    echo ""
    echo -e "  ${CYAN}Latest GitHub release: ${LATEST}${NC}"
    echo ""
    if ${ASSUME_YES} || ${DRY_RUN}; then
      TARGET_VERSION="${LATEST}"
    else
      read -r -p "Upgrade to ${LATEST}? [Y/n]: " confirm
      case "${confirm}" in
        [nN]*)
          read -r -p "Enter target version (e.g. 11.1.2): " TARGET_VERSION
          [[ -z "${TARGET_VERSION}" ]] && error "No version specified"
          ;;
        *)
          TARGET_VERSION="${LATEST}"
          ;;
      esac
    fi
  else
    warn "Could not detect latest version from GitHub API"
    if ${ASSUME_YES} || ${DRY_RUN}; then
      error "Cannot resolve latest release noninteractively; supply --version X.Y.Z"
    fi
    # Fallback: try to detect from currently installed binary
    if [[ -x "${BIN_DIR}/cardano-node" ]]; then
      INSTALLED=$("${BIN_DIR}/cardano-node" --version 2>/dev/null | head -1 | awk '{print $2}') || INSTALLED=""
      if [[ -n "${INSTALLED}" ]]; then
        warn "Currently installed version: ${INSTALLED}"
      fi
    fi
    echo ""
    read -r -p "Enter target version (e.g. 11.0.1): " TARGET_VERSION
    [[ -z "${TARGET_VERSION}" ]] && error "No version specified. Use: $0 --version X.Y.Z"
  fi
fi

# Basic version format validation
if ! [[ "${TARGET_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  error "Invalid version format '${TARGET_VERSION}'. Expected X.Y.Z (e.g. 11.0.1)"
fi

version_at_least() {
  printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

info "Target version: ${TARGET_VERSION}"
info "Node role:      ${NODE_ROLE}"

PLANNER_ARGS=(--files-dir "${FILES_DIR}" --role "${NODE_ROLE}"
  --network-magic "${EXPECTED_NETWORK_MAGIC}" --target-version "${TARGET_VERSION}")
[[ -z "${TOPOLOGY_BACKUP}" ]] || PLANNER_ARGS+=(--topology-backup "${TOPOLOGY_BACKUP}")
python3 "${CONFIG_PLANNER}" "${PLANNER_ARGS[@]}" --config "${FILES_DIR}/config.json" \
  --output-dir "${WORK_DIR}/initial-plan" || error "Praos topology planning failed; no live files changed"
[[ "$(jq -r '.config_before_sha256' "${WORK_DIR}/initial-plan/plan.json")" == "${CONFIG_HASH_BEFORE}" && \
  "$(jq -r '.topology_before_sha256' "${WORK_DIR}/initial-plan/plan.json")" == "${TOPOLOGY_HASH_BEFORE}" ]] \
  || error "Config/topology changed during initial inventory; retry with stable files"
TOPOLOGY_P2P=$(jq -r '.topology_p2p' "${WORK_DIR}/initial-plan/plan.json")

CURRENT_BACKEND=$(jq -r '.LedgerDB.Backend // empty' "${FILES_DIR}/config.json" 2>/dev/null) || CURRENT_BACKEND=""
[[ "${CURRENT_BACKEND}" == "V2InMemory" || "${CURRENT_BACKEND}" == "V2LSM" ]] \
  || error "Existing config has no valid LedgerDB backend. Expected V2InMemory or V2LSM."
info "Current LedgerDB backend: ${CURRENT_BACKEND}"

if ${KEEP_CONFIG} && version_at_least "${TARGET_VERSION}" "11.1.2"; then
  jq -e '.TraceOptions."".backends | type == "array"' "${FILES_DIR}/config.json" >/dev/null 2>&1 \
    || error "cardano-node ${TARGET_VERSION} requires current TraceOptions configuration; rerun with --refresh-config"
  LEGACY_TRACER_KEYS=$(jq -r '
    . as $config
    |
    ["TurnOnLogging", "TurnOnLogMetrics", "UseTraceDispatcher"]
    | map(select(. as $key | $config | has($key)))
    | join(", ")
  ' "${FILES_DIR}/config.json")
  if [[ -n "${LEGACY_TRACER_KEYS}" ]]; then
    info "Unsupported legacy tracer keys will be removed from the staged config: ${LEGACY_TRACER_KEYS}"
  fi
  jq -e '.LedgerDB.Backend == "V2InMemory" or .LedgerDB.Backend == "V2LSM"' "${FILES_DIR}/config.json" >/dev/null 2>&1 \
    || error "Preserved config must explicitly select LedgerDB.Backend; rerun with --refresh-config and --ledger-backend"
  if [[ "${NODE_ROLE}" == "bp" ]]; then
    jq -e '.LedgerDB.Backend == "V2InMemory"' "${FILES_DIR}/config.json" >/dev/null 2>&1 \
      || error "Block producers require LedgerDB.Backend=V2InMemory; rerun with --refresh-config --ledger-backend V2InMemory --fresh-db"
  fi
  info "--keep-config preserves custom settings except explicit Praos/P2P/BP privacy normalization"
fi

STAGED_BIN_DIR="${WORK_DIR}/binaries"
BINARY_DESTINATION_SOURCE="standard"

# --- Resolve download URL and architecture -----------------------------------
ARCH=$(uname -m)
if [[ -n "${CUSTOM_URL}" ]]; then
  NODE_RELEASE_URL="${CUSTOM_URL}"
  info "Architecture:   ${ARCH}"
  info "Download URL:   ${NODE_RELEASE_URL} (custom)"
else
  case "${ARCH}" in
    x86_64)
      NODE_RELEASE_URL="https://github.com/${GITHUB_REPO}/releases/download/${TARGET_VERSION}/cardano-node-${TARGET_VERSION}-linux-amd64.tar.gz"
      ;;
    aarch64)
      NODE_RELEASE_URL="https://github.com/${GITHUB_REPO}/releases/download/${TARGET_VERSION}/cardano-node-${TARGET_VERSION}-linux-arm64.tar.gz"
      ;;
    *)
      error "Unsupported architecture: ${ARCH}. Use --url to provide a custom binary URL."
      ;;
  esac
  info "Architecture:   ${ARCH}"
  info "Download URL:   ${NODE_RELEASE_URL}"
fi

if ${CUSTOM_INSTANCE}; then
  ENV_NODE_BIN=""
  if ! ENV_NODE_BIN=$(read_env_path CNODEBIN 2>&1); then
    error "${ENV_NODE_BIN}"
  fi
  PROCESS_NODE_BIN=$(readlink -f "/proc/${INITIAL_PID}/exe") \
    || error "Cannot resolve active service executable"
  if [[ -n "${ENV_NODE_BIN}" ]]; then
    [[ -x "${ENV_NODE_BIN}" && ! -L "${ENV_NODE_BIN}" ]] \
      || error "Configured CNODEBIN is not a regular non-symlink executable: ${ENV_NODE_BIN}"
    [[ "$(readlink -f "${ENV_NODE_BIN}")" == "${PROCESS_NODE_BIN}" ]] \
      || error "Configured CNODEBIN does not match active service executable: ${ENV_NODE_BIN}"
    CURRENT_NODE_BIN="${ENV_NODE_BIN}"
  else
    [[ -n "${BINARY_DIR_OVERRIDE}" ]] \
      || error "CNODEBIN is not explicitly configured; use --binary-dir after reviewing the active executable"
    CURRENT_NODE_BIN="${PROCESS_NODE_BIN}"
  fi
  ENV_CLI_BIN=""
  if ! ENV_CLI_BIN=$(read_env_path CCLI 2>&1); then
    error "${ENV_CLI_BIN}"
  fi
  CURRENT_CLI_BIN="${ENV_CLI_BIN:-$(dirname "${CURRENT_NODE_BIN}")/cardano-cli}"
  [[ -x "${CURRENT_CLI_BIN}" && ! -L "${CURRENT_CLI_BIN}" ]] \
    || error "Configured cardano-cli is not a regular non-symlink executable: ${CURRENT_CLI_BIN}"
  CURRENT_VERSION=$("${CURRENT_NODE_BIN}" --version 2>/dev/null | head -1 | awk '{print $2}') \
    || CURRENT_VERSION="unknown"
  [[ "${CURRENT_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || error "Could not determine current semantic version from ${CURRENT_NODE_BIN}"
  if ! ACTIVE_BIN_DIR=$(infer_custom_binary_dir "${CURRENT_NODE_BIN}" "${CURRENT_VERSION}" \
      "${TARGET_VERSION}" "${BINARY_DIR_OVERRIDE}" 2>&1); then
    error "${ACTIVE_BIN_DIR}"
  fi
  validate_custom_binary_target "${ACTIVE_BIN_DIR}" "${INITIAL_PID}" \
    || error "Custom binary target validation failed"
  BINARY_DESTINATION_SOURCE="$( [[ -n "${BINARY_DIR_OVERRIDE}" ]] && echo explicit || echo inferred )"
  info "Active binary:  ${CURRENT_NODE_BIN}"
  info "Install path:   ${ACTIVE_BIN_DIR} (${BINARY_DESTINATION_SOURCE})"
else
  if [[ "${NETWORK}" == "mainnet" ]]; then
    ACTIVE_BIN_DIR="${BIN_DIR}"
  else
    ACTIVE_BIN_DIR="${HOME}/.local/cardano-node/${TARGET_VERSION}/bin"
  fi
  CURRENT_NODE_BIN="${ACTIVE_BIN_DIR}/cardano-node"
  CURRENT_CLI_BIN="${ACTIVE_BIN_DIR}/cardano-cli"
  if [[ "${NETWORK}" != "mainnet" && -f "${ENV_FILE}" ]]; then
    ENV_NODE_BIN=$(sed -n 's|^CNODEBIN="\{0,1\}\([^" ]*\)"\{0,1\}$|\1|p' "${ENV_FILE}" | head -1)
    [[ -x "${ENV_NODE_BIN:-}" ]] && CURRENT_NODE_BIN="${ENV_NODE_BIN}"
  fi
  CURRENT_CLI_BIN="$(dirname "${CURRENT_NODE_BIN}")/cardano-cli"
  CURRENT_VERSION=$("${CURRENT_NODE_BIN}" --version 2>/dev/null | head -1 | awk '{print $2}') \
    || CURRENT_VERSION="unknown"
  info "Install path:   ${ACTIVE_BIN_DIR}"
fi
[[ "$(readlink -f "/proc/${INITIAL_PID}/exe")" == "$(readlink -f "${CURRENT_NODE_BIN}")" ]] \
  || error "Active process is not using the expected current binary ${CURRENT_NODE_BIN}"
CURRENT_NODE_HASH_BEFORE=$(sha256sum "${CURRENT_NODE_BIN}" | awk '{print $1}')
CURRENT_CLI_HASH_BEFORE=$(sha256sum "${CURRENT_CLI_BIN}" | awk '{print $1}')
REUSE_INSTALLED_BINARIES=false
if [[ -z "${CUSTOM_URL}" && "${CURRENT_VERSION}" == "${TARGET_VERSION}" && -x "${CURRENT_CLI_BIN}" \
  && "$(dirname "${CURRENT_NODE_BIN}")" == "${ACTIVE_BIN_DIR}" ]]; then
  REUSE_INSTALLED_BINARIES=true
fi

# --- Choose LedgerDB backend -------------------------------------------------
if ${LEDGER_BACKEND_EXPLICIT}; then
  [[ "${LEDGER_BACKEND}" == "V2InMemory" || "${LEDGER_BACKEND}" == "V2LSM" ]] \
    || error "Invalid --ledger-backend '${LEDGER_BACKEND}'. Expected V2InMemory or V2LSM."
fi

if ${KEEP_CONFIG}; then
  if ${LEDGER_BACKEND_EXPLICIT} && [[ "${LEDGER_BACKEND}" != "${CURRENT_BACKEND}" ]]; then
    error "Changing LedgerDB backend requires --refresh-config (current: ${CURRENT_BACKEND}, requested: ${LEDGER_BACKEND})."
  fi
  LEDGER_BACKEND="${CURRENT_BACKEND}"
  info "LedgerDB backend: ${LEDGER_BACKEND} (unchanged)"
elif [[ -n "${LEDGER_BACKEND}" ]]; then
  info "LedgerDB backend: ${LEDGER_BACKEND}"
else
  LEDGER_BACKEND="${CURRENT_BACKEND}"
  info "LedgerDB backend: ${LEDGER_BACKEND}"
fi

if ! ${KEEP_CONFIG} && [[ "${NODE_ROLE}" == "bp" && "${LEDGER_BACKEND}" != "V2InMemory" ]]; then
  error "Block producers require --ledger-backend V2InMemory; V2LSM is only supported for relays"
fi

# --- Smart DB decision (unless --fresh-db already set) -----------------------
if [[ "${CURRENT_BACKEND}" != "${LEDGER_BACKEND}" ]]; then
  echo ""
  warn "LedgerDB backend changing from ${CURRENT_BACKEND} to ${LEDGER_BACKEND}."
  warn "The ledger formats are incompatible; a fresh database is required."
  ${FRESH_DB} || error "Backend changes require explicit --fresh-db; --yes does not authorize database replacement"
fi

if ${DRY_RUN}; then
  info "DRY RUN - validating real staged binaries/configuration in temporary scratch; no live changes"
fi

# --- Step 0: Download staged binaries ----------------------------------------
mkdir -p "${STAGED_BIN_DIR}"

if ${REUSE_INSTALLED_BINARIES}; then
  info "Step 0: Reusing installed cardano-node ${TARGET_VERSION} binaries..."
  install -m 0755 "${CURRENT_NODE_BIN}" "${STAGED_BIN_DIR}/cardano-node"
  install -m 0755 "${CURRENT_CLI_BIN}" "${STAGED_BIN_DIR}/cardano-cli"
else
  info "Step 0: Downloading cardano-node ${TARGET_VERSION} binaries..."
  DOWNLOAD_FILE="${WORK_DIR}/cardano-node.archive"

  # Verify URL is reachable before downloading
  HTTP_CODE=$(curl -sI -o /dev/null -w "%{http_code}" -L "${NODE_RELEASE_URL}" 2>/dev/null) || HTTP_CODE="000"
  if [[ "${HTTP_CODE}" != "200" && "${HTTP_CODE}" != "302" ]]; then
    error "Download URL returned HTTP ${HTTP_CODE}. Verify the version/arch exists:\n  ${NODE_RELEASE_URL}\n\nFor older ARM64 releases, you may need --url with a custom binary (e.g. Armada Alliance)."
  fi

  info "Downloading..."
  curl -L --fail --progress-bar "${NODE_RELEASE_URL}" -o "${DOWNLOAD_FILE}" \
    || error "Download failed from ${NODE_RELEASE_URL}"
  verify_cardano_archive_checksum "${DOWNLOAD_FILE}"

  # Clear staged directory for clean extraction
  rm -rf "${STAGED_BIN_DIR:?}"/*

  # Auto-detect compression format and extract
  _extract() {
    local file="$1" dest="$2"
    case "${NODE_RELEASE_URL}" in
      *.tar.zst)
        tar -I zstd -xf "${file}" -C "${dest}" --strip-components=1 ;;
      *.tar.gz|*.tgz)
        tar xzf "${file}" -C "${dest}" --strip-components=1 ;;
      *.tar.xz)
        tar xJf "${file}" -C "${dest}" --strip-components=1 ;;
      *)
        # Fallback: detect from file magic
        local ftype
        ftype=$(file -b "${file}" 2>/dev/null || echo "unknown")
        case "${ftype}" in
          *gzip*)      tar xzf "${file}" -C "${dest}" --strip-components=1 ;;
          *Zstandard*) tar -I zstd -xf "${file}" -C "${dest}" --strip-components=1 ;;
          *XZ*)        tar xJf "${file}" -C "${dest}" --strip-components=1 ;;
          *)           error "Unknown archive format: ${ftype}" ;;
        esac
        ;;
    esac
  }

_extract "${DOWNLOAD_FILE}" "${STAGED_BIN_DIR}"
rm -f "${DOWNLOAD_FILE}"
fi

# Handle tarballs that extract with a nested bin/ subdirectory (11.0.1+)
if [[ ! -x "${STAGED_BIN_DIR}/cardano-node" && -x "${STAGED_BIN_DIR}/bin/cardano-node" ]]; then
  mv "${STAGED_BIN_DIR}"/bin/* "${STAGED_BIN_DIR}"/
  rmdir "${STAGED_BIN_DIR}/bin" 2>/dev/null || true
  rm -rf "${STAGED_BIN_DIR}/share" 2>/dev/null || true
fi

info "Staged binaries ready in ${STAGED_BIN_DIR} ✓"

# --- Pre-flight checks -------------------------------------------------------
[[ -d "${STAGED_BIN_DIR}" ]] || error "Staged binaries not found at ${STAGED_BIN_DIR}"
[[ -x "${STAGED_BIN_DIR}/cardano-node" ]] || error "No cardano-node binary in ${STAGED_BIN_DIR}"
[[ -x "${STAGED_BIN_DIR}/cardano-cli" ]] || error "No cardano-cli binary in ${STAGED_BIN_DIR}"

STAGED_VERSION=$("${STAGED_BIN_DIR}/cardano-node" --version | head -1 | awk '{print $2}')
if [[ "${STAGED_VERSION}" != "${TARGET_VERSION}" ]]; then
  error "Staged binary is ${STAGED_VERSION}, expected ${TARGET_VERSION}"
fi
info "Staged binary version verified: ${STAGED_VERSION}"
STAGED_CLI_VERSION=$("${STAGED_BIN_DIR}/cardano-cli" --version | head -1 | awk '{print $2}')
[[ -n "${STAGED_CLI_VERSION}" ]] || error "Staged cardano-cli did not report a version"
info "Staged cardano-cli package version verified: ${STAGED_CLI_VERSION}"

TARGET_BINARY_DISPOSITION="standard"
if ${CUSTOM_INSTANCE}; then
  if ! TARGET_BINARY_DISPOSITION=$(classify_custom_binary_target \
      "${ACTIVE_BIN_DIR}" "${STAGED_BIN_DIR}" 2>&1); then
    error "${TARGET_BINARY_DISPOSITION}"
  fi
  info "Binary target:  ${TARGET_BINARY_DISPOSITION} (${ACTIVE_BIN_DIR})"
  TARGET_BINARY_STATE_BEFORE=$(snapshot_custom_binary_target "${ACTIVE_BIN_DIR}")
else
  TARGET_BINARY_STATE_BEFORE="standard"
fi

info "Current binary version: ${CURRENT_VERSION}"

if [[ "${CURRENT_VERSION}" == "${TARGET_VERSION}" ]]; then
  warn "Already running ${TARGET_VERSION}."
  if ! ${ASSUME_YES} && ! ${DRY_RUN}; then
    read -r -p "Continue anyway? [y/N]: " confirm
    [[ "${confirm}" =~ ^[yY] ]] || { info "Aborted."; exit 0; }
  fi
fi

prepare_activation() {
# --- Step 1: Install system dependencies -------------------------------------
if ! ${REUSE_INSTALLED_BINARIES}; then
info "Step 1: Installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq liburing-dev protobuf-compiler libsnappy-dev > /dev/null 2>&1
for pkg in liburing-dev protobuf-compiler libsnappy-dev; do
  dpkg -s "${pkg}" > /dev/null 2>&1 || error "Failed to install ${pkg}"
done
info "System dependencies installed ✓"
else
  info "Step 1: Reusing installed binaries; no package changes"
fi

# --- Step 2: Backup config files ---------------------------------------------
info "Step 2: Backing up config files..."
BACKUP_SUFFIX="${CURRENT_VERSION}-bak-$(date -u +%Y%m%dT%H%M%SZ)"
[[ ! -e "${FILES_DIR}-${BACKUP_SUFFIX}" && ! -e "${ENV_FILE}-${BACKUP_SUFFIX}" \
  && ! -e "${BACKUP_BIN_DIR}/${BACKUP_SCOPE}-${BACKUP_SUFFIX}" ]] || error "Backup path already exists; retry later"
cp -a "${FILES_DIR}" "${FILES_DIR}-${BACKUP_SUFFIX}"
cp -a "${ENV_FILE}" "${ENV_FILE}-${BACKUP_SUFFIX}"
cp -a "${PLAN_DIR}/plan.json" "${FILES_DIR}-${BACKUP_SUFFIX}/upgrade-plan.json"
python3 - "${FILES_DIR}-${BACKUP_SUFFIX}/upgrade-transaction.json" "${SERVICE_NAME}" \
  "${CURRENT_VERSION}" "${TARGET_VERSION}" "${ACTIVE_BIN_DIR}" \
  "${BACKUP_BIN_DIR}/${BACKUP_SCOPE}-${BACKUP_SUFFIX}" "${ENV_FILE}" "${ENV_HASH_BEFORE}" \
  "${DB_DIR}" "${FRESH_DB}" "${BACKUP_SUFFIX}" "${CURRENT_NODE_BIN}" \
  "${CURRENT_NODE_HASH_BEFORE}" "${CURRENT_CLI_BIN}" "${CURRENT_CLI_HASH_BEFORE}" \
  "${BINARY_DESTINATION_SOURCE}" "${TARGET_BINARY_DISPOSITION}" <<'PYEOF'
import json, pathlib, sys
output, service, old, new, binaries, backup, env, env_hash, db, fresh, suffix, current_binary, current_hash, current_cli, cli_hash, source, disposition = sys.argv[1:]
pathlib.Path(output).write_text(json.dumps({
    'service': service, 'previous_version': old, 'target_version': new,
    'current_binary': current_binary, 'current_binary_sha256': current_hash,
    'current_cli': current_cli, 'current_cli_sha256': cli_hash,
    'binary_directory': binaries,
    'binary_destination_source': source, 'binary_target_disposition': disposition,
    'binary_backup': backup,
    'environment': env, 'environment_backup': env + '-' + suffix,
    'environment_before_sha256': env_hash, 'database': db,
    'fresh_database_requested': fresh == 'true',
    'possible_database_backup': db + '-' + suffix if fresh == 'true' else None,
    'note': 'Prepared plan, not proof of activation; inspect upgrade-installed-files.txt and service state.'
}, indent=2) + '\n')
PYEOF
info "Config backed up to ${FILES_DIR}-${BACKUP_SUFFIX} ✓"
info "Guild environment backed up to ${ENV_FILE}-${BACKUP_SUFFIX} ✓"

# --- Step 3: Backup current binaries -----------------------------------------
info "Step 3: Backing up current binaries..."
BINARY_BACKUP_DIR="${BACKUP_BIN_DIR}/${BACKUP_SCOPE}-${BACKUP_SUFFIX}"
mkdir -p "${BINARY_BACKUP_DIR}"
while IFS= read -r -d '' staged_file; do
  binary_name=$(basename "${staged_file}")
  if [[ -f "${ACTIVE_BIN_DIR}/${binary_name}" ]]; then
    cp -a "${ACTIVE_BIN_DIR}/${binary_name}" "${BINARY_BACKUP_DIR}/${binary_name}"
  fi
done < <(find "${STAGED_BIN_DIR}" -maxdepth 1 -type f -print0)
info "Existing binaries backed up to ${BINARY_BACKUP_DIR} ✓"
}

# --- Step 4: Stage official network configuration ----------------------------
CONFIG_STAGE_DIR="${WORK_DIR}/config-stage"
mkdir -p "${CONFIG_STAGE_DIR}"
if ${KEEP_CONFIG}; then
  info "Step 4: Keeping custom configuration; staging Praos normalization only"
  cp -a "${FILES_DIR}/config.json" "${CONFIG_STAGE_DIR}/config.json"
  if version_at_least "${TARGET_VERSION}" "11.1.2"; then
    remove_legacy_tracer_keys "${CONFIG_STAGE_DIR}/config.json"
  fi
else
  info "Step 4: Staging official ${NETWORK} configuration..."
  curl -fsSL "${CONFIG_BASE_URL}/config.json" -o "${CONFIG_STAGE_DIR}/config.json"

  python3 - "${CONFIG_STAGE_DIR}/config.json" > "${WORK_DIR}/referenced-files" <<'PYEOF'
import json, os, sys
c = json.load(open(sys.argv[1]))
allowed = {'byron-genesis.json', 'shelley-genesis.json', 'alonzo-genesis.json',
           'conway-genesis.json', 'checkpoints.json'}
for key, value in c.items():
    if key.endswith("File") and isinstance(value, str) and value.endswith(".json"):
        name = os.path.basename(value)
        if name not in allowed:
            raise SystemExit(f'Unsupported official config dependency {key}={value}; review before upgrade')
        print(name)
PYEOF
  mapfile -t REFERENCED_FILES < "${WORK_DIR}/referenced-files"
  for file_name in "${REFERENCED_FILES[@]}"; do
    [[ "$(basename "${file_name}")" != "topology.json" ]] \
      || error "Refusing to stage protected topology.json from network config"
    curl -fsSL "${CONFIG_BASE_URL}/${file_name}" -o "${CONFIG_STAGE_DIR}/${file_name}"
  done

  # Apply all edits via Python for reliability
  CONFIG_STAGE_DIR="${CONFIG_STAGE_DIR}" \
  FILES_DIR="${FILES_DIR}" \
  EXPECTED_NETWORK_MAGIC="${EXPECTED_NETWORK_MAGIC}" \
  TOPOLOGY_P2P="${TOPOLOGY_P2P}" \
  PROM_BIND="${PROM_BIND}" \
  PROM_PORT="${PROM_PORT}" \
  LEDGER_BACKEND="${LEDGER_BACKEND}" \
  NODE_ROLE="${NODE_ROLE}" \
  python3 << 'PYEOF'
import hashlib, json, os, pathlib

stage_dir = pathlib.Path(os.environ["CONFIG_STAGE_DIR"])
files_dir = pathlib.Path(os.environ["FILES_DIR"])
config_path = stage_dir / "config.json"
prom_bind = os.environ["PROM_BIND"]
prom_port = int(os.environ["PROM_PORT"])
ledger_backend = os.environ["LEDGER_BACKEND"]
node_role = os.environ["NODE_ROLE"]
topology_p2p = os.environ["TOPOLOGY_P2P"] == "true"

c = json.loads(config_path.read_text())
previous = json.loads((files_dir / 'config.json').read_text())
for era in ('Byron', 'Shelley', 'Alonzo', 'Conway'):
  key = era + 'GenesisHash'
  if key in previous:
    assert previous[key] == c.get(key), f'{key} would change network identity; review manually'

for key, value in list(c.items()):
  if key.endswith("File") and isinstance(value, str) and value.endswith(".json"):
    c[key] = str(files_dir / pathlib.Path(value).name)

# Guild Operators compat fields
c["EnableP2P"] = topology_p2p
if node_role == "bp":
  c["PeerSharing"] = False
elif "PeerSharing" in previous:
  c["PeerSharing"] = previous["PeerSharing"]
else:
  c.pop("PeerSharing", None)
c["ConsensusMode"] = "PraosMode"

# Prometheus bind in TraceOptions
backends = c.get("TraceOptions", {}).get("", {}).get("backends", [])
c["TraceOptions"][""]["backends"] = [
  f"PrometheusSimple suffix {prom_bind} {prom_port}" if "PrometheusSimple" in b else b
    for b in backends
]
if not any("PrometheusSimple" in b for b in c["TraceOptions"][""]["backends"]):
  c["TraceOptions"][""]["backends"].append(f"PrometheusSimple suffix {prom_bind} {prom_port}")

# LedgerDB backend
if "LedgerDB" in c:
    c["LedgerDB"]["Backend"] = ledger_backend

# OpenBlockPerf traces (relay only)
if node_role == "relay":
    to = c.get("TraceOptions", {})
    to.setdefault("BlockFetch.Client.SendFetchRequest", {})["severity"] = "Info"
    to.setdefault("BlockFetch.Client.CompletedBlockFetch", {}).update({"severity": "Info", "maxFrequency": 4.0})
    to.setdefault("ChainDB.AddBlockEvent.AddedToCurrentChain", {})["severity"] = "Info"
    to.setdefault("ChainDB.AddBlockEvent.SwitchedToAFork", {})["severity"] = "Info"
    to.setdefault("ChainSync.Client.DownloadedHeader", {}).update({"severity": "Info", "maxFrequency": 14.0})
    if "Net.ConnectionManager.Remote" in to:
        to["Net.ConnectionManager.Remote"]["severity"] = "Info"

config_path.write_text(json.dumps(c, indent=2) + "\n")

expected_magic = int(os.environ["EXPECTED_NETWORK_MAGIC"])
shelley = json.loads((stage_dir / pathlib.Path(c["ShelleyGenesisFile"]).name).read_text())
assert shelley["networkMagic"] == expected_magic, "network magic mismatch"

if "CheckpointsFile" in c and "CheckpointsFileHash" in c:
    data = (stage_dir / pathlib.Path(c["CheckpointsFile"]).name).read_bytes()
    actual = hashlib.blake2b(data, digest_size=32).hexdigest()
    assert actual == c["CheckpointsFileHash"], "CheckpointsFile hash mismatch"

print("Config patched successfully")
PYEOF

  for genesis in byron shelley alonzo conway; do
    hash_key="${genesis^}GenesisHash"
    expected_hash=$(jq -r ".${hash_key}" "${CONFIG_STAGE_DIR}/config.json")
    if [[ "${genesis}" == "byron" ]]; then
      actual_hash=$("${STAGED_BIN_DIR}/cardano-cli" byron genesis print-genesis-hash \
        --genesis-json "${CONFIG_STAGE_DIR}/${genesis}-genesis.json")
    else
      actual_hash=$("${STAGED_BIN_DIR}/cardano-cli" hash genesis-file \
        --genesis "${CONFIG_STAGE_DIR}/${genesis}-genesis.json")
    fi
    [[ "${actual_hash}" == "${expected_hash}" ]] \
      || error "${genesis^} genesis hash mismatch"
  done

  # Validate final config
  python3 -c "
import json
config_path = '${CONFIG_STAGE_DIR}/config.json'
c = json.load(open(config_path))
assert c['LedgerDB']['Backend'] == '${LEDGER_BACKEND}', 'Wrong backend'
assert c['EnableP2P'] is ${TOPOLOGY_P2P^}, 'Topology/P2P mode mismatch'
assert c['ConsensusMode'] == 'PraosMode', 'PraosMode is required for all topology types'
prom_line = [b for b in c['TraceOptions']['']['backends'] if 'PrometheusSimple' in b]
assert prom_line == ['PrometheusSimple suffix ${PROM_BIND} ${PROM_PORT}'], 'Prometheus endpoint wrong'
print('Config validation passed ✓')
" || error "Config validation failed"

  info "Official config, genesis hashes, network magic, and metrics validated ✓"
fi

# Both keep and refresh use the same topology recovery and normalization policy.
PLAN_DIR="${WORK_DIR}/final-plan"
python3 "${CONFIG_PLANNER}" "${PLANNER_ARGS[@]}" --config "${CONFIG_STAGE_DIR}/config.json" \
  --output-dir "${PLAN_DIR}" || error "Final Praos plan failed; no live files changed"
[[ "$(jq -r '.topology_after_sha256' "${PLAN_DIR}/plan.json")" \
  == "$(jq -r '.topology_after_sha256' "${WORK_DIR}/initial-plan/plan.json")" ]] \
  || error "Topology selection changed while staging; review and retry"

# Validate preserved network files as well as freshly downloaded ones. Versioned
# binaries do not make the Operations Book's moving config URL version-pinned.
python3 - "${PLAN_DIR}/config.json" "${TARGET_VERSION}" "${EXPECTED_NETWORK_MAGIC}" \
  "${FILES_DIR}" "${CONFIG_STAGE_DIR}" "${WORK_DIR}/network-dependencies.json" <<'PYEOF'
import hashlib, json, pathlib, sys
config_path, target, magic, live, stage, output = sys.argv[1:]
c = json.loads(pathlib.Path(config_path).read_text())
version = lambda v: tuple(map(int, v.split('.')))
assert version(target) >= version(c.get('MinNodeVersion', '0.0.0')), 'Official config requires a newer node'
assert c['ConsensusMode'] == 'PraosMode', 'Expected PraosMode'
deps = {}
for prefix in ('ByronGenesis', 'ShelleyGenesis', 'AlonzoGenesis', 'ConwayGenesis', 'Checkpoints'):
    if prefix == 'Checkpoints' and prefix + 'File' not in c:
        continue
    reference = pathlib.Path(c[prefix + 'File'])
    path = pathlib.Path(stage) / reference.name
    if not path.exists():
        path = pathlib.Path(live) / reference
    data = path.read_bytes()
    deps[str(path.resolve())] = hashlib.sha256(data).hexdigest()
    if prefix == 'ShelleyGenesis':
        assert json.loads(data)['networkMagic'] == int(magic), 'Wrong network magic'
    if prefix != 'ByronGenesis':
      hash_key = 'CheckpointsFileHash' if prefix == 'Checkpoints' else prefix + 'Hash'
      assert hashlib.blake2b(data, digest_size=32).hexdigest() == c[hash_key], f'{prefix} hash mismatch'
pathlib.Path(output).write_text(json.dumps(deps))
PYEOF
BYRON_REFERENCE=$(jq -r '.ByronGenesisFile' "${PLAN_DIR}/config.json")
BYRON_PATH="${CONFIG_STAGE_DIR}/$(basename "${BYRON_REFERENCE}")"
if [[ ! -f "${BYRON_PATH}" ]]; then
  BYRON_PATH="${BYRON_REFERENCE}"
  [[ "${BYRON_PATH}" == /* ]] || BYRON_PATH="${FILES_DIR}/${BYRON_PATH}"
fi
[[ "$("${STAGED_BIN_DIR}/cardano-cli" byron genesis print-genesis-hash --genesis-json "${BYRON_PATH}")" \
  == "$(jq -r '.ByronGenesisHash' "${PLAN_DIR}/config.json")" ]] || error "Byron genesis hash mismatch"

verify_plan_inputs() {
  python3 - "${WORK_DIR}/initial-plan/plan.json" "${PLAN_DIR}/plan.json" \
    "${WORK_DIR}/network-dependencies.json" "${ENV_FILE}" "${ENV_HASH_BEFORE}" <<'PYEOF' || return 1
import hashlib, json, pathlib, sys
initial, final, network, env, env_hash = sys.argv[1:]
digest = lambda p: hashlib.sha256(pathlib.Path(p).read_bytes()).hexdigest()
for manifest in (initial, final):
    plan = json.loads(pathlib.Path(manifest).read_text())
    for path, expected in plan['dependencies'].items():
        assert digest(path) == expected, f'Input changed since planning: {path}'
    directory = pathlib.Path(manifest).parent
    for name, key in (('config.json', 'config_after_sha256'), ('topology.json', 'topology_after_sha256')):
        assert digest(directory / name) == plan[key], f'Staged artifact changed: {name}'
for path, expected in json.loads(pathlib.Path(network).read_text()).items():
    assert digest(path) == expected, f'Network dependency changed: {path}'
assert digest(env) == env_hash, 'Guild env changed since planning'
PYEOF
  [[ "$(sha256sum "${CURRENT_NODE_BIN}" | awk '{print $1}')" == "${CURRENT_NODE_HASH_BEFORE}" ]] \
    || { echo "Current cardano-node changed since planning" >&2; return 1; }
  [[ "$(sha256sum "${CURRENT_CLI_BIN}" | awk '{print $1}')" == "${CURRENT_CLI_HASH_BEFORE}" ]] \
    || { echo "Current cardano-cli changed since planning" >&2; return 1; }
  if ${CUSTOM_INSTANCE}; then
    validate_custom_binary_target "${ACTIVE_BIN_DIR}" "${INITIAL_PID}" || return 1
    [[ "$(snapshot_custom_binary_target "${ACTIVE_BIN_DIR}")" == "${TARGET_BINARY_STATE_BEFORE}" ]] \
      || { echo "Custom binary target changed since planning" >&2; return 1; }
  fi
}
verify_plan_inputs || error "Inputs changed; refusing to overwrite concurrent changes"
TOPOLOGY_HASH_EXPECTED=$(jq -r '.topology_after_sha256' "${PLAN_DIR}/plan.json")
info "Consensus: PraosMode; topology $(jq -r '.decision' "${PLAN_DIR}/plan.json")"
info "Snapshot: $(jq -r '.snapshot_status' "${PLAN_DIR}/plan.json") (no snapshot files deleted)"
info "Database: $(${FRESH_DB} && echo 'explicit replacement requested' || echo 'preserved'); backend: ${LEDGER_BACKEND}"
info "Restart required: on-disk equality cannot prove the running process loaded these bytes"
if ${DRY_RUN}; then
  info "Dry run passed: staged configuration and network hashes validated; no live files or service changed"
  exit 0
fi

prepare_activation
verify_plan_inputs || error "Inputs changed during backup; refusing activation"
[[ "$(systemctl show -p MainPID --value "${SERVICE_NAME}")" == "${INITIAL_PID}" ]] \
  || error "Service process changed during planning; retry"

# --- Step 5: Stop the node ---------------------------------------------------
info "Step 5: Stopping ${SERVICE_NAME}..."
ROLLBACK_ARMED=true
trap rollback_on_exit EXIT
if systemctl is-active --quiet "${SERVICE_NAME}"; then
  NODE_WAS_ACTIVE=true
  sudo systemctl stop "${SERVICE_NAME}"
  # Wait for clean shutdown
  for i in $(seq 1 12); do
    systemctl is-active --quiet "${SERVICE_NAME}" || break
    sleep 5
  done
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    error "Service did not stop within 60 seconds"
  fi
  info "Service stopped ✓"
else
  error "Service stopped unexpectedly before activation; no installation attempted"
fi
[[ "$(systemctl show -p ActiveState --value "${SERVICE_NAME}")" == "inactive" ]] \
  || error "Service is not confirmed inactive; refusing installation"
verify_plan_inputs || error "Inputs changed during shutdown; refusing installation"

# Record each replacement BEFORE installation so a partial failure is reversible.
install_config_file() {
  local source="$1" name destination temporary
  name=$(basename "${source}")
  destination="${FILES_DIR}/${name}"
  cmp -s "${source}" "${destination}" && return 0
  [[ ! -L "${destination}" ]] || error "Refusing to replace symlink: ${destination}"
  CONFIG_INSTALLED_FILES+=("${name}")
  printf '%s\n' "${name}" >> "${FILES_DIR}-${BACKUP_SUFFIX}/upgrade-installed-files.txt"
  temporary=$(mktemp "${FILES_DIR}/.upgrade-${name}.XXXXXX")
  cp -- "${source}" "${temporary}"
  if [[ -f "${destination}" ]]; then
    chmod --reference="${destination}" "${temporary}"
    chown --reference="${destination}" "${temporary}"
  else
    chmod 0644 "${temporary}"
  fi
  mv -f -- "${temporary}" "${destination}"
}
while IFS= read -r -d '' config_file; do
  install_config_file "${config_file}"
done < <(find "${CONFIG_STAGE_DIR}" -maxdepth 1 -type f ! -name config.json -print0)
install_config_file "${PLAN_DIR}/config.json"
install_config_file "${PLAN_DIR}/topology.json"
info "Validated Praos configuration installed ✓"

TOPOLOGY_HASH_AFTER=$(sha256sum "${TOPOLOGY_FILE}" | awk '{print $1}')
[[ "${TOPOLOGY_HASH_AFTER}" == "${TOPOLOGY_HASH_EXPECTED}" ]] \
  || error "Topology does not match the approved plan; service will not be started"
[[ "$(sha256sum "${FILES_DIR}/config.json" | awk '{print $1}')" \
  == "$(jq -r '.config_after_sha256' "${PLAN_DIR}/plan.json")" ]] || error "Installed config differs from plan"
info "Topology matches approved plan ✓"

# --- Step 6: Copy new binaries -----------------------------------------------
info "Step 6: Installing new binaries..."
if ! ${REUSE_INSTALLED_BINARIES} \
  && [[ "${TARGET_BINARY_DISPOSITION}" != "reuse" ]]; then
  BINARY_CHANGED=true
  if ${CUSTOM_INSTANCE}; then
    install_custom_binaries "${ACTIVE_BIN_DIR}" "${STAGED_BIN_DIR}"
  else
    mkdir -p "${ACTIVE_BIN_DIR}"
    while IFS= read -r -d '' staged_file; do
      binary_name=$(basename "${staged_file}")
      install -m 0755 "${staged_file}" "${ACTIVE_BIN_DIR}/.${binary_name}.new"
      mv -f "${ACTIVE_BIN_DIR}/.${binary_name}.new" "${ACTIVE_BIN_DIR}/${binary_name}"
    done < <(find "${STAGED_BIN_DIR}" -maxdepth 1 -type f -print0)
  fi
fi

if ${CUSTOM_INSTANCE}; then
  validate_custom_binary_target "${ACTIVE_BIN_DIR}" "${INITIAL_PID}" \
    || error "Custom binary target changed after installation"
  [[ "$(classify_custom_binary_target "${ACTIVE_BIN_DIR}" "${STAGED_BIN_DIR}")" == "reuse" ]] \
    || error "Installed custom binaries do not match the staged package"
  INSTALLED_VERSION="${STAGED_VERSION}"
else
  INSTALLED_VERSION=$("${ACTIVE_BIN_DIR}/cardano-node" --version | head -1 | awk '{print $2}')
fi
if [[ "${INSTALLED_VERSION}" != "${TARGET_VERSION}" ]]; then
  error "Installed version ${INSTALLED_VERSION} != expected ${TARGET_VERSION}"
fi
info "Binaries installed: cardano-node ${INSTALLED_VERSION} ✓"

if ${CUSTOM_INSTANCE} || [[ "${NETWORK}" != "mainnet" ]]; then
  ENV_CHANGED=true
  set_env_value "${ENV_FILE}" CNODEBIN "${ACTIVE_BIN_DIR}/cardano-node"
  if [[ -x "${ACTIVE_BIN_DIR}/cardano-cli" ]]; then
    set_env_value "${ENV_FILE}" CCLI "${ACTIVE_BIN_DIR}/cardano-cli"
  fi
fi
info "Guild binary settings updated; existing metrics settings preserved ✓"

# --- Step 7: Handle database (keep or fresh Mithril) ------------------------
if ${FRESH_DB}; then
  info "Step 7: --fresh-db specified — backing up DB and deploying Mithril snapshot..."

  # Disk space preflight
  info "  Checking free disk space before snapshot deploy..."
  check_snapshot_disk_space

  if [[ -d "${DB_DIR}" ]]; then
    DB_BACKUP="${DB_DIR}-${BACKUP_SUFFIX}"
    [[ ! -e "${DB_BACKUP}" ]] || error "Refusing to overwrite DB backup ${DB_BACKUP}"
    mv "${DB_DIR}" "${DB_BACKUP}"
    info "DB renamed to ${DB_BACKUP}"
  else
    warn "No database directory found at ${DB_DIR}"
  fi

  MITHRIL_SCRIPT="${HOME}/DeployMithrilUncompressOnTheFly.sh"
  MITHRIL_SCRIPT_URL="https://raw.githubusercontent.com/CryptoBlocks-pro/public/main/Cardano/DeployMithrilUncompressOnTheFly.sh"

  official_deploy_ok=false
  if install_mithril_client && deploy_snapshot_with_official_client; then
    official_deploy_ok=true
    info "Mithril snapshot deployed via official mithril-client ✓"
  else
    warn "Official mithril-client deploy failed or unavailable, falling back to custom deploy script"
  fi

  if [[ "${official_deploy_ok}" != "true" && "${NETWORK}" == "mainnet" ]]; then
    if [[ ! -x "${MITHRIL_SCRIPT}" ]]; then
      info "Mithril deploy script not found — downloading..."
      curl -sL "${MITHRIL_SCRIPT_URL}" -o "${MITHRIL_SCRIPT}"
      chmod +x "${MITHRIL_SCRIPT}"
      [[ -x "${MITHRIL_SCRIPT}" ]] || error "Failed to download Mithril deploy script"
      info "Downloaded ${MITHRIL_SCRIPT} ✓"
    fi

    info "Deploying fresh Mithril snapshot to ${DB_DIR} with fallback script..."
    "${MITHRIL_SCRIPT}" --path "${DB_DIR}" --yes
    info "Mithril snapshot deployed via fallback script ✓"
  elif [[ "${official_deploy_ok}" != "true" ]]; then
    error "Official Mithril snapshot deploy failed for ${NETWORK}; the mainnet-only fallback was not used"
  fi

  # Ensure db metadata file exists for node startup
  ensure_protocol_magic_id
else
  info "Step 7: Keeping existing database (use --fresh-db if DB format changed)"
fi

# --- Step 8: Start the node --------------------------------------------------
info "Step 8: Starting ${SERVICE_NAME}..."
sudo systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true
VALIDATION_STARTED_AT=$(date --iso-8601=seconds)
sudo systemctl start "${SERVICE_NAME}"

# Wait for service to become active or show early failure
STARTED=false
for i in $(seq 1 12); do
  sleep 5
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    STARTED=true
    break
  fi
  # Check if it failed immediately
  STATUS=$(systemctl show -p ActiveState --value "${SERVICE_NAME}")
  if [[ "${STATUS}" == "failed" ]]; then
    echo ""
    error "Service failed to start. Check: journalctl -u ${SERVICE_NAME} --no-hostname -n 30 --no-pager"
  fi
done

if ! ${STARTED}; then
  STATUS=$(systemctl show -p ActiveState --value "${SERVICE_NAME}")
  error "Service did not become active within 60 seconds (status: ${STATUS})"
fi
VALIDATION_INVOCATION=$(systemctl show -p InvocationID --value "${SERVICE_NAME}")
[[ "${VALIDATION_INVOCATION}" =~ ^[[:xdigit:]]{32}$ ]] || error "Cannot determine new service invocation"
VALIDATION_PID=$(systemctl show -p MainPID --value "${SERVICE_NAME}")
verify_service_process "${VALIDATION_PID}" "${ACTIVE_BIN_DIR}/cardano-node" \
  || error "Restarted service does not match the approved instance"

# --- Step 9: Validate -------------------------------------------------------
info "Step 9: Validating upgraded node startup..."
METRICS_VERSION=""
ACTIVE_PEERS=""
METRICS_SLOT=""
STARTUP_STATE=""
VALIDATION_INTERVAL_SECONDS=5
[[ "${STARTUP_VALIDATION_TIMEOUT_SECONDS}" =~ ^[1-9][0-9]*$ ]] \
  || error "STARTUP_VALIDATION_TIMEOUT_SECONDS must be a positive integer"
VALIDATION_START_SECONDS=${SECONDS}

while (( SECONDS - VALIDATION_START_SECONDS < STARTUP_VALIDATION_TIMEOUT_SECONDS )); do
  ELAPSED=$((SECONDS - VALIDATION_START_SECONDS))
  SERVICE_STATE=$(systemctl is-active "${SERVICE_NAME}" 2>/dev/null || true)
  MAIN_PID=$(systemctl show -p MainPID --value "${SERVICE_NAME}" 2>/dev/null || true)
  PROCESS_EXE=""
  if [[ "${MAIN_PID}" =~ ^[1-9][0-9]*$ ]]; then
    PROCESS_EXE=$(readlink -f "/proc/${MAIN_PID}/exe" 2>/dev/null || true)
  fi

  info "  ${ELAPSED}s service: $([[ "${SERVICE_STATE}" == "active" ]] && echo PASS || echo FAIL) (state=${SERVICE_STATE:-unknown}, pid=${MAIN_PID:-unavailable})"
  [[ "${SERVICE_STATE}" == "active" ]] || error "Service stopped during post-upgrade validation"
  [[ "${MAIN_PID}" == "${VALIDATION_PID}" && \
    "$(systemctl show -p InvocationID --value "${SERVICE_NAME}")" == "${VALIDATION_INVOCATION}" ]] \
    || error "Service restarted during startup validation"
  info "  ${ELAPSED}s process: $([[ "${PROCESS_EXE}" == "${ACTIVE_BIN_DIR}/cardano-node" ]] && echo PASS || echo PENDING) (executable=${PROCESS_EXE:-unavailable})"

  JOURNAL_TEXT=$(journalctl -q -u "${SERVICE_NAME}" "_SYSTEMD_INVOCATION_ID=${VALIDATION_INVOCATION}" \
    --since "${VALIDATION_STARTED_AT}" --no-hostname --no-pager) \
    || error "Journal probe failed; cannot claim no startup errors"
  JOURNAL_FAILURES=$(grep -Ei '(\((Error|Critical|Alert|Emergency),|(^|[^[:alpha:]])(fatal|panic)([^[:alpha:]]|$)|uncaught exception)' \
    <<<"${JOURNAL_TEXT}" | grep -Ev 'Net\.PeerSelection\.Actions\.(ConnectionError|StatusChangeFailure)' || true)
  JOURNAL_PRIORITY_TEXT=$(journalctl -q -u "${SERVICE_NAME}" "_SYSTEMD_INVOCATION_ID=${VALIDATION_INVOCATION}" \
    --since "${VALIDATION_STARTED_AT}" -p emerg..err --no-hostname --no-pager) \
    || error "Journal priority probe failed; startup error status is unknown"
  JOURNAL_PRIORITY_FAILURES=$(grep -Ev 'Net\.PeerSelection\.Actions\.(ConnectionError|StatusChangeFailure)' \
    <<<"${JOURNAL_PRIORITY_TEXT}" || true)
  if [[ -n "${JOURNAL_PRIORITY_FAILURES}" ]]; then
    JOURNAL_FAILURES="${JOURNAL_FAILURES}${JOURNAL_FAILURES:+$'\n'}${JOURNAL_PRIORITY_FAILURES}"
  fi
  if [[ -n "${JOURNAL_FAILURES}" ]]; then
    echo "${JOURNAL_FAILURES}" >&2
    error "Fatal/error journal entries detected after starting the upgraded node"
  fi
  info "  ${ELAPSED}s journal errors: PASS (queries succeeded; none detected)"

  PROM_RESPONSE=$(curl -sf --max-time 5 "http://localhost:${PROM_PORT}/metrics" 2>/dev/null) || PROM_RESPONSE=""
  METRICS_VERSION=$(awk '/cardano_node_metrics_cardano_build_info/ && match($0, /version="[^"]+"/) { print substr($0, RSTART + 9, RLENGTH - 10); exit }' <<<"${PROM_RESPONSE}")
  ACTIVE_PEERS=$(awk '$1 == "cardano_node_metrics_peerSelection_ActivePeers_int" { print int($2); exit }' <<<"${PROM_RESPONSE}")
  METRICS_SLOT=$(awk '$1 == "cardano_node_metrics_slotNum_int" { print int($2); exit }' <<<"${PROM_RESPONSE}")
  info "  ${ELAPSED}s metrics: $([[ "${METRICS_VERSION}" == "${TARGET_VERSION}" ]] && echo PASS || echo PENDING) (version=${METRICS_VERSION:-unavailable}, slot=${METRICS_SLOT:-unavailable}, activePeers=${ACTIVE_PEERS:-unavailable})"

  REPLAY_LINE=$(grep -E 'LedgerReplay|ChainDB\.ImmDbEvent\.ChunkValidation' <<<"${JOURNAL_TEXT}" | tail -1 || true)
  REPLAY_PROGRESS=$(awk 'match($0, /Progress: [0-9.]+%/) { print substr($0, RSTART, RLENGTH) }' <<<"${REPLAY_LINE}")

  if [[ "${METRICS_SLOT}" =~ ^[0-9]+$ && "${METRICS_SLOT}" -gt 0 ]]; then
    STARTUP_STATE="running (sync not established)"
    info "  ${ELAPSED}s node activity: PASS (state=${STARTUP_STATE}, slot=${METRICS_SLOT})"
  elif [[ -n "${REPLAY_LINE}" ]]; then
    STARTUP_STATE="replaying/validating"
    info "  ${ELAPSED}s node activity: PASS (state=${STARTUP_STATE}, ${REPLAY_PROGRESS:-journal activity detected})"
  elif [[ "${METRICS_SLOT}" == "0" ]]; then
    STARTUP_STATE="starting"
    info "  ${ELAPSED}s node activity: PASS (state=${STARTUP_STATE}; equivalent to gLiveView slotNum=0)"
  else
    STARTUP_STATE=""
    info "  ${ELAPSED}s node activity: PENDING (waiting for metrics or replay journal activity)"
  fi

  if [[ "${PROCESS_EXE}" == "${ACTIVE_BIN_DIR}/cardano-node" \
    && "${METRICS_VERSION}" == "${TARGET_VERSION}" \
    && -n "${STARTUP_STATE}" ]]; then
    break
  fi
  sleep 5
done

[[ "${PROCESS_EXE}" == "${ACTIVE_BIN_DIR}/cardano-node" ]] \
  || error "Service did not run ${ACTIVE_BIN_DIR}/cardano-node within ${STARTUP_VALIDATION_TIMEOUT_SECONDS} seconds"
[[ "${METRICS_VERSION}" == "${TARGET_VERSION}" ]] \
  || error "Prometheus did not report target version ${TARGET_VERSION} within ${STARTUP_VALIDATION_TIMEOUT_SECONDS} seconds"
[[ -n "${STARTUP_STATE}" ]] \
  || error "No startup, replay, validation, or normal slot activity was detected within ${STARTUP_VALIDATION_TIMEOUT_SECONDS} seconds"
info "Startup validation passed: cardano-node ${METRICS_VERSION} is ${STARTUP_STATE} ✓"

if [[ "${ACTIVE_PEERS}" =~ ^[0-9]+$ && "${ACTIVE_PEERS}" -gt 0 ]]; then
  info "  Peer observation: PASS (${ACTIVE_PEERS} active peer(s))"
else
  warn "Peer observation: PENDING (${ACTIVE_PEERS:-unavailable} active peers; expected while ${STARTUP_STATE})"
fi

SOCKET_PATH="${CNODE_HOME}/sockets/node.socket"
NETWORK_ARGS=(--testnet-magic "${EXPECTED_NETWORK_MAGIC}")
[[ "${NETWORK}" == "mainnet" ]] && NETWORK_ARGS=(--mainnet)
[[ -x "${ACTIVE_BIN_DIR}/cardano-cli" ]] || error "Matching cardano-cli was not installed"
TIP_JSON=""
if [[ -S "${SOCKET_PATH}" ]]; then
  TIP_JSON=$(CARDANO_NODE_SOCKET_PATH="${SOCKET_PATH}" timeout 10s \
    "${ACTIVE_BIN_DIR}/cardano-cli" query tip "${NETWORK_ARGS[@]}" 2>/dev/null) || TIP_JSON=""
fi
if [[ -n "${TIP_JSON}" ]]; then
  TIP_BLOCK=$(jq -r '.block // 0' <<<"${TIP_JSON}")
  TIP_SLOT=$(jq -r '.slot // 0' <<<"${TIP_JSON}")
  SYNC_PROGRESS=$(jq -r '.syncProgress // "0"' <<<"${TIP_JSON}")
  info "  Tip observation: PASS (block=${TIP_BLOCK}, slot=${TIP_SLOT}, syncProgress=${SYNC_PROGRESS}%)"
else
  warn "Tip observation: PENDING (socket query unavailable while ${STARTUP_STATE})"
fi

systemctl is-active --quiet "${SERVICE_NAME}" || error "Service stopped after tip probe"
[[ "$(systemctl show -p MainPID --value "${SERVICE_NAME}")" == "${VALIDATION_PID}" && \
  "$(systemctl show -p InvocationID --value "${SERVICE_NAME}")" == "${VALIDATION_INVOCATION}" ]] \
  || error "Service restarted after validation"
[[ "$(sha256sum "${TOPOLOGY_FILE}" | awk '{print $1}')" == "${TOPOLOGY_HASH_EXPECTED}" && \
  "$(sha256sum "${FILES_DIR}/config.json" | awk '{print $1}')" == "$(jq -r '.config_after_sha256' "${PLAN_DIR}/plan.json")" ]] \
  || error "Installed config/topology changed during startup"
verify_service_process "${VALIDATION_PID}" "${ACTIVE_BIN_DIR}/cardano-node" \
  || error "Validated service no longer matches the approved instance"
info "PraosMode configured at verified startup path; runtime consensus is not independently exposed by these probes"
info "Startup accepted; full synchronization and peer-serving readiness are separate observations"
ROLLBACK_ARMED=false
trap cleanup_workspace EXIT

# Show recent logs
echo ""
info "=== Recent logs ==="
journalctl -u "${SERVICE_NAME}" "_SYSTEMD_INVOCATION_ID=${VALIDATION_INVOCATION}" --no-hostname -n 10 --no-pager 2>/dev/null || true

echo ""
info "============================================"
info "Upgrade to ${TARGET_VERSION} complete!"
info "============================================"
info ""
info "Post-upgrade checklist:"
info "  1. Monitor sync: journalctl -u ${SERVICE_NAME} -f --no-hostname"
info "  2. Check Prometheus: curl -s http://localhost:${PROM_PORT}/metrics | head -20"
info "  3. Monitor startup/replay: ${CNODE_HOME}/scripts/gLiveView.sh"
if ! ${FRESH_DB}; then
  info ""
  info "  Replay/validation after an upgrade is expected and does not indicate failure."
  info "  Do not use --fresh-db unless the release requires it or replay reports an error."
fi
if [[ "${NODE_ROLE}" == "relay" ]]; then
  info "  4. Verify OpenBlockPerf: journalctl -u ${SERVICE_NAME} --no-hostname | grep CompletedBlockFetch"
fi
info ""
info "Recovery backups (retain all until operational checks pass):"
info "  Config/topology and plan: ${FILES_DIR}-${BACKUP_SUFFIX}"
info "  Guild env: ${ENV_FILE}-${BACKUP_SUFFIX}"
info "  Binaries: ${BINARY_BACKUP_DIR}"
info "  Database: ${DB_BACKUP:-unchanged; not backed up by this run}"
info "For interrupted-run/manual recovery, follow upgrade-cardano-node-notes.md; restore the matching binaries and config together."
