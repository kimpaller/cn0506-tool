#!/bin/bash -e

# TODO: Add setup function to install required packages and setup for the ssh
# TODO: Add setup function to install required packages for production testing

if [ $(id -u) -ne 0 ]
  then echo "Please run as root"
  exit 1
fi

# TODO: Add instructions
usage() {
	echo
	echo "======================================================================="
	echo
	echo "Usage: cn0506_tool.sh <command> [args]install_sshpass"
}

: '
[ -n "$1" ] || {
	usage
	exit 1
}
'
command_exists() {
	local cmd=$1
	[ -n "$cmd" ] || return 1
	type "$cmd" >/dev/null 2>&1
}

install_sshpass()
{
  echo "Installing sshpass..."
  apt-get install sshpass
  if [ $? -eq 0 ];
  then
    echo "sshpass installed!"
  else
    echo "sshpass not succesfully installed!"
    echo "Exiting program"
    exit 1
  fi
  exit 0
}

# TODO: Add setup routines for the prerequisites

#kill running iperf
kill_iperf()
{ 
  PID=`ps -eaf | grep iperf3 | grep -v grep | awk '{print $2}'`
  if [ "" !=  "$PID" ]; then
    kill -9 $PID
  fi
}

remove_ns_interfaces()
{
  res=`ip netns list | grep "iperf_server" || true`
  if [ -n "$res" ];
  then 
    local DEV0=${1:-eth0}
    local DEV1=${2:-eth1}
    local resdev0=`ip netns exec iperf_server ip link list | grep "$DEV0" || true`
    if [ -n "$resdev0" ];
    then
      #echo "removing link"
      ip netns exec iperf_server ip link set $DEV0 netns 1
    fi
    resdev1=`ip netns exec iperf_server ip link list | grep "$DEV1" || true`
    if [ -n "$resdev1" ];
    then
      #echo "removing link"
      ip netns exec iperf_server ip link set $DEV1 netns 1
    fi
    #echo "Removing namespace"
    ip netns delete iperf_server
  fi
  kill_iperf
}

get_ip()
{
  DEV0=${1:-eth0}
  DEV_IP=`ip -4 addr show $DEV0 | grep -oP '(?<=inet\s)\d+(\.\d+){3}'`
  echo $DEV_IP
}

setup_ns_interfaces()
{
  local DEV0=${1:-eth0}
  local DEV1=${2:-eth1}
  local CLIENT_IP=${3:-192.168.10.10}
  local SERVER_IP=${4:-192.168.10.11}
  local DEFAULT_GW=$5
  local CLIENT_HOME=${6:-/home/analog}
  if [ -z "$DEFAULT_GW" ];
  then
    DEFAULT_GW=`dhcpcd -U $DEV0  |  grep "routers" | awk -v FS="=" '{gsub(/'\''/, '\"\"', $2); print $2}'`
  else
    ip addr flush dev $DEV0
    ip addr flush dev $DEV1
    ip link set dev $DEV0 down
    ip addr add dev $DEV0 $CLIENT_IP/24
    ip link set dev $DEV0 up
    route add default gw $DEFAULT_GW
  fi

  ip netns add iperf_server
  # Add DEV1 in iperf_server namespace
  ip link set $DEV1 netns iperf_server
  ip netns exec iperf_server ip addr add dev $DEV1 $SERVER_IP/24
  ip netns exec iperf_server ip link set dev $DEV1 up

  # add gateway to DEV1 in iperf_server namespace
  ip netns exec iperf_server route add default gw $DEFAULT_GW

}

check_link()
{
  local DEV0=${1:-eth0}
  local resdev0=`ip netns exec iperf_server ip link list | grep "$DEV0" || true`
  local res=""
  if [ -n "$resdev0" ];
  then
    # In a namespace"
    res=`ip netns exec iperf_server ethtool $DEV0 | grep "Link detected" | awk '{print $3}'`
  else
    res=`ethtool $DEV0 | grep "Link detected" | awk '{print $3}'`
  fi
  if [ "$res" = "no" ]
  then
    echo "1"
    exit 1
  else
    echo "0"
    exit 0
  fi
}

run_ns_iperf_server()
{
  local SERVER_IP=${1:-192.168.10.11}
  # running iperf server daemon
  ip netns exec iperf_server iperf3 -s -B $SERVER_IP -D
}

run_ns_iperf_client()
{
  local CLIENT_IP=${1:-192.168.10.10}
  local SERVER_IP=${2:-192.168.10.11}
  local RESULTS_FILE=${3:-results.json}
  [ -e $RESULTS_FILE ] && rm $RESULTS_FILE
  # running iperf client
  iperf3 -c $SERVER_IP -B $CLIENT_IP -w 2M -J > $RESULTS_FILE
}

test_throughput()
{
  run_ns_iperf_client $1 $2
  ret=`sudo -u analog python3 verify_results.py results.json 90.0 90.0`
  echo $ret
}

test_data_integrity()
{
  # Make sure to generate an ssh key using ssh-keygen from the iperf_server namespace.
  # Since you will be using root here, .ssh/ will be in /root directory
  # Copy the corresponding public key to the /home/analog/.ssh
  # append the key to the ~/.ssh/authorized_keys
  # chmod 600 ~/.ssh/authorized_keys
  # chmod 700 ~/.ssh

  local CLIENT_IP=${1:-192.168.10.10}
  local SERVER_IP=${2:-192.168.10.11}
  local CLIENT_HOME=${3:-/home/analog}
  local DATA_SIZE=${4:-1M}
  dd if=/dev/urandom of=test.data bs=1M count=1 status=none
  data_sha256=`sha256sum test.data | awk '{print $1}'`
  # transfer file to  analog@${CLIENT_IP}:${CLIENT_HOME}
  ip netns exec iperf_server sshpass -p analog scp -q -o LogLevel=QUIET test.data analog@${CLIENT_IP}:${CLIENT_HOME}/rx_test.data
  rx_data_sha256=`sha256sum ${CLIENT_HOME}/rx_test.data | awk '{print $1}'`
  if [ "$data_sha256" = "$rx_data_sha256" ];
  then 
    echo "0"
    exit 0
  else 
    echo "1"

    exit 1
  fi

  rm test.data
  rm ${CLIENT_HOME}/rx_test.data
}


tester()
{
  #echo "Removing existing name space"
  remove_ns_interfaces "eth0" "eth1"
  echo "Setup interfaces"
  setup_ns_interfaces "eth0" "eth1" "192.168.10.6" "192.168.10.7" "192.168.10.1"
  echo "Run iperf server"
  run_ns_iperf_server "192.168.10.7"
  echo "run test"
  test1=`test_throughput "192.168.10.6" "192.168.10.7"`
  test2=`test_data_integrity "192.168.10.6" "192.168.10.7" "/home/analog/" "500K"`
  echo "Removing existing name space"
  remove_ns_interfaces "eth0" "eth1"
  if [ $test1=0 -a $test2=0 ];
  then 
    echo "PASS"
    exit 0
  else 
    echo "FAILED"
    exit 1
  fi
}

cmd="$1"

command_exists "$cmd" || {
	echo "Unknown command: $cmd"
	usage
	exit 1
}

shift
$cmd $@
