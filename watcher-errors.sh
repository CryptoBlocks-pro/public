#!/bin/bash

# Get the current date and time, subtract 30 minutes, and format it to match the log timestamps
start_time=$(date -u -d"30 minutes ago" +"%Y-%m-%dT%H:%M")

# Run the docker logs command and save the output to a variable
log_data=$(sudo docker logs watcher-service-1)

# Use awk to filter the log data for entries from the last 30 minutes
recent_logs=$(echo "$log_data" | awk -v start_time="$start_time" '$0 > start_time')

# Use grep to separate the logs into info, warn, and error messages, and ignore lines starting with "at"
info_logs=$(echo "$recent_logs" | grep 'info' | grep -v '^at')
warn_logs=$(echo "$recent_logs" | grep 'warn' | grep -v '^at')
error_logs=$(echo "$recent_logs" | grep 'error' | grep -v '^at')

# Use sed to remove text within curly brackets, square brackets, "at height [value]", "in block [string]", "at block [string]", and "box id is: [string]"
info_logs=$(echo "$info_logs" | sed 's/{[^}]*}//g' | sed 's/\[[^]]*\]//g' | sed 's/at height [0-9]*//g' | sed 's/in block [a-zA-Z0-9]*//g' | sed 's/at block [a-zA-Z0-9]*//g' | sed 's/box id is: [a-zA-Z0-9]*//g' | sed 's/\(WID is set to:\) [a-zA-Z0-9]* /\1 MASKED-ID /g')
warn_logs=$(echo "$warn_logs" | sed 's/{[^}]*}//g' | sed 's/\[[^]]*\]//g' | sed 's/at height [0-9]*//g' | sed 's/in block [a-zA-Z0-9]*//g' | sed 's/at block [a-zA-Z0-9]*//g' | sed 's/box id is: [a-zA-Z0-9]*//g' | sed 's/\(WID is set to:\) [a-zA-Z0-9]* /\1 MASKED-ID /g')
error_logs=$(echo "$error_logs" | sed 's/{[^}]*}//g' | sed 's/\[[^]]*\]//g' | sed 's/at height [0-9]*//g' | sed 's/in block [a-zA-Z0-9]*//g' | sed 's/at block [a-zA-Z0-9]*//g' | sed 's/box id is: [a-zA-Z0-9]*//g' | sed 's/\(WID is set to:\) [a-zA-Z0-9]* /\1 MASKED-ID /g')

# Use sort and uniq to identify unique messages and count their occurrences
# Cut is used to remove the timestamp from each line before identifying unique messages
echo "info messages:"
echo "$info_logs" | cut -d' ' -f2- | sort | uniq -c
echo ""
echo "warn messages:"
echo "$warn_logs" | cut -d' ' -f2- | sort | uniq -c
echo ""
echo "error messages:"
echo "$error_logs" | cut -d' ' -f2- | sort | uniq -c