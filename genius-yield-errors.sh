#!/bin/bash

# Get the ID of the most recently started container
container_id=$(sudo docker ps -l -q)

# Run the docker logs command and save the output to a variable
log_data=$(sudo docker logs $container_id)

# Get the current date and time, subtract 30 minutes, and format it to match the log timestamps
start_time=$(date -u -d"30 minutes ago" +"%Y-%m-%dT%H:%M")

# Use awk to filter the log data for entries from the last 30 minutes
recent_logs=$(echo "$log_data" | awk -v start_time="$start_time" '$0 > start_time')

# Define the phrases to count
phrases=("Matches Found:" "Total matches found:" "Matches to Execute:" "Number Of Matches To Execute:" "Number Of Matches Built:" "Transactions are losing money:" "Transaction to submit:" "Submitted order matching transaction with id:" "SubmitTxException:" "Insufficient funds:" "BuildTxException" "Transaction losing lovelaces:" "Transaction losing tokens:" "CompleteChecks:")

# Count the occurrences of each phrase
for phrase in "${phrases[@]}"; do
    count=$(echo "$recent_logs" | grep -o "$phrase" | wc -l)
    echo "$phrase: $count"
done