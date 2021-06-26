#!/bin/bash
set -o pipefail
. "$BASH_OO/oo-bootstrap.sh"
import util/log util/exception util/tryCatch util/namedParameters
namespace deven
Log::AddOutput deven INFO

_init() {
    try {
        if [[ "$(lxc storage show default 2>&1)" =~ "Error" ]]; then
            lxd init
        fi

        if [[ "$(lxc profile show x11 2>&1)" =~ "Error" ]]; then
            lxc profile create x11
            read -p "nvidia.runtime = ? (DEFAULT=false): " nvidia_runtime
            if [ "$nvidia_runtime" = "true" ]; then
                Log "$(UI.Color.Green) Set nvidia.runtime = true $(UI.Color.Default)"
            else
                nvidia_runtime=false
                Log "$(UI.Color.RED) Set nvidia.runtime = false $(UI.Color.Default)"
            fi
            cat $HOME/.deven/x11.profile | sed -e "s|connect: unix:@/tmp/.X11-unix/X0|connect: unix:@/tmp/.X11-unix/X${DISPLAY: -1}|" | sed -e "s|nvidia.runtime: \"false\"|nvidia.runtime: \"$nvidia_runtime\"|" | lxc profile edit x11
        fi
    } catch {
        Log "$(UI.Color.Red) lxc init failed, please fix manually $(UI.Color.Default)"
        Exception::PrintException "${__EXCEPTION__[@]}"
        exit 1
    }
    
    Log "$(UI.Color.Green) Creating base container from image $(UI.Color.Default)"
    uid=$(id -u $(whoami))
    gid=$(id -g $(whoami))
    try {
        if [[ ! "$(cat /etc/subuid)" =~ "root:$uid:1" ]]; then
            echo "root:$uid:1" | sudo tee -a /etc/subuid >/dev/null
        fi
        if [[ ! "$(cat /etc/subgid)" =~ "root:$gid:1" ]]; then
            echo "root:$gid:1" | sudo tee -a /etc/subgid >/dev/null
        fi
        lxc launch ubuntu:bionic --profile default --profile x11 base
        lxc stop base
        lxc config set base raw.idmap "both $uid $gid"
        lxc config device add base homedir disk source=/home/$(whoami) path=/home/ubuntu/$(whoami)
        lxc config set base boot.autostart false
    } catch {
        lxc stop base
        lxc delete base
        Log "$(UI.Color.Red) Creating base container failed $(UI.Color.Default)"
        Exception::PrintException "${__EXCEPTION__[@]}"
        exit 1 
    }
}

_validateNewContainerName() {
    while [[ "$(lxc list $container_name -c n --format csv)" =~ ^$container_name$ ]]; do
        read -p "Container name already exist, please chose another: " container_name
    done
    if [ -z "$container_name" ]; then
        _askIfEmpty
        _validateNewContainerName
    fi
}

_startIfStopped() {
    if [[ "$(lxc list $container_name -c s --format csv)" =~ "STOPPED" ]]; then
        _restart
    fi
}

_restart() {
    lxc restart $container_name
    lxc exec $container_name -- cloud-init status --wait
}

_activateSshPasswordless() {
    if [ "$no_ssh_passwordless" != "true" ]; then
        Log "$(UI.Color.Green) Activate ssh passwordless $(UI.Color.Default)"
        _startIfStopped
        lxc exec $container_name -- passwd -d ubuntu
        lxc exec $container_name -- bash -c "cat /etc/ssh/sshd_config | sed -e \"s|PasswordAuthentication no|PasswordAuthentication yes|\" | sed -e \"s|#PermitEmptyPasswords no|PermitEmptyPasswords yes|\" | sudo tee /etc/ssh/sshd_config > /dev/null"
        lxc exec $container_name -- bash -c "sudo echo \"ssh\" >> /etc/securetty"
        _restart
        Log "$(UI.Color.Green) Done ! First ssh to initialize connection $(UI.Color.Default)"
        getIp
        until ssh ubuntu@$ip command; do
            sleep 3
        done
        lxc stop $container_name
    fi
}

spawn() {
    if [[ "$(lxc list $container_name -c n --format csv)" =~ ^$container_name$ ]]; then
        _startIfStopped
        lxc exec $container_name -- sudo --user ubuntu --login
    else
        if [[ "$(lxc list base -c n --format csv)" =~ ^base$ ]]; then
            try {
                if [[ "$(lxc list base -c s --format csv)" =~ "RUNNING" ]]; then
                    lxc stop base
                fi
                _validateNewContainerName
                lxc copy base $container_name
                _activateSshPasswordless
            } catch {
                lxc stop $container_name
                lxc delete $container_name
                Log "$(UI.Color.Red) Creating $container_name container from base failed $(UI.Color.Default)"
                Exception::PrintException "${__EXCEPTION__[@]}"
                exit 1
            }
        else
            Log "$(UI.Color.Red) Base container not found $(UI.Color.Default)"
            _init
        fi
        spawn
    fi
}

getIp() {
    if [[ "$(lxc list $container_name -c n --format csv)" =~ ^$container_name$ ]]; then
        _startIfStopped
        ip=$(lxc list $container_name -c 4 --format csv | cut -d' ' -f1)
    else
        e="$container_name doesn't exist to get ip" throw 
    fi 
}

_askIfEmpty() {
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
        Log "$(UI.Color.Red) $PROGRAM_NAME: '$1' is not a $PROGRAM_NAME command. $(UI.Color.Default)"
        Log "$(UI.Color.Red) See '$PROGRAM_NAME help' $(UI.Color.Default)"
        exit 1
        ;;
    esac

    while getopts ':c:' opt; do
        case "$opt" in
        c)
            Log "$(UI.Color.Green) -c: classic mode, without activating ssh passwordless $(UI.Color.Default)"
            no_ssh_passwordless="true"
            shift
            ;;
        \?)
            Log "$(UI.Color.Red) Unknown option: -$OPTARG $(UI.Color.Default)"
            exit 1
            ;;
        esac
    done

    container_name=$1
    _askIfEmpty
    if [[ ! "$ACTION" =~ ^_spawn$ ]]; then
        if [[ ! "$(lxc list $container_name -c n --format csv)" =~ ^$container_name$ ]]; then
            Log "$(UI.Color.Red) Container $container_name not found $(UI.Color.Default)"
            exit 1
        fi
    fi

    case $ACTION in
    _spawn)
        spawn
        ;;
    _showip)
        getIp
        Log "$(UI.Color.Green) IP of $container_name is $ip $(UI.Color.Default)"
        ;;
    _delete)
        getIp
        ssh-keygen -R $ip
        lxc stop $container_name
        lxc delete $container_name
        ;;
    esac
}

main "$@"
