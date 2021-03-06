#!/usr/bin/env bats

load helpers

function teardown() {
	swarm_manage_cleanup
	stop_docker
}

@test "shared volumes dependency" {
	start_docker_with_busybox 2
	swarm_manage

	# Running the second container with shared volumes.
	run docker_swarm run --name b1 -e constraint:node==node-1 -d busybox:latest sleep 500
	[ "$status" -eq 0 ]
	run docker_swarm run --name b2 --volumes-from=/b1 -d busybox:latest sh
	[ "$status" -eq 0 ]

	# check if containers share volume.
	run docker_swarm inspect -f "{{ .HostConfig.VolumesFrom }}" b2
	[ "$status" -eq 0 ]
	[[ "${output}" == *"[/b1]"* ]]

	# check if both containers are started on the same node
	run docker_swarm inspect b1
	[ "$status" -eq 0 ]
	[[ "${output}" == *'"Name": "node-1"'* ]]

	run docker_swarm inspect b2
	[ "$status" -eq 0 ]
	[[ "${output}" == *'"Name": "node-1"'* ]]
}

@test "links dependency" {
	start_docker_with_busybox 2
	swarm_manage

	# Running the second container with link dependency.
	run docker_swarm run --name b1 -e constraint:node==node-1 -d busybox:latest sleep 500
	[ "$status" -eq 0 ]
	run docker_swarm run --name b2 --link=/b1:foo -d busybox:latest sh
	[ "$status" -eq 0 ]

	# check if containers share link.
	run docker_swarm inspect -f "{{ .HostConfig.Links }}" b2
	[ "$status" -eq 0 ]
	[[ "${output}" == *"[/b1:/b2/foo]"* ]]
	
	# check if both containers are started on the same node
	run docker_swarm inspect b1
	[ "$status" -eq 0 ]
	[[ "${output}" == *'"Name": "node-1"'* ]]

	run docker_swarm inspect b2
	[ "$status" -eq 0 ]
	[[ "${output}" == *'"Name": "node-1"'* ]]
}

@test "shared network stack dependency" {
	start_docker_with_busybox 2
	swarm_manage

	# Running the second container with network stack dependency.
	run docker_swarm run --name b1 -e constraint:node==node-1 -d busybox:latest sleep 500
	[ "$status" -eq 0 ]
	run docker_swarm run --name b2 --net=container:/b1 -d busybox:latest sh
	[ "$status" -eq 0 ]

	# check if containers have shared network stack.
	run docker_swarm inspect -f "{{ .HostConfig.NetworkMode }}" b2
	[ "$status" -eq 0 ]
	[[ "${output}" == *"container:/b1"* ]]

	# check if both containers are started on the same node
	run docker_swarm inspect b1
	[ "$status" -eq 0 ]
	[[ "${output}" == *'"Name": "node-1"'* ]]

	run docker_swarm inspect b2
	[ "$status" -eq 0 ]
	[[ "${output}" == *'"Name": "node-1"'* ]]
}
