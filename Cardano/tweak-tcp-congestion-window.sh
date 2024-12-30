#!/bin/bash
# As per karknu's comments here: https://forum.cardano.org/t/problem-with-increasing-blocksize-or-processing-requirements/140044/6?u=karknu
# This script will maximize the initial TCP/IP congestion window and initial receive window to reduce the number of round trips a block would have, and thus hopefully reduce block propagation times.

# Get the current default route
default_route=$(ip route show default)

# Extract the gateway and interface from the default route
gateway=$(echo $default_route | awk '{print $3}')
interface=$(echo $default_route | awk '{print $5}')
src_ip=$(echo $default_route | grep -oP 'src \K\S+')

# Construct the new route command
new_route_command="ip route change default via $gateway dev $interface proto dhcp"
if [ -n "$src_ip" ]; then
    new_route_command="$new_route_command src $src_ip"
fi
new_route_command="$new_route_command metric 100 initcwnd 42 initrwnd 42"

# Execute the new route command
eval $new_route_command

# Show the updated routes to confirm the change
ip route show default
