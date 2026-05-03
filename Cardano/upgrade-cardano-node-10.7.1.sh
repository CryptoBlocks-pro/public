#!/bin/bash
set -euo pipefail

###############################################################################
# Cardano Node Upgrade Script: → 10.7.1
#
# Upgrades a Guild Operators (Koios/CNTools) managed cardano-node from
# 10.x to 10.7.1. Handles:
#   - System dependency installation
#   - Config/binary/DB backup
#   - Official config.json download + edits
#   - Genesis + checkpoints file updates
#   - Binary swap and service restart
#
# Usage:
#   ./upgrade-cardano-node-10.7.1.sh [--relay|--bp]
#
# Flags:
#   --relay   Include OpenBlockPerf traces (default)
#   --bp      Block producer config (skip OpenBlockPerf traces)
#   --dry-run Show what would be done without making changes
#
# Prerequisites:
#   - New binaries staged in ~/tmp/bin/
#   - Run as the node's service user (e.g. stakeman)
#   - sudo access for systemctl and apt-get
#
# Tested: 10.6.2 → 10.7.1 on Ubuntu 24.04 (Azure)
###############################################################################

# --- Configuration -----------------------------------------------------------
CNODE_HOME="${CNODE_HOME:-/opt/cardano/cnode}"
FILES_DIR="${CNODE_HOME}/files"
DB_DIR="${CNODE_HOME}/db"
BIN_DIR="${HOME}/.local/bin"
STAGED_BIN_DIR="${HOME}/tmp/bin"
BACKUP_BIN_DIR="${HOME}/tmp/backup-bin"
SERVICE_NAME="cnode.service"

EXPECTED_NODE_VERSION="10.7.1"

CONFIG_URL="https://book.play.dev.cardano.org/environments/mainnet/config.json"
CONWAY_GENESIS_URL="https://book.play.dev.cardano.org/environments/mainnet/conway-genesis.json"
CHECKPOINTS_URL="https://book.play.dev.cardano.org/environments/mainnet/checkpoints.json"

ARCH=$(uname -m)
case "${ARCH}" in
  x86_64)  NODE_RELEASE_URL="https://github.com/IntersectMBO/cardano-node/releases/download/${EXPECTED_NODE_VERSION}/cardano-node-${EXPECTED_NODE_VERSION}-linux-amd64.tar.gz" ;;
  aarch64) NODE_RELEASE_URL="https://github.com/armada-alliance/cardano-node-binaries/raw/main/static-binaries/cardano-10_7_1-aarch64-static-musl-ghc_9122.tar.zst" ;;
  *)       error "Unsupported architecture: ${ARCH}" ;;
esac

PROM_BIND="0.0.0.0"
PROM_PORT="12798"
EKG_PORT="12788"
LEDGER_BACKEND="${LEDGER_BACKEND:-ask}"  # ask, V2InMemory or V2LSM
SNAPSHOT_SAFETY_GB="${SNAPSHOT_SAFETY_GB:-20}"
MITHRIL_CLIENT_BIN="${MITHRIL_CLIENT_BIN:-${BIN_DIR}/mithril-client}"
MITHRIL_RELEASE_TAG="${MITHRIL_RELEASE_TAG:-latest}"
MITHRIL_SIGNING_FPR="${MITHRIL_SIGNING_FPR:-73FC4C3DFD55DBDC428AD2B5BE043B79FDA4C2EE}"
DB_HANDLING_MODE="${DB_HANDLING_MODE:-ask}"

# --- Color helpers -----------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

bytes_to_gib() {
  awk -v b="$1" 'BEGIN { printf "%.2f", b/1024/1024/1024 }'
}

check_snapshot_disk_space() {
  local target_path avail_bytes db_size_bytes required_bytes safety_bytes est_avail_after_cleanup
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

  info "Disk preflight (target: ${target_path})"
  info "  DB handling mode: ${DB_HANDLING_MODE}"
  info "  Available: $(bytes_to_gib "${avail_bytes}") GiB"

  case "${DB_HANDLING_MODE}" in
    backup)
      required_bytes=$((db_size_bytes + safety_bytes))
      info "  Estimated required to keep backup + new DB buffer: $(bytes_to_gib "${required_bytes}") GiB"
      if (( avail_bytes < required_bytes )); then
        warn "Free space is below the estimate needed to keep full backup + growing production DB."
        warn "You can continue, but may need to manually remove old backup DB before new DB grows too large."
      fi
      ;;
    overwrite)
      est_avail_after_cleanup=$((avail_bytes + db_size_bytes))
      required_bytes=${safety_bytes}
      info "  Estimated available after overwrite cleanup: $(bytes_to_gib "${est_avail_after_cleanup}") GiB"
      info "  Estimated required for snapshot + buffer: $(bytes_to_gib "${required_bytes}") GiB"
      if (( est_avail_after_cleanup < required_bytes )); then
        error "Insufficient free space even after overwrite cleanup. Need at least $(bytes_to_gib "${required_bytes}") GiB free after DB removal, but estimate is $(bytes_to_gib "${est_avail_after_cleanup}") GiB."
      fi
      ;;
    *)
      error "Unsupported DB_HANDLING_MODE in disk check: ${DB_HANDLING_MODE}"
      ;;
  esac
}

select_db_handling_mode() {
  local choice
  case "${DB_HANDLING_MODE}" in
    backup|overwrite)
      ;;
    ask|"")
      if [[ -t 0 ]]; then
        echo
        echo "Choose how to handle existing DB directory (${DB_DIR}):"
        echo "  1) backup    - move current DB aside before snapshot restore"
        echo "  2) overwrite - delete current DB before snapshot restore"
        read -r -p "Selection [1/2] (default 1): " choice
        case "${choice}" in
          ""|1|b|B|backup) DB_HANDLING_MODE="backup" ;;
          2|o|O|overwrite) DB_HANDLING_MODE="overwrite" ;;
          *) error "Invalid selection: ${choice}" ;;
        esac
      else
        warn "Non-interactive shell and DB_HANDLING_MODE not set; defaulting to backup"
        DB_HANDLING_MODE="backup"
      fi
      ;;
    *)
      error "Invalid DB_HANDLING_MODE='${DB_HANDLING_MODE}'. Use: ask, backup, overwrite"
      ;;
  esac

  info "DB handling mode selected: ${DB_HANDLING_MODE}"
}

select_ledger_backend() {
  local choice

  case "${LEDGER_BACKEND}" in
    V2InMemory|V2LSM)
      ;;
    ask|"")
      if [[ -t 0 ]]; then
        echo
        echo "Choose LedgerDB backend:"
        echo "  1) V2InMemory (default) - lower disk usage, replay from genesis"
        echo "  2) V2LSM              - on-disk ledger snapshot backend"
        read -r -p "Selection [1/2] (default 1): " choice
        case "${choice}" in
          ""|1|i|I|inmemory|V2InMemory) LEDGER_BACKEND="V2InMemory" ;;
          2|l|L|lsm|V2LSM) LEDGER_BACKEND="V2LSM" ;;
          *) error "Invalid LedgerDB backend selection: ${choice}" ;;
        esac
      else
        warn "Non-interactive shell and LEDGER_BACKEND not set; defaulting to V2InMemory"
        LEDGER_BACKEND="V2InMemory"
      fi
      ;;
    *)
      error "Invalid LEDGER_BACKEND='${LEDGER_BACKEND}'. Use: ask, V2InMemory, V2LSM"
      ;;
  esac

  info "LedgerDB backend selected: ${LEDGER_BACKEND}"
}

prepare_db_directory_for_snapshot() {
  local backup_base backup_target

  if [[ ! -d "${DB_DIR}" ]]; then
    warn "No database directory found at ${DB_DIR}"
    return 0
  fi

  case "${DB_HANDLING_MODE}" in
    backup)
      backup_base="${DB_DIR}-${CURRENT_VERSION}-bak"
      backup_target="${backup_base}"
      if [[ -e "${backup_target}" ]]; then
        backup_target="${backup_base}-$(date +%s)"
        warn "Default backup path exists, using ${backup_target}"
      fi
      mv "${DB_DIR}" "${backup_target}"
      info "DB moved to backup path ${backup_target}"
      ;;
    overwrite)
      rm -rf "${DB_DIR}"
      info "Deleted existing DB directory ${DB_DIR}"
      ;;
    *)
      error "Unsupported DB_HANDLING_MODE in DB prepare: ${DB_HANDLING_MODE}"
      ;;
  esac
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
  aggregator_endpoint="https://aggregator.release-mainnet.api.mithril.network/aggregator"

  genesis_vkey=$(curl -fsSL "https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/release-mainnet/genesis.vkey") || return 1
  ancillary_vkey=$(curl -fsSL "https://raw.githubusercontent.com/input-output-hk/mithril/main/mithril-infra/configuration/release-mainnet/ancillary.vkey") || return 1

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

# --- Parse arguments ---------------------------------------------------------
NODE_ROLE="relay"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --relay)   NODE_ROLE="relay"; shift ;;
    --bp)      NODE_ROLE="bp"; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    *)         error "Unknown argument: $1" ;;
  esac
done

info "Node role: ${NODE_ROLE}"
${DRY_RUN} && info "DRY RUN — no changes will be made"
select_ledger_backend
select_db_handling_mode

# --- Step 0: Download staged binaries ----------------------------------------
info "Step 0: Downloading cardano-node ${EXPECTED_NODE_VERSION} binaries..."
mkdir -p "${STAGED_BIN_DIR}"
if [[ -x "${STAGED_BIN_DIR}/cardano-node" ]]; then
  EXISTING_VER=$("${STAGED_BIN_DIR}/cardano-node" --version 2>/dev/null | head -1 | awk '{print $2}') || EXISTING_VER="unknown"
  if [[ "${EXISTING_VER}" == "${EXPECTED_NODE_VERSION}" ]]; then
    info "Binaries already downloaded (${EXISTING_VER}) — skipping download"
  else
    info "Existing binaries are ${EXISTING_VER}, downloading ${EXPECTED_NODE_VERSION}..."
    wget -c "${NODE_RELEASE_URL}" -O - | tar -I zstd -xv -C "${STAGED_BIN_DIR}" --strip-components=1
  fi
else
  wget -c "${NODE_RELEASE_URL}" -O - | tar -I zstd -xv -C "${STAGED_BIN_DIR}" --strip-components=1
fi
info "Staged binaries ready in ${STAGED_BIN_DIR} ✓"

# --- Pre-flight checks -------------------------------------------------------
[[ -d "${STAGED_BIN_DIR}" ]] || error "Staged binaries not found at ${STAGED_BIN_DIR}"
[[ -x "${STAGED_BIN_DIR}/cardano-node" ]] || error "No cardano-node binary in ${STAGED_BIN_DIR}"

STAGED_VERSION=$("${STAGED_BIN_DIR}/cardano-node" --version | head -1 | awk '{print $2}')
if [[ "${STAGED_VERSION}" != "${EXPECTED_NODE_VERSION}" ]]; then
  error "Staged binary is ${STAGED_VERSION}, expected ${EXPECTED_NODE_VERSION}"
fi
info "Staged binary version verified: ${STAGED_VERSION}"

CURRENT_VERSION=$("${BIN_DIR}/cardano-node" --version 2>/dev/null | head -1 | awk '{print $2}') || CURRENT_VERSION="unknown"
info "Current binary version: ${CURRENT_VERSION}"

if ${DRY_RUN}; then
  info "Dry run complete. Would upgrade ${CURRENT_VERSION} → ${EXPECTED_NODE_VERSION}"
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
BACKUP_SUFFIX="${CURRENT_VERSION}-bak"
if [[ -d "${FILES_DIR}-${BACKUP_SUFFIX}" ]]; then
  warn "Backup already exists: ${FILES_DIR}-${BACKUP_SUFFIX} — skipping"
else
  cp -a "${FILES_DIR}" "${FILES_DIR}-${BACKUP_SUFFIX}"
  info "Config backed up to ${FILES_DIR}-${BACKUP_SUFFIX} ✓"
fi

# --- Step 3: Backup current binaries -----------------------------------------
info "Step 3: Backing up current binaries..."
mkdir -p "${BACKUP_BIN_DIR}"
for bin in cardano-node cardano-cli; do
  if [[ -f "${BIN_DIR}/${bin}" ]]; then
    DEST="${BACKUP_BIN_DIR}/${bin}-${CURRENT_VERSION}"
    if [[ -f "${DEST}" ]]; then
      warn "Binary backup already exists: ${DEST} — skipping"
    else
      cp "${BIN_DIR}/${bin}" "${DEST}"
      info "Backed up ${bin} → ${DEST} ✓"
    fi
  fi
done

# --- Step 4: Download updated genesis + checkpoints -------------------------
info "Step 4: Downloading updated genesis and checkpoints..."
curl -sL "${CONWAY_GENESIS_URL}" -o "${FILES_DIR}/conway-genesis.json"
curl -sL "${CHECKPOINTS_URL}" -o "${FILES_DIR}/checkpoints.json"

# Verify downloads are valid JSON
for f in conway-genesis.json checkpoints.json; do
  python3 -c "import json; json.load(open('${FILES_DIR}/${f}'))" 2>/dev/null \
    || error "Downloaded ${f} is not valid JSON"
done
info "Genesis and checkpoints updated ✓"

# --- Step 5: Download and patch config.json ----------------------------------
info "Step 5: Downloading official config.json and applying edits..."
curl -sL "${CONFIG_URL}" -o "${FILES_DIR}/config.json"

# Validate the download
python3 -c "import json; json.load(open('${FILES_DIR}/config.json'))" 2>/dev/null \
  || error "Downloaded config.json is not valid JSON"

# Apply all edits via Python for reliability
PROM_BIND="${PROM_BIND}" \
PROM_PORT="${PROM_PORT}" \
EKG_PORT="${EKG_PORT}" \
LEDGER_BACKEND="${LEDGER_BACKEND}" \
NODE_ROLE="${NODE_ROLE}" \
python3 << PYEOF
import json, os

config_path = "${FILES_DIR}/config.json"
prom_bind = os.environ["PROM_BIND"]
prom_port = int(os.environ["PROM_PORT"])
ekg_port = int(os.environ["EKG_PORT"])
ledger_backend = os.environ["LEDGER_BACKEND"]
node_role = os.environ["NODE_ROLE"]

with open(config_path) as f:
    c = json.load(f)

# Guild Operators compat fields
c["EnableP2P"] = True
c["TraceChainDb"] = True
c["hasEKG"] = ekg_port
c["hasPrometheus"] = [prom_bind, prom_port]

# Prometheus bind in TraceOptions
backends = c.get("TraceOptions", {}).get("", {}).get("backends", [])
c["TraceOptions"][""]["backends"] = [
    b.replace("127.0.0.1", prom_bind) if "PrometheusSimple" in b else b
    for b in backends
]

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

with open(config_path, 'w') as f:
    json.dump(c, f, indent=2)
    f.write('\n')

print("Config patched successfully")
PYEOF

# Validate final config
python3 -c "
import json
c = json.load(open('${FILES_DIR}/config.json'))
assert c['UseTraceDispatcher'] == True, 'UseTraceDispatcher not true'
assert c['TraceChainDb'] == True, 'TraceChainDb missing'
assert c['LedgerDB']['Backend'] == '${LEDGER_BACKEND}', 'Wrong backend'
prom_line = [b for b in c['TraceOptions']['']['backends'] if 'PrometheusSimple' in b]
assert len(prom_line) == 1 and '${PROM_BIND}' in prom_line[0], 'Prometheus bind wrong'
print('Config validation passed ✓')
" || error "Config validation failed"

info "Config downloaded and patched ✓"

# --- Step 6: Stop the node ---------------------------------------------------
info "Step 6: Stopping ${SERVICE_NAME}..."
if systemctl is-active --quiet "${SERVICE_NAME}"; then
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

# --- Step 6.5: Disk space preflight for snapshot restore ---------------------
info "Step 6.5: Checking free disk space before snapshot deploy..."
check_snapshot_disk_space

# --- Step 7: Copy new binaries -----------------------------------------------
info "Step 7: Installing new binaries..."
cp "${STAGED_BIN_DIR}"/* "${BIN_DIR}/"

INSTALLED_VERSION=$("${BIN_DIR}/cardano-node" --version | head -1 | awk '{print $2}')
if [[ "${INSTALLED_VERSION}" != "${EXPECTED_NODE_VERSION}" ]]; then
  error "Installed version ${INSTALLED_VERSION} != expected ${EXPECTED_NODE_VERSION}"
fi
info "Binaries installed: cardano-node ${INSTALLED_VERSION} ✓"

# --- Step 8: Rename old DB and deploy Mithril snapshot -----------------------
info "Step 8: Preparing database path and deploying Mithril snapshot..."
prepare_db_directory_for_snapshot

MITHRIL_SCRIPT="${HOME}/DeployMithrilUncompressOnTheFly.sh"
MITHRIL_SCRIPT_URL="https://raw.githubusercontent.com/CryptoBlocks-pro/public/main/Cardano/DeployMithrilUncompressOnTheFly.sh"

official_deploy_ok=false
if install_mithril_client && deploy_snapshot_with_official_client; then
  official_deploy_ok=true
  info "Mithril snapshot deployed via official mithril-client ✓"
else
  warn "Official mithril-client deploy failed or unavailable, falling back to custom deploy script"
fi

if [[ "${official_deploy_ok}" != "true" ]]; then
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
fi

# Ensure db metadata file exists for node startup.
ensure_protocol_magic_id

# --- Step 9: Start the node --------------------------------------------------
info "Step 9: Starting ${SERVICE_NAME}..."
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
  # Could still be activating (replay from genesis takes time)
  STATUS=$(systemctl show -p ActiveState --value "${SERVICE_NAME}")
  if [[ "${STATUS}" == "activating" ]]; then
    warn "Service is still activating (likely replaying ledger from genesis)"
    warn "This is expected with V2LSM backend — replay can take many hours"
  else
    error "Service did not start within 60 seconds (status: ${STATUS})"
  fi
fi

# --- Step 10: Validate -------------------------------------------------------
info "Step 10: Validating..."

# Check Prometheus
sleep 5
PROM_RESPONSE=$(curl -sf "http://localhost:${PROM_PORT}/metrics" 2>/dev/null | head -5) || true
if [[ -n "${PROM_RESPONSE}" ]]; then
  METRICS_VERSION=$(curl -sf "http://localhost:${PROM_PORT}/metrics" | grep 'cardano_node_metrics_cardano_build_info' | tr -d '\n' | grep -oP 'version="[^"]+' | cut -d'"' -f2) || true
  if [[ "${METRICS_VERSION}" == "${EXPECTED_NODE_VERSION}" ]]; then
    info "Prometheus metrics serving version ${METRICS_VERSION} ✓"
  else
    warn "Prometheus responding but version='${METRICS_VERSION}' (expected ${EXPECTED_NODE_VERSION})"
  fi
else
  warn "Prometheus not responding yet on port ${PROM_PORT} (may still be initializing)"
fi

# Show recent logs
echo ""
info "=== Recent logs ==="
journalctl -u "${SERVICE_NAME}" --no-hostname -n 10 --no-pager 2>/dev/null || true

echo ""
info "============================================"
info "Upgrade to ${EXPECTED_NODE_VERSION} complete!"
info "============================================"
info ""
info "Post-upgrade checklist:"
info "  1. Monitor replay: journalctl -u ${SERVICE_NAME} -f --no-hostname"
info "  2. Check Prometheus: curl -s http://localhost:${PROM_PORT}/metrics | head -20"
info "  3. Check gLiveView once synced: /opt/cardano/cnode/scripts/gLiveView.sh"
if [[ "${NODE_ROLE}" == "relay" ]]; then
  info "  4. Verify OpenBlockPerf: journalctl -u ${SERVICE_NAME} --no-hostname | grep CompletedBlockFetch"
fi
info ""
info "Rollback (if needed):"
info "  sudo systemctl stop ${SERVICE_NAME}"
info "  cp ${BACKUP_BIN_DIR}/cardano-node-${CURRENT_VERSION} ${BIN_DIR}/cardano-node"
info "  cp ${BACKUP_BIN_DIR}/cardano-cli-${CURRENT_VERSION} ${BIN_DIR}/cardano-cli"
info "  cp -a ${FILES_DIR}-${BACKUP_SUFFIX}/config.json ${FILES_DIR}/config.json"
info "  sudo systemctl start ${SERVICE_NAME}"
