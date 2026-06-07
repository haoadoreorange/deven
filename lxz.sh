#!/bin/bash
## bash-oo errors with -eu

. "$BASHOO/oo-bootstrap.sh" 2>/dev/null || {
  local_bashoo="$(dirname "$(realpath "$0")")/bash-oo-framework"
  if [ -d "$local_bashoo" ]; then
    [ $((RANDOM % 10)) -eq 7 ] && printf 'Update dependency in %s\n' "$local_bashoo" && git -C "$local_bashoo" pull
  else
    printf 'Install dependency in %s\n' "$local_bashoo"
    git clone https://github.com/niieani/bash-oo-framework.git "$local_bashoo"
  fi
  . "$local_bashoo/lib/oo-bootstrap.sh" || exit 1
}

import util/log util/exception util/tryCatch
namespace lxz
Log::AddOutput lxz INFO
Log::AddOutput error ERROR
Log::AddOutput warn WARN

type lxc >/dev/null 2>&1 || {
  if type pacman >/dev/null 2>&1; then sudo pacman -S lxd
  elif type apt-get >/dev/null 2>&1; then sudo apt-get install lxd
  else subject=error Log 'Cannot install lxd. Install manually https://documentation.ubuntu.com/lxd/latest/installing/'; exit 1; fi
}

PROGRAM=$(basename "$0")
VERSION='1.0'
GID=$(id -g)
BASE="base-$UID"
X11="X11-$UID"

main() {
  case ${1-} in
    ls) awk '/^Host .*-lxz$/{name=substr($2,1,length($2)-4)} /^  HostName /{if(name){print name,$2;name=""}}' "$HOME/.ssh/config" 2>/dev/null; exit ;;
    cd | ip | rm | mont | proxy) ;;
    *)
      cat <<EOF
v$VERSION
Usage: $PROGRAM <command> [options] [container]
Commands:
  ls           - List containers (from cache, may be outdated)
  cd           - Into the container
  ip           - Get ip address, implies starting container
  mont         - Configure shared directory
  proxy        - Forward SOCKS proxy
  rm           - Remove container
  help/version - Print this message
EOF
      exit 1
      ;;
  esac

  local cmd=${1} && shift
  local cn=${1-}
  local msg

  while true; do
    if [ ! "$cn" ]; then
      msg='cannot be empty'
    elif case "$cn" in *[!a-zA-Z0-9-]*) true ;; *) false ;; esac then
      msg='only alphanumeric and hyphens'
    elif [ "$cn" = "$BASE" ]; then
      msg="cannot be $BASE"
    else break; fi
    printf 'Container name (%s): ' "$msg"
    read -r cn
  done

  [ "$cmd" != 'cd' ] && ! _container_exist "$cn" && e="No container $cn to $cmd" throw
  case $cmd in
    cd) spawn "$cn" ;;
    ip) Log "$cn IPv4: $(get_ip "$cn")" ;;
    mont) mont "$cn" ;;
    proxy) proxy "$cn" ;;
    rm) remove "$cn" ;;
  esac
}

spawn() { # throws
  _container_exist "${1:?}" && {
    _start_container_if_stop "$1" # exist → start → login
    [ -f "${XAUTHORITY-}" ] && {
      # Push Xauthority for Xwayland auth
      sudo lxc file push "$XAUTHORITY" "$1"/home/ubuntu/.Xauthority
      sudo lxc exec "$1" -- chown ubuntu:ubuntu /home/ubuntu/.Xauthority
    }
    _forward_ssh_agent "$1"
    sudo lxc exec "$1" -- sudo --user ubuntu ${SOCK_PATH:+SSH_AUTH_SOCK=$SOCK_PATH} --login || : # shell may exit non-zero
    return
  }

  _container_exist "$BASE" || {
    Log "No base for user id $UID. Initialize $PROGRAM"
    _init      # no base → init
    spawn "$@" # then retry
    return
  }

  _try_create_from_base "$1" # otherwise create
  spawn "$@"                # then retry
}

get_ip() { # throws
  _start_container_if_stop "${1:?}"
  # For some reason `lxc list` doesn't show ipv4, but the container does have one.
  # ip="$(sudo lxc list "$1" -c 4 --format csv | grep eth0 | cut -d' ' -f1)"
  local ip
  ip=$(sudo lxc exec "$1" -- ip addr show eth0 | grep "inet\b" | awk '{print $2}' | cut -d/ -f1)

  if [ "$ip" ]; then
    printf '%s' "$ip"
  else
    subject=error Log "No IPv4 for $1, firewall might be blocking DHCP on the bridge interface. Review it then enter to retry"
    read -r _
    _restart "$1"
    get_ip "$@"
  fi
}

mont() {
  local cn=${1:?}
  [ "$cn" = "$BASE" ] && cn='all'
  while true; do
    printf 'Shared directory for %s%s: ' "$cn" "${2+ [$2]}"
    read -r _dir
    _dir=${_dir:-${2-}}
    case $_dir in "~/"*) _dir="$HOME/${_dir#??}" ;; esac
    [ -d "$_dir" ] || { echo 'Not a directory'; continue; }
    [ -r "$_dir" ] && [ -w "$_dir" ] || { echo 'No rw access'; continue; }
    break
  done
  local device
  device=$(basename "$_dir")
  sudo lxc config device add "$1" "$device" disk source="$_dir" path="/home/ubuntu/$device" >/dev/null
}

proxy() {
  printf 'Port [65535]: '
  read -r _port
  _port=${_port:-65535}
  sudo lxc config device remove "${1:?}" socks-proxy 2>/dev/null || : # overwrite
  sudo lxc config device add "$1" socks-proxy proxy \
    listen="tcp:127.0.0.1:$_port" connect="tcp:127.0.0.1:$_port" bind=instance
}

remove() { # throws
  Log "Remove ${1:?} IP in ssh known_hosts"
  ssh-keygen -R "$(get_ip "$1")" || : # continue, remove what's possible
  Log "Remove host $1-lxz in ssh config"
  SOURCE=true . "$(dirname "$(realpath "$0")")/install.sh" && set +eu
  edit -n "$HOME/.ssh/config" sed "/^Host $1-lxz$/,/^Host /{/^Host $1-lxz$/d;/^Host /!d}" </dev/null
  Log "Remove $1"
  sudo lxc stop "$1" || :
  sudo lxc delete "$1" || :
}

# ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────
#                                                     init
# ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────

_init() {
  _try_lxd_init
  sudo lxc profile show "$X11" >/dev/null 2>&1 || (
    Log "$(sudo lxc profile create "$X11")"
    sudo lxc profile edit "$X11" <<EOF
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
    bind: instance
    connect: unix:/run/user/1000/pulse/native
    listen: unix:/home/ubuntu/pulse-native
    security.gid: "$GID"
    security.uid: "$UID"
    uid: "1000"
    gid: "1000"
    mode: "0777"
    type: proxy
  X0:
    bind: instance
    connect: unix:@/tmp/.X11-unix/X${DISPLAY#:}
    listen: unix:@/tmp/.X11-unix/X0
    security.gid: "$GID"
    security.uid: "$UID"
    type: proxy
  mygpu:
    type: gpu
name: X11
used_by: []
EOF
  )
  _try_create_base
}

# ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────
#                                                     Helpers
# ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────

_container_exist() (
  sudo lxc info "${1:?}" >/dev/null 2>&1
)

_start_container_if_stop() { # throws
  if [ "$(_container_state "${1:?}")" = "STOPPED" ]; then
    Log "Start $1"
    Log "$(sudo lxc start "$1")"
    _wait_cloud_init "$1"
  fi
}

_restart() { # throws
  [ "$(_container_state "${1:?}")" != "RUNNING" ] && e="Not running $1, cannot restart" throw
  Log "Restart $1"
  Log "$(sudo lxc restart "$1")"
  _wait_cloud_init "$1"
}

_wait_cloud_init() { # throws
  [ "$(_container_state "${1:?}")" != "RUNNING" ] && e="Not running $1, cannot wait for cloud-init" throw
  Log "Wait for cloud-init in $1"
  Log "$(sudo lxc exec "$1" -- cloud-init status --wait)"
}

_container_state() (
  ## lxc list does substring match — querying "foo" also returns "foobar"
  ## grep -w ensures exact name match
  sudo lxc list "${1:?}" --format csv | grep -w "$1" | cut -d ',' -f2
)

_forward_ssh_agent() { # throws
  printf 'Forward ssh-agent [y/N]: '
  read -r _yn
  case "${_yn:-n}" in
    [Yy])
      [ "${SSH_AUTH_SOCK-}" ] || e='No $SSH_AUTH_SOCK' throw
      local device='ssh-agent'
      SOCK_PATH="/tmp/$device.sock" # trap fire immediately after $() aka BEFORE exec → set env instead
      sudo lxc config device get "${1:?}" "$device" type >/dev/null 2>&1 || {
        sudo lxc config device add "$1" "$device" proxy \
          connect="unix:$SSH_AUTH_SOCK" listen="unix:$SOCK_PATH" \
          bind=instance uid=1000 gid=1000 mode=0600 >&2
        # shellcheck disable=SC2064 # capture current $1 and $device
        trap "sudo lxc config device remove '$1' '$device'" EXIT INT TERM
      }
      ;;
  esac
}

_stop_on_idle() {
  sudo lxc exec "${1:?}" -- sh -c 'cat > /etc/systemd/system/stop-on-idle.service' <<'EOF'
[Unit]
Description=Shutdown if no active sessions

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'if ! who | grep -q .; then poweroff; fi'
EOF
  sudo lxc exec "$1" -- sh -c 'cat > /etc/systemd/system/stop-on-idle.timer' <<'EOF'
[Unit]
Description=Check for idle sessions

[Timer]
OnBootSec=10min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOF
  ! sudo lxc exec "$1" -- systemctl enable stop-on-idle.timer 2>&1 >/dev/null | grep -v '^Created symlink'
}

# ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────
#                                                    try/catch
# ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────

_try_lxd_init() {
  sudo lxc storage show default >/dev/null 2>&1 || { # no default storage -> attempt `lxd init`
    try {
      sudo lxd init
    } catch {
      subject=error Log 'Fail to `lxd init`, fix manually'
      Exception::PrintException "${__EXCEPTION__[@]}"
      exit 1
    }
  }
}

_try_create_base() {
  try {
    ## Allow lxd (root) to use host uid/gid for container mapping
    ## name:start:count — controls which host IDs root may use, not where they map to
    ## Map id fail without this
    Log 'Allow map uid/gid'
    _allowMapId() (
      [ "${2:?}" ] && [ ! -f "${1:?}" ] && subject=warn Log "No $1, may fail to create container"
      if ! grep -qF "$2" "$1" 2>/dev/null; then edit "$1" "<< $2"; fi
    )
    _allowMapId /etc/subuid "root:$UID:1"
    _allowMapId /etc/subgid "root:$GID:1"
    sudo systemctl restart lxd.service

    Log 'Create base ubuntu:noble'
    sudo lxc launch ubuntu:noble "$BASE" --profile default --profile "$X11" \
      --config user.user-data="$(printf '#cloud-config\nssh_pwauth: true\n')" >/dev/null
    _wait_cloud_init "$BASE"
    Log 'Enable stop on idle'
    _stop_on_idle "$BASE"
    sudo lxc stop "$BASE"

    ############################################################################
    ## Actual map id real user to container for r/w mount
    ## Must match uid/gid in X11 profile
    printf 'uid %s 1000\ngid %s 1000\n' "$UID" "$GID" | sudo lxc config set "$BASE" raw.idmap -
    mont "$BASE" '~/dev-sync'

    ############################################################################
    sudo lxc config set "$BASE" boot.autostart false
    # require for docker
    sudo lxc config set "$BASE" security.nesting=true security.syscalls.intercept.setxattr=true security.syscalls.intercept.mknod=true

  } catch {
    subject=error Log 'Fail to create base, clean up'
    remove "$BASE"
    Exception::PrintException "${__EXCEPTION__[@]}"
    exit 1
  }
}

_try_create_from_base() {
  try {
    [ "$(_container_state "$BASE")" = 'RUNNING' ] && {
      subject=warn Log 'Unexpected found base running'
      sudo lxc stop "$BASE"
    }
    Log "Create ${1:?}"
    sudo lxc copy "$BASE" "$1"
    _start_container_if_stop "$1"

    ############################################################################
    Log 'Enable passwordless ssh'
    sudo lxc exec "$1" -- passwd -d ubuntu >/dev/null
    sudo lxc exec "$1" -- bash -c \
      'sudo sed -i -e "s|PasswordAuthentication no|PasswordAuthentication yes|"\
                  -e "s|#PermitEmptyPasswords no|PermitEmptyPasswords yes|" /etc/ssh/sshd_config'
    ## Full restart to pick up sshd config and get a stable IP
    _restart "$1"

    ############################################################################
    Log 'Test ssh connection'
    local ip
    ip=$(get_ip "$1")
    while ! ssh -oStrictHostKeyChecking=accept-new ubuntu@"$ip" true; do
      sleep 3
    done
    SOURCE=true . "$(dirname "$(realpath "$0")")/install.sh" && set +eu
    edit -n "$HOME/.ssh/config" << EOF
Host $1-lxz
  HostName $ip
  User ubuntu
EOF

  } catch {
    Log 'Fail to create container, clean up'
    remove "$1"
    Exception::PrintException "${__EXCEPTION__[@]}"
    exit 1
  }
}

main "$@"
