#!/bin/bash
set -euo pipefail

###############################################################################
# Cardano Node Upgrade Script (multi-version, multi-arch)
#
# Upgrades a Guild Operators (Koios/CNTools) managed cardano-node.
# Handles:
#   - Automatic latest version detection from GitHub
#   - Multi-architecture support (x86_64 / aarch64)
#   - System dependency installation
#   - Config/binary/DB backup
#   - Official config.json download + edits
#   - Genesis + checkpoints file updates
#   - Binary swap and service restart
#
# Usage:
#   ./upgrade-cardano-node.sh [--version X.Y.Z] [--relay|--bp] [--dry-run]
#   ./upgrade-cardano-node.sh                          # auto-detect latest
#   ./upgrade-cardano-node.sh --version 11.0.1 --bp --keep-config
#   ./upgrade-cardano-node.sh --version 12.0.0 --relay --fresh-db
#   ./upgrade-cardano-node.sh --url https://... --version 10.7.1
#
# Flags:
#   --version      Target version (default: latest GitHub release)
#   --url          Custom binary download URL (overrides auto-detected URL)
#   --relay        Include OpenBlockPerf traces (default)
#   --bp           Block producer config (skip OpenBlockPerf traces)
#   --keep-config  Skip config download/patch (use when config unchanged between versions)
#   --fresh-db     Backup DB and deploy fresh Mithril snapshot (use for DB-breaking upgrades)
#   --dry-run      Show what would be done without making changes
#
# Prerequisites:
#   - Run as the node's service user (e.g. stakeman)
#   - sudo access for systemctl and apt-get
#   - curl and python3 available
#
# Tested: 10.6.2 → 10.7.1, 10.7.1 → 11.0.1 on Ubuntu 24.04 (Azure)
###############################################################################

# --- Configuration -----------------------------------------------------------
CNODE_HOME="${CNODE_HOME:-/opt/cardano/cnode}"
FILES_DIR="${CNODE_HOME}/files"
DB_DIR="${CNODE_HOME}/db"
BIN_DIR="${HOME}/.local/bin"
STAGED_BIN_DIR="${HOME}/tmp/bin"
BACKUP_BIN_DIR="${HOME}/tmp/backup-bin"
SERVICE_NAME="cnode.service"

GITHUB_REPO="IntersectMBO/cardano-node"
GITHUB_API_URL="https://api.github.com/repos/${GITHUB_REPO}/releases/latest"

CONFIG_URL="https://book.play.dev.cardano.org/environments/mainnet/config.json"
CONWAY_GENESIS_URL="https://book.play.dev.cardano.org/environments/mainnet/conway-genesis.json"
CHECKPOINTS_URL="https://book.play.dev.cardano.org/environments/mainnet/checkpoints.json"

PROM_BIND="0.0.0.0"
PROM_PORT="12798"
EKG_PORT="12788"

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
TARGET_VERSION=""
CUSTOM_URL=""
KEEP_CONFIG=false
FRESH_DB=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || error "--version requires a value (e.g. --version 11.0.1)"
      TARGET_VERSION="$2"; shift 2 ;;
    --url)
      [[ $# -ge 2 ]] || error "--url requires a value"
      CUSTOM_URL="$2"; shift 2 ;;
    --relay)       NODE_ROLE="relay"; shift ;;
    --bp)          NODE_ROLE="bp"; shift ;;
    --keep-config) KEEP_CONFIG=true; shift ;;
    --fresh-db)    FRESH_DB=true; shift ;;
    --dry-run)     DRY_RUN=true; shift ;;
    *)             error "Unknown argument: $1\nUsage: $0 [--version X.Y.Z] [--url URL] [--relay|--bp] [--keep-config] [--fresh-db] [--dry-run]" ;;
  esac
done

# --- Resolve target version --------------------------------------------------
if [[ -z "${TARGET_VERSION}" ]]; then
  info "No --version specified. Detecting latest release from GitHub..."

  LATEST=$(curl -sf "${GITHUB_API_URL}" 2>/dev/null \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null) || LATEST=""

  if [[ -n "${LATEST}" ]]; then
    echo ""
    echo -e "  ${CYAN}Latest GitHub release: ${LATEST}${NC}"
    echo ""
    read -r -p "Upgrade to ${LATEST}? [Y/n]: " confirm
    case "${confirm}" in
      [nN]*)
        read -r -p "Enter target version (e.g. 11.0.1): " TARGET_VERSION
        [[ -z "${TARGET_VERSION}" ]] && error "No version specified"
        ;;
      *)
        TARGET_VERSION="${LATEST}"
        ;;
    esac
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

info "Target version: ${TARGET_VERSION}"
info "Node role:      ${NODE_ROLE}"

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
else
  echo ""
  echo -e "${GREEN}LedgerDB backend options:${NC}"
  echo "  1) V2InMemory — ledger state in RAM (faster forging, higher memory ~16-24 GB)"
  echo "  2) V2LSM      — ledger state on disk (lower memory ~4-8 GB, slightly higher latency)"
  if [[ "${NODE_ROLE}" == "bp" ]]; then
    echo -e "${YELLOW}[WARN]${NC}  V2InMemory is recommended for block producers to minimize forge latency."
  fi
  read -r -p "Choose backend [1=V2InMemory (default), 2=V2LSM]: " backend_choice
  case "${backend_choice}" in
    2)  LEDGER_BACKEND="V2LSM" ;;
    *)  LEDGER_BACKEND="V2InMemory" ;;
  esac
  info "LedgerDB backend: ${LEDGER_BACKEND}"
fi

# --- Smart DB decision (unless --fresh-db already set) -----------------------
if ! ${FRESH_DB} && ! ${KEEP_CONFIG}; then
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

${DRY_RUN} && info "DRY RUN — no changes will be made"

# --- Step 0: Download staged binaries ----------------------------------------
info "Step 0: Downloading cardano-node ${TARGET_VERSION} binaries..."
mkdir -p "${STAGED_BIN_DIR}"

# Check if binaries already downloaded at the correct version
SKIP_DOWNLOAD=false
if [[ -x "${STAGED_BIN_DIR}/cardano-node" ]]; then
  EXISTING_VER=$("${STAGED_BIN_DIR}/cardano-node" --version 2>/dev/null | head -1 | awk '{print $2}') || EXISTING_VER="unknown"
  if [[ "${EXISTING_VER}" == "${TARGET_VERSION}" ]]; then
    info "Binaries already staged (${EXISTING_VER}) — skipping download"
    SKIP_DOWNLOAD=true
  else
    info "Staged binaries are ${EXISTING_VER}, need ${TARGET_VERSION} — re-downloading..."
  fi
fi

if ! ${SKIP_DOWNLOAD}; then
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
fi

info "Staged binaries ready in ${STAGED_BIN_DIR} ✓"

# --- Pre-flight checks -------------------------------------------------------
[[ -d "${STAGED_BIN_DIR}" ]] || error "Staged binaries not found at ${STAGED_BIN_DIR}"
[[ -x "${STAGED_BIN_DIR}/cardano-node" ]] || error "No cardano-node binary in ${STAGED_BIN_DIR}"

STAGED_VERSION=$("${STAGED_BIN_DIR}/cardano-node" --version | head -1 | awk '{print $2}')
if [[ "${STAGED_VERSION}" != "${TARGET_VERSION}" ]]; then
  error "Staged binary is ${STAGED_VERSION}, expected ${TARGET_VERSION}"
fi
info "Staged binary version verified: ${STAGED_VERSION}"

CURRENT_VERSION=$("${BIN_DIR}/cardano-node" --version 2>/dev/null | head -1 | awk '{print $2}') || CURRENT_VERSION="unknown"
info "Current binary version: ${CURRENT_VERSION}"

if [[ "${CURRENT_VERSION}" == "${TARGET_VERSION}" ]]; then
  warn "Already running ${TARGET_VERSION}."
  read -r -p "Continue anyway? [y/N]: " confirm
  [[ "${confirm}" =~ ^[yY] ]] || { info "Aborted."; exit 0; }
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

# --- Step 4: Download updated genesis + checkpoints + config ----------------
if ${KEEP_CONFIG}; then
  info "Step 4: --keep-config specified — skipping config/genesis download and patching"
else
  info "Step 4: Downloading updated genesis, checkpoints, and config..."
  curl -sL "${CONWAY_GENESIS_URL}" -o "${FILES_DIR}/conway-genesis.json"
  curl -sL "${CHECKPOINTS_URL}" -o "${FILES_DIR}/checkpoints.json"

  # Verify downloads are valid JSON
  for f in conway-genesis.json checkpoints.json; do
    python3 -c "import json; json.load(open('${FILES_DIR}/${f}'))" 2>/dev/null \
      || error "Downloaded ${f} is not valid JSON"
  done
  info "Genesis and checkpoints updated ✓"

  # --- Download and patch config.json ----------------------------------------
  info "  Downloading official config.json and applying edits..."
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
  python3 << 'PYEOF'
import json, os

config_path = os.path.join(os.environ.get("CNODE_HOME", "/opt/cardano/cnode"), "files", "config.json")
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
import json, os
config_path = os.path.join(os.environ.get('CNODE_HOME', '/opt/cardano/cnode'), 'files', 'config.json')
c = json.load(open(config_path))
assert c['UseTraceDispatcher'] == True, 'UseTraceDispatcher not true'
assert c['TraceChainDb'] == True, 'TraceChainDb missing'
assert c['LedgerDB']['Backend'] == '${LEDGER_BACKEND}', 'Wrong backend'
prom_line = [b for b in c['TraceOptions']['']['backends'] if 'PrometheusSimple' in b]
assert len(prom_line) == 1 and '${PROM_BIND}' in prom_line[0], 'Prometheus bind wrong'
print('Config validation passed ✓')
" || error "Config validation failed"

  info "Config downloaded and patched ✓"
fi

# --- Step 5: Stop the node ---------------------------------------------------
info "Step 5: Stopping ${SERVICE_NAME}..."
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

# --- Step 6: Copy new binaries -----------------------------------------------
info "Step 6: Installing new binaries..."
cp "${STAGED_BIN_DIR}"/* "${BIN_DIR}/"

INSTALLED_VERSION=$("${BIN_DIR}/cardano-node" --version | head -1 | awk '{print $2}')
if [[ "${INSTALLED_VERSION}" != "${TARGET_VERSION}" ]]; then
  error "Installed version ${INSTALLED_VERSION} != expected ${TARGET_VERSION}"
fi
info "Binaries installed: cardano-node ${INSTALLED_VERSION} ✓"

# --- Step 7: Handle database (keep or fresh Mithril) ------------------------
if ${FRESH_DB}; then
  info "Step 7: --fresh-db specified — backing up DB and deploying Mithril snapshot..."

  # Disk space preflight
  info "  Checking free disk space before snapshot deploy..."
  check_snapshot_disk_space

  if [[ -d "${DB_DIR}" ]]; then
    DB_BACKUP="${DB_DIR}-${CURRENT_VERSION}-bak"
    if [[ -d "${DB_BACKUP}" ]]; then
      warn "DB backup already exists: ${DB_BACKUP} — removing current DB"
      rm -rf "${DB_DIR}"
    else
      mv "${DB_DIR}" "${DB_BACKUP}"
      info "DB renamed to ${DB_BACKUP}"
    fi
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
  # Could still be activating (replay from genesis takes time)
  STATUS=$(systemctl show -p ActiveState --value "${SERVICE_NAME}")
  if [[ "${STATUS}" == "activating" ]]; then
    warn "Service is still activating (likely replaying ledger from genesis)"
    warn "This is expected with V2LSM backend — replay can take many hours"
  else
    error "Service did not start within 60 seconds (status: ${STATUS})"
  fi
fi

# --- Step 9: Validate -------------------------------------------------------
info "Step 9: Validating..."

# Check Prometheus
sleep 5
PROM_RESPONSE=$(curl -sf "http://localhost:${PROM_PORT}/metrics" 2>/dev/null | head -5) || true
if [[ -n "${PROM_RESPONSE}" ]]; then
  METRICS_VERSION=$(curl -sf "http://localhost:${PROM_PORT}/metrics" | grep 'cardano_node_metrics_cardano_build_info' | grep -oP '[ ,{]version="[^"]+' | cut -d'"' -f2 | head -1) || true
  if [[ "${METRICS_VERSION}" == "${TARGET_VERSION}" ]]; then
    info "Prometheus metrics serving version ${METRICS_VERSION} ✓"
  else
    warn "Prometheus responding but version='${METRICS_VERSION}' (expected ${TARGET_VERSION})"
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
info "Upgrade to ${TARGET_VERSION} complete!"
info "============================================"
info ""
info "Post-upgrade checklist:"
info "  1. Monitor sync: journalctl -u ${SERVICE_NAME} -f --no-hostname"
info "  2. Check Prometheus: curl -s http://localhost:${PROM_PORT}/metrics | head -20"
info "  3. Check gLiveView once synced: /opt/cardano/cnode/scripts/gLiveView.sh"
if ! ${FRESH_DB}; then
  info ""
  info "  ⚠️  If the node appears to be replaying from genesis (slot numbers starting"
  info "     from 0), the DB format may have changed. Re-run with --fresh-db:"
  info "     $0 --version ${TARGET_VERSION} --${NODE_ROLE} --fresh-db"
fi
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
