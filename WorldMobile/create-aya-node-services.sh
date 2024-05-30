#!/bin/bash

# Check if script is run as sudo
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as sudo" 
   exit 1
fi

# Get the username of the user who invoked sudo
user=$(who am i | awk '{print $1}')

echo "Please note that the requirements for RAM and hard drive space will continually increase over time. On May 26, 2024, it was 1 GB of RAM and 15 GB of hard drive space. Plan accordingly and don't overcommit and run out of resources."

# Find the highest numbered aya-node directory
last_node=$(ls /opt | grep aya-node | sort -V | tail -n 1)
last_node_number=${last_node#aya-node}

read -p "How many additional Aya nodes do you want to create? " copies

start=$((last_node_number + 1))
end=$((last_node_number + copies))

for i in $(seq $start $end)
do
mkdir -p /opt/aya-node${i}

cat << EOF > aya-node${i}.service
[Unit]
Description=AyA Node${i}
After=network.target

[Service]
WorkingDirectory=/opt/aya-node${i}
ExecStart="/opt/aya-node${i}/start_aya_validator${i}.sh"
User=stakeman
Restart=always
RestartSec=90
LimitNOFILE=4096

[Install]
WantedBy=multi-user.target
EOF

cat << EOF > /opt/aya-node${i}/start_aya_validator${i}.sh
#!/usr/bin/env bash
/opt/aya-node${i}/target/release/aya-node     --base-path /opt/aya-node${i}/data/validator     --validator     --chain /opt/aya-node${i}/wm-devnet-chainspec.json     --port $((30333+i-1))     --rpc-port $((9944+i-1))  --prometheus-external --prometheus-port $((9615+i-1))   --log info     --bootnodes /dns/devnet-rpc.worldmobilelabs.com/tcp/30340/ws/p2p/12D3KooWRWZpEJygTo38qwwutM1Yo7dQQn8xw1zAAWpfMiAqbmyK
EOF

chmod +x /opt/aya-node${i}/start_aya_validator${i}.sh

# Change ownership of the files to the user who ran the script
chown -R $user:$user /opt/aya-node${i}
done

echo "Remember to open ports for the public port value for other Aya nodes to be able to reach your nodes."
echo "--port: 30333-$(expr 30333 + $end - 1)"