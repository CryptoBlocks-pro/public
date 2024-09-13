#!/usr/bin/env bash

trap 'killall -s SIGINT cardano-node' SIGINT SIGTERM
# "docker run --init" to enable the docker init proxy
# To manually test: docker kill -s SIGTERM container

head -n 8 ~/.scripts/banner.txt

# shellcheck disable=SC1090
. ~/.bashrc > /dev/null 2>&1

[[ -z "${ENTRYPOINT_PROCESS}" ]] && export ENTRYPOINT_PROCESS=cnode.sh 

# Debugging
echo "testing, 1, 2, 3"
echo "NETWORK: $NETWORK $POOL_NAME $TOPOLOGY"
echo "ENTRYPOINT_PROCESS: $ENTRYPOINT_PROCESS"

[[ -z "${CNODE_HOME}" ]] && export CNODE_HOME=/opt/cardano/cnode 
[[ -z "${CNODE_PORT}" ]] && export CNODE_PORT=6000

echo "NODE: ${HOSTNAME} - Port:$CNODE_PORT - $POOL_NAME";
cardano-node --version;

# Cryptoblocks.pro Modified the Guildcomminity version of this script to use Azure Fileshare for backup and restore
# Make aure ENABLE_RESTORE are set to Y in the Helm values.yaml file
if [[ "${ENABLE_BACKUP}" == "Y" ]] || [[ "${ENABLE_RESTORE}" == "Y" ]]; then
  [[ ! -d "${CNODE_HOME}"/backup/$NETWORK-db ]] && mkdir -p $CNODE_HOME/backup/$NETWORK-db
  dbsize=$(du -s $CNODE_HOME/db | awk '{print $1}')
  bksizedb=$(du -s /mnt/${dbBootstrap.AzureFileshareName}/db 2>/dev/null | awk '{print $1}')
  if [[ "${ENABLE_RESTORE}" == "Y" ]] && [[ "$dbsize" -lt "$bksizedb" ]]; then
    echo "Restore Started"
    cp -rf /mnt/${dbBootstrap.AzureFileshareName}/db/* "${CNODE_HOME}"/db 2>/dev/null # Copy the db files from the Azure Fileshare to the db directory
    cp -rf /mnt/${dbBootstrap.AzureFileshareName}/files/topology.json "${CNODE_HOME}"/files 2>/dev/null # Copy the topology.json file from the Azure Fileshare to the files directory
    echo "Restore Finished"
  fi

  if [[ "${ENABLE_BACKUP}" == "Y" ]] && [[ "$dbsize" -gt "$bksizedb" ]]; then
    echo "Backup Started"
    cp -rf "${CNODE_HOME}"/db/* "${CNODE_HOME}"/backup/"${NETWORK}"-db/ 2>/dev/null
    echo "Backup Finished"
  fi
fi

# Customisation 
customise () {
  find /opt/cardano/cnode/files -name "*config*.json" -print0 | xargs -0 sed -i 's/127.0.0.1/0.0.0.0/g' > /dev/null 2>&1 
  grep -i ENABLE_CHATTR /opt/cardano/cnode/scripts/cntools.sh >/dev/null && sed -E -i 's/^#?ENABLE_CHATTR=(true|false)?/ENABLE_CHATTR=false/g' /opt/cardano/cnode/scripts/cntools.sh > /dev/null 2>&1
  grep -i ENABLE_DIALOG /opt/cardano/cnode/scripts/cntools.sh >/dev/null && sed -E -i 's/^#?ENABLE_DIALOG=(true|false)?/ENABLE_DIALOG=false/' /opt/cardano/cnode/scripts/cntools.sh > /dev/null 2>&1
  find /opt/cardano/cnode/files -name "*config*.json" -print0 | xargs -0 sed -i 's/\"hasEKG\": 12788,/\"hasEKG\": [\n    \"0.0.0.0\",\n    12788\n],/g' > /dev/null 2>&1
  return 0
}

# Function to load configuration files
load_configs () {
  # Check if topology.json exists in the target directory
  if [ ! -f "$CNODE_HOME/files/topology.json" ]; then
    cp -rf /conf/"${NETWORK}"/topology.json "$CNODE_HOME"/files/
  fi

#   # Copy other configuration files
#   cp -rf /conf/"${NETWORK}"/{alonzo,byron,conway,shelley}-genesis.json "$CNODE_HOME"/files/
#   cp -rf /conf/"${NETWORK}"/config.json "$CNODE_HOME"/files/
#   cp -rf /conf/"${NETWORK}"/db-sync-config.json "$CNODE_HOME"/files/
# }

# Create necessary directories
# mkdir -p /opt/cardano/cnode/files /opt/cardano/cnode/scripts

# Download configuration files to /opt/cardano/cnode/files
curl -s -o /opt/cardano/cnode/files/config.json https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${GUILD_DEPLOY_BRANCH}/files/configs/${network}/config.json
curl -s -o /opt/cardano/cnode/files/db-sync-config.json https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${GUILD_DEPLOY_BRANCH}/files/configs/${network}/db-sync-config.json
curl -s -o /opt/cardano/cnode/files/alonzo-genesis.json https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${GUILD_DEPLOY_BRANCH}/files/configs/${network}/alonzo-genesis.json
curl -s -o /opt/cardano/cnode/files/byron-genesis.json https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${GUILD_DEPLOY_BRANCH}/files/configs/${network}/byron-genesis.json
curl -s -o /opt/cardano/cnode/files/conway-genesis.json https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${GUILD_DEPLOY_BRANCH}/files/configs/${network}/conway-genesis.json
curl -s -o /opt/cardano/cnode/files/shelley-genesis.json https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${GUILD_DEPLOY_BRANCH}/files/configs/${network}/shelley-genesis.json

# Download scripts to /opt/cardano/cnode/scripts
curl -s -o /opt/cardano/cnode/scripts/guild-deploy.sh https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${GUILD_DEPLOY_BRANCH}/scripts/cnode-helper-scripts/guild-deploy.sh
curl -s -o /opt/cardano/cnode/scripts/mithril-client.sh https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${GUILD_DEPLOY_BRANCH}/scripts/cnode-helper-scripts/mithril-client.sh
curl -s -o /opt/cardano/cnode/scripts/mithril-signer.sh https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${GUILD_DEPLOY_BRANCH}/scripts/cnode-helper-scripts/mithril-signer.sh
curl -s -o /opt/cardano/cnode/scripts/mithril-relay.sh https://raw.githubusercontent.com/${G_ACCOUNT}/guild-operators/${GUILD_DEPLOY_BRANCH}/scripts/cnode-helper-scripts/mithril-relay.sh

# Set permissions and ownership
sudo chown -R guild:guild /opt/cardano/cnode/files /opt/cardano/cnode/scripts
sudo chmod -R a+rx /opt/cardano/cnode/files /opt/cardano/cnode/scripts

# Create a file with the name of the pod in the /opt/cardano/cnode/files directory
# touch /opt/cardano/cnode/files/${HOSTNAME}
touch /opt/cardano/cnode/files/$(hostname)

# Debugging
echo "File permissions for /opt/cardano/cnode/files/config.json:" $(ls -l /opt/cardano/cnode/files/config.json)


if [[ -n "${NETWORK}" ]] ; then
  if [[ "${UPDATE_CHECK}" == "Y" ]] ; then
    "$CNODE_HOME"/scripts/guild-deploy.sh -n "$NETWORK" -u -s f > /dev/null 2>&1
  else
    load_configs
  fi
else
  echo "Please set a NETWORK environment variable to one of: mainnet / preview / preprod / guild-mainnet / guild"
  echo "mount a '$CNODE_HOME/priv/files' volume containing: mainnet-config.json, mainnet-shelley-genesis.json, mainnet-byron-genesis.json, and mainnet-topology.json "
  echo "for active nodes set POOL_DIR environment variable where op.cert, hot.skey and vrf.skey files reside. (usually under '${CNODE_HOME}/priv/pool/$POOL_NAME' ) "
  echo "or just set POOL_NAME environment variable (for default path). "
fi

customise \
&& exec "$CNODE_HOME/scripts/$ENTRYPOINT_PROCESS" "$@"