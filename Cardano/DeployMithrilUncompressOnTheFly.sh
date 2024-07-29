#!/bin/bash

# This script retrieves the latest Mithril Mainnet snapshot from a JSON URL,
# extracts the snapshot data, and deploys it to a specified directory.
# It is based on the excellent script found at https://github.com/asnakep/Mithril-Snapshot-Deployer/releases/tag/v1.0.0
# It mainly differs by uncompressed the snapshot on the fly, saving disk space and time, wihtout the need to store the compressed file.

# Define color codes for output
export whi=`printf "\033[1;37m"`
export gre=`printf "\033[1;36m"`

# Clear the terminal
tput clear

# Print the script title
echo
echo $gre"Deploy Latest Mithril Mainnet Snapshot"
echo

# Define the URL where the snapshots are located
snapshots="https://aggregator.release-mainnet.api.mithril.network/aggregator/artifact/snapshots"

# Get the latest snapshot data in JSON format
last_snapshot=$(curl -s $snapshots | jq -r .[0])

# Extract and print various pieces of information about the snapshot
digest=$(echo $last_snapshot | jq -r '.digest')
echo $whi"Snapshot Digest: $gre$digest"

network=$(echo $last_snapshot | jq -r '.beacon.network')
echo $whi"Network: $gre$network"

epoch=$(echo $last_snapshot | jq -r '.beacon.epoch')
echo $whi"Epoch: $gre$epoch"

immutable_file_number=$(echo $last_snapshot | jq -r '.beacon.immutable_file_number')
echo $whi"Immutable File Number: $gre$immutable_file_number"

certificate_hash=$(echo $last_snapshot | jq -r '.certificate_hash')
echo $whi"Certificate Hash: $gre$certificate_hash"

size=$(echo $last_snapshot | jq -r '.size')
size_gb=$((size / 1024 / 1024))
size_gb_format=$(echo $size_gb | awk '{print substr($0, 1, length($0)-3) "." substr($0, length($0)-1)}')
echo $whi"Size: $gre$size_gb_format""Gb"

created_at=$(echo $last_snapshot | jq -r '.created_at' | awk '{print substr($0, 1, length($0)-11)}')
echo $whi"Created At: $gre$created_at"

compression_algorithm=$(echo $last_snapshot | jq -r '.compression_algorithm')
echo $whi"Compression Algorithm: $gre$compression_algorithm"

cardano_node_version=$(echo $last_snapshot | jq -r '.cardano_node_version')
echo $whi"Cardano Node Version: $gre$cardano_node_version"

downloadUrl=$(echo $last_snapshot | jq -r '.locations[]')
echo $whi"Download Url: $gre$downloadUrl"

# Print some warnings and information to the user
echo
echo $whi"A highly compressed file will expand to roughly four times its size upon extraction."
echo
echo $whi"Please ensure you've enough space to perform this operation."
echo
echo $whi"Paste your Cardano Blockchain DB Path: "
echo

# Get the path where the user wants to deploy the snapshot
read -r inputPath

dbdir=$inputPath
echo

# Print the snapshot digest and the directory where it will be deployed
echo $whi"Latest Mithril Snapshot $gre$digest"
echo $whi"will be downloaded and deployed under directory: $gre$dbdir"
echo $gre

# Check if the 'pv' command is available, if not, install it
if ! command -v pv &> /dev/null
then
    echo "pv could not be found"
    echo "Installing pv..."
    if [ -f /etc/debian_version ]; then
        sudo apt-get update && sudo apt-get install -y pv
    elif [ -f /etc/redhat-release ]; then
        sudo yum update && sudo yum install -y pv
    else
        echo "Unsupported Linux distribution. Please install pv manually."
        progress_cmd="cat"
    fi
else
    progress_cmd="pv"
fi

# Check if the 'unzstd' command is available, if not, install it
if ! command -v unzstd &> /dev/null
then
    echo "unzstd could not be found"
    echo "Installing unzstd..."
    if [ -f /etc/debian_version ]; then
        sudo apt-get update && sudo apt-get install -y zstd
    elif [ -f /etc/redhat-release ]; then
        sudo yum update && sudo yum install -y zstd
    else
        echo "Unsupported Linux distribution. Please install unzstd manually."
        exit 1
    fi
fi

# Change to the directory where the snapshot will be deployed
cd $dbdir

# Start a timer
start_time=$(date "+%s")

# Download the snapshot, show a progress bar, extract the snapshot, and unpack it
echo $whi"Downloading and extracting snapshot"
wget -qO- $downloadUrl | $progress_cmd | unzstd | tar -xv

# Print the directory where the snapshot has been deployed
echo
echo $whi"Cardano Blockchain DB has been restored under: $gre$dbDir"
echo $whi

# List the files in the directory
ls -l $dbDir
echo

# Stop the timer and print the elapsed time
end_time=$(date "+%s")
elapsed=$(date -u -d @$((end_time - start_time)) +"%T")

echo "Elapsed hh:mm:ss $elapsed"
