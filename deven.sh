#!/bin/bash
# -u will error with bash-oo
set -o pipefail

local_bash_oo="$(dirname "$(realpath "$BASH_SOURCE")")/bash-oo-framework"
oo_bootstrap="$BASH_OO"/oo-bootstrap.sh
if [ ! -f "$oo_bootstrap" ]; then
    oo_bootstrap="$local_bash_oo"/lib/oo-bootstrap.sh
    echo "Bash OO framework not found on system"
    if [ ! -f "$oo_bootstrap" ]; then
        echo "Downloading bundled version to $local_bash_oo"
        git clone https://github.com/niieani/bash-oo-framework.git "$local_bash_oo"
    else 
        echo "Found bundled version at $local_bash_oo"
        cd "$local_bash_oo" &&
        git pull
    fi
fi
. "$oo_bootstrap"
import util/log util/exception util/tryCatch
namespace deven
Log::AddOutput deven INFO
Log::AddOutput error ERROR
Log::AddOutput warn WARN

#####################################################################################################################
############################################## Global Variables #####################################################
#####################################################################################################################

VERSION="0.2"
LUID="$(id -u "$(whoami)")"
LGID="$(id -g "$(whoami)")"
BASE="base-$LUID"

#####################################################################################################################
########################################## Init Functions & Helpers #################################################
#####################################################################################################################

#######################################
# Return 0 if container exists
#######################################
# shellcheck disable=SC2120
_containerExists() {
    cn="${1:-$container_name}"
    if [ "$(sudo lxc list "$cn" -c n --format csv | sed -n '1p')" = "$cn" ]; then
        return 0
    else
        return 1
    fi
}

#######################################
# Throw if container not exist
# Arguments:
#   Function name to use in error message
#   Container name to check, default=$container_name
#######################################
_throwContainerNotExist() {
    cn="${2:-$container_name}"
    if ! _containerExists "$cn"; then
        e="Call $1 with non existent container $cn" throw 
        exit 1
    fi
}

#######################################
# Throw if container name is empty
# Arguments:
#   Function name to use in error message
#   Container name to check, default=$container_name
#######################################
_throwEmptyContainerName() {
    cn="${2:-$container_name}"
    if [ -z "$cn" ]; then
        e="Call $1 with empty container name" throw 
        exit 1
    fi
}

_getContainerState() {
    cn="${1:-$container_name}"
    _throwEmptyContainerName "_getContainerState" "$cn"
    _throwContainerNotExist "_getContainerState" "$cn"
    sudo lxc list "$cn" -c s --format csv
}

#######################################
# Wait for cloud-init to finish in container
# Arguments:
#   Container name to wait, default=$container_name
#######################################
_waitForCloudInit() {
    cn="${1:-$container_name}"
    _throwEmptyContainerName "_waitForCloudInit" "$cn"
    _throwContainerNotExist "_waitForCloudInit" "$cn"
    if [ "$(_getContainerState "$cn")" != "RUNNING" ]; then
        e="$cn container not running, cannot wait for cloud-init" throw 
        exit 1
    fi
    Log "Waiting for $cn container cloud-init"
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
        Log "Configuring lxc x11 profile for user id $LUID"
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
    fi
    
    # We only execute this funcion if base container doesn't exist 
    # so if it exists here, something went wrong
    if _containerExists "$BASE"; then
        e="Something went wrong, base container should not exist at this point" throw 
        exit 1
    fi
    
    try {
        # Allow to map user in container to real user in host for r/w mount
        
        subuid=/etc/subuid
        if [ ! -f "$subuid" ]; then
            subject=warn Log "$subuid is missing, creating container might fail"
        fi
        # subuid_content not contains the mapping
        subuid_content="$(cat "$subuid" 2>/dev/null || :)"
        if [ "$subuid_content" = "${subuid_content/root:$LUID:1/}" ]; then
            echo "root:$LUID:1" | sudo tee -a "$subuid" >/dev/null
            restart_lxd=true
        fi
        
        subgid=/etc/subgid
        if [ ! -f "$subgid" ]; then
            subject=warn Log "$subgid is missing, creating container might fail"
        fi
        # subgid_content not contains the mapping
        subgid_content="$(cat "$subgid" 2>/dev/null || :)"
        if [ "$subgid_content" = "${subgid_content/root:$LGID:1/}" ]; then
            echo "root:$LGID:1" | sudo tee -a "$subgid" >/dev/null
            restart_lxd=true
        fi
        
        if [ "${restart_lxd-}" = "true" ]; then
            Log "Restarting lxd.service"
            sudo systemctl restart lxd.service
        fi
        
        Log "Creating base container from cloud image"
        Log "$(sudo lxc launch images:ubuntu/jammy/cloud --profile default --profile "$x11" "$BASE")"
        _waitForCloudInit "$BASE"
        sudo lxc stop "$BASE"
        
        # Map user in container to real user in host for r/w mount
        Log "Configuring base container"
        echo -e "uid $LUID 1000\ngid $LGID 1002" | sudo lxc config set "$BASE" raw.idmap -
        read -rp "Path of the shared dir that containers has access to (r/w) [default=~/dev-sync]: " shared_dir
        shared_dir="${shared_dir:-$HOME/dev-sync}"
        dir_name="$(basename "$shared_dir")"
        # Mount host directory with r/w 
        Log "$(sudo lxc config device add "$BASE" "$dir_name" disk source="$shared_dir" path=/home/ubuntu/"$dir_name")"
        sudo lxc config set "$BASE" boot.autostart false
        # Needed for docker
        sudo lxc config set "$BASE" security.nesting=true security.syscalls.intercept.setxattr=true security.syscalls.intercept.mknod=true
        
    } catch {
        subject=error Log "Create base container failed for user id $LUID. Clean up base container leftovers"
        sudo lxc stop "$BASE" 2>/dev/null || :
        sudo lxc delete "$BASE"
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
        read -rp "Container name (cannot be empty): " container_name
    done
}

#######################################
# Make sure container name doesn't already exist or empty
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
# Start container if stopped and wait until cloud-init is done
#######################################
_startContainerIfStopped() {
    _throwEmptyContainerName "_startContainerIfStopped"
    _throwContainerNotExist "_startContainerIfStopped"
    if [ "$(_getContainerState)" = "STOPPED" ]; then
        Log "Starting $container_name container"
        sudo lxc start "$container_name"
        _waitForCloudInit
        if [ "$(_getContainerState)" != "RUNNING" ]; then
            e="Start $container_name container failed" throw 
            exit 1
        fi
    else
        Log "$container_name container is not stopped, no need to start" 
    fi
}

#######################################
# Restart container and wait until cloud-init is done
#######################################
_restart() {
    _throwEmptyContainerName "_restart"
    _throwContainerNotExist "_restart"
    if [ "$(_getContainerState)" != "RUNNING" ]; then
        e="$cn container not running, cannot restart" throw 
        exit 1
    fi
    Log "Restarting $container_name container"
    sudo lxc restart "$container_name"
    _waitForCloudInit
    if [ "$(_getContainerState)" != "RUNNING" ]; then
        e="Restart $container_name container failed" throw 
        exit 1
    fi
}

#######################################
# Get IP address, set $ip variable
#######################################
_getIp() {
    _throwEmptyContainerName "_getIp"
    _throwContainerNotExist "_getIp"
    _startContainerIfStopped
    
    # For some reason `lxc list` doesn't show ipv4, but the container does have one.
    # ip="$(sudo lxc list "$container_name" -c 4 --format csv | grep eth0 | cut -d' ' -f1)"
    ip="$(sudo lxc exec "$container_name" -- ip addr show eth0 | grep "inet\b" | awk '{print $2}' | cut -d/ -f1)"
    
    if [ -z "$ip" ]; then
        subject=error Log "$container_name container does not have ipv4, your firewall might be blocking dhcp on the bridge interface. Please review it and enter to retry"
        read -r r 
        _restart
        _getIp
    fi
}

#######################################
# Delete & clean up container
#######################################
delete() {
    _throwEmptyContainerName "delete"
    _throwContainerNotExist "delete"
    Log "Removing $container_name container IP address from ssh known_hosts"
    _getIp
    ssh-keygen -R "$ip" 2>/dev/null
    Log "Removing $container_name-container entry from ssh config"
    sed -i "/# <$container_name-container>/,/# <\/$container_name-container>/d" "$HOME"/.ssh/config
    Log "Deleting $container_name container"
    sudo lxc stop "$container_name" 2>/dev/null || :
    sudo lxc delete "$container_name"
}

#######################################
# Login to container or spawn if not found
#######################################
spawn() {
    # If container exists then login 
    if _containerExists; then
        _startContainerIfStopped
        sudo lxc exec "$container_name" -- sudo --user ubuntu --login || :
    else
        # Otherwise, if base container exists then create from copy 
        if _containerExists "$BASE"; then
            try {
                if [ "$(_getContainerState "$BASE")" = "RUNNING" ]; then
                    subject=warn Log "Base container is running, stopping it"
                    sudo lxc stop "$BASE"
                fi
                _validateNewContainerName
                Log "Creating $container_name container from base"
                sudo lxc copy "$BASE" "$container_name"
                _getIp
                
                # Activating ssh passwordless
                if [ "$no_ssh_passwordless" != "true" ]; then
                    _startContainerIfStopped
                    Log "Activating ssh passwordless for $container_name container"
                    sudo lxc exec "$container_name" -- passwd -d ubuntu
                    sudo lxc exec "$container_name" -- bash -c \
                        "sudo sed -i -e \"s|PasswordAuthentication no|PasswordAuthentication yes|\"\
                        -e \"s|#PermitEmptyPasswords no|PermitEmptyPasswords yes|\" /etc/ssh/sshd_config"
                    # sudo lxc exec "$container_name" -- bash -c "sudo echo \"ssh\" >> /etc/securetty"
                    _restart
                    Log "Making 1st ssh to initialize connection"
                    until ssh -oStrictHostKeyChecking=accept-new ubuntu@"$ip" command; do
                        sleep 3
                    done
                fi
                
                # Add entry to ~/.ssh/config
                ssh_entry_name="$container_name-container"
                cat >> "$HOME"/.ssh/config <<EOF
# <$ssh_entry_name>
Host $ssh_entry_name 
    HostName $ip
    User ubuntu
# </$ssh_entry_name> 
EOF

            } catch {
                Log "Create $container_name container from base failed. Clean up container leftovers"
                if _containerExists; then
                    delete
                fi 
                Exception::PrintException "${__EXCEPTION__[@]}"
                exit 1
            }
        # Otherwise init everything 
        else
            Log "Base container not found for user id $LUID. Initing"
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
            Log "Creating container in classic mode"
            no_ssh_passwordless="true"
            ;;
        esac
    done
    shift $((OPTIND - 1))

    container_name="${1-}"
    _askContainerNameIfEmpty
    if [ "$ACTION" != "_spawn" ]; then
        _throwContainerNotExist "$ACTION"
    fi

    case $ACTION in
    _spawn)
        spawn
        ;;
    _showip)
        _getIp
        Log "IP of $container_name container is $ip"
        ;;
    _delete)
        delete
        ;;
    esac
}

main "$@"
