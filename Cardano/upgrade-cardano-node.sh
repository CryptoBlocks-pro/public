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
#   ./upgrade-cardano-node.sh                          # auto-detect latest
#   ./upgrade-cardano-node.sh --network preview --bp
#   ./upgrade-cardano-node.sh --network preprod --version 11.1.2 --bp
#   ./upgrade-cardano-node.sh --version 12.0.0 --relay --fresh-db
#   ./upgrade-cardano-node.sh --url https://... --version 10.7.1
#
# Flags:
#   --network      Network profile: mainnet, preprod, or preview (default: mainnet)
#   --version      Target version (default: latest GitHub release)
#   --url          Custom binary download URL (overrides auto-detected URL)
#   --relay        Include OpenBlockPerf traces (default)
#   --bp           Block producer config (skip OpenBlockPerf traces)
#   --keep-config  Preserve config/genesis files (default)
#   --refresh-config Download current official config/genesis files and apply local metrics
#   --fresh-db     Backup DB and deploy fresh Mithril snapshot (use for DB-breaking upgrades)
#   --ledger-backend V2InMemory|V2LSM (default: current backend, or V2InMemory)
#   --yes          Accept recommended defaults without prompting
#   --dry-run      Show what would be done without making changes
#
# Prerequisites:
#   - Run as the node's service user (e.g. stakeman)
#   - sudo access for systemctl and apt-get
#   - curl and python3 available
#
# Tested: 10.6.2 -> 10.7.1, 10.7.1 -> 11.0.1 on Ubuntu 24.04 (Azure)
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
import pathlib, re, sys

path = pathlib.Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
text = path.read_text()
replacement = f'{key}="{value}"'
pattern = re.compile(rf'^#?{re.escape(key)}=.*$', re.MULTILINE)
if pattern.search(text):
    text = pattern.sub(replacement, text, count=1)
else:
    text = replacement + '\n' + text
path.write_text(text)
PYEOF
}

ROLLBACK_ARMED=false
NODE_WAS_ACTIVE=false
BINARY_BACKUP_DIR=""
DB_BACKUP=""
ENV_CHANGED=false
declare -a CONFIG_INSTALLED_FILES=()

rollback_on_exit() {
  local status=$?
  local rollback_failed=false restored_topology_hash
  [[ "${status}" -ne 0 && "${ROLLBACK_ARMED}" == "true" ]] || return "${status}"
  trap - EXIT
  set +e

  warn "Upgrade failed after activation began; restoring the previous installation..."
  sudo systemctl stop "${SERVICE_NAME}" 2>/dev/null || rollback_failed=true

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

  if [[ -d "${BINARY_BACKUP_DIR}" ]]; then
    while IFS= read -r -d '' staged_file; do
      binary_name=$(basename "${staged_file}")
      if [[ -f "${BINARY_BACKUP_DIR}/${binary_name}" ]]; then
        install -m 0755 "${BINARY_BACKUP_DIR}/${binary_name}" "${ACTIVE_BIN_DIR}/.${binary_name}.rollback" \
          && mv -f "${ACTIVE_BIN_DIR}/.${binary_name}.rollback" "${ACTIVE_BIN_DIR}/${binary_name}" \
          || rollback_failed=true
      else
        rm -f "${ACTIVE_BIN_DIR}/${binary_name}" || rollback_failed=true
      fi
    done < <(find "${STAGED_BIN_DIR}" -maxdepth 1 -type f -print0)
  else
    rollback_failed=true
  fi

  if [[ -n "${DB_BACKUP}" && -d "${DB_BACKUP}" ]]; then
    rm -rf "${DB_DIR}" && mv "${DB_BACKUP}" "${DB_DIR}" || rollback_failed=true
  fi

  if [[ "${NODE_WAS_ACTIVE}" == "true" ]]; then
    sudo systemctl reset-failed "${SERVICE_NAME}" 2>/dev/null || true
    sudo systemctl start "${SERVICE_NAME}" || rollback_failed=true
    systemctl is-active --quiet "${SERVICE_NAME}" || rollback_failed=true
  fi
  if [[ -f "${TOPOLOGY_FILE}" ]]; then
    restored_topology_hash=$(sha256sum "${TOPOLOGY_FILE}" | awk '{print $1}')
    [[ "${restored_topology_hash}" == "${TOPOLOGY_HASH_BEFORE}" ]] \
      || rollback_failed=true
  else
    rollback_failed=true
  fi
  if ${rollback_failed}; then
    warn "ROLLBACK INCOMPLETE; manual recovery is required from backups ending ${BACKUP_SUFFIX}"
  else
    warn "Rollback completed and previous service state restored"
  fi
  exit "${status}"
}

# --- Parse arguments ---------------------------------------------------------
NODE_ROLE="relay"
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
    --version)
      [[ $# -ge 2 ]] || error "--version requires a value (e.g. --version 11.0.1)"
      TARGET_VERSION="$2"; shift 2 ;;
    --url)
      [[ $# -ge 2 ]] || error "--url requires a value"
      CUSTOM_URL="$2"; shift 2 ;;
    --relay)       NODE_ROLE="relay"; shift ;;
    --bp)          NODE_ROLE="bp"; shift ;;
    --keep-config) KEEP_CONFIG=true; shift ;;
    --refresh-config) KEEP_CONFIG=false; shift ;;
    --fresh-db)    FRESH_DB=true; shift ;;
    --ledger-backend)
      [[ $# -ge 2 ]] || error "--ledger-backend requires V2InMemory or V2LSM"
      LEDGER_BACKEND="$2"; LEDGER_BACKEND_EXPLICIT=true; shift 2 ;;
    --yes)         ASSUME_YES=true; shift ;;
    --dry-run)     DRY_RUN=true; shift ;;
    *)             error "Unknown argument: $1\nUsage: $0 [--network mainnet|preprod|preview] [--version X.Y.Z] [--url URL] [--relay|--bp] [--keep-config|--refresh-config] [--fresh-db] [--ledger-backend V2InMemory|V2LSM] [--yes] [--dry-run]" ;;
  esac
done

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

FILES_DIR="${CNODE_HOME}/files"
DB_DIR="${CNODE_HOME}/db"
ENV_FILE="${CNODE_HOME}/scripts/env"
TOPOLOGY_FILE="${FILES_DIR}/topology.json"
CONFIG_BASE_URL="https://book.world.dev.cardano.org/environments/${NETWORK}"

read_env_value() {
  local key="$1"
  sed -n "s|^${key}=[\"']\{0,1\}\([^\"' #]*\).*$|\1|p" "${ENV_FILE}" | head -1
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

[[ -s "${TOPOLOGY_FILE}" ]] || error "Missing topology file: ${TOPOLOGY_FILE}"
python3 -c "import json; value=json.load(open('${TOPOLOGY_FILE}')); assert isinstance(value, dict) and value" 2>/dev/null \
  || error "Existing topology is not a non-empty JSON object: ${TOPOLOGY_FILE}"
TOPOLOGY_P2P=$(python3 - "${TOPOLOGY_FILE}" <<'PYEOF'
import json, sys

topology = json.load(open(sys.argv[1]))
if isinstance(topology.get("Producers"), list):
  print("false")
elif isinstance(topology.get("localRoots"), list) and isinstance(topology.get("publicRoots"), list):
  print("true")
else:
  raise SystemExit("unsupported topology structure")
PYEOF
) || error "Topology is neither legacy Producers nor P2P localRoots/publicRoots format"
TOPOLOGY_HASH_BEFORE=$(sha256sum "${TOPOLOGY_FILE}" | awk '{print $1}')
info "Topology:       protected (${TOPOLOGY_HASH_BEFORE}, P2P=${TOPOLOGY_P2P})"

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

if ${KEEP_CONFIG} && version_at_least "${TARGET_VERSION}" "11.1.2"; then
  jq -e '.TraceOptions."".backends | type == "array"' "${FILES_DIR}/config.json" >/dev/null 2>&1 \
    || error "cardano-node ${TARGET_VERSION} requires current TraceOptions configuration; rerun with --refresh-config"
  jq -e '.LedgerDB.Backend == "V2InMemory" or .LedgerDB.Backend == "V2LSM"' "${FILES_DIR}/config.json" >/dev/null 2>&1 \
    || error "Preserved config must explicitly select LedgerDB.Backend; rerun with --refresh-config and --ledger-backend"
  CONFIG_P2P=$(jq -r '.EnableP2P // false' "${FILES_DIR}/config.json")
  [[ "${CONFIG_P2P}" == "${TOPOLOGY_P2P}" ]] \
    || error "Preserved config EnableP2P=${CONFIG_P2P} does not match protected topology P2P=${TOPOLOGY_P2P}; use --refresh-config"
  if [[ "${TOPOLOGY_P2P}" == "false" ]]; then
    [[ "$(jq -r '.ConsensusMode // empty' "${FILES_DIR}/config.json")" == "PraosMode" ]] \
      || error "Protected legacy topology requires ConsensusMode=PraosMode; use --refresh-config"
  fi
fi

info "Target version: ${TARGET_VERSION}"
info "Node role:      ${NODE_ROLE}"

if [[ "${NETWORK}" == "mainnet" ]]; then
  ACTIVE_BIN_DIR="${BIN_DIR}"
else
  ACTIVE_BIN_DIR="${HOME}/.local/cardano-node/${TARGET_VERSION}/bin"
fi
STAGED_BIN_DIR="${HOME}/tmp/cardano-node-${TARGET_VERSION}-$(uname -m)"
info "Install path:   ${ACTIVE_BIN_DIR}"

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

# --- Choose LedgerDB backend -------------------------------------------------
if ${KEEP_CONFIG}; then
  LEDGER_BACKEND="(unchanged)"
  info "LedgerDB backend: skipped (--keep-config)"
elif [[ -n "${LEDGER_BACKEND}" ]]; then
  [[ "${LEDGER_BACKEND}" == "V2InMemory" || "${LEDGER_BACKEND}" == "V2LSM" ]] \
    || error "Invalid --ledger-backend '${LEDGER_BACKEND}'. Expected V2InMemory or V2LSM."
  info "LedgerDB backend: ${LEDGER_BACKEND}"
else
  CURRENT_BACKEND=$(python3 -c "
import json
try:
    print(json.load(open('${FILES_DIR}/config.json')).get('LedgerDB', {}).get('Backend', ''))
except Exception:
    pass
" 2>/dev/null) || CURRENT_BACKEND=""
  if [[ -z "${CURRENT_BACKEND}" ]] && ! ${LEDGER_BACKEND_EXPLICIT}; then
    error "Existing config has no LedgerDB backend. Select --ledger-backend V2InMemory or V2LSM explicitly for --refresh-config."
  fi
  if ${ASSUME_YES} || ${DRY_RUN}; then
    LEDGER_BACKEND="${CURRENT_BACKEND}"
  else
    echo ""
    echo -e "${GREEN}LedgerDB backend options:${NC}"
    echo "  1) V2InMemory - ledger state in RAM (faster forging, higher memory ~16-24 GB)"
    echo "  2) V2LSM      - ledger state on disk (lower memory ~4-8 GB, slightly higher latency)"
    if [[ "${NODE_ROLE}" == "bp" ]]; then
      echo -e "${YELLOW}[WARN]${NC}  V2InMemory is recommended for block producers to minimize forge latency."
    fi
    read -r -p "Choose backend [1=V2InMemory (default), 2=V2LSM]: " backend_choice
    case "${backend_choice}" in
      2)  LEDGER_BACKEND="V2LSM" ;;
      *)  LEDGER_BACKEND="V2InMemory" ;;
    esac
  fi
  info "LedgerDB backend: ${LEDGER_BACKEND}"
fi

# --- Smart DB decision (unless --fresh-db already set) -----------------------
if ! ${FRESH_DB} && ! ${KEEP_CONFIG} && ! ${ASSUME_YES} && ! ${DRY_RUN}; then
  # Detect current backend from existing config
  CURRENT_BACKEND=""
  if [[ -f "${FILES_DIR}/config.json" ]]; then
    CURRENT_BACKEND=$(python3 -c "
import json
try:
    c = json.load(open('${FILES_DIR}/config.json'))
    print(c.get('LedgerDB', {}).get('Backend', ''))
except: pass
" 2>/dev/null) || CURRENT_BACKEND=""
  fi

  RECOMMEND_FRESH=false
  FRESH_REASON=""

  # Check for backend change
  if [[ -n "${CURRENT_BACKEND}" && "${CURRENT_BACKEND}" != "${LEDGER_BACKEND}" ]]; then
    RECOMMEND_FRESH=true
    FRESH_REASON="Backend changing from ${CURRENT_BACKEND} → ${LEDGER_BACKEND} (ledger format incompatible)"
  fi

  echo ""
  if ${RECOMMEND_FRESH}; then
    echo -e "${YELLOW}[WARN]${NC}  ${FRESH_REASON}"
    echo -e "${YELLOW}[WARN]${NC}  A fresh Mithril snapshot is recommended to avoid hours of ledger replay."
    echo ""
    echo "  1) Deploy fresh Mithril snapshot (recommended)"
    echo "  2) Keep existing database"
    read -r -p "Choose [1=fresh (default), 2=keep]: " db_choice
    case "${db_choice}" in
      2)  info "Keeping existing database" ;;
      *)  FRESH_DB=true; info "Will deploy fresh Mithril snapshot" ;;
    esac
  else
    echo "  1) Keep existing database (recommended — same backend, minor upgrade)"
    echo "  2) Deploy fresh Mithril snapshot"
    read -r -p "Choose [1=keep (default), 2=fresh]: " db_choice
    case "${db_choice}" in
      2)  FRESH_DB=true; info "Will deploy fresh Mithril snapshot" ;;
      *)  info "Keeping existing database" ;;
    esac
  fi
fi

if ${DRY_RUN}; then
  info "DRY RUN - no changes will be made"
  info "Would download ${NODE_RELEASE_URL}"
  if ${KEEP_CONFIG}; then
    info "Would preserve config.json, genesis files, env, and topology.json"
  else
    info "Would refresh config/genesis from ${CONFIG_BASE_URL} while preserving the existing metrics endpoint"
  fi
  info "Would preserve database: $([[ "${FRESH_DB}" == "true" ]] && echo no || echo yes)"
  info "Existing Prometheus endpoint: ${PROM_BIND}:${PROM_PORT}"
  exit 0
fi

# --- Step 0: Download staged binaries ----------------------------------------
info "Step 0: Downloading cardano-node ${TARGET_VERSION} binaries..."
mkdir -p "${STAGED_BIN_DIR}"
rm -rf "${STAGED_BIN_DIR}"
mkdir -p "${STAGED_BIN_DIR}"
DOWNLOAD_FILE=$(mktemp /tmp/cardano-node-XXXXXX)
trap 'rm -f "${DOWNLOAD_FILE}"' EXIT

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
trap - EXIT

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

CURRENT_NODE_BIN="${BIN_DIR}/cardano-node"
if [[ "${NETWORK}" != "mainnet" && -f "${ENV_FILE}" ]]; then
  ENV_NODE_BIN=$(sed -n 's|^CNODEBIN="\{0,1\}\([^" ]*\)"\{0,1\}$|\1|p' "${ENV_FILE}" | head -1)
  [[ -x "${ENV_NODE_BIN:-}" ]] && CURRENT_NODE_BIN="${ENV_NODE_BIN}"
fi
CURRENT_VERSION=$("${CURRENT_NODE_BIN}" --version 2>/dev/null | head -1 | awk '{print $2}') || CURRENT_VERSION="unknown"
info "Current binary version: ${CURRENT_VERSION}"

if [[ "${CURRENT_VERSION}" == "${TARGET_VERSION}" ]]; then
  warn "Already running ${TARGET_VERSION}."
  if ! ${ASSUME_YES}; then
    read -r -p "Continue anyway? [y/N]: " confirm
    [[ "${confirm}" =~ ^[yY] ]] || { info "Aborted."; exit 0; }
  fi
fi

if ${DRY_RUN}; then
  info "Dry run complete. Would upgrade ${CURRENT_VERSION} → ${TARGET_VERSION}"
  exit 0
fi

# --- Step 1: Install system dependencies -------------------------------------
info "Step 1: Installing system dependencies..."
sudo apt-get update -qq
sudo apt-get install -y -qq liburing-dev protobuf-compiler libsnappy-dev > /dev/null 2>&1
for pkg in liburing-dev protobuf-compiler libsnappy-dev; do
  dpkg -s "${pkg}" > /dev/null 2>&1 || error "Failed to install ${pkg}"
done
info "System dependencies installed ✓"

# --- Step 2: Backup config files ---------------------------------------------
info "Step 2: Backing up config files..."
BACKUP_SUFFIX="${CURRENT_VERSION}-bak-$(date -u +%Y%m%dT%H%M%SZ)"
cp -a "${FILES_DIR}" "${FILES_DIR}-${BACKUP_SUFFIX}"
cp -a "${ENV_FILE}" "${ENV_FILE}-${BACKUP_SUFFIX}"
info "Config backed up to ${FILES_DIR}-${BACKUP_SUFFIX} ✓"
info "Guild environment backed up to ${ENV_FILE}-${BACKUP_SUFFIX} ✓"

# --- Step 3: Backup current binaries -----------------------------------------
info "Step 3: Backing up current binaries..."
BINARY_BACKUP_DIR="${BACKUP_BIN_DIR}/${NETWORK}-${BACKUP_SUFFIX}"
mkdir -p "${BINARY_BACKUP_DIR}"
while IFS= read -r -d '' staged_file; do
  binary_name=$(basename "${staged_file}")
  if [[ -f "${ACTIVE_BIN_DIR}/${binary_name}" ]]; then
    cp -a "${ACTIVE_BIN_DIR}/${binary_name}" "${BINARY_BACKUP_DIR}/${binary_name}"
  fi
done < <(find "${STAGED_BIN_DIR}" -maxdepth 1 -type f -print0)
info "Existing binaries backed up to ${BINARY_BACKUP_DIR} ✓"

# --- Step 4: Stage official network configuration ----------------------------
if ${KEEP_CONFIG}; then
  info "Step 4: --keep-config specified — skipping config/genesis download and patching"
else
  info "Step 4: Staging official ${NETWORK} configuration..."
  CONFIG_STAGE_DIR=$(mktemp -d)
  curl -fsSL "${CONFIG_BASE_URL}/config.json" -o "${CONFIG_STAGE_DIR}/config.json"

  mapfile -t REFERENCED_FILES < <(python3 - "${CONFIG_STAGE_DIR}/config.json" <<'PYEOF'
import json, os, sys
c = json.load(open(sys.argv[1]))
for key, value in c.items():
    if key.endswith("File") and isinstance(value, str) and value.endswith(".json"):
        print(os.path.basename(value))
PYEOF
  )
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

for key, value in list(c.items()):
  if key.endswith("File") and isinstance(value, str) and value.endswith(".json"):
    c[key] = str(files_dir / pathlib.Path(value).name)

# Guild Operators compat fields
c["EnableP2P"] = topology_p2p
c["PeerSharing"] = False
if not topology_p2p:
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
if not c['EnableP2P']:
  assert c['ConsensusMode'] == 'PraosMode', 'Legacy topology requires PraosMode'
prom_line = [b for b in c['TraceOptions']['']['backends'] if 'PrometheusSimple' in b]
assert prom_line == ['PrometheusSimple suffix ${PROM_BIND} ${PROM_PORT}'], 'Prometheus endpoint wrong'
print('Config validation passed ✓')
" || error "Config validation failed"

  info "Official config, genesis hashes, network magic, and metrics validated ✓"
fi

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
  warn "Service was not running"
fi

# Install the fully validated configuration only after the node is stopped.
if ! ${KEEP_CONFIG}; then
  [[ ! -e "${CONFIG_STAGE_DIR}/topology.json" ]] \
    || error "Refusing to install a staged topology.json"
  while IFS= read -r -d '' config_file; do
    config_name=$(basename "${config_file}")
    CONFIG_INSTALLED_FILES+=("${config_name}")
    cp -a "${config_file}" "${FILES_DIR}/${config_name}"
  done < <(find "${CONFIG_STAGE_DIR}" -maxdepth 1 -type f ! -name topology.json -print0)
  rm -rf "${CONFIG_STAGE_DIR}"
  info "Validated ${NETWORK} configuration installed ✓"
fi

TOPOLOGY_HASH_AFTER=$(sha256sum "${TOPOLOGY_FILE}" | awk '{print $1}')
[[ "${TOPOLOGY_HASH_AFTER}" == "${TOPOLOGY_HASH_BEFORE}" ]] \
  || error "Protected topology changed unexpectedly; service will not be started"
info "Protected topology unchanged ✓"

# --- Step 6: Copy new binaries -----------------------------------------------
info "Step 6: Installing new binaries..."
mkdir -p "${ACTIVE_BIN_DIR}"
while IFS= read -r -d '' staged_file; do
  binary_name=$(basename "${staged_file}")
  install -m 0755 "${staged_file}" "${ACTIVE_BIN_DIR}/.${binary_name}.new"
  mv -f "${ACTIVE_BIN_DIR}/.${binary_name}.new" "${ACTIVE_BIN_DIR}/${binary_name}"
done < <(find "${STAGED_BIN_DIR}" -maxdepth 1 -type f -print0)

INSTALLED_VERSION=$("${ACTIVE_BIN_DIR}/cardano-node" --version | head -1 | awk '{print $2}')
if [[ "${INSTALLED_VERSION}" != "${TARGET_VERSION}" ]]; then
  error "Installed version ${INSTALLED_VERSION} != expected ${TARGET_VERSION}"
fi
info "Binaries installed: cardano-node ${INSTALLED_VERSION} ✓"

if [[ "${NETWORK}" != "mainnet" ]]; then
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

# --- Step 9: Validate -------------------------------------------------------
info "Step 9: Validating..."

# Require the service and its public observability contract to remain healthy.
METRICS_VERSION=""
ACTIVE_PEERS=""
METRICS_SLOT=""
for i in $(seq 1 24); do
  systemctl is-active --quiet "${SERVICE_NAME}" \
    || error "Service stopped during post-upgrade validation"
  PROM_RESPONSE=$(curl -sf --max-time 5 "http://localhost:${PROM_PORT}/metrics" 2>/dev/null) || PROM_RESPONSE=""
  METRICS_VERSION=$(awk '/cardano_node_metrics_cardano_build_info/ && match($0, /version="[^"]+"/) { print substr($0, RSTART + 9, RLENGTH - 10); exit }' <<<"${PROM_RESPONSE}")
  ACTIVE_PEERS=$(awk '$1 == "cardano_node_metrics_peerSelection_ActivePeers_int" { print int($2); exit }' <<<"${PROM_RESPONSE}")
  METRICS_SLOT=$(awk '$1 == "cardano_node_metrics_slotNum_int" { print int($2); exit }' <<<"${PROM_RESPONSE}")
  if [[ "${METRICS_VERSION}" == "${TARGET_VERSION}" \
    && "${ACTIVE_PEERS}" =~ ^[0-9]+$ && "${ACTIVE_PEERS}" -gt 0 \
    && "${METRICS_SLOT}" =~ ^[0-9]+$ && "${METRICS_SLOT}" -gt 0 ]]; then
    break
  fi
  sleep 5
done
[[ "${METRICS_VERSION}" == "${TARGET_VERSION}" ]] \
  || error "Prometheus did not report target version ${TARGET_VERSION} within 120 seconds"
info "Prometheus metrics serving version ${METRICS_VERSION} ✓"
[[ "${ACTIVE_PEERS}" =~ ^[0-9]+$ && "${ACTIVE_PEERS}" -gt 0 ]] \
  || error "Prometheus reported no active peers within 120 seconds"
[[ "${METRICS_SLOT}" =~ ^[0-9]+$ && "${METRICS_SLOT}" -gt 0 ]] \
  || error "Prometheus did not expose a valid current slot"
info "Relay has ${ACTIVE_PEERS} active peer(s) ✓"

SOCKET_PATH="${CNODE_HOME}/sockets/node.socket"
NETWORK_ARGS=(--testnet-magic "${EXPECTED_NETWORK_MAGIC}")
[[ "${NETWORK}" == "mainnet" ]] && NETWORK_ARGS=(--mainnet)
[[ -x "${ACTIVE_BIN_DIR}/cardano-cli" ]] || error "Matching cardano-cli was not installed"
TIP_JSON=""
for i in $(seq 1 24); do
  systemctl is-active --quiet "${SERVICE_NAME}" \
    || error "Service stopped while waiting for the node socket"
  if [[ -S "${SOCKET_PATH}" ]]; then
    TIP_JSON=$(CARDANO_NODE_SOCKET_PATH="${SOCKET_PATH}" timeout 10s \
      "${ACTIVE_BIN_DIR}/cardano-cli" query tip "${NETWORK_ARGS[@]}" 2>/dev/null) || TIP_JSON=""
  fi
  [[ -n "${TIP_JSON}" ]] && break
  sleep 5
done
if [[ -n "${TIP_JSON}" ]]; then
  TIP_BLOCK=$(jq -r '.block // 0' <<<"${TIP_JSON}")
  TIP_SLOT=$(jq -r '.slot // 0' <<<"${TIP_JSON}")
  SYNC_PROGRESS=$(jq -r '.syncProgress // "0"' <<<"${TIP_JSON}")
  [[ "${TIP_BLOCK}" =~ ^[0-9]+$ && "${TIP_BLOCK}" -gt 0 ]] \
    || error "Node socket returned an invalid block number"
  [[ "${TIP_SLOT}" =~ ^[0-9]+$ && "${TIP_SLOT}" -gt 0 ]] \
    || error "Node socket returned an invalid slot number"
  awk -v progress="${SYNC_PROGRESS}" 'BEGIN { exit !(progress + 0 >= 99.99) }' \
    || error "Node sync progress is ${SYNC_PROGRESS}%"
  SLOT_DELTA=$((TIP_SLOT - METRICS_SLOT))
  (( SLOT_DELTA < 0 )) && SLOT_DELTA=$(( -SLOT_DELTA ))
  (( SLOT_DELTA <= 300 )) \
    || error "Prometheus and socket slot values differ by ${SLOT_DELTA} slots"
  info "Node socket healthy at block ${TIP_BLOCK}, slot ${TIP_SLOT}, sync ${SYNC_PROGRESS}% ✓"
else
  error "Node socket query did not succeed within 120 seconds"
fi

ROLLBACK_ARMED=false
trap - EXIT

# Show recent logs
echo ""
info "=== Recent logs ==="
journalctl -u "${SERVICE_NAME}" --no-hostname -n 10 --no-pager 2>/dev/null || true

echo ""
info "============================================"
info "Upgrade to ${TARGET_VERSION} complete!"
info "============================================"
info ""
info "Post-upgrade checklist:"
info "  1. Monitor sync: journalctl -u ${SERVICE_NAME} -f --no-hostname"
info "  2. Check Prometheus: curl -s http://localhost:${PROM_PORT}/metrics | head -20"
info "  3. Check gLiveView once synced: ${CNODE_HOME}/scripts/gLiveView.sh"
if ! ${FRESH_DB}; then
  info ""
  info "  ⚠️  If the node appears to be replaying from genesis (slot numbers starting"
  info "     from 0), the DB format may have changed. Re-run with --fresh-db:"
  info "     $0 --network ${NETWORK} --version ${TARGET_VERSION} --${NODE_ROLE} --fresh-db"
fi
if [[ "${NODE_ROLE}" == "relay" ]]; then
  info "  4. Verify OpenBlockPerf: journalctl -u ${SERVICE_NAME} --no-hostname | grep CompletedBlockFetch"
fi
info ""
info "Rollback (if needed):"
info "  sudo systemctl stop ${SERVICE_NAME}"
info "  sudo cp -a ${FILES_DIR}-${BACKUP_SUFFIX}/. ${FILES_DIR}/"
info "  sudo cp -a ${ENV_FILE}-${BACKUP_SUFFIX} ${ENV_FILE}"
info "  sudo systemctl start ${SERVICE_NAME}"
