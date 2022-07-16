#!/bin/bash
set -o pipefail

CURRENT_DIR="$(dirname "$(realpath "$BASH_SOURCE")")"
if [ -f "$BASH_OO/oo-bootstrap.sh" ]; then
    . "$BASH_OO/oo-bootstrap.sh"
else 
    echo "Bash OO Framework not found on system, downloading to $CURRENT_DIR"
    git clone https://github.com/niieani/bash-oo-framework.git "$CURRENT_DIR"/bash-oo-framework
    . "$CURRENT_DIR"/bash-oo-framework/lib/oo-bootstrap.sh
fi
import util/log util/exception util/tryCatch
namespace deven
Log::AddOutput deven INFO
Log::AddOutput error ERROR

#####################################################################################################################
############################################## Global Variables #####################################################
#####################################################################################################################

VERSION="0.1"
        
LUID=$(id -u $(whoami))
LGID=$(id -g $(whoami))
BASE="base-$LUID"

#####################################################################################################################
########################################## Init Functions & Helpers #################################################
#####################################################################################################################

# shellcheck disable=SC2120
_containerExists() {
    cn="${1:-"$container_name"}"
    if [ "$(sudo lxc list "$cn" -c n --format csv)" == "$cn" ]; then
        return 0
    else
        return 1
    fi
}

#######################################
# Throw if container not exist
# Arguments:
#   Function name to use in error message
#######################################
_throwContainerNotExist() {
    if ! _containerExists; then
        e="Call $1 with non existent container" throw 
        exit 1
    fi
}

_waitForCloudInit() {
    cn="${1:-"$container_name"}"
    _throwEmptyContainerName "_waitForCloudInit" "$cn"
    if [ "$(sudo lxc list "$cn" -c s --format csv)" != "RUNNING" ]; then
        e="$cn container not running, cannot wait for cloud-init" throw 
        exit 1
    fi
    Log "Wait for $cn container cloud-init"
    Log "$(sudo lxc exec "$cn" -- cloud-init status --wait)"
}

#######################################
# Run `lxd init` if necessary
# Create a x11 profile if necessary
# Create and configure the base container
#######################################
_init() {
    x11="x11-$LUID"
    try {
        # If there is no default storage, chance is `lxd init` has not been run
        if ! sudo lxc storage show default >/dev/null 2>&1; then
            Log "Running \`lxd init\`"
            sudo lxd init
        fi
    } catch {
        subject=error Log "\`lxd init\` failed, please fix manually"
        Exception::PrintException "${__EXCEPTION__[@]}"
        exit 1
    }   

    # Create if x11 profile doesn't exists for current user
    if ! sudo lxc profile show "$x11"  >/dev/null 2>&1; then
        Log "$(sudo lxc profile create "$x11")"
        { 
            cat << EOF
config:
  environment.DISPLAY: :0
  environment.PULSE_SERVER: unix:/home/ubuntu/pulse-native
  nvidia.driver.capabilities: all
  nvidia.runtime: "true"
  user.user-data: |
    #cloud-config
    runcmd:
      - 'sed -i "s/; enable-shm = yes/enable-shm = no/g" /etc/pulse/client.conf'
    packages:
      - x11-apps
      - mesa-utils
      - pulseaudio
      - openssh-server
description: GUI LXD profile
devices:
  PASocket1:
    bind: container
    connect: unix:/run/user/1000/pulse/native
    listen: unix:/home/ubuntu/pulse-native
    security.gid: "$LGID"
    security.uid: "$LUID"
    uid: "1000"
    gid: "1002"
    mode: "0777"
    type: proxy
  X0:
    bind: container
    connect: unix:@/tmp/.X11-unix/X${DISPLAY//:/}
    listen: unix:@/tmp/.X11-unix/X0
    security.gid: "$LGID"
    security.uid: "$LUID"
    type: proxy
  mygpu:
    type: gpu
name: x11
used_by: []
EOF
        } | sudo lxc profile edit "$x11"
        Log "Container x11 profile edited for user id $LUID succesfully"
    fi
    
    # We only execute this funcion if base container doesn't exist 
    # so if it exists here, something went wrong
    if _containerExists "$BASE"; then
        e="Something went wrong, base container should not exist at this point" throw 
        exit 1
    fi
    
    try {
        # Allow to map user in container to real user in host for r/w mount
        if [ ! -f "/etc/subuid" ]; then
            subject=warn Log "/etc/subuid was missing, creating container might fail"
        fi
        if [[ ! "$(cat /etc/subuid)" =~ "root:$LUID:1" ]]; then
            echo "root:$LUID:1" | sudo tee -a /etc/subuid >/dev/null
            restart_lxd=true
        fi
        if [ ! -f "/etc/subgid" ]; then
            subject=warn Log "/etc/subgid was missing, creating container might fail"
        fi
        if [[ ! "$(cat /etc/subgid)" =~ "root:$LGID:1" ]]; then
            echo "root:$LGID:1" | sudo tee -a /etc/subgid >/dev/null
            restart_lxd=true
        fi
        if [ "$restart_lxd" == "true" ]; then
            sudo systemctl restart lxd.service
            Log "Restart lxd.service successfully"
        fi
        
        Log "$(sudo lxc launch images:ubuntu/jammy/cloud --profile default --profile "$x11" "$BASE")"
        _waitForCloudInit "$BASE"
        sudo lxc stop "$BASE"
        Log "Create base container from cloud image successfully"
        
        # Map user in container to real user in host for r/w mount
        echo -e "uid $LUID 1000\ngid $LGID 1002" | sudo lxc config set "$BASE" raw.idmap -
        read -rp "Path of the shared dir that containers has access to (r/w) [default=~/dev-sync]: " shared_dir
        shared_dir="${shared_dir:-"$HOME"/dev-sync}"
        dir_name="$(basename "$shared_dir")"
        # Mount host directory with r/w 
        Log "$(sudo lxc config device add "$BASE" "$dir_name" disk source="$shared_dir" path=/home/ubuntu/"$dir_name")"
        sudo lxc config set "$BASE" boot.autostart false
        Log "Config base container successfully"
        
    } catch {
        sudo lxc stop "$BASE" || :
        sudo lxc delete "$BASE"
        subject=error Log "Create base container failed for user id $LUID. Deleted base container leftovers"
        Exception::PrintException "${__EXCEPTION__[@]}"
        exit 1 
    }
}

#####################################################################################################################
############################################ Spawn Functions & Helpers ##############################################
#####################################################################################################################

#######################################
# Make sure container name ins't empty
#######################################
_askContainerNameIfEmpty() {
    while [ -z "$container_name" ]; do
        read -rp "Container name: " container_name
    done
}

#######################################
# Make sure container name doesn't already exist
#######################################
_validateNewContainerName() {
    while _containerExists; do
        read -rp "Container name already exist, please chose another: " container_name
    done
    if [ -z "$container_name" ]; then
        _askContainerNameIfEmpty
        _validateNewContainerName
    fi
}

#######################################
# Throw if container name is empty
# Arguments:
#   Function name to use in error message
#######################################
_throwEmptyContainerName() {
    cn="${2:-"$container_name"}"
    if [ -z "$cn" ]; then
        e="Call $1 with empty container name" throw 
        exit 1
    fi
}

#######################################
# Start container if stopped and wait until cloud-init is done
#######################################
_startContainerIfStopped() {
    _throwEmptyContainerName "_startContainerIfStopped"
    if [ "$(sudo lxc list "$container_name" -c s --format csv)" == "STOPPED" ]; then
        sudo lxc start "$container_name"
        _waitForCloudInit
        if [ "$(sudo lxc list "$container_name" -c s --format csv)" != "RUNNING" ]; then
            e="Start $container_name container failed" throw 
            exit 1
        fi
        Log "Start $container_name container successfully"
    fi
}

#######################################
# Restart container and wait until cloud-init is done
#######################################
_restart() {
    _throwEmptyContainerName "_restart"
    _throwContainerNotExist "_restart"
    sudo lxc restart "$container_name"
    _waitForCloudInit
    if [ "$(sudo lxc list "$container_name" -c s --format csv)" != "RUNNING" ]; then
        e="Restart $container_name container failed" throw 
        exit 1
    fi
    Log "Restart $container_name container successfully"
}

#######################################
# Get IP address, set $ip variable
#######################################
_getIp() {
    _throwEmptyContainerName "_getIp"
    _throwContainerNotExist "_getIp"
    _startContainerIfStopped
    ip="$(sudo lxc list "$container_name" -c 4 --format csv | cut -d' ' -f1)"
    if [ -z "$ip" ]; then
        subject=error Log "$container_name container does not have ipv4, your firewall might be blocking dhcp on the bridge interface. Please allow it and enter to continue"
        read -r r 
        sudo lxc restart "$container_name"
        _getIp
    fi
}

_activateSshPasswordless() {
    if [ "$no_ssh_passwordless" != "true" ]; then
        _startContainerIfStopped
        sudo lxc exec "$container_name" -- passwd -d ubuntu
        sudo lxc exec "$container_name" -- bash -c "cat /etc/ssh/sshd_config | sed -e \"s|PasswordAuthentication no|PasswordAuthentication yes|\" | sed -e \"s|#PermitEmptyPasswords no|PermitEmptyPasswords yes|\" | sudo tee /etc/ssh/sshd_config > /dev/null"
        # sudo lxc exec "$container_name" -- bash -c "sudo echo \"ssh\" >> /etc/securetty"
        Log "Activate ssh passwordless for $container_name container successfully"
        _restart
        _getIp
        until ssh ubuntu@$ip command; do
            sleep 3
        done
        Log "First ssh to initialize connection successfully"
    fi
}

#######################################
# Login to container or spawn if not found
#######################################
spawn() {
    # If container exists then login 
    if _containerExists; then
        _startContainerIfStopped
        try { 
            sudo lxc exec "$container_name" -- sudo --user ubuntu --login
        } catch {
            exit 0
        }
    else
        # Otherwise, if base container exists then create from copy 
        if _containerExists "$BASE"; then
            try {
                if [ "$(sudo lxc list "$BASE" -c s --format csv)" == "RUNNING" ]; then
                    subject=warn Log "Base container is running, stopping it"
                    sudo lxc stop "$BASE"
                fi
                _validateNewContainerName
                sudo lxc copy "$BASE" "$container_name"
                Log "Create $container_name container from base successfully"
                _activateSshPasswordless
            } catch {
                sudo lxc stop "$container_name" || :
                sudo lxc delete "$container_name"
                Log "Create $container_name container from base failed. Delete container leftovers"
                Exception::PrintException "${__EXCEPTION__[@]}"
                exit 1
            }
        # Otherwise init everything 
        else
            Log "Base container not found for user id $LUID. Init"
            _init
        fi
        # Recursive call until login successfully 
        spawn
    fi
}

display_help() {
  cat <<EOUSAGE
deven v$VERSION 
Usage: deven <command>
    Commands:
        spawn               Spawn a new container
            Options:
            -c                  Classic mode (without ssh passwordless). Only effective if used on newly created container
            
        showip              Show ip address of container, implies starting container
        delete              Delete container
        help                Print this message and exit
        version             Print the version and exit
EOUSAGE
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
    help)
        display_help
        exit 0
        ;;
    version)
        echo "v$VERSION"
        exit 0
        ;;
    *)
        display_help
        exit 1
        ;;
    esac

    while getopts 'c' opt; do
        case "$opt" in
        c)
            no_ssh_passwordless="true"
            Log "Classic mode enabled"
            ;;
        esac
    done
    shift $((OPTIND - 1))

    container_name=$1
    _askContainerNameIfEmpty
    if [ "$ACTION" != "_spawn" ]; then
        if ! _containerExists; then
            e="$container_name container not found" throw 
            exit 1
        fi
    fi

    case $ACTION in
    _spawn)
        spawn
        ;;
    _showip)
        _getIp
        Log "IP of $container_name is $ip"
        ;;
    _delete)
        _getIp
        ssh-keygen -R "$ip"
        Log "Remove "$container_name" container IP address from ssh known_hosts successfully"
        sudo lxc stop "$container_name"
        sudo lxc delete "$container_name"
        Log "Delete "$container_name" container successfully"
        ;;
    esac
}

main "$@"
