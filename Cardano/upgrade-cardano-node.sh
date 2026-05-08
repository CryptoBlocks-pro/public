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
#   ./upgrade-cardano-node.sh --version 11.0.1 --bp
#   ./upgrade-cardano-node.sh --url https://... --version 10.7.1
#
# Flags:
#   --version  Target version (default: latest GitHub release)
#   --url      Custom binary download URL (overrides auto-detected URL)
#   --relay    Include OpenBlockPerf traces (default)
#   --bp       Block producer config (skip OpenBlockPerf traces)
#   --dry-run  Show what would be done without making changes
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

# --- Color helpers -----------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# --- Parse arguments ---------------------------------------------------------
NODE_ROLE="relay"
DRY_RUN=false
TARGET_VERSION=""
CUSTOM_URL=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --version)
      [[ $# -ge 2 ]] || error "--version requires a value (e.g. --version 11.0.1)"
      TARGET_VERSION="$2"; shift 2 ;;
    --url)
      [[ $# -ge 2 ]] || error "--url requires a value"
      CUSTOM_URL="$2"; shift 2 ;;
    --relay)   NODE_ROLE="relay"; shift ;;
    --bp)      NODE_ROLE="bp"; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    *)         error "Unknown argument: $1\nUsage: $0 [--version X.Y.Z] [--url URL] [--relay|--bp] [--dry-run]" ;;
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

# --- Step 7: Copy new binaries -----------------------------------------------
info "Step 7: Installing new binaries..."
cp "${STAGED_BIN_DIR}"/* "${BIN_DIR}/"

INSTALLED_VERSION=$("${BIN_DIR}/cardano-node" --version | head -1 | awk '{print $2}')
if [[ "${INSTALLED_VERSION}" != "${TARGET_VERSION}" ]]; then
  error "Installed version ${INSTALLED_VERSION} != expected ${TARGET_VERSION}"
fi
info "Binaries installed: cardano-node ${INSTALLED_VERSION} ✓"

# --- Step 8: Rename old DB and deploy Mithril snapshot -----------------------
info "Step 8: Renaming old database and deploying Mithril snapshot..."
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
if [[ ! -x "${MITHRIL_SCRIPT}" ]]; then
  info "Mithril deploy script not found — downloading..."
  curl -sL "${MITHRIL_SCRIPT_URL}" -o "${MITHRIL_SCRIPT}"
  chmod +x "${MITHRIL_SCRIPT}"
  [[ -x "${MITHRIL_SCRIPT}" ]] || error "Failed to download Mithril deploy script"
  info "Downloaded ${MITHRIL_SCRIPT} ✓"
fi
info "Deploying fresh Mithril snapshot to ${DB_DIR}..."
"${MITHRIL_SCRIPT}" --path "${DB_DIR}" --yes
info "Mithril snapshot deployed ✓"

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
  METRICS_VERSION=$(curl -sf "http://localhost:${PROM_PORT}/metrics" | grep 'cardano_node_metrics_cardano_build_info' | grep -oP 'version="[^"]+' | cut -d'"' -f2) || true
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
