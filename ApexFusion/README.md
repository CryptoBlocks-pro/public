# ApexPrime-to-cntools.sh

## Overview

The `ApexPrime-to-cntools.sh` script is designed to set up and configure an Apex/Cardano node instance for the Apex Prime testnet. This script is provided by Crypto Blocks, LLC for use as-is with no warranty.

## Purpose

This script converts a standard cntools Cardano install to the Apex Prime testnet. It can be used to create multiple instances running on the same server. For that use case, you will need to choose different ports for each instance you install.

This script will download all Apex Fusion Prime components directly from their GitHub repository. No need to pre-download anything.

## Prerequisites

Before running this script, ensure you have the following:

- Koios/cntools setup completed.
  See https://cardano-community.github.io/guild-operators/basics/ for usage. A recommended command to run is the following, noting that
  - `-p` is the parent folder in which the top level folder gets created
  - `-t` is the top-level folder to install the cntools instance into
  - `-b` is an alternate branch of cntools, for specified older cardano-node version compatibility.
  - `-s` is a selective install to control which components are installed
  - `-d` will download cardano-node and cardano-cli on amd64 systems (but not aarch64)
  - `-f` will force overwrite config files so that it's in the default state
  
  In this example we will install a cntools intance to /opt/apex/pool1 compatible with cardano-node 8.7.3
  
  ```./guild-deploy.sh -p /opt/apex -b node-8.7.3 -t pool1 -u -sdf"```


- A cntools Cardano install.
  Cardano-node can be installed via your choice of methods. Cntools will download it for you. For aarch64/arm64 systems it will not.

The following will be installed if not present on the system:
- Python 3 and pip3
- `jq` for JSON manipulation.

## Usage

1. **Clone the Repository**:
   ```bash
   git clone https://github.com/yourusername/apexprime-to-cntools.git
   cd apexprime-to-cntools
   ./ApexPrime-to-cntools.sh  