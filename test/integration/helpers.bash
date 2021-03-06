#!/bin/bash

# Root directory of integration tests.
INTEGRATION_ROOT=$(dirname "$(readlink -f "$BASH_SOURCE")")

# Test data path.
TESTDATA="${INTEGRATION_ROOT}/testdata"

# Root directory of the repository.
SWARM_ROOT=${SWARM_ROOT:-$(cd "$INTEGRATION_ROOT/../.."; pwd -P)}

# Path of the Swarm binary.
SWARM_BINARY=${SWARM_BINARY:-${SWARM_ROOT}/swarm}

# Docker image and version to use for integration tests.
DOCKER_IMAGE=${DOCKER_IMAGE:-dockerswarm/dind-master}
DOCKER_VERSION=${DOCKER_VERSION:-latest}
DOCKER_BINARY=${DOCKER_BINARY:-`command -v docker`}

# Host on which the manager will listen to (random port between 6000 and 7000).
SWARM_HOST=127.0.0.1:$(( ( RANDOM % 1000 )  + 6000 ))

# Use a random base port (for engines) between 5000 and 6000.
BASE_PORT=$(( ( RANDOM % 1000 )  + 5000 ))

# Drivers to use for Docker engines the tests are going to create.
STORAGE_DRIVER=${STORAGE_DRIVER:-aufs}
EXEC_DRIVER=${EXEC_DRIVER:-native}

BUSYBOX_IMAGE="$BATS_TMPDIR/busybox.tgz"

# Join an array with a given separator.
function join() {
	local IFS="$1"
	shift
	echo "$*"
}

# Run docker using the binary specified by $DOCKER_BINARY.
# This must ONLY be run on engines created with `start_docker`.
function docker() {
	"$DOCKER_BINARY" "$@"
}

# Communicate with Docker on the host machine.
# Should rarely use this.
function docker_host() {
	command docker "$@"
}

# Run the docker CLI against swarm.
function docker_swarm() {
	docker -H $SWARM_HOST "$@"
}

# Run the swarm binary. You must NOT fork this command (swarm foo &) as the PID
# ($!) will be the one of the subshell instead of swarm and you won't be able
# to kill it.
function swarm() {
	"$SWARM_BINARY" "$@"
}

# Retry a command $1 times until it succeeds. Wait $2 seconds between retries.
function retry() {
	local attempts=$1
	shift
	local delay=$1
	shift
	local i

	for ((i=0; i < attempts; i++)); do
		run "$@"
		if [[ "$status" -eq 0 ]] ; then
			return 0
		fi
		sleep $delay
	done

	echo "Command \"$@\" failed $attempts times. Output: $output"
	false
}

# Waits until the given docker engine API becomes reachable.
function wait_until_reachable() {
	retry 10 1 docker -H $1 info
}

# Returns true if all nodes have joined the swarm.
function check_swarm_nodes() {
	docker_swarm info | grep -q "Nodes: ${#HOSTS[@]}"
}

# Start the swarm manager in background.
function swarm_manage() {
	local discovery
	if [ $# -eq 0 ]; then
		discovery=`join , ${HOSTS[@]}`
	else
		discovery="$@"
	fi

	"$SWARM_BINARY" manage -H "$SWARM_HOST" --heartbeat=1 "$discovery" &
	SWARM_PID=$!
	wait_until_reachable "$SWARM_HOST"
	retry 10 1 check_swarm_nodes
}

# swarm join every engine created with `start_docker`.
#
# It will wait until all nodes are visible in discovery (`swarm list`) before
# returning and will fail if that's not the case after a certain time.
#
# It can be called multiple times and will only join new engines started with
# `start_docker` since the last `swarm_join` call.
function swarm_join() {
	local current=${#SWARM_JOIN_PID[@]}
	local nodes=${#HOSTS[@]}
	local addr="$1"
	shift

	# Start the engines.
	local i
	echo "current: $current | nodes: $nodes" > log
	for ((i=current; i < nodes; i++)); do
		local h="${HOSTS[$i]}"
		echo "Swarm join #${i}: $h $addr"
		"$SWARM_BINARY" join --addr="$h" "$addr" &
		SWARM_JOIN_PID[$i]=$!
	done
	retry 10 0.5 check_discovery_nodes "$addr"
}

# Returns true if all nodes have joined the discovery.
function check_discovery_nodes() {
	local joined=`swarm list "$1" | wc -l`
	local total=${#HOSTS[@]}

	echo "${joined} out of ${total} hosts joined discovery"
	[ "$joined" -eq "$total" ]
}

# Stops the manager.
function swarm_manage_cleanup() {
	kill $SWARM_PID || true
}

# Clean up Swarm join processes
function swarm_join_cleanup() {
	for pid in ${SWARM_JOIN_PID[@]}; do
		kill $pid || true
	done
}

function start_docker_with_busybox() {
	# Preload busybox if not available.
	[ "$(docker_host images -q busybox)" ] || docker_host pull busybox:latest
	[ -f "$BUSYBOX_IMAGE" ] || docker_host save -o "$BUSYBOX_IMAGE" busybox:latest

	# Start the docker instances.
	local current=${#DOCKER_CONTAINERS[@]}
	start_docker "$@"
	local new=${#DOCKER_CONTAINERS[@]}

	# Load busybox on the new instances.
	for ((i=current; i < new; i++)); do
		docker -H ${HOSTS[$i]} load -i "$BUSYBOX_IMAGE"
	done
}

# Start N docker engines.
function start_docker() {
	local current=${#DOCKER_CONTAINERS[@]}
	local instances="$1"
	shift
	local i

	# Start the engines.
	for ((i=current; i < (current + instances); i++)); do
		local port=$(($BASE_PORT + $i))
		HOSTS[$i]=127.0.0.1:$port

		# We have to manually call `hostname` since --hostname and --net cannot
		# be used together.
		DOCKER_CONTAINERS[$i]=$(
			docker_host run -d --name node-$i --privileged -it --net=host \
			${DOCKER_IMAGE}:${DOCKER_VERSION} \
			bash -c "\
				hostname node-$i && \
				docker -d -H 127.0.0.1:$port \
					--storage-driver=$STORAGE_DRIVER --exec-driver=$EXEC_DRIVER \
					`join ' ' $@` \
		")
	done

	# Wait for the engines to be reachable.
	for ((i=current; i < (current + instances); i++)); do
		wait_until_reachable "${HOSTS[$i]}"
	done
}

# Stop all engines.
function stop_docker() {
	for id in ${DOCKER_CONTAINERS[@]}; do
		echo "Stopping $id"
		docker_host rm -f -v $id > /dev/null;
	done
}
