#!/bin/bash
# Auto-reroute

scriptversion="1.0.8"
scriptname="auto-reroute"

# Author adamaze
# curl -s -L -o ~/auto-reroute.sh http://git.io/hsFb && bash ~/auto-reroute.sh

############################
####### Script Notes #######
############################

# This script is meant to be run on a machine at your home.
# It will download test files using each of Feral's available routes, determine the fastest one, and then set that route for you.
# You need curl, bc, and openssl for this to work.
# Because of an added check in v1.0.1 you can be sure that when the script has ended, the route change has actually taken effect, so speedy downloads can begin right away.

############################
##### Version History  #####
############################

# v1.0.8 - Added "Console" routes
# v1.0.6 - Added check for sed
# v1.0.6 - Added Cogent route option, removed FiberRing options
# v1.0.5 - Fixed issue where fastest route was not always chosen on cygwin
# v1.0.4 - Removed route
# v1.0.3 - Added logging (~./auto-reroute/auto-reroute.log).
# v1.0.2 - Added new route option (Level3).
# v1.0.1 - Added route change verification to speed up script. (no more waiting full two minutes)
# v1.0.0 - First version with official test downloads.

############################
##### Feral Variables ######
############################

# Feral route ips and route names.
routes=(0.0.0.0 130.117.255.36 31.217.134.49 31.217.134.45 77.67.64.81 81.20.64.101 81.20.69.197 213.19.196.233 62.115.145.50)
route_names=(Default Cogent Console#1 Console#2 GTT NTT#1 NTT#2 Level3 Telia)

# Feral test files.
test_files=(https://feral.io/test.bin https://cogent-1.feral.io/test.bin https://console-1.feral.io/test.bin https://console-2.feral.io/test.bin https://gtt-1.feral.io/test.bin https://ntt-1.feral.io/test.bin https://ntt-2.feral.io/test.bin https://level3.feral.io/test.bin https://telia.feral.io/test.bin)

############################
##### Other Variables ######
############################

# Location of the reroute log
reroute_log=/tmp/$(openssl rand -hex 10)

############################
######### Functions ########
############################

function reroute_check {
	ext_IP=$(curl -4 -s https://network.feral.io/reroute | grep "Your IPv4 address is" | sed 's/<\/p>//g' | awk '{print $NF}')
	route_set=0
	while [ $route_set = 0 ]; do
		route_set=$(curl -4 -s "https://network.feral.io/looking-glass?action=traceroute&host=$ext_IP" | grep -c "$(curl -4 -s https://network.feral.io/reroute | grep checked | awk '{print $(NF-1)}' | sed 's|value=||g' | sed 's/"//g')")
	done
	echo Route has been set.
}

function error_exit {
	rm -f $reroute_log
	exit 1
}

function requested_route_check {
	curl -4 -s https://network.feral.io/reroute | grep checked | grep -o -P 'value=".{0,15}' | awk '{print $1}' | sed 's/value="//g' | sed 's/"//g' | sed 's/>//g'
}

############################
#### Prerequisite Check ####
############################

# Check if running from a feral slot. If so, print error and exit.
if [ "$(hostname -f | awk -F. '{print $2;}')" == "feralhosting" ]; then
	echo -e "\033[31m""it looks like you are trying to run this from a Feral slot, it is meant to be run from your home network""\e[0m"
	exit
fi

# Check if necessary packages are installed
command -v sed >/dev/null 2>&1 || { echo >&2 "This script requires sed but it's not installed.  Aborting."; exit 1; }
command -v curl >/dev/null 2>&1 || { echo >&2 "This script requires curl but it's not installed.  Aborting."; exit 1; }
command -v bc >/dev/null 2>&1 || { echo >&2 "This script requires bc but it's not installed.  Aborting."; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo >&2 "This script requires openssl but it's not installed.  Aborting."; exit 1; }

# Check if reroute page is up. If not, envoke error_exit function.
if [ "$(curl -s https://network.feral.io/reroute | head -2 | grep -c 502)" = "1" ]; then
	echo "The Feral reroute tool is unavailable at this time."
	error_exit
fi

############################
# Determine Fastest Route  #
############################

# Make a local directory to store log output
mkdir -p ~/.auto-reroute

# Determine current route and set route to default.
if [ $(curl -4 -s https://network.feral.io/reroute | grep checked | grep -c 0.0.0.0) = 0  ]; then
	echo "Starting off by setting route to default to ensure accurate results."
	old_route=$(curl -4 -s https://network.feral.io/reroute | grep checked | awk '{print $(NF-1)}' | sed 's|value=||g' | sed 's/"//g')
	timeout 10 curl -4 'https://network.feral.io/reroute' --data "nh=0.0.0.0" >/dev/null 2>&1
	if [ $? = 124  ]; then
		echo "there seems to be an issue with the reroute page..."
		error_exit
	fi
	echo "Waiting for route change to take effect..."
	ext_IP=$(curl -4 -s https://network.feral.io/reroute | grep "Your IPv4 address is" | sed 's/<\/p>//g' | awk '{print $NF}')
	route_set=1
	while [ $route_set = 1 ]; do
	route_set=$(curl -4 -s "https://network.feral.io/looking-glass?action=traceroute&host=$ext_IP" | grep -c "$old_route")
	done
else
	echo "You are currently using the default route"
fi

# Loop through the routes using test files to determine download speed
count=-1
for i in "${routes[@]}"; do
	((count++))
	echo "Testing single segment download speed from ${route_names[$count]}..."
	messyspeed=$(echo -n "scale=2; " && curl -4 -s -m 120 -L ${test_files[$count]} -w "%{speed_download}" -o /dev/null | sed "s/\,/\./g")
	if [ -z "$(echo $messyspeed | awk -F\; '{print $2}'| sed 's/ //g')" ]; then
		echo "There was an issue downloading ${test_files[$count]}"
		speed="0"
	else
		speed=$(echo $messyspeed/1048576*8 | bc | sed 's/$/ Mbit\/s/')	
		if [ "$speed" = "ERROR404:" ]; then
			echo -e "\033[31m""\nThe test file cannot be found at ${test_files[$count]} \n""\e[0m"
			exit
		fi
	echo -e "\033[32m""routing through ${route_names[$count]} results in $speed""\e[0m"
	echo 
	echo "$speed ${routes[$count]} ${route_names[$count]}" >> $reroute_log
	fi
done

############################
# Parse Results and Apply  #
############################

# Find the fastest route/speed/name by sorting results in reroute_log
fastestroute=$(sort -gr $reroute_log | head -n 1 | awk '{print $3}')
fastestspeed=$(sort -gr $reroute_log | head -n 1 | awk '{print $1}')
fastestroutename=$(sort -gr $reroute_log | head -n 1 | awk '{print $4}')

# Apply fastest route.
echo -e "Routing through $fastestroutename provided the highest speed of $fastestspeed Mbit/s"
if [ $fastestroute = "0.0.0.0" ]; then
	echo "No need to change routes, as the Default was chosen at the beginning of this test."
else
	echo "Setting route to $fastestroutename / $fastestroute ..."
	curl -4 'https://network.feral.io/reroute' --data "nh=$fastestroute" >/dev/null 2>&1
	echo "Waiting for route change to take effect..."
	reroute_check
fi

############################
######### Finish  ##########
############################

# Clean up
sed -i 's/ /, /g' $reroute_log
sed -i "s/^/$(date -u), /g" $reroute_log
cat $reroute_log >> ~/.auto-reroute/auto-reroute.log
rm $reroute_log

echo 'All done!'