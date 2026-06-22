#!/bin/bash

set -euo pipefail

# ApexPrime-to-cntools.sh
# This script sets up and configures an Apex/Cardano node instance for the Apex Prime mainnet.
# Provided by Crypto Blocks, LLC for use as-is with no warranty.
# Website: https://cryptoblocks.pro
# Email: admin@cryptoblocks.pro

# Changelog October 20, 2024
# Now handles multiple cardano-node versions that Apex supports. No longer requires downloading the zip file and uncompressing... will download the files directly from the Apex Prime mainnet repo.

# Changelog June 21, 2026 (Apex consolidation)
# - Fixed config download source: replaced broken Apex-Fusion URLs with stable Scitz0/guild-operators-apex/main
# - Added normalization of logging configuration: all new instances use StdoutSK (journald-only) with minSeverity=Error
# - Normalized telemetry ports: hasPrometheus and hasEKG set to per-workload values
# - Ensured genesis file paths are relative (not /opt/cardano/cnode absolute paths)

usage() {
    cat <<'EOF'
Usage: ApexPrimeMainnet-to-cntools.sh [options]

Options:
  --version <8.7.3|8.9.4|9.2.1>
  --node-name <name>
  --cpu-cores <count>
  --cnode-port <port>
  --prometheus-port <port>
  --apex-home <path>
  --parent-folder <path>
  --top-folder <name>
  --home-var <VAR_NAME>
  --yes
  --help

Examples:
  ./ApexPrimeMainnet-to-cntools.sh --yes --version 9.2.1 --node-name ODYS2 --cpu-cores 4 --cnode-port 5531 --prometheus-port 12688 --parent-folder /opt/apex --top-folder odys2
  ./ApexPrimeMainnet-to-cntools.sh --yes --version 9.2.1 --node-name SOUTH --cpu-cores 4 --cnode-port 5524 --prometheus-port 12758 --apex-home /opt/apex/south
EOF
}

version_choice=""
cardano_version=""
node_name=""
cpu_cores=""
cnode_port=""
prometheus_port=""
apex_home_arg=""
parent_folder=""
top_folder=""
home_var_name=""
skip_setup_prompt="N"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)
            cardano_version="$2"
            shift 2
            ;;
        --node-name)
            node_name="$2"
            shift 2
            ;;
        --cpu-cores)
            cpu_cores="$2"
            shift 2
            ;;
        --cnode-port)
            cnode_port="$2"
            shift 2
            ;;
        --prometheus-port)
            prometheus_port="$2"
            shift 2
            ;;
        --apex-home)
            apex_home_arg="$2"
            shift 2
            ;;
        --parent-folder)
            parent_folder="$2"
            shift 2
            ;;
        --top-folder)
            top_folder="$2"
            shift 2
            ;;
        --home-var)
            home_var_name="$2"
            shift 2
            ;;
        --yes)
            skip_setup_prompt="Y"
            shift
            ;;
        --help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ -n "$apex_home_arg" ]]; then
    APEX_TOP_LEVEL_FOLDER="$apex_home_arg"
elif [[ -n "$parent_folder" && -n "$top_folder" ]]; then
    APEX_TOP_LEVEL_FOLDER="$parent_folder/$top_folder"
fi

# Introduction prompt
echo "This script will convert a cntools Cardano install to Apex Prime mainnet."
echo "It can be used to create multiple instances running on the same server."
echo "For that use case, you will need to choose different ports for each instance you install."
echo ""

# Prompt user to select the version of cardano-node
if [[ -z "$cardano_version" ]]; then
    echo "Select the version of cardano-node for Apex Prime mainnet:"
    echo "NOTE: this script will not install cardano-node. You will need to do this yourself."
    echo "a) 8.7.3"
    echo "b) 8.9.4"
    echo "c) 9.2.1"
    read -p "Enter your choice (a/b/c): " version_choice

    case $version_choice in
        a) cardano_version="8.7.3" ;;
        b) cardano_version="8.9.4" ;;
        c) cardano_version="9.2.1" ;;
        *) echo "Invalid choice"; exit 1 ;;
    esac
fi

case "$cardano_version" in
    8.7.3|8.9.4|9.2.1) ;;
    node-8.7.3) cardano_version="8.7.3" ;;
    node-8.9.4) cardano_version="8.9.4" ;;
    node-9.2.1) cardano_version="9.2.1" ;;
    *) echo "Unsupported version: $cardano_version"; exit 1 ;;
esac

# Check for Koios/cntools setup
if [[ "$skip_setup_prompt" == "Y" ]]; then
    koios_setup="y"
else
    read -p "Have you run the Koios/cntools setup for the instance you want to convert to Apex Prime mainnet? (y/n): " koios_setup
fi
if [ "$koios_setup" != "y" ]; then
    echo "Please setup Koios/cntools as per the following instructions then come back and run this script:"
    echo "1. Download the Guild Community Tools (cntools) using the following command:"
    echo "   curl -sS -o guild-deploy.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/guild-deploy.sh"
    echo "2. Make the script executable:"
    echo "   chmod 755 guild-deploy.sh"
    echo "3. Run the script with the following command and force the cardano-node version to use. In this example we are forceing 8.7.3, but substitue with your target Apex Prime supported-version:"
    echo "   ./guild-deploy.sh -p /opt/apex -b node-8.7.3 -t prime-pubmainnet -u -sdf"
    echo "   (the "d" flag will download the cardano-node and cardano-cli binaries on x64 systems. You can omit this if you already have them)"
    echo "   This would install the cntools in the /opt/apex/prime-pubmainnet folder; you can modify the -p (parent folder) and -t (top-level folder) as desired."
    echo "   The -sf force overwrites the existing files, which is done to ensure it's starting from a known default state. It will overwrite the existing files in the /opt/apex/prime-pubmainnet folder."
    exit 1
fi

# User input prompts
if [[ -z "$node_name" ]]; then
    read -p "Enter the node name to be displayed in gLiveView: " node_name
fi
if [[ -z "$cpu_cores" ]]; then
    read -p "Enter the number of CPU cores to assign to the running Apex/Cardano instance: " cpu_cores
fi
if [[ -z "$cnode_port" ]]; then
    read -p "Enter the port that the cardano-node Prime instance should listen on (default 5521): " cnode_port
fi
cnode_port=${cnode_port:-5521}
if [[ -z "$prometheus_port" ]]; then
    read -p "Enter the Prometheus port to use (default 12798, EKG port will be set to 1 less than the Prometheus value supplied): " prometheus_port
fi
prometheus_port=${prometheus_port:-12798}

# Retrieve _HOME variables from .bashrc only when the target folder was not supplied.
declare -A home_vars
if [[ -z "$APEX_TOP_LEVEL_FOLDER" ]]; then
    while IFS='=' read -r key value; do
        if [[ $key == *_HOME ]]; then
            home_vars[$key]=$value
        fi
    done < ~/.bashrc

    if [[ -n "$home_var_name" ]]; then
        if [[ -n "${home_vars[$home_var_name]:-}" ]]; then
            APEX_TOP_LEVEL_FOLDER=${home_vars[$home_var_name]}
        else
            echo "Could not find home variable: $home_var_name"
            exit 1
        fi
    fi

    if [[ -z "$APEX_TOP_LEVEL_FOLDER" ]]; then
        echo "Select the variable that corresponds to the home folder of the Apex install:"
        select home_var in "${!home_vars[@]}"; do
            APEX_TOP_LEVEL_FOLDER=${home_vars[$home_var]}
            break
        done
    fi
fi

if [[ -z "$APEX_TOP_LEVEL_FOLDER" || ! -d "$APEX_TOP_LEVEL_FOLDER" ]]; then
    echo "Resolved Apex top-level folder is invalid: $APEX_TOP_LEVEL_FOLDER"
    exit 1
fi

# Check and install dependencies
if ! command -v python3 &> /dev/null; then
    echo "Python 3 not found, installing..."
    sudo apt-get update
    sudo apt-get install -y python3
fi

if ! command -v pip3 &> /dev/null; then
    echo "pip3 not found, installing..."
    sudo apt-get install -y python3-pip
fi

if ! python3 -c "import yaml" &> /dev/null; then
    echo "PyYAML not found, installing..."
    pip3 install pyyaml
fi

# Download and rename configuration files
# Apex-Fusion source path no longer serves these files. Use the maintained guild source instead.
base_url="https://raw.githubusercontent.com/Scitz0/guild-operators-apex/main/files/configs/afpm"
files=("config.json" "topology.json" "byron-genesis.json" "shelley-genesis.json" "alonzo-genesis.json" "conway-genesis.json")
dest_files=("config.json" "topology.json" "byron-genesis.json" "shelley-genesis.json" "alonzo-genesis.json" "conway-genesis.json")

for i in "${!files[@]}"; do
    curl -sfL -o "$APEX_TOP_LEVEL_FOLDER/files/${dest_files[$i]}" "$base_url/${files[$i]}"
    echo "Copied ${dest_files[$i]} to $APEX_TOP_LEVEL_FOLDER/files/${dest_files[$i]}"
done

# Build configuration.json from config.json for compatibility with existing env CONFIG setting.
cp "$APEX_TOP_LEVEL_FOLDER/files/config.json" "$APEX_TOP_LEVEL_FOLDER/files/configuration.json"
echo "Copied config.json to configuration.json"

# Replace values in the env file
sed -i "s/#CNODE_PORT=6000/CNODE_PORT=$cnode_port/g" "$APEX_TOP_LEVEL_FOLDER/scripts/env"
echo "Replaced CNODE_PORT in $APEX_TOP_LEVEL_FOLDER/scripts/env"

sed -i "s|#CONFIG=\"\${CNODE_HOME}/files/config.json\"|CONFIG=\"${APEX_TOP_LEVEL_FOLDER}/files/configuration.json\"|g" "$APEX_TOP_LEVEL_FOLDER/scripts/env"
echo "Replaced CONFIG in $APEX_TOP_LEVEL_FOLDER/scripts/env"

sed -i "s/#STRICT_VERSION_CHECK=\"Y\"/STRICT_VERSION_CHECK=\"N\"/g" "$APEX_TOP_LEVEL_FOLDER/scripts/env"
echo "Replaced STRICT_VERSION_CHECK in $APEX_TOP_LEVEL_FOLDER/scripts/env"

sed -i "s/#SHELLEY_TRANS_EPOCH=208/SHELLEY_TRANS_EPOCH=2/g" "$APEX_TOP_LEVEL_FOLDER/scripts/env"
echo "Replaced SHELLEY_TRANS_EPOCH in $APEX_TOP_LEVEL_FOLDER/scripts/env"

# Calculate EKG port
ekg_port=$((prometheus_port - 1))

# Modify the paths and ports in configuration.json using jq
# Also normalize logging to StdoutSK (journald-only) with minSeverity Error
jq --arg port "$prometheus_port" --arg ekg "$ekg_port" '
    .hasPrometheus[1] = ($port | tonumber)
    | .hasEKG = ($ekg | tonumber)
    | .ByronGenesisFile = "byron-genesis.json"
    | .ShelleyGenesisFile = "shelley-genesis.json"
    | .AlonzoGenesisFile = "alonzo-genesis.json"
    | .ConwayGenesisFile = "conway-genesis.json"
    | .minSeverity = "Error"
    | .defaultScribes = [["StdoutSK", "stdout"]]
    | .setupScribes = [{"scKind": "StdoutSK", "scName": "stdout", "scFormat": "ScText"}]
' "$APEX_TOP_LEVEL_FOLDER/files/configuration.json" > "$APEX_TOP_LEVEL_FOLDER/files/configuration.tmp.json"
mv "$APEX_TOP_LEVEL_FOLDER/files/configuration.tmp.json" "$APEX_TOP_LEVEL_FOLDER/files/configuration.json"
echo "Normalized logging to StdoutSK with Error severity, updated ports and genesis paths in configuration.json"

# Update gLiveView and cnode.sh scripts
sed -i "s|#NODE_NAME=\"Cardano Node\"|NODE_NAME=\"$node_name\"|g" "$APEX_TOP_LEVEL_FOLDER/scripts/gLiveView.sh"
echo "Updated NODE_NAME in gLiveView.sh"
sed -i "s/^#RETRIES=3/RETRIES=300/" $APEX_TOP_LEVEL_FOLDER/scripts/gLiveView.sh
sed -i "s|#CPU_CORES=4|CPU_CORES=$cpu_cores|g" "$APEX_TOP_LEVEL_FOLDER/scripts/cnode.sh"

# Final instructions and reminders
echo "Please ensure the following manual changes are made if necessary:"
echo -e "\n\e[1mFirewall Access:\e[0m"
echo "Don't forget to open inbound firewall access to the CNODE_PORT env value if you are running a relay node."

echo -e "\n\e[1mService Configuration:\e[0m"
echo "To enable the cardano-node instance to run as a service, you can use the following command:"
echo -e "\e[7m${APEX_TOP_LEVEL_FOLDER}/scripts/cnode.sh -d\e[0m"

# Extract the last folder name from the selected path
SERVICE_NAME=$(basename "$APEX_TOP_LEVEL_FOLDER")

# Display the command to start the service
echo -e "\nYou will need to start the service manually the first time using the following command:"
echo -e "\e[7msudo systemctl start $SERVICE_NAME\e[0m\n"

echo "Script execution completed successfully."
