#!/bin/bash

# ApexPrime-to-cntools.sh
# This script sets up and configures an Apex/Cardano node instance for the Apex Prime testnet.
# Provided by Crypto Blocks, LLC for use as-is with no warranty.
# Website: https://cryptoblocks.pro
# Email: admin@cryptoblocks.pro

# Changelog October 20, 2024
# Now handles multiple cardano-node versions that Apex supports. No longer requires downloading the zip file and uncompressing... will download the files directly from the Apex Prime testnet repo.

# Introduction prompt
echo "This script will convert a cntools Cardano install to Apex Prime testnet."
echo "It can be used to create multiple instances running on the same server."
echo "For that use case, you will need to choose different ports for each instance you install."
echo ""

# Prompt user to select the version of cardano-node
echo "Select the version of cardano-node for Apex Prime testnet:"
echo "NOTE: this script will not install cardano-node. You will need to do this yourself."
echo "a) 8.7.3"
echo "b) 8.9.4"
echo "c) 9.2.1"
read -p "Enter your choice (a/b/c): " version_choice

case $version_choice in
    a) cardano_version="node-8.7.3" ;;
    b) cardano_version="node-8.9.4" ;;
    c) cardano_version="node-9.2.1" ;;
    *) echo "Invalid choice"; exit 1 ;;
esac

# Check for Koios/cntools setup
read -p "Have you run the Koios/cntools setup for the instance you want to convert to Apex Prime testnet? (y/n): " koios_setup
if [ "$koios_setup" != "y" ]; then
    echo "Please setup Koios/cntools as per the following instructions then come back and run this script:"
    echo "1. Download the Guild Community Tools (cntools) using the following command:"
    echo "   curl -sS -o guild-deploy.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/guild-deploy.sh"
    echo "2. Make the script executable:"
    echo "   chmod 755 guild-deploy.sh"
    echo "3. Run the script with the following command and force the cardano-node version to use. In this example we are forceing 8.7.3, but substitue with your target Apex Prime supported-version:"
    echo "   ./guild-deploy.sh -p /opt/apex -b node-8.7.3 -t prime-pubtestnet -u -sdf"
    echo "   (the "d" flag will download the cardano-node and cardano-cli binaries on x64 systems. You can omit this if you already have them)"
    echo "   This would install the cntools in the /opt/apex/prime-pubtestnet folder; you can modify the -p (parent folder) and -t (top-level folder) as desired."
    echo "   The -sf force overwrites the existing files, which is done to ensure it's starting from a known default state. It will overwrite the existing files in the /opt/apex/prime-pubtestnet folder."
    exit 1
fi

# User input prompts
read -p "Enter the node name to be displayed in gLiveView: " node_name
read -p "Enter the number of CPU cores to assign to the running Apex/Cardano instance: " cpu_cores
read -p "Enter the port that the cardano-node Prime instance should listen on (default 5521): " cnode_port
cnode_port=${cnode_port:-5521}
read -p "Enter the Prometheus port to use (default 12798, EKG port will be set to 1 less than the Prometheus value supplied): " prometheus_port
prometheus_port=${prometheus_port:-12798}

# Retrieve _HOME variables from .bashrc
declare -A home_vars
while IFS='=' read -r key value; do
    if [[ $key == *_HOME ]]; then
        home_vars[$key]=$value
    fi
done < ~/.bashrc

# User selection of home folder variable
echo "Select the variable that corresponds to the home folder of the Apex install:"
select home_var in "${!home_vars[@]}"; do
    APEX_TOP_LEVEL_FOLDER=${home_vars[$home_var]}
    break
done

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
base_url="https://raw.githubusercontent.com/Apex-Fusion/prime-docker/refs/heads/main/testnet/$cardano_version/config/node"
files=("configuration.yaml" "topology.json" "genesis/byron/genesis.json" "genesis/shelley/genesis.json" "genesis/shelley/genesis.alonzo.json" "genesis/shelley/genesis.conway.json")
dest_files=("configuration.yaml" "topology.json" "byron-genesis.json" "shelley-genesis.json" "alonzo-genesis.json" "conway-genesis.json")

for i in "${!files[@]}"; do
    curl -o "$APEX_TOP_LEVEL_FOLDER/files/${dest_files[$i]}" "$base_url/${files[$i]}"
    echo "Copied ${dest_files[$i]} to $APEX_TOP_LEVEL_FOLDER/files/${dest_files[$i]}"
done

# Convert configuration.yaml to configuration.json
python3 -c "
import yaml, json, sys
with open('$APEX_TOP_LEVEL_FOLDER/files/configuration.yaml', 'r') as yaml_file:
    config = yaml.safe_load(yaml_file)
with open('$APEX_TOP_LEVEL_FOLDER/files/configuration.json', 'w') as json_file:
    json.dump(config, json_file, indent=2)
"
echo "Converted configuration.yaml to configuration.json"

# Replace values in the env file
sed -i "s/#CNODE_PORT=6000/CNODE_PORT=$cnode_port/g" "$APEX_TOP_LEVEL_FOLDER/scripts/env"
echo "Replaced CNODE_PORT in $APEX_TOP_LEVEL_FOLDER/scripts/env"

sed -i "s|#CONFIG=\"\${CNODE_HOME}/files/config.json\"|CONFIG=\"${APEX_TOP_LEVEL_FOLDER}/files/configuration.json\"|g" "$APEX_TOP_LEVEL_FOLDER/scripts/env"
echo "Replaced CONFIG in $APEX_TOP_LEVEL_FOLDER/scripts/env"

# Calculate EKG port
ekg_port=$((prometheus_port - 1))

# Modify the paths and ports in configuration.json using jq
jq --arg port "$prometheus_port" --arg ekg "$ekg_port" \
   '.hasPrometheus[1] = ($port | tonumber) | .hasEKG = ($ekg | tonumber) | .ByronGenesisFile = "byron-genesis.json" | .ShelleyGenesisFile = "shelley-genesis.json" | .AlonzoGenesisFile = "alonzo-genesis.json" | .ConwayGenesisFile = "conway-genesis.json"' \
   "$APEX_TOP_LEVEL_FOLDER/files/configuration.json" > "$APEX_TOP_LEVEL_FOLDER/files/configuration.tmp.json" && mv "$APEX_TOP_LEVEL_FOLDER/files/configuration.tmp.json" "$APEX_TOP_LEVEL_FOLDER/files/configuration.json"
echo "Replaced prometheus and ekg port, and updated genesis file paths in configuration.json"

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