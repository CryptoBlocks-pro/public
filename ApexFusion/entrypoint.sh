#!/usr/bin/env bash

trap 'killall -s SIGINT cardano-node' SIGINT SIGTERM
# "docker run --init" to enable the docker init proxy
# To manually test: docker kill -s SIGTERM container

head -n 8 ~/.scripts/banner.txt

# shellcheck disable=SC1090
. ~/.bashrc > /dev/null 2>&1

[[ -z "${ENTRYPOINT_PROCESS}" ]] && export ENTRYPOINT_PROCESS=cnode.sh

echo "NETWORK: $NETWORK $POOL_NAME $TOPOLOGY"
echo "ENTRYPOINT_PROCESS: $ENTRYPOINT_PROCESS"

# Set CNODE_HOME based on the network
if [[ "$NETWORK" == "afpm" ]]; then
  [[ -z "${CNODE_HOME}" ]] && export CNODE_HOME=/opt/apex/prime
else
  [[ -z "${CNODE_HOME}" ]] && export CNODE_HOME=/opt/cardano/cnode
fi

[[ -z "${CNODE_PORT}" ]] && export CNODE_PORT=6000

echo "NODE: $HOSTNAME - Port:$CNODE_PORT - $POOL_NAME";
cardano-node --version;

if [[ "${ENABLE_BACKUP}" == "Y" ]] || [[ "${ENABLE_RESTORE}" == "Y" ]]; then
  [[ ! -d "${CNODE_HOME}"/backup/$NETWORK-db ]] && mkdir -p $CNODE_HOME/backup/$NETWORK-db
  dbsize=$(du -s $CNODE_HOME/db | awk '{print $1}')
  bksizedb=$(du -s $CNODE_HOME/backup/$NETWORK-db 2>/dev/null | awk '{print $1}')
  if [[ "${ENABLE_RESTORE}" == "Y" ]] && [[ "$dbsize" -lt "$bksizedb" ]]; then
    echo "Backup Started"
    cp -rf "${CNODE_HOME}"/backup/"${NETWORK}"-db/* "${CNODE_HOME}"/db 2>/dev/null
    echo "Backup Finished"
  fi

  if [[ "${ENABLE_BACKUP}" == "Y" ]] && [[ "$dbsize" -gt "$bksizedb" ]]; then
    echo "Restore Started"
    cp -rf "${CNODE_HOME}"/db/* "${CNODE_HOME}"/backup/"${NETWORK}"-db/ 2>/dev/null
    echo "Restore Finished"
  fi
fi

# Customisation
customise () {
  if [[ "$NETWORK" == "afpm" ]]; then
    find /opt/apex/prime/files -name "*config*.json" -print0 | xargs -0 sed -i 's/127.0.0.1/0.0.0.0/g' > /dev/null 2>&1
    grep -i ENABLE_CHATTR /opt/apex/prime/scripts/cntools.sh >/dev/null && sed -E -i 's/^#?ENABLE_CHATTR=(true|false)?/ENABLE_CHATTR=false/g' /opt/apex/prime/scripts/cntools.sh > /dev/null 2>&1
    grep -i ENABLE_DIALOG /opt/apex/prime/scripts/cntools.sh >/dev/null && sed -E -i 's/^#?ENABLE_DIALOG=(true|false)?/ENABLE_DIALOG=false/' /opt/apex/prime/scripts/cntools.sh > /dev/null 2>&1
    find /opt/apex/prime/files -name "*config*.json" -print0 | xargs -0 sed -i 's/\"hasEKG\": 12788,/\"hasEKG\": [\n    \"0.0.0.0\",\n    12788\n],/g' > /dev/null 2>&1
  else
    find /opt/cardano/cnode/files -name "*config*.json" -print0 | xargs -0 sed -i 's/127.0.0.1/0.0.0.0/g' > /dev/null 2>&1
    grep -i ENABLE_CHATTR /opt/cardano/cnode/scripts/cntools.sh >/dev/null && sed -E -i 's/^#?ENABLE_CHATTR=(true|false)?/ENABLE_CHATTR=false/g' /opt/cardano/cnode/scripts/cntools.sh > /dev/null 2>&1
    grep -i ENABLE_DIALOG /opt/cardano/cnode/scripts/cntools.sh >/dev/null && sed -E -i 's/^#?ENABLE_DIALOG=(true|false)?/ENABLE_DIALOG=false/' /opt/cardano/cnode/scripts/cntools.sh > /dev/null 2>&1
    find /opt/cardano/cnode/files -name "*config*.json" -print0 | xargs -0 sed -i 's/\"hasEKG\": 12788,/\"hasEKG\": [\n    \"0.0.0.0\",\n    12788\n],/g' > /dev/null 2>&1
  fi
  return 0
}

load_configs () {
  cp -rf /conf/"${NETWORK}"/* "$CNODE_HOME"/files/
}

if [[ -n "${NETWORK}" ]] ; then
  if [[ "${UPDATE_CHECK}" == "Y" ]] ; then
    if [[ "$NETWORK" == "afpm" ]]; then
      "$CNODE_HOME"/scripts/guild-deploy.sh -b main -n afpm -p /opt/apex/prime -t POOL -s f > /dev/null 2>&1
    else
      "$CNODE_HOME"/scripts/guild-deploy.sh -n "$NETWORK" -u -s f > /dev/null 2>&1
    fi
  else
    load_configs
  fi

customise \
&& exec "$CNODE_HOME/scripts/$ENTRYPOINT_PROCESS" "$@"