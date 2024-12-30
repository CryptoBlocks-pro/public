import csv
import json
import os

# This script generates topology.json files for each server in a CSV file. It generates the localRoots and publicRoots sections based on the role of the server.
# The input file is defined in the Main function, server_list_file. The CSV file should have the following columns: address,port,friendly_name,role.
# The role can be either node or relay. For relay servers, extra entries are added to the publicRoots section.
#sample text file content:
#address,port,friendly_name,role
#relay1.foo.com,5521,Main-relay1,relay
#relay2.foo.com,5521,Main-relay2,relay
#node1.foo.com,5521,Main-node1,node
# save the file as apex-prime-servers.txt

# Define the extra entries for relays; these only get added in relay toplogy files, and are put in the publicRoots section
extra_relay_entries = [
    {"friendly_name": "", "address": "relay-g1.prime.mainnet.apexfusion.org", "port": 5521},
    {"friendly_name": "", "address": "relay-g2.prime.mainnet.apexfusion.org", "port": 5521}
]

# Custom JSON encoder to format accessPoints on one line
class CustomJSONEncoder(json.JSONEncoder):
    def encode(self, obj):
        if isinstance(obj, dict) and "accessPoints" in obj:
            access_points = obj["accessPoints"]
            obj["accessPoints"] = json.dumps(access_points, separators=(',', ':'))
            result = super().encode(obj)
            obj["accessPoints"] = access_points  # Restore original list
            return result.replace('"[', '[').replace(']"', ']')
        return super().encode(obj)

# Read the server list from a CSV file
def read_server_list(file_path):
    servers = []
    with open(file_path, mode='r') as file:
        csv_reader = csv.DictReader(file)
        for row in csv_reader:
            servers.append(row)
    return servers

# Generate the topology.json for each server
def generate_topology_files(servers):
    for server in servers:
        local_roots = [{"friendly_name": s['friendly_name'], "address": s['address'], "port": int(s['port'])} for s in servers if s['address'] != server['address'] or s['port'] != server['port']]
        if server['role'] == 'relay':
            local_roots.extend(extra_relay_entries)
            public_roots = [{"accessPoints": [entry for entry in extra_relay_entries], "advertise": True, "valency": 1}]
        else:
            public_roots = [{"accessPoints": [], "advertise": False}]
        
        topology = {
            "localRoots": [
                {
                    "accessPoints": local_roots,
                    "advertise": False,
                    "valency_INFO": "set the .localRoots.valency to the number of configured accessPoints",
                    "valency": len(local_roots)
                }
            ],
            "publicRoots": public_roots,
            "useLedgerAfterSlot_INFO": "the node will use the .publicRoots.accessPoints only until he synchronised up to slot .useLedgerAfterSlot. then P2P peering jumps in, plus static links to .localRoots.accessPoints",
            "useLedgerAfterSlot": -1 if server['role'] == 'node' else 0
        }
        
        file_name = f"{server['friendly_name']}_topology.json"
        with open(file_name, 'w') as file:
            json.dump(topology, file, indent=2, separators=(',', ': '), cls=CustomJSONEncoder)
        print(f"Generated {file_name}")

# Main function
def main():
    server_list_file = 'apex-prime-servers.txt'  # Path to your server list CSV file
    servers = read_server_list(server_list_file)
    generate_topology_files(servers)

if __name__ == "__main__":
    main()