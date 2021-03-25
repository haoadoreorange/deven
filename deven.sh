#!/bin/bash

init() {
	if [[ "$(lxc storage show default 2>&1)" =~ "Error" ]]; then
		lxd init
	fi

	if [[ "$(lxc profile show x11 2>&1)" =~ "Error" ]]; then
		lxc profile create x11
		read -p "nvidia.runtime = ? (DEFAULT=false): " nvidia_runtime
		if [ "$nvidia_runtime" = "true" ]; then
			echo "Set nvidia.runtime = true"
		else
			nvidia_runtime=false
			echo "Set nvidia.runtime = false"
		fi
		cat x11.profile | sed -e "s|connect: unix:@/tmp/.X11-unix/X0|connect: unix:@/tmp/.X11-unix/X${DISPLAY: -1}|" | sed -e "s|nvidia.runtime: \"false\"|nvidia.runtime: \"$nvidia_runtime\"|" | lxc profile edit x11
	fi
}

getip() {
	host_name=$(lxc list $container_name -c 4 --format csv | cut -d' ' -f1)
}

activate_ssh_password_less() {
	echo "Activate ssh passwordless"
	lxc start $container_name
	echo "WORKAROUND: Requires executing under current user $(whoami), please authenticate"
	until su - $USER -c "lxc exec $container_name -- passwd -d ubuntu"; do :; done
	lxc exec $container_name -- bash -c "cat /etc/ssh/sshd_config | sed -e \"s|PasswordAuthentication no|PasswordAuthentication yes|\" | sed -e \"s|#PermitEmptyPasswords no|PermitEmptyPasswords yes|\" | sudo tee /etc/ssh/sshd_config > /dev/null"
	lxc exec $container_name -- bash -c "sudo echo \"ssh\" >> /etc/securetty"
	lxc restart $container_name
	echo "Done ! First ssh to initialize connection"
	getip
	if [ -z "$host_name" ]; then
		:
	else
		until ssh ubuntu@$host_name command; do
			sleep 3
		done
	fi
	lxc restart $container_name
}

validate_container_name() {
	while [[ "$(lxc list $container_name -c n --format csv)" =~ "$container_name" || -z "$container_name" ]]; do
		read -p "Container name already exist, please chose another: " container_name
	done
}

create() {
	init
	echo "Creating new container from image"
	validate_container_name
	uid=$(id -u $(whoami))
	gid=$(id -g $(whoami))

	if [[ "$(cat /etc/subuid)" =~ "root:$uid:1" ]]; then
		:
	else
		echo "root:$uid:1" | sudo tee -a /etc/subuid >/dev/null
	fi
	if [[ "$(cat /etc/subgid)" =~ "root:$gid:1" ]]; then
		:
	else
		echo "root:$gid:1" | sudo tee -a /etc/subgid >/dev/null
	fi
	lxc launch ubuntu:bionic --profile default --profile x11 $container_name
	lxc stop $container_name
	lxc config set $container_name raw.idmap "both $uid $gid"
	lxc config device add $container_name homedir disk source=/home/$(whoami) path=/home/ubuntu/$(whoami)
	lxc config set $container_name boot.autostart false
	activate_ssh_password_less
	spawn
}

spawn() {
	if [[ "$(lxc list $container_name -c n --format csv)" =~ "$container_name" ]]; then
		if [[ "$(lxc list $container_name -c s --format csv)" =~ "STOPPED" ]]; then
			lxc start $container_name
			sleep 3
		fi
		lxc exec $container_name -- sudo --user ubuntu --login
	else
		if [[ "$(lxc list base -c n --format csv)" =~ "base" ]]; then
			if [[ "$(lxc list base -c s --format csv)" =~ "RUNNING" ]]; then
				lxc stop base
			fi
			lxc copy base $container_name
			activate_ssh_password_less
			spawn
		else
			echo "Base container not found"
			create $container_name
		fi
	fi
}

ask_if_empty() {
	while [ -z "$container_name" ]; do
		read -p "Container name: " container_name
	done
}

main() {
	container_name=$2
	ask_if_empty
	case $1 in
	spawn)
		spawn
		;;
	create)
		create $container_name
		;;
	showip)
		getip
		if [ -z "$host_name" ]; then
			echo "IP of $container_name not found"
		else
			echo "IP of $container_name is $host_name"
		fi
		;;
	delete)
		if [[ "$(lxc list $container_name -c n --format csv)" =~ "$container_name" ]]; then
			if [[ "$(lxc list $container_name -c s --format csv)" =~ "STOPPED" ]]; then
				lxc start $container_name
				sleep 3
			fi
			ssh-keygen -R $host_name
			lxc stop $container_name 2>/dev/null
			lxc delete $container_name
		else
			echo "$container_name not found"
		fi
		;;
	*)
		PROGRAM_NAME="$(basename "$0")"
		echo "$PROGRAM_NAME: '$1' is not a $PROGRAM_NAME command."
		echo "See '$PROGRAM_NAME help'"
		exit 1
		;;
	esac
}

main "$@"
