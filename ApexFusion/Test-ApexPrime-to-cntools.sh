#!/bin/bash
# This script is intended to be run at the top of the folder path of the Apex tar.gz folder path.
# In other words, extract the Apex files into a directory and this file as well and run from there.

# This script is intended to be run at the top of the folder path of the Apex tar.gz folder path.
# If you are doing multiple instances on the same server, you'll need to change the hasEKG and hasPrometheus
# ports in the configuration.yaml file before running this script, or the configuration.json file after running
# this script.
# You will also need to change the CNODE_PORT running port in the env file in the scripts folder.



# Ask the user if they have run Koios/cntools setup
read -p "Have you run Koios/cntools setup? (y/n) " answer
if [[ $answer != y ]]; then
    echo "Please setup Koios/cntools as per the following instructions then come back and run this script:"
    echo "1. Download the Guild Community Tools (cntools) using the following command:"
    echo "   curl -sS -o guild-deploy.sh https://raw.githubusercontent.com/cardano-community/guild-operators/master/scripts/cnode-helper-scripts/guild-deploy.sh"
    echo "2. Make the script executable:"
    echo "   chmod 755 guild-deploy.sh"
    echo "3. Run the script with the following command and force the 8.7.3 version the tools:"
    echo "   ./guild-deploy.sh -p /opt/apex -b node-8.7.3 -t prime-pubtestnet -u -sf"
    echo "   This would install the cntools in the /opt/apex/prime-pubtestnet folder; you can modify as desired."
    echo "   The -sf force overwrites the existing files, which is done to ensure it's starting from a known state."
    exit 1
fi

# Ask the user for the node name
read -p "What do you want the running Apex node to be called in gLiveView? " node_name

# Ask the user for the number of CPU cores to assign
read -p "How many CPU cores do you want to assign to the running Apex/Cardano instance? " cpu_cores

# Get all "_HOME" variables from .bashrc
declare -A home_variables
while IFS= read -r line; do
    VAR_NAME="${line%%=*}"
    VAR_VALUE="${line#*=}"
    home_variables["$VAR_NAME"]="$VAR_VALUE"
done < <(grep -oP '(?<=export ).*?_HOME=.*' ~/.bashrc)

# Ask the user to choose the variable
echo "Please choose the variable that corresponds to the home folder of the Apex install you are trying to modify:"
select VAR_NAME in "${!home_variables[@]}"; do
    if [[ -n $VAR_NAME ]]; then
        APEX_TOP_LEVEL_FOLDER="${home_variables[$VAR_NAME]}"
        break
    fi
done

# Check for Python and install if necessary
if ! command -v python3 &> /dev/null
then
    echo "Python could not be found. Installing..."
    sudo apt-get update
    sudo apt-get install -y python3
fi

# Check for pip and install if necessary
if ! command -v pip3 &> /dev/null
then
    echo "pip could not be found. Installing..."
    sudo apt-get install -y python3-pip
fi

# Check for PyYAML and install if necessary
if ! python3 -c "import yaml" &> /dev/null
then
    echo 'PyYAML could not be found. Installing...'
    pip3 install pyyaml
fi

# Copy and rename the files
cp ./config/node/configuration.yaml "$APEX_TOP_LEVEL_FOLDER/files/configuration.yaml"
echo "Copied configuration.yaml to $APEX_TOP_LEVEL_FOLDER/files/configuration.yaml"

cp ./config/node/topology.json "$APEX_TOP_LEVEL_FOLDER/files/topology.json"
echo "Copied topology.json to $APEX_TOP_LEVEL_FOLDER/files/topology.json"

cp ./config/node/genesis/byron/genesis.json "$APEX_TOP_LEVEL_FOLDER/files/byron-genesis.json"
echo "Copied byron-genesis.json to $APEX_TOP_LEVEL_FOLDER/files/byron-genesis.json"

cp ./config/node/genesis/shelley/genesis.json "$APEX_TOP_LEVEL_FOLDER/files/shelley-genesis.json"
echo "Copied shelley-genesis.json to $APEX_TOP_LEVEL_FOLDER/files/shelley-genesis.json"

cp ./config/node/genesis/shelley/genesis.alonzo.json "$APEX_TOP_LEVEL_FOLDER/files/alonzo-genesis.json"
echo "Copied genesis.alonzo.json to $APEX_TOP_LEVEL_FOLDER/files/alonzo-genesis.json"

cp ./config/node/genesis/shelley/genesis.conway.json "$APEX_TOP_LEVEL_FOLDER/files/conway-genesis.json"
echo "Copied genesis.conway.json to $APEX_TOP_LEVEL_FOLDER/files/conway-genesis.json"

# Convert configuration.yaml to configuration.json
python3 -c "\
import yaml, json
with open('$APEX_TOP_LEVEL_FOLDER/files/configuration.yaml', 'r') as yaml_file, open('$APEX_TOP_LEVEL_FOLDER/files/configuration.json', 'w') as json_file:
    data = yaml.safe_load(yaml_file)
    json.dump(data, json_file, indent=4)
"
echo "Converted configuration.yaml to configuration.json"

# Replace values in the env file
sed -i 's/#CNODE_PORT=6000/CNODE_PORT=5521/g' "$APEX_TOP_LEVEL_FOLDER/scripts/env"
echo "Replaced CNODE_PORT in $APEX_TOP_LEVEL_FOLDER/scripts/env"

sed -i "s|#CONFIG=\"\${CNODE_HOME}/files/config.json\"|CONFIG=\"${APEX_TOP_LEVEL_FOLDER}/files/configuration.json\"|g" "$APEX_TOP_LEVEL_FOLDER/scripts/env"
echo "Replaced CONFIG in $APEX_TOP_LEVEL_FOLDER/scripts/env"

# Modify the paths in configuration.json
sed -i 's|"ByronGenesisFile": "genesis/byron/genesis.json"|"ByronGenesisFile": "byron-genesis.json"|g' "$APEX_TOP_LEVEL_FOLDER/files/configuration.json"
echo "Updated ByronGenesisFile in configuration.json"

sed -i 's|"ShelleyGenesisFile": "genesis/shelley/genesis.json"|"ShelleyGenesisFile": "shelley-genesis.json"|g' "$APEX_TOP_LEVEL_FOLDER/files/configuration.json"
echo "Updated ShelleyGenesisFile in configuration.json"

sed -i 's|"AlonzoGenesisFile": "genesis/shelley/genesis.alonzo.json"|"AlonzoGenesisFile": "alonzo-genesis.json"|g' "$APEX_TOP_LEVEL_FOLDER/files/configuration.json"
echo "Updated AlonzoGenesisFile in configuration.json"

sed -i 's|"ConwayGenesisFile": "genesis/shelley/genesis.conway.json"|"ConwayGenesisFile": "conway-genesis.json"|g' "$APEX_TOP_LEVEL_FOLDER/files/configuration.json"
echo "Updated ConwayGenesisFile in configuration.json"

# Replace NODE_NAME in gLiveView.sh
sed -i "s|#NODE_NAME=\"Cardano Node\"|NODE_NAME=\"$node_name\"|g" "$APEX_TOP_LEVEL_FOLDER/scripts/gLiveView.sh"
echo "Updated NODE_NAME in gLiveView.sh"

# Replace CPU_CORES in cnode.sh
sed -i "s|#CPU_CORES=4|CPU_CORES=$cpu_cores|g" "$APEX_TOP_LEVEL_FOLDER/scripts/cnode.sh"
echo "Updated CPU_CORES in cnode.sh"

# Job finished, remind of manual changes possibly required
echo -e "\n\e[1mScript execution completed.\e[0m Please note the following:"

echo -e "\n\e[1mPort Configuration:\e[0m"
echo "If you are running multiple instances on the same server, you'll need to manually change these to unused port numbers:"
echo -e "1. hasEKG and hasPrometheus port numbers in the configuration.yaml file \e[1mBEFORE\e[0m running this script, or in the configuration.json file after running this script."
echo "2. the CNODE_PORT running port in the env file in the scripts folder."

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