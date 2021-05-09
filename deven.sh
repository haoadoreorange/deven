#!/bin/bash
set -eo pipefail

GREEN="\e[32m"
RED="\e[31m"
ERROR_SPAWN_FAILED=901
ERROR_INIT_FAILED=902
ERROR_CREATE_BASE_FROM_IMAGE_FAILED=903

_init() {
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
		cat $HOME/.deven/x11.profile | sed -e "s|connect: unix:@/tmp/.X11-unix/X0|connect: unix:@/tmp/.X11-unix/X${DISPLAY: -1}|" | sed -e "s|nvidia.runtime: \"false\"|nvidia.runtime: \"$nvidia_runtime\"|" | lxc profile edit x11
	fi
}

_validate_new_container_name() {
	while [[ "$(lxc list $container_name -c n --format csv)" =~ "$container_name" ]]; do
		read -p "Container name already exist, please chose another: " container_name
	done
	if [ -z "$container_name" ]; then
		_ask_if_empty
		_validate_new_container_name
	fi
}

_start_if_stopped() {
	if [[ "$(lxc list $container_name -c s --format csv)" =~ "STOPPED" ]]; then
		lxc start $container_name
		sleep 3
	fi
}

_activate_ssh_passwordless() {
	if [ "$no_ssh_passwordless" != "true" ]; then
		echo -e "$GREEN Activate ssh passwordless"
		_start_if_stopped
		lxc exec $container_name -- cloud-init status --wait
		lxc exec $container_name -- passwd -d ubuntu
		lxc exec $container_name -- bash -c "cat /etc/ssh/sshd_config | sed -e \"s|PasswordAuthentication no|PasswordAuthentication yes|\" | sed -e \"s|#PermitEmptyPasswords no|PermitEmptyPasswords yes|\" | sudo tee /etc/ssh/sshd_config > /dev/null"
		lxc exec $container_name -- bash -c "sudo echo \"ssh\" >> /etc/securetty"
		lxc restart $container_name
		sleep 3
		echo -e "$GREEN Done ! First ssh to initialize connection"
		getip
		if [ -n "$host_name" ]; then
			until ssh ubuntu@$host_name command; do
				sleep 3
			done
		fi
		lxc stop $container_name
	fi
}

_create_base() {
	echo -e "$GREEN Creating base container from image"
	uid=$(id -u $(whoami))
	gid=$(id -g $(whoami))
	if [[ ! "$(cat /etc/subuid)" =~ "root:$uid:1" ]]; then
		echo -e "root:$uid:1" | sudo tee -a /etc/subuid >/dev/null
	fi
	if [[ ! "$(cat /etc/subgid)" =~ "root:$gid:1" ]]; then
		echo -e "root:$gid:1" | sudo tee -a /etc/subgid >/dev/null
	fi
	lxc launch ubuntu:bionic --profile default --profile x11 base
	lxc stop base
	lxc config set base raw.idmap "both $uid $gid"
	lxc config device add base homedir disk source=/home/$(whoami) path=/home/ubuntu/$(whoami)
	lxc config set base boot.autostart false
}
spawn() {
	if [[ "$(lxc list $container_name -c n --format csv)" =~ "$container_name" ]]; then
		_start_if_stopped
		lxc exec $container_name -- sudo --user ubuntu --login
	else
		if [[ "$(lxc list base -c n --format csv)" =~ "base" ]]; then
			if [[ "$(lxc list base -c s --format csv)" =~ "RUNNING" ]]; then
				lxc stop base
			fi
			_validate_new_container_name
			lxc copy base $container_name
			_activate_ssh_passwordless
		else
			echo -e "$RED Base container not found"
			_init || {
				return $ERROR_INIT_FAILED
			}
			_create_base || {
				return $ERROR_CREATE_BASE_FROM_IMAGE_FAILED
			}
		fi
		spawn
	fi
}

showip() {
	_start_if_stopped
	host_name=$(lxc list $container_name -c 4 --format csv | cut -d' ' -f1)
	echo -e "$GREEN IP of $container_name is $host_name"
}

_ask_if_empty() {
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
			no_ssh_passwordless="true"
			shift
			;;
		\?)
			echo -e "$RED Unknown option: -$OPTARG"
			exit 1
			;;
		esac
	done

	container_name=$1
	_ask_if_empty
	if [[ ! "$ACTION" =~ "_spawn" ]]; then
		if [[ ! "$(lxc list $container_name -c n --format csv)" =~ "$container_name" ]]; then
			echo -e "$RED container $container_name not found"
			exit 1
		fi
	fi

	case $ACTION in
	_spawn)
		spawn || {
			error_code=$?
			if [ $error_code -eq $ERROR_INIT_FAILED ] || [ $error_code -eq $ERROR_CREATE_BASE_FROM_IMAGE_FAILED ]; then
				return $error_code
			else
				return $ERROR_SPAWN_FAILED
			fi
		}
		;;
	_showip)
		showip
		;;
	_delete)
		showip
		ssh-keygen -R $host_name
		lxc stop $container_name
		lxc delete $container_name	
		;;
	esac
}

main "$@" || {
	case $? in
	$ERROR_INIT_FAILED)
		echo -e "$RED Error while initializing lxc, please fix it manually"
		;;
	$ERROR_CREATE_BASE_FROM_IMAGE_FAILED)
		echo -e "$RED Error while createing base container from image, revert"
		echo -e "$RED Fix manually lxc configurations (profiles,..etc) if needed"
		lxc stop base || { :; }
		lxc delete base
		;;
	$ERROR_SPAWN_FAILED)
		echo -e "$RED Error while createing new container from base, revert"
		lxc stop $container_name || { :; }
		lxc delete $container_name
		;;
	*)
		echo -e "$RED some error happened"
		;;
	esac
}
