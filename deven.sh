#!/bin/bash

GREEN="\e[32m"
RED="\e[31m"

init() {
	if [[ "$(lxc storage show default 2>&1)" =~ "Error" ]]; then
		lxd init
	fi

	if [[ "$(lxc profile show x11 2>&1)" =~ "Error" ]]; then
		lxc profile create x11
		read -p "nvidia.runtime = ? (DEFAULT=false): " nvidia_runtime
		if [ "$nvidia_runtime" = "true" ]; then
			echo -e "$GREEN Set nvidia.runtime = true"
		else
			nvidia_runtime=false
			echo -e "$RED Set nvidia.runtime = false"
		fi
		cat x11.profile | sed -e "s|connect: unix:@/tmp/.X11-unix/X0|connect: unix:@/tmp/.X11-unix/X${DISPLAY: -1}|" | sed -e "s|nvidia.runtime: \"false\"|nvidia.runtime: \"$nvidia_runtime\"|" | lxc profile edit x11
	fi
}

getip() {
	host_name=$(lxc list $container_name -c 4 --format csv | cut -d' ' -f1)
}

activate_ssh_password_less() {
	if [ "$NO_SSH_PASSWORDLESS" = "true" ]; then
		:
	else
		echo -e "$GREEN Activate ssh passwordless"
		start_if_stopped
		echo -e "$RED WORKAROUND: Requires executing under current user $(whoami), please authenticate"
		until su - $USER -c "lxc exec $container_name -- passwd -d ubuntu"; do :; done
		lxc exec $container_name -- bash -c "cat /etc/ssh/sshd_config | sed -e \"s|PasswordAuthentication no|PasswordAuthentication yes|\" | sed -e \"s|#PermitEmptyPasswords no|PermitEmptyPasswords yes|\" | sudo tee /etc/ssh/sshd_config > /dev/null"
		lxc exec $container_name -- bash -c "sudo echo \"ssh\" >> /etc/securetty"
		lxc restart $container_name
		echo -e "$GREEN Done ! First ssh to initialize connection"
		getip
		if [ -z "$host_name" ]; then
			:
		else
			until ssh ubuntu@$host_name command; do
				sleep 3
			done
		fi
		lxc stop $container_name
	fi
}

validate_container_name() {
	while [[ "$(lxc list $container_name -c n --format csv)" =~ "$container_name" || -z "$container_name" ]]; do
		read -p "Container name already exist, please chose another: " container_name
	done
}

start_if_stopped() {
	if [[ "$(lxc list $container_name -c s --format csv)" =~ "STOPPED" ]]; then
		lxc start $container_name
		sleep 3
	fi
}

create() {
	init
	echo -e "$GREEN Creating new container from image"
	validate_container_name
	uid=$(id -u $(whoami))
	gid=$(id -g $(whoami))

	if [[ "$(cat /etc/subuid)" =~ "root:$uid:1" ]]; then
		:
	else
		echo -e "root:$uid:1" | sudo tee -a /etc/subuid >/dev/null
	fi
	if [[ "$(cat /etc/subgid)" =~ "root:$gid:1" ]]; then
		:
	else
		echo -e "root:$gid:1" | sudo tee -a /etc/subgid >/dev/null
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
		start_if_stopped
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
			echo -e "$RED Base container not found"
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
	case $1 in
	spawn)
		ACTION="_spawn"
		shift
		;;
	create)
		ACTION="_create"
		shift
		;;
	showip)
		ACTION="_showip"
		shift
		;;
	delete)
		ACTION="_delete"
		shift
		;;
	*)
		PROGRAM_NAME="$(basename "$0")"
		echo -e "$RED $PROGRAM_NAME: '$1' is not a $PROGRAM_NAME command."
		echo -e "$RED See '$PROGRAM_NAME help'"
		exit 1
		;;
	esac

	while getopts ':c:' opt; do
		case "$opt" in
		c)
			echo -e "$GREEN -c: classic mode, without activating ssh passwordless"
			NO_SSH_PASSWORDLESS="true"
			shift
			;;
		\?)
			echo -e "$RED Unknown option: -$OPTARG"
			exit 3
			;;
		esac
	done
	container_name=$1
	ask_if_empty

	case $ACTION in
	_spawn)
		spawn
		;;
	_create)
		create
		;;
	_showip)
		getip
		if [ -z "$host_name" ]; then
			echo -e "$RED IP of $container_name not found"
		else
			echo -e "$GREEN IP of $container_name is $host_name"
		fi
		;;
	_delete)
		if [[ "$(lxc list $container_name -c n --format csv)" =~ "$container_name" ]]; then
			start_if_stopped
			getip
			ssh-keygen -R $host_name
			lxc stop $container_name
			lxc delete $container_name
		else
			echo -e "$RED $container_name not found"
		fi
		;;
	*)
		exit 1
		;;
	esac
}

main "$@"
