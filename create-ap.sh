#!/bin/bash

# general dependencies:
#    bash (to run this script)
#    util-linux (for getopt)
#    procps or procps-ng
#    hostapd
#    iproute2
#    iw
#    iwconfig (you only need this if 'iw' can not recognize your adapter)
#    haveged (optional)

# dependencies for 'nat' or 'none' Internet sharing method
#    dnsmasq
#    iptables

VERSION=0.1
PROGNAME="$(basename $0)"

# make sure that all command outputs are in english
# so we can parse them correctly
export LC_ALL=C

# all new files and directories must be readable only by root.
# in special cases we must use chmod to give any other permissions.
SCRIPT_UMASK=0077
umask $SCRIPT_UMASK

usage() {
    echo "Usage: "$PROGNAME" [options] <wifi-interface> [<interface-with-internet>] [<access-point-name> [<passphrase>]]"
    echo
    echo "Options:"
    echo "  -h, --help              Show this help"
    echo "  --version               Print version number"
    echo "  -c <channel>            Channel number (default: 1)"
    echo "  -w <WPA version>        Use 1 for WPA, use 2 for WPA2, use 1+2 for both (default: 1+2)"
    echo "  -n                      Disable Internet sharing (if you use this, don't pass"
    echo "                          the <interface-with-internet> argument)"
    echo "  -m <method>             Method for Internet sharing."
    echo "                          Use: 'nat' for NAT (default)"
    echo "                               'bridge' for bridging"
    echo "                               'none' for no Internet sharing (equivalent to -n)"
    echo "  --psk                   Use 64 hex digits pre-shared-key instead of passphrase"
    echo "  --hidden                Make the Access Point hidden (do not broadcast the SSID)"
    echo "  --ieee80211n            Enable IEEE 802.11n (HT)"
    echo "  --ht_capab <HT>         HT capabilities (default: [HT40+])"
    echo "  --country <code>        Set two-letter country code for regularity (example: US)"
    echo "  --freq-band <GHz>       Set frequency band. Valid inputs: 2.4, 5 (default: 2.4)"
    echo "  --driver                Choose your WiFi adapter driver (default: nl80211)"
    echo "  --no-virt               Do not create virtual interface"
    echo "  --no-haveged            Do not run 'haveged' automatically when needed"
    echo "  --fix-unmanaged         If NetworkManager shows your interface as unmanaged after you"
    echo "                          close create_ap, then use this option to switch your interface"
    echo "                          back to managed"
    echo "  --mac <MAC>             Set MAC address"
    echo "  --daemon                Run create_ap in the background"
    echo "  --stop <id>             Send stop command to an already running create_ap. For an <id>"
    echo "                          you can put the PID of create_ap or the WiFi interface. You can"
    echo "                          get them with --list-running"
    echo "  --list-running          Show the create_ap processes that are already running"
    echo "  --list-clients <id>     List the clients connected to create_ap instance associated with <id>."
    echo "                          For an <id> you can put the PID of create_ap or the WiFi interface."
    echo "                          If virtual WiFi interface was created, then use that one."
    echo "                          You can get them with --list-running"
    echo "  --mkconfig <conf_file>  Store configs in conf_file"
    echo "  --config <conf_file>    Load configs from conf_file"
    echo
    echo "Non-Bridging Options:"
    echo "  -g <gateway>            IPv4 Gateway for the Access Point (default: 192.168.12.1)"
    echo "  -d                      DNS server will take into account /etc/hosts"
    echo
    echo "Useful informations:"
    echo "  * If you're not using the --no-virt option, then you can create an AP with the same"
    echo "    interface you are getting your Internet connection."
    echo "  * You can pass your SSID and password through pipe or through arguments (see examples)."
    echo "  * On bridge method if the <interface-with-internet> is not a bridge interface, then"
    echo "    a bridge interface is created automatically."
    echo
    echo "Examples:"
    echo "  "$PROGNAME" wlan0 eth0 MyAccessPoint MyPassPhrase"
    echo "  echo -e 'MyAccessPoint\nMyPassPhrase' | "$PROGNAME" wlan0 eth0"
    echo "  "$PROGNAME" wlan0 eth0 MyAccessPoint"
    echo "  echo 'MyAccessPoint' | "$PROGNAME" wlan0 eth0"
    echo "  "$PROGNAME" wlan0 wlan0 MyAccessPoint MyPassPhrase"
    echo "  "$PROGNAME" -n wlan0 MyAccessPoint MyPassPhrase"
    echo "  "$PROGNAME" -m bridge wlan0 eth0 MyAccessPoint MyPassPhrase"
    echo "  "$PROGNAME" -m bridge wlan0 br0 MyAccessPoint MyPassPhrase"
    echo "  "$PROGNAME" --driver rtl871xdrv wlan0 eth0 MyAccessPoint MyPassPhrase"
    echo "  "$PROGNAME" --daemon wlan0 eth0 MyAccessPoint MyPassPhrase"
    echo "  "$PROGNAME" --stop wlan0"
}

# on success it echos a non-zero unused FD
# on error it echos 0
get_avail_fd() {
    local x
    for x in $(seq 1 $(ulimit -n)); do
        if [[ ! -a "/proc/$BASHPID/fd/$x" ]]; then
            echo $x
            return
        fi
    done
    echo 0
}

# lock file for the mutex counter
COUNTER_LOCK_FILE=/tmp/create_ap.$$.lock

cleanup_lock() {
    rm -f $COUNTER_LOCK_FILE
}

init_lock() {
    local LOCK_FILE=/tmp/create_ap.all.lock

    # we initialize only once
    [[ $LOCK_FD -ne 0 ]] && return 0

    LOCK_FD=$(get_avail_fd)
    [[ $LOCK_FD -eq 0 ]] && return 1

    # open/create lock file with write access for all users
    # otherwise normal users will not be able to use it.
    # to avoid race conditions on creation, we need to
    # use umask to set the permissions.
    umask 0555
    eval "exec $LOCK_FD>$LOCK_FILE" > /dev/null 2>&1 || return 1
    umask $SCRIPT_UMASK

    # there is a case where lock file was created from a normal
    # user. change the owner to root as soon as we can.
    [[ $(id -u) -eq 0 ]] && chown 0:0 $LOCK_FILE

    # create mutex counter lock file
    echo 0 > $COUNTER_LOCK_FILE

    return $?
}

# recursive mutex lock for all create_ap processes
mutex_lock() {
    local counter_mutex_fd
    local counter

    # lock local mutex and read counter
    counter_mutex_fd=$(get_avail_fd)
    if [[ $counter_mutex_fd -ne 0 ]]; then
        eval "exec $counter_mutex_fd<>$COUNTER_LOCK_FILE"
        flock $counter_mutex_fd
        read -u $counter_mutex_fd counter
    else
        echo "Failed to lock mutex counter" >&2
        return 1
    fi

    # lock global mutex and increase counter
    [[ $counter -eq 0 ]] && flock $LOCK_FD
    counter=$(( $counter + 1 ))

    # write counter and unlock local mutex
    echo $counter > /proc/$BASHPID/fd/$counter_mutex_fd
    eval "exec ${counter_mutex_fd}<&-"
    return 0
}

# recursive mutex unlock for all create_ap processes
mutex_unlock() {
    local counter_mutex_fd
    local counter

    # lock local mutex and read counter
    counter_mutex_fd=$(get_avail_fd)
    if [[ $counter_mutex_fd -ne 0 ]]; then
        eval "exec $counter_mutex_fd<>$COUNTER_LOCK_FILE"
        flock $counter_mutex_fd
        read -u $counter_mutex_fd counter
    else
        echo "Failed to lock mutex counter" >&2
        return 1
    fi

    # decrease counter and unlock global mutex
    if [[ $counter -gt 0 ]]; then
        counter=$(( $counter - 1 ))
        [[ $counter -eq 0 ]] && flock -u $LOCK_FD
    fi

    # write counter and unlock local mutex
    echo $counter > /proc/$BASHPID/fd/$counter_mutex_fd
    eval "exec ${counter_mutex_fd}<&-"
    return 0
}

# it takes 2 arguments
# returns:
#  0 if v1 (1st argument) and v2 (2nd argument) are the same
#  1 if v1 is less than v2
#  2 if v1 is greater than v2
version_cmp() {
    local V1 V2 VN x
    [[ ! $1 =~ ^[0-9]+(\.[0-9]+)*$ ]] && die "Wrong version format!"
    [[ ! $2 =~ ^[0-9]+(\.[0-9]+)*$ ]] && die "Wrong version format!"

    V1=( $(echo $1 | tr '.' ' ') )
    V2=( $(echo $2 | tr '.' ' ') )
    VN=${#V1[@]}
    [[ $VN -lt ${#V2[@]} ]] && VN=${#V2[@]}

    for ((x = 0; x < $VN; x++)); do
        [[ ${V1[x]} -lt ${V2[x]} ]] && return 1
        [[ ${V1[x]} -gt ${V2[x]} ]] && return 2
    done

    return 0
}

USE_IWCONFIG=0

is_interface() {
    [[ -z "$1" ]] && return 1
    [[ -d "/sys/class/net/${1}" ]]
}

is_wifi_interface() {
    which iw > /dev/null 2>&1 && iw dev $1 info > /dev/null 2>&1 && return 0
    if which iwconfig > /dev/null 2>&1 && iwconfig $1 > /dev/null 2>&1; then
        USE_IWCONFIG=1
        return 0
    fi
    return 1
}

is_bridge_interface() {
    [[ -z "$1" ]] && return 1
    [[ -d "/sys/class/net/${1}/bridge" ]]
}

get_phy_device() {
    local x
    for x in /sys/class/ieee80211/*; do
        [[ ! -e "$x" ]] && continue
        if [[ "${x##*/}" = "$1" ]]; then
            echo $1
            return 0
        elif [[ -e "$x/device/net/$1" ]]; then
            echo ${x##*/}
            return 0
        elif [[ -e "$x/device/net:$1" ]]; then
            echo ${x##*/}
            return 0
        fi
    done
    echo "Failed to get phy interface" >&2
    return 1
}

get_adapter_info() {
    local PHY
    PHY=$(get_phy_device "$1")
    [[ $? -ne 0 ]] && return 1
    iw phy $PHY info
}

get_adapter_kernel_module() {
    local MODULE
    MODULE=$(readlink -f "/sys/class/net/$1/device/driver/module")
    echo ${MODULE##*/}
}

can_be_sta_and_ap() {
    # iwconfig does not provide this information, assume false
    [[ $USE_IWCONFIG -eq 1 ]] && return 1
    get_adapter_info "$1" | grep -E '{.* managed.* AP.*}' > /dev/null 2>&1 && return 0
    get_adapter_info "$1" | grep -E '{.* AP.* managed.*}' > /dev/null 2>&1 && return 0
    return 1
}

can_be_ap() {
    # iwconfig does not provide this information, assume true
    [[ $USE_IWCONFIG -eq 1 ]] && return 0
    get_adapter_info "$1" | grep -E '\* AP$' > /dev/null 2>&1 && return 0
    return 1
}

can_transmit_to_channel() {
    local IFACE CHANNEL_NUM CHANNEL_INFO
    IFACE=$1
    CHANNEL_NUM=$2

    if [[ $USE_IWCONFIG -eq 0 ]]; then
        if [[ $FREQ_BAND == 2.4 ]]; then
            CHANNEL_INFO=$(get_adapter_info ${IFACE} | grep " 24[0-9][0-9] MHz \[${CHANNEL_NUM}\]")
        else
            CHANNEL_INFO=$(get_adapter_info ${IFACE} | grep " \(49[0-9][0-9]\|5[0-9]\{3\}\) MHz \[${CHANNEL_NUM}\]")
        fi
        [[ -z "${CHANNEL_INFO}" ]] && return 1
        [[ "${CHANNEL_INFO}" == *no\ IR* ]] && return 1
        [[ "${CHANNEL_INFO}" == *disabled* ]] && return 1
        return 0
    else
        CHANNEL_NUM=$(printf '%02d' ${CHANNEL_NUM})
        CHANNEL_INFO=$(iwlist ${IFACE} channel | grep "Channel ${CHANNEL_NUM} :")
        [[ -z "${CHANNEL_INFO}" ]] && return 1
        return 0
    fi
}

# taken from iw/util.c
ieee80211_frequency_to_channel() {
    local FREQ=$1
    if [[ $FREQ -eq 2484 ]]; then
        echo 14
    elif [[ $FREQ -lt 2484 ]]; then
        echo $(( ($FREQ - 2407) / 5 ))
    elif [[ $FREQ -ge 4910 && $FREQ -le 4980 ]]; then
        echo $(( ($FREQ - 4000) / 5 ))
    elif [[ $FREQ -le 45000 ]]; then
        echo $(( ($FREQ - 5000) / 5 ))
    elif [[ $FREQ -ge 58320 && $FREQ -le 64800 ]]; then
        echo $(( ($FREQ - 56160) / 2160 ))
    else
        echo 0
    fi
}

is_5ghz_frequency() {
    [[ $1 =~ ^(49[0-9]{2})|(5[0-9]{3})$ ]]
}

is_wifi_connected() {
    if [[ $USE_IWCONFIG -eq 0 ]]; then
        iw dev "$1" link 2>&1 | grep -E '^Connected to' > /dev/null 2>&1 && return 0
    else
        iwconfig "$1" 2>&1 | grep -E 'Access Point: [0-9a-fA-F]{2}:' > /dev/null 2>&1 && return 0
    fi
    return 1
}

is_macaddr() {
    echo "$1" | grep -E "^([0-9a-fA-F]{2}:){5}[0-9a-fA-F]{2}$" > /dev/null 2>&1
}

is_unicast_macaddr() {
    local x
    is_macaddr "$1" || return 1
    x=$(echo "$1" | cut -d: -f1)
    x=$(printf '%d' "0x${x}")
    [[ $(expr $x % 2) -eq 0 ]]
}

get_macaddr() {
    is_interface "$1" || return
    cat "/sys/class/net/${1}/address"
}

alloc_new_iface() {
    local prefix=$1
    local i=0

    mutex_lock
    while :; do
        if ! is_interface $prefix$i && [[ ! -f $COMMON_CONFDIR/ifaces/$prefix$i ]]; then
            mkdir -p $COMMON_CONFDIR/ifaces
            touch $COMMON_CONFDIR/ifaces/$prefix$i
            echo $prefix$i
            mutex_unlock
            return
        fi
        i=$((i + 1))
    done
    mutex_unlock
}

dealloc_iface() {
    rm -f $COMMON_CONFDIR/ifaces/$1
}

get_all_macaddrs() {
    cat /sys/class/net/*/address
}

get_new_macaddr() {
    local OLDMAC NEWMAC LAST_BYTE i
    OLDMAC=$(get_macaddr "$1")
    LAST_BYTE=$(printf %d 0x${OLDMAC##*:})
    mutex_lock
    for i in {1..255}; do
        NEWMAC="${OLDMAC%:*}:$(printf %02x $(( ($LAST_BYTE + $i) % 256 )))"
        (get_all_macaddrs | grep "$NEWMAC" > /dev/null 2>&1) || break
    done
    mutex_unlock
    echo $NEWMAC
}

# start haveged when needed
haveged_watchdog() {
    local show_warn=1
    while :; do
        mutex_lock
        if [[ $(cat /proc/sys/kernel/random/entropy_avail) -lt 1000 ]]; then
            if ! which haveged > /dev/null 2>&1; then
                if [[ $show_warn -eq 1 ]]; then
                    echo "WARN: Low entropy detected. We recommend you to install \`haveged'"
                    show_warn=0
                fi
            elif ! pidof haveged > /dev/null 2>&1; then
                echo "Low entropy detected, starting haveged"
                # boost low-entropy
                haveged -w 1024 -p $COMMON_CONFDIR/haveged.pid
            fi
        fi
        mutex_unlock
        sleep 2
    done
}

NETWORKMANAGER_CONF=/etc/NetworkManager/NetworkManager.conf
NM_OLDER_VERSION=1

networkmanager_exists() {
    local NM_VER
    which nmcli > /dev/null 2>&1 || return 1
    NM_VER=$(nmcli -v | grep -m1 -oE '[0-9]+(\.[0-9]+)*\.[0-9]+')
    version_cmp $NM_VER 0.9.9
    if [[ $? -eq 1 ]]; then
        NM_OLDER_VERSION=1
    else
        NM_OLDER_VERSION=0
    fi
    return 0
}

networkmanager_is_running() {
    local NMCLI_OUT
    networkmanager_exists || return 1
    if [[ $NM_OLDER_VERSION -eq 1 ]]; then
        NMCLI_OUT=$(nmcli -t -f RUNNING nm)
    else
        NMCLI_OUT=$(nmcli -t -f RUNNING g)
    fi
    [[ "$NMCLI_OUT" == "running" ]]
}

networkmanager_iface_is_unmanaged() {
    is_interface "$1" || return 2
    (nmcli -t -f DEVICE,STATE d | grep -E "^$1:unmanaged$" > /dev/null 2>&1) || return 1
}

ADDED_UNMANAGED=

networkmanager_add_unmanaged() {
    local MAC UNMANAGED WAS_EMPTY x
    networkmanager_exists || return 1

    [[ -d ${NETWORKMANAGER_CONF%/*} ]] || mkdir -p ${NETWORKMANAGER_CONF%/*}
    [[ -f ${NETWORKMANAGER_CONF} ]] || touch ${NETWORKMANAGER_CONF}

    if [[ $NM_OLDER_VERSION -eq 1 ]]; then
        if [[ -z "$2" ]]; then
            MAC=$(get_macaddr "$1")
        else
            MAC="$2"
        fi
        [[ -z "$MAC" ]] && return 1
    fi

    mutex_lock
    UNMANAGED=$(grep -m1 -Eo '^unmanaged-devices=[[:alnum:]:;,-]*' /etc/NetworkManager/NetworkManager.conf)

    WAS_EMPTY=0
    [[ -z "$UNMANAGED" ]] && WAS_EMPTY=1
    UNMANAGED=$(echo "$UNMANAGED" | sed 's/unmanaged-devices=//' | tr ';,' ' ')

    # if it exists, do nothing
    for x in $UNMANAGED; do
        if [[ $x == "mac:${MAC}" ]] ||
               [[ $NM_OLDER_VERSION -eq 0 && $x == "interface-name:${1}" ]]; then
            mutex_unlock
            return 2
        fi
    done

    if [[ $NM_OLDER_VERSION -eq 1 ]]; then
        UNMANAGED="${UNMANAGED} mac:${MAC}"
    else
        UNMANAGED="${UNMANAGED} interface-name:${1}"
    fi

    UNMANAGED=$(echo $UNMANAGED | sed -e 's/^ //')
    UNMANAGED="${UNMANAGED// /;}"
    UNMANAGED="unmanaged-devices=${UNMANAGED}"

    if ! grep -E '^\[keyfile\]' ${NETWORKMANAGER_CONF} > /dev/null 2>&1; then
        echo -e "\n\n[keyfile]\n${UNMANAGED}" >> ${NETWORKMANAGER_CONF}
    elif [[ $WAS_EMPTY -eq 1 ]]; then
        sed -e "s/^\(\[keyfile\].*\)$/\1\n${UNMANAGED}/" -i ${NETWORKMANAGER_CONF}
    else
        sed -e "s/^unmanaged-devices=.*/${UNMANAGED}/" -i ${NETWORKMANAGER_CONF}
    fi

    ADDED_UNMANAGED="${ADDED_UNMANAGED} ${1} "
    mutex_unlock

    return 0
}

networkmanager_rm_unmanaged() {
    local MAC UNMANAGED
    networkmanager_exists || return 1
    [[ ! -f ${NETWORKMANAGER_CONF} ]] && return 1

    if [[ $NM_OLDER_VERSION -eq 1 ]]; then
        if [[ -z "$2" ]]; then
            MAC=$(get_macaddr "$1")
        else
            MAC="$2"
        fi
        [[ -z "$MAC" ]] && return 1
    fi

    mutex_lock
    UNMANAGED=$(grep -m1 -Eo '^unmanaged-devices=[[:alnum:]:;,-]*' /etc/NetworkManager/NetworkManager.conf | sed 's/unmanaged-devices=//' | tr ';,' ' ')

    if [[ -z "$UNMANAGED" ]]; then
        mutex_unlock
        return 1
    fi

    [[ -n "$MAC" ]] && UNMANAGED=$(echo $UNMANAGED | sed -e "s/mac:${MAC}\( \|$\)//g")
    UNMANAGED=$(echo $UNMANAGED | sed -e "s/interface-name:${1}\( \|$\)//g")
    UNMANAGED=$(echo $UNMANAGED | sed -e 's/ $//')

    if [[ -z "$UNMANAGED" ]]; then
        sed -e "/^unmanaged-devices=.*/d" -i ${NETWORKMANAGER_CONF}
    else
        UNMANAGED="${UNMANAGED// /;}"
        UNMANAGED="unmanaged-devices=${UNMANAGED}"
        sed -e "s/^unmanaged-devices=.*/${UNMANAGED}/" -i ${NETWORKMANAGER_CONF}
    fi

    ADDED_UNMANAGED="${ADDED_UNMANAGED/ ${1} /}"
    mutex_unlock

    return 0
}

networkmanager_fix_unmanaged() {
    [[ -f ${NETWORKMANAGER_CONF} ]] || return
    mutex_lock
    sed -e "/^unmanaged-devices=.*/d" -i ${NETWORKMANAGER_CONF}
    mutex_unlock
}

networkmanager_rm_unmanaged_if_needed() {
    [[ $ADDED_UNMANAGED =~ .*\ ${1}\ .* ]] && networkmanager_rm_unmanaged $1 $2
}

networkmanager_wait_until_unmanaged() {
    local RES
    networkmanager_is_running || return 1
    while :; do
        networkmanager_iface_is_unmanaged "$1"
        RES=$?
        [[ $RES -eq 0 ]] && break
        [[ $RES -eq 2 ]] && die "Interface '${1}' does not exists.
       It's probably renamed by a udev rule."
        sleep 1
    done
    sleep 2
    return 0
}


CHANNEL=default
GATEWAY=192.168.12.1
WPA_VERSION=1+2
ETC_HOSTS=0
HIDDEN=0
SHARE_METHOD=nat
IEEE80211N=0
HT_CAPAB='[HT40+]'
DRIVER=nl80211
NO_VIRT=0
COUNTRY=
FREQ_BAND=2.4
NEW_MACADDR=
DAEMONIZE=0
NO_HAVEGED=0
USE_PSK=0


CONFIG_OPTS=(CHANNEL GATEWAY WPA_VERSION ETC_HOSTS HIDDEN SHARE_METHOD
             IEEE80211N HT_CAPAB DRIVER NO_VIRT COUNTRY FREQ_BAND
             NEW_MACADDR DAEMONIZE NO_HAVEGED WIFI_IFACE INTERNET_IFACE
             SSID PASSPHRASE USE_PSK)

FIX_UNMANAGED=0
LIST_RUNNING=0
STOP_ID=
LIST_CLIENTS_ID=

STORE_CONFIG=
LOAD_CONFIG=

CONFDIR=
WIFI_IFACE=
VWIFI_IFACE=
INTERNET_IFACE=
BRIDGE_IFACE=
OLD_MACADDR=
IP_ADDRS=
ROUTE_ADDRS=

HAVEGED_WATCHDOG_PID=

_cleanup() {
    local PID x

    trap "" SIGINT SIGUSR1 SIGUSR2 EXIT
    mutex_lock
    disown -a

    # kill haveged_watchdog
    [[ -n "$HAVEGED_WATCHDOG_PID" ]] && kill $HAVEGED_WATCHDOG_PID

    # kill processes
    for x in $CONFDIR/*.pid; do
        # even if the $CONFDIR is empty, the for loop will assign
        # a value in $x. so we need to check if the value is a file
        [[ -f $x ]] && kill -9 $(cat $x)
    done

    rm -rf $CONFDIR

    local found=0
    for x in $(list_running_conf); do
        if [[ -f $x/nat_internet_iface && $(cat $x/nat_internet_iface) == $INTERNET_IFACE ]]; then
            found=1
            break
        fi
    done

    if [[ $found -eq 0 ]]; then
        cp -f $COMMON_CONFDIR/${INTERNET_IFACE}_forwarding \
           /proc/sys/net/ipv4/conf/$INTERNET_IFACE/forwarding
        rm -f $COMMON_CONFDIR/${INTERNET_IFACE}_forwarding
    fi

    # if we are the last create_ap instance then set back the common values
    if ! has_running_instance; then
        # kill common processes
        for x in $COMMON_CONFDIR/*.pid; do
            [[ -f $x ]] && kill -9 $(cat $x)
        done

        # set old ip_forward
        if [[ -f $COMMON_CONFDIR/ip_forward ]]; then
            cp -f $COMMON_CONFDIR/ip_forward /proc/sys/net/ipv4
            rm -f $COMMON_CONFDIR/ip_forward
        fi

        # set old bridge-nf-call-iptables
        if [[ -f $COMMON_CONFDIR/bridge-nf-call-iptables ]]; then
            if [[ -e /proc/sys/net/bridge/bridge-nf-call-iptables ]]; then
                cp -f $COMMON_CONFDIR/bridge-nf-call-iptables /proc/sys/net/bridge
            fi
            rm -f $COMMON_CONFDIR/bridge-nf-call-iptables
        fi

        rm -rf $COMMON_CONFDIR
    fi

    if [[ "$SHARE_METHOD" != "none" ]]; then
        if [[ "$SHARE_METHOD" == "nat" ]]; then
            iptables -t nat -D POSTROUTING -o ${INTERNET_IFACE} -s ${GATEWAY%.*}.0/24 -j MASQUERADE
            iptables -D FORWARD -i ${WIFI_IFACE} -s ${GATEWAY%.*}.0/24 -j ACCEPT
            iptables -D FORWARD -i ${INTERNET_IFACE} -d ${GATEWAY%.*}.0/24 -j ACCEPT
        elif [[ "$SHARE_METHOD" == "bridge" ]]; then
            if ! is_bridge_interface $INTERNET_IFACE; then
                ip link set dev $BRIDGE_IFACE down
                ip link set dev $INTERNET_IFACE down
                ip link set dev $INTERNET_IFACE promisc off
                ip link set dev $INTERNET_IFACE nomaster
                ip link delete $BRIDGE_IFACE type bridge
                ip addr flush $INTERNET_IFACE
                ip link set dev $INTERNET_IFACE up
                dealloc_iface $BRIDGE_IFACE

                for x in "${IP_ADDRS[@]}"; do
                    x="${x/inet/}"
                    x="${x/secondary/}"
                    x="${x/dynamic/}"
                    x=$(echo $x | sed 's/\([0-9]\)sec/\1/g')
                    x="${x/${INTERNET_IFACE}/}"
                    ip addr add $x dev $INTERNET_IFACE
                done

                ip route flush dev $INTERNET_IFACE

                for x in "${ROUTE_ADDRS[@]}"; do
                    [[ -z "$x" ]] && continue
                    [[ "$x" == default* ]] && continue
                    ip route add $x dev $INTERNET_IFACE
                done

                for x in "${ROUTE_ADDRS[@]}"; do
                    [[ -z "$x" ]] && continue
                    [[ "$x" != default* ]] && continue
                    ip route add $x dev $INTERNET_IFACE
                done

                networkmanager_rm_unmanaged_if_needed $INTERNET_IFACE
            fi
        fi
    fi

    if [[ "$SHARE_METHOD" != "bridge" ]]; then
        iptables -D INPUT -p tcp -m tcp --dport 53 -j ACCEPT
        iptables -D INPUT -p udp -m udp --dport 53 -j ACCEPT
        iptables -D INPUT -p udp -m udp --dport 67 -j ACCEPT
    fi

    if [[ $NO_VIRT -eq 0 ]]; then
        if [[ -n "$VWIFI_IFACE" ]]; then
            ip link set down dev ${VWIFI_IFACE}
            ip addr flush ${VWIFI_IFACE}
            networkmanager_rm_unmanaged_if_needed ${VWIFI_IFACE} ${OLD_MACADDR}
            iw dev ${VWIFI_IFACE} del
            dealloc_iface $VWIFI_IFACE
        fi
    else
        ip link set down dev ${WIFI_IFACE}
        ip addr flush ${WIFI_IFACE}
        if [[ -n "$NEW_MACADDR" ]]; then
            ip link set dev ${WIFI_IFACE} address ${OLD_MACADDR}
        fi
        networkmanager_rm_unmanaged_if_needed ${WIFI_IFACE} ${OLD_MACADDR}
    fi

    mutex_unlock
    cleanup_lock
}

cleanup() {
    echo
    echo -n "Doing cleanup.. "
    _cleanup > /dev/null 2>&1
    echo "done"
}

die() {
    [[ -n "$1" ]] && echo -e "\nERROR: $1\n" >&2
    # send die signal to the main process
    [[ $BASHPID -ne $$ ]] && kill -USR2 $$
    # we don't need to call cleanup because it's traped on EXIT
    exit 1
}

clean_exit() {
    # send clean_exit signal to the main process
    [[ $BASHPID -ne $$ ]] && kill -USR1 $$
    # we don't need to call cleanup because it's traped on EXIT
    exit 0
}

list_running_conf() {
    local x
    mutex_lock
    for x in /tmp/create_ap.*; do
        if [[ -f $x/pid && -f $x/wifi_iface && -d /proc/$(cat $x/pid) ]]; then
            echo $x
        fi
    done
    mutex_unlock
}

list_running() {
    local IFACE wifi_iface x
    mutex_lock
    for x in $(list_running_conf); do
        IFACE=${x#*.}
        IFACE=${IFACE%%.*}
        wifi_iface=$(cat $x/wifi_iface)

        if [[ $IFACE == $wifi_iface ]]; then
            echo $(cat $x/pid) $IFACE
        else
            echo $(cat $x/pid) $IFACE '('$(cat $x/wifi_iface)')'
        fi
    done
    mutex_unlock
}

get_wifi_iface_from_pid() {
    list_running | awk '{print $1 " " $NF}' | tr -d '\(\)' | grep -E "^${1} " | cut -d' ' -f2
}

get_pid_from_wifi_iface() {
    list_running | awk '{print $1 " " $NF}' | tr -d '\(\)' | grep -E " ${1}$" | cut -d' ' -f1
}

get_confdir_from_pid() {
    local IFACE x
    mutex_lock
    for x in $(list_running_conf); do
        if [[ $(cat $x/pid) == "$1" ]]; then
            echo $x
            break
        fi
    done
    mutex_unlock
}

print_client() {
    local line ipaddr hostname
    local mac="$1"

    if [[ -f $CONFDIR/dnsmasq.leases ]]; then
        line=$(grep " $mac " $CONFDIR/dnsmasq.leases | tail -n 1)
        ipaddr=$(echo $line | cut -d' ' -f3)
        hostname=$(echo $line | cut -d' ' -f4)
    fi

    [[ -z "$ipaddr" ]] && ipaddr="*"
    [[ -z "$hostname" ]] && hostname="*"

    printf "%-20s %-18s %s\n" "$mac" "$ipaddr" "$hostname"
}

list_clients() {
    local wifi_iface pid

    # If PID is given, get the associated wifi iface
    if [[ "$1" =~ ^[1-9][0-9]*$ ]]; then
        pid="$1"
        wifi_iface=$(get_wifi_iface_from_pid "$pid")
        [[ -z "$wifi_iface" ]] && die "'$pid' is not the pid of a running $PROGNAME instance."
    fi

    [[ -z "$wifi_iface" ]] && wifi_iface="$1"
    is_wifi_interface "$wifi_iface" || die "'$wifi_iface' is not a WiFi interface."

    [[ -z "$pid" ]] && pid=$(get_pid_from_wifi_iface "$wifi_iface")
    [[ -z "$pid" ]] && die "'$wifi_iface' is not used from $PROGNAME instance.\n\
       Maybe you need to pass the virtual interface instead.\n\
       Use --list-running to find it out."
    [[ -z "$CONFDIR" ]] && CONFDIR=$(get_confdir_from_pid "$pid")

    if [[ $USE_IWCONFIG -eq 0 ]]; then
        local awk_cmd='($1 ~ /Station$/) {print $2}'
        local client_list=$(iw dev "$wifi_iface" station dump | awk "$awk_cmd")

        if [[ -z "$client_list" ]]; then
            echo "No clients connected"
            return
        fi

        printf "%-20s %-18s %s\n" "MAC" "IP" "Hostname"

        local mac
        for mac in $client_list; do
            print_client $mac
        done
    else
        die "This option is not supported for the current driver."
    fi
}

has_running_instance() {
    local PID x

    mutex_lock
    for x in /tmp/create_ap.*; do
        if [[ -f $x/pid ]]; then
            PID=$(cat $x/pid)
            if [[ -d /proc/$PID ]]; then
                mutex_unlock
                return 0
            fi
        fi
    done
    mutex_lock

    return 1
}

is_running_pid() {
    list_running | grep -E "^${1} " > /dev/null 2>&1
}

send_stop() {
    local x

    mutex_lock
    # send stop signal to specific pid
    if is_running_pid $1; then
        kill -USR1 $1
        mutex_unlock
        return
    fi

    # send stop signal to specific interface
    for x in $(list_running | grep -E " \(?${1}( |\)?\$)" | cut -f1 -d' '); do
        kill -USR1 $x
    done
    mutex_unlock
}

# Storing configs
write_config() {
    local i=1

    if ! eval 'echo -n > "$STORE_CONFIG"' > /dev/null 2>&1; then
        echo "ERROR: Unable to create config file $STORE_CONFIG" >&2
        exit 1
    fi

    WIFI_IFACE=$1
    if [[ "$SHARE_METHOD" == "none" ]]; then
        SSID="$2"
        PASSPHRASE="$3"
    else
        INTERNET_IFACE="$2"
        SSID="$3"
        PASSPHRASE="$4"
    fi

    for config_opt in "${CONFIG_OPTS[@]}"; do
        eval echo $config_opt=\$$config_opt
    done >> "$STORE_CONFIG"

    echo -e "Config options written to '$STORE_CONFIG'"
    exit 0
}

is_config_opt() {
    local elem opt="$1"

    for elem in "${CONFIG_OPTS[@]}"; do
        if [[ "$elem" == "$opt" ]]; then
            return 0
        fi
    done
    return 1
}

# Load options from config file
read_config() {
    local opt_name opt_val line

    while read line; do
        # Read switches and their values
        opt_name="${line%%=*}"
        opt_val="${line#*=}"
        if is_config_opt "$opt_name" ; then
            eval $opt_name="\$opt_val"
        else
            echo "WARN: Unrecognized configuration entry $opt_name" >&2
        fi
    done < "$LOAD_CONFIG"
}


ARGS=( "$@" )

# Preprocessing for --config before option-parsing starts
for ((i=0; i<$#; i++)); do
    if [[ "${ARGS[i]}" = "--config" ]]; then
        if [[ -f "${ARGS[i+1]}" ]]; then
            LOAD_CONFIG="${ARGS[i+1]}"
            read_config
        else
            echo "ERROR: No config file found at given location" >&2
            exit 1
        fi
        break
    fi
done

GETOPT_ARGS=$(getopt -o hc:w:g:dnm: -l "help","hidden","ieee80211n","ht_capab:","driver:","no-virt","fix-unmanaged","country:","freq-band:","mac:","daemon","stop:","list","list-running","list-clients:","version","psk","no-haveged","mkconfig:","config:" -n "$PROGNAME" -- "$@")
[[ $? -ne 0 ]] && exit 1
eval set -- "$GETOPT_ARGS"

while :; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --version)
            echo $VERSION
            exit 0
            ;;
        --hidden)
            shift
            HIDDEN=1
            ;;
        -c)
            shift
            CHANNEL="$1"
            shift
            ;;
        -w)
            shift
            WPA_VERSION="$1"
            [[ "$WPA_VERSION" == "2+1" ]] && WPA_VERSION=1+2
            shift
            ;;
        -g)
            shift
            GATEWAY="$1"
            shift
            ;;
        -d)
            shift
            ETC_HOSTS=1
            ;;
        -n)
            shift
            SHARE_METHOD=none
            ;;
        -m)
            shift
            SHARE_METHOD="$1"
            shift
            ;;
        --ieee80211n)
            shift
            IEEE80211N=1
            ;;
        --ht_capab)
            shift
            HT_CAPAB="$1"
            shift
            ;;
        --driver)
            shift
            DRIVER="$1"
            shift
            ;;
        --no-virt)
            shift
            NO_VIRT=1
            ;;
        --fix-unmanaged)
            shift
            FIX_UNMANAGED=1
            ;;
        --country)
            shift
            COUNTRY="$1"
            shift
            ;;
        --freq-band)
            shift
            FREQ_BAND="$1"
            shift
            ;;
        --mac)
            shift
            NEW_MACADDR="$1"
            shift
            ;;
        --daemon)
            shift
            DAEMONIZE=1
            ;;
        --stop)
            shift
            STOP_ID="$1"
            shift
            ;;
        --list)
            shift
            LIST_RUNNING=1
            echo -e "WARN: --list is deprecated, use --list-running instead.\n" >&2
            ;;
        --list-running)
            shift
            LIST_RUNNING=1
            ;;
        --list-clients)
            shift
            LIST_CLIENTS_ID="$1"
            shift
            ;;
        --no-haveged)
            shift
            NO_HAVEGED=1
            ;;
        --psk)
            shift
            USE_PSK=1
            ;;
        --mkconfig)
            shift
            STORE_CONFIG="$1"
            shift
            ;;
        --config)
            shift
            shift
            ;;
        --)
            shift
            break
            ;;
    esac
done

# Load positional args from config file, if needed
if [[ -n "$LOAD_CONFIG" && $# -eq 0 ]]; then
    i=0
    # set arguments in order
    for x in WIFI_IFACE INTERNET_IFACE SSID PASSPHRASE; do
        if eval "[[ -n \"\$${x}\" ]]"; then
            eval "set -- \"\${@:1:$i}\" \"\$${x}\""
            ((i++))
        fi
        # we unset the variable to avoid any problems later
        eval "unset $x"
    done
fi

# Check if required number of positional args are present
if [[ $# -lt 1 && $FIX_UNMANAGED -eq 0  && -z "$STOP_ID" &&
      $LIST_RUNNING -eq 0 && -z "$LIST_CLIENTS_ID" ]]; then
    usage >&2
    exit 1
fi

trap "cleanup_lock" EXIT

if ! init_lock; then
    echo "ERROR: Failed to initialize lock" >&2
    exit 1
fi

# if the user press ctrl+c or we get USR1 signal
# then run clean_exit()
trap "clean_exit" SIGINT SIGUSR1
# if we get USR2 signal then run die().
trap "die" SIGUSR2

[[ -n "$STORE_CONFIG" ]] && write_config "$@"

if [[ $LIST_RUNNING -eq 1 ]]; then
    echo -e "List of running $PROGNAME instances:\n"
    list_running
    exit 0
fi

if [[ -n "$LIST_CLIENTS_ID" ]]; then
    list_clients "$LIST_CLIENTS_ID"
    exit 0
fi

if [[ $(id -u) -ne 0 ]]; then
    echo "You must run it as root." >&2
    exit 1
fi

if [[ -n "$STOP_ID" ]]; then
    echo "Trying to kill $PROGNAME instance associated with $STOP_ID..."
    send_stop "$STOP_ID"
    exit 0
fi

if [[ $FIX_UNMANAGED -eq 1 ]]; then
    echo "Trying to fix unmanaged status in NetworkManager..."
    networkmanager_fix_unmanaged
    exit 0
fi

if [[ $DAEMONIZE -eq 1 && $RUNNING_AS_DAEMON -eq 0 ]]; then
    echo "Running as Daemon..."
    # run a detached create_ap
    RUNNING_AS_DAEMON=1 setsid "$0" "${ARGS[@]}" &
    exit 0
fi

if [[ $FREQ_BAND != 2.4 && $FREQ_BAND != 5 ]]; then
    echo "ERROR: Invalid frequency band" >&2
    exit 1
fi

if [[ $CHANNEL == default ]]; then
    if [[ $FREQ_BAND == 2.4 ]]; then
        CHANNEL=1
    else
        CHANNEL=36
    fi
fi

if [[ $FREQ_BAND != 5 && $CHANNEL -gt 14 ]]; then
    echo "Channel number is greater than 14, assuming 5GHz frequency band"
    FREQ_BAND=5
fi

WIFI_IFACE=$1

if ! is_wifi_interface ${WIFI_IFACE}; then
    echo "ERROR: '${WIFI_IFACE}' is not a WiFi interface" >&2
    exit 1
fi

if ! can_be_ap ${WIFI_IFACE}; then
    echo "ERROR: Your adapter does not support AP (master) mode" >&2
    exit 1
fi

if ! can_be_sta_and_ap ${WIFI_IFACE}; then
    if is_wifi_connected ${WIFI_IFACE}; then
        echo "ERROR: Your adapter can not be a station (i.e. be connected) and an AP at the same time" >&2
        exit 1
    elif [[ $NO_VIRT -eq 0 ]]; then
        echo "WARN: Your adapter does not fully support AP virtual interface, enabling --no-virt" >&2
        NO_VIRT=1
    fi
fi

if [[ $(get_adapter_kernel_module ${WIFI_IFACE}) =~ ^(8192[cd][ue]|8723a[sue])$ ]]; then
    if ! strings $(which hostapd) | grep -m1 rtl871xdrv > /dev/null 2>&1; then
        echo "ERROR: You need to patch your hostapd with rtl871xdrv patches." >&2
        exit 1
    fi

    if [[ $DRIVER != "rtl871xdrv" ]]; then
        echo "WARN: Your adapter needs rtl871xdrv, enabling --driver=rtl871xdrv" >&2
        DRIVER=rtl871xdrv
    fi
fi

if [[ "$SHARE_METHOD" != "nat" && "$SHARE_METHOD" != "bridge" && "$SHARE_METHOD" != "none" ]]; then
    echo "ERROR: Wrong Internet sharing method" >&2
    echo
    usage >&2
    exit 1
fi

if [[ -n "$NEW_MACADDR" ]]; then
    if ! is_macaddr "$NEW_MACADDR"; then
        echo "ERROR: '${NEW_MACADDR}' is not a valid MAC address" >&2
        exit 1
    fi

    if ! is_unicast_macaddr "$NEW_MACADDR"; then
        echo "ERROR: The first byte of MAC address (${NEW_MACADDR}) must be even" >&2
        exit 1
    fi

    if [[ $(get_all_macaddrs | grep -c ${NEW_MACADDR}) -ne 0 ]]; then
        echo "WARN: MAC address '${NEW_MACADDR}' already exists. Because of this, you may encounter some problems" >&2
    fi
fi

if [[ "$SHARE_METHOD" != "none" ]]; then
    MIN_REQUIRED_ARGS=2
else
    MIN_REQUIRED_ARGS=1
fi

if [[ $# -gt $MIN_REQUIRED_ARGS ]]; then
    if [[ "$SHARE_METHOD" != "none" ]]; then
        if [[ $# -ne 3 && $# -ne 4 ]]; then
            usage >&2
            exit 1
        fi
        INTERNET_IFACE="$2"
        SSID="$3"
        PASSPHRASE="$4"
    else
        if [[ $# -ne 2 && $# -ne 3 ]]; then
            usage >&2
            exit 1
        fi
        SSID="$2"
        PASSPHRASE="$3"
    fi
else
    if [[ "$SHARE_METHOD" != "none" ]]; then
        if [[ $# -ne 2 ]]; then
            usage >&2
            exit 1
        fi
        INTERNET_IFACE="$2"
    fi
    if tty -s; then
        while :; do
            read -p "SSID: " SSID
            if [[ ${#SSID} -lt 1 || ${#SSID} -gt 32 ]]; then
                echo "ERROR: Invalid SSID length ${#SSID} (expected 1..32)" >&2
                continue
            fi
            break
        done
        while :; do
            if [[ $USE_PSK -eq 0 ]]; then
                read -p "Passphrase: " -s PASSPHRASE
                echo
                if [[ ${#PASSPHRASE} -gt 0 && ${#PASSPHRASE} -lt 8 ]] || [[ ${#PASSPHRASE} -gt 63 ]]; then
                    echo "ERROR: Invalid passphrase length ${#PASSPHRASE} (expected 8..63)" >&2
                    continue
                fi
                read -p "Retype passphrase: " -s PASSPHRASE2
                echo
                if [[ "$PASSPHRASE" != "$PASSPHRASE2" ]]; then
                    echo "Passphrases do not match."
                else
                    break
                fi
            else
                read -p "PSK: " PASSPHRASE
                echo
                if [[ ${#PASSPHRASE} -gt 0 && ${#PASSPHRASE} -ne 64 ]]; then
                    echo "ERROR: Invalid pre-shared-key length ${#PASSPHRASE} (expected 64)" >&2
                    continue
                fi
            fi
        done
    else
        read SSID
        read PASSPHRASE
    fi
fi

if [[ "$SHARE_METHOD" != "none" ]] && ! is_interface $INTERNET_IFACE; then
    echo "ERROR: '${INTERNET_IFACE}' is not an interface" >&2
    exit 1
fi

if [[ ${#SSID} -lt 1 || ${#SSID} -gt 32 ]]; then
    echo "ERROR: Invalid SSID length ${#SSID} (expected 1..32)" >&2
    exit 1
fi

if [[ $USE_PSK -eq 0 ]]; then
    if [[ ${#PASSPHRASE} -gt 0 && ${#PASSPHRASE} -lt 8 ]] || [[ ${#PASSPHRASE} -gt 63 ]]; then
        echo "ERROR: Invalid passphrase length ${#PASSPHRASE} (expected 8..63)" >&2
        exit 1
    fi
elif [[ ${#PASSPHRASE} -gt 0 && ${#PASSPHRASE} -ne 64 ]]; then
    echo "ERROR: Invalid pre-shared-key length ${#PASSPHRASE} (expected 64)" >&2
    exit 1
fi

if [[ $(get_adapter_kernel_module ${WIFI_IFACE}) =~ ^rtl[0-9].*$ ]]; then
    if [[ -n "$PASSPHRASE" ]]; then
        echo "WARN: Realtek drivers usually have problems with WPA1, enabling -w 2" >&2
        WPA_VERSION=2
    fi
    echo "WARN: If AP doesn't work, please read: howto/realtek.md" >&2
fi

if [[ "$SHARE_METHOD" == "bridge" ]]; then
    if is_bridge_interface $INTERNET_IFACE; then
        BRIDGE_IFACE=$INTERNET_IFACE
    else
        BRIDGE_IFACE=$(alloc_new_iface br)
    fi
fi

if [[ $NO_VIRT -eq 1 && "$WIFI_IFACE" == "$INTERNET_IFACE" ]]; then
    echo -n "ERROR: You can not share your connection from the same" >&2
    echo " interface if you are using --no-virt option." >&2
    exit 1
fi

mutex_lock
trap "cleanup" EXIT
CONFDIR=$(mktemp -d /tmp/create_ap.${WIFI_IFACE}.conf.XXXXXXXX)
echo "Config dir: $CONFDIR"
echo "PID: $$"
echo $$ > $CONFDIR/pid

# to make --list-running work from any user, we must give read
# permissions to $CONFDIR and $CONFDIR/pid
chmod 755 $CONFDIR
chmod 444 $CONFDIR/pid

COMMON_CONFDIR=/tmp/create_ap.common.conf
mkdir -p $COMMON_CONFDIR

if [[ "$SHARE_METHOD" == "nat" ]]; then
    echo $INTERNET_IFACE > $CONFDIR/nat_internet_iface
    cp -n /proc/sys/net/ipv4/conf/$INTERNET_IFACE/forwarding \
       $COMMON_CONFDIR/${INTERNET_IFACE}_forwarding
fi
cp -n /proc/sys/net/ipv4/ip_forward $COMMON_CONFDIR
if [[ -e /proc/sys/net/bridge/bridge-nf-call-iptables ]]; then
    cp -n /proc/sys/net/bridge/bridge-nf-call-iptables $COMMON_CONFDIR
fi
mutex_unlock

if [[ $NO_VIRT -eq 0 ]]; then
    VWIFI_IFACE=$(alloc_new_iface ap)

    # in NetworkManager 0.9.9 and above we can set the interface as unmanaged without
    # the need of MAC address, so we set it before we create the virtual interface.
    if networkmanager_is_running && [[ $NM_OLDER_VERSION -eq 0 ]]; then
        echo -n "Network Manager found, set ${VWIFI_IFACE} as unmanaged device... "
        networkmanager_add_unmanaged ${VWIFI_IFACE}
        # do not call networkmanager_wait_until_unmanaged because interface does not
        # exist yet
        echo "DONE"
    fi

    if is_wifi_connected ${WIFI_IFACE}; then
        WIFI_IFACE_FREQ=$(iw dev ${WIFI_IFACE} link | grep -i freq | awk '{print $2}')
        WIFI_IFACE_CHANNEL=$(ieee80211_frequency_to_channel ${WIFI_IFACE_FREQ})
        echo -n "${WIFI_IFACE} is already associated with channel ${WIFI_IFACE_CHANNEL} (${WIFI_IFACE_FREQ} MHz)"
        if is_5ghz_frequency $WIFI_IFACE_FREQ; then
            FREQ_BAND=5
        else
            FREQ_BAND=2.4
        fi
        if [[ $WIFI_IFACE_CHANNEL -ne $CHANNEL ]]; then
            echo ", fallback to channel ${WIFI_IFACE_CHANNEL}"
            CHANNEL=$WIFI_IFACE_CHANNEL
        else
            echo
        fi
    fi

    VIRTDIEMSG="Maybe your WiFi adapter does not fully support virtual interfaces.
       Try again with --no-virt."
    echo -n "Creating a virtual WiFi interface... "

    if iw dev ${WIFI_IFACE} interface add ${VWIFI_IFACE} type managed; then
        # now we can call networkmanager_wait_until_unmanaged
        networkmanager_is_running && [[ $NM_OLDER_VERSION -eq 0 ]] && networkmanager_wait_until_unmanaged ${VWIFI_IFACE}
        echo "${VWIFI_IFACE} created."
    else
        VWIFI_IFACE=
        die "$VIRTDIEMSG"
    fi
    OLD_MACADDR=$(get_macaddr ${VWIFI_IFACE})
    if [[ -z "$NEW_MACADDR" && $(get_all_macaddrs | grep -c ${OLD_MACADDR}) -ne 1 ]]; then
        NEW_MACADDR=$(get_new_macaddr ${VWIFI_IFACE})
    fi
    WIFI_IFACE=${VWIFI_IFACE}
else
    OLD_MACADDR=$(get_macaddr ${WIFI_IFACE})
fi

mutex_lock
echo $WIFI_IFACE > $CONFDIR/wifi_iface
chmod 444 $CONFDIR/wifi_iface
mutex_unlock

can_transmit_to_channel ${WIFI_IFACE} ${CHANNEL} || die "Your adapter can not transmit to channel ${CHANNEL}, frequency band ${FREQ_BAND}GHz."

if networkmanager_is_running && ! networkmanager_iface_is_unmanaged ${WIFI_IFACE}; then
    echo -n "Network Manager found, set ${WIFI_IFACE} as unmanaged device... "
    networkmanager_add_unmanaged ${WIFI_IFACE}
    networkmanager_wait_until_unmanaged ${WIFI_IFACE}
    echo "DONE"
fi

[[ $HIDDEN -eq 1 ]] && echo "Access Point's SSID is hidden!"

# hostapd config
cat << EOF > $CONFDIR/hostapd.conf
beacon_int=100
ssid=${SSID}
interface=${WIFI_IFACE}
driver=${DRIVER}
channel=${CHANNEL}
ctrl_interface=$CONFDIR/hostapd_ctrl
ctrl_interface_group=0
ignore_broadcast_ssid=$HIDDEN
EOF

if [[ -n $COUNTRY ]]; then
    [[ $USE_IWCONFIG -eq 0 ]] && iw reg set $COUNTRY
    echo "country_code=${COUNTRY}" >> $CONFDIR/hostapd.conf
fi

if [[ $FREQ_BAND == 2.4 ]]; then
    echo "hw_mode=g" >> $CONFDIR/hostapd.conf
else
    echo "hw_mode=a" >> $CONFDIR/hostapd.conf
fi

if [[ $IEEE80211N -eq 1 ]]; then
    cat << EOF >> $CONFDIR/hostapd.conf
ieee80211n=1
wmm_enabled=1
ht_capab=${HT_CAPAB}
EOF
fi

if [[ -n "$PASSPHRASE" ]]; then
    [[ "$WPA_VERSION" == "1+2" ]] && WPA_VERSION=3
    if [[ $USE_PSK -eq 0 ]]; then
        WPA_KEY_TYPE=passphrase
    else
        WPA_KEY_TYPE=psk
    fi
    cat << EOF >> $CONFDIR/hostapd.conf
wpa=${WPA_VERSION}
wpa_${WPA_KEY_TYPE}=${PASSPHRASE}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP CCMP
rsn_pairwise=CCMP
EOF
fi

if [[ "$SHARE_METHOD" == "bridge" ]]; then
    echo "bridge=${BRIDGE_IFACE}" >> $CONFDIR/hostapd.conf
else
    # dnsmasq config (dhcp + dns)
    DNSMASQ_VER=$(dnsmasq -v | grep -m1 -oE '[0-9]+(\.[0-9]+)*\.[0-9]+')
    version_cmp $DNSMASQ_VER 2.63
    if [[ $? -eq 1 ]]; then
        DNSMASQ_BIND=bind-interfaces
    else
        DNSMASQ_BIND=bind-dynamic
    fi
    cat << EOF > $CONFDIR/dnsmasq.conf
listen-address=${GATEWAY}
${DNSMASQ_BIND}
dhcp-range=${GATEWAY%.*}.1,${GATEWAY%.*}.254,255.255.255.0,24h
dhcp-option=option:router,${GATEWAY}
EOF
    [[ $ETC_HOSTS -eq 0 ]] && echo no-hosts >> $CONFDIR/dnsmasq.conf
fi

# initialize WiFi interface
if [[ $NO_VIRT -eq 0 && -n "$NEW_MACADDR" ]]; then
    ip link set dev ${WIFI_IFACE} address ${NEW_MACADDR} || die "$VIRTDIEMSG"
fi

ip link set down dev ${WIFI_IFACE} || die "$VIRTDIEMSG"
ip addr flush ${WIFI_IFACE} || die "$VIRTDIEMSG"

if [[ $NO_VIRT -eq 1 && -n "$NEW_MACADDR" ]]; then
    ip link set dev ${WIFI_IFACE} address ${NEW_MACADDR} || die
fi

if [[ "$SHARE_METHOD" != "bridge" ]]; then
    ip link set up dev ${WIFI_IFACE} || die "$VIRTDIEMSG"
    ip addr add ${GATEWAY}/24 broadcast ${GATEWAY%.*}.255 dev ${WIFI_IFACE} || die "$VIRTDIEMSG"
fi

# enable Internet sharing
if [[ "$SHARE_METHOD" != "none" ]]; then
    echo "Sharing Internet using method: $SHARE_METHOD"
    if [[ "$SHARE_METHOD" == "nat" ]]; then
        iptables -t nat -I POSTROUTING -o ${INTERNET_IFACE} -s ${GATEWAY%.*}.0/24 -j MASQUERADE || die
        iptables -I FORWARD -i ${WIFI_IFACE} -s ${GATEWAY%.*}.0/24 -j ACCEPT || die
        iptables -I FORWARD -i ${INTERNET_IFACE} -d ${GATEWAY%.*}.0/24 -j ACCEPT || die
        echo 1 > /proc/sys/net/ipv4/conf/$INTERNET_IFACE/forwarding || die
        echo 1 > /proc/sys/net/ipv4/ip_forward || die
        # to enable clients to establish PPTP connections we must
        # load nf_nat_pptp module
        modprobe nf_nat_pptp > /dev/null 2>&1
    elif [[ "$SHARE_METHOD" == "bridge" ]]; then
        # disable iptables rules for bridged interfaces
        if [[ -e /proc/sys/net/bridge/bridge-nf-call-iptables ]]; then
            echo 0 > /proc/sys/net/bridge/bridge-nf-call-iptables
        fi

        # to initialize the bridge interface correctly we need to do the following:
        #
        # 1) save the IPs and route table of INTERNET_IFACE
        # 2) if NetworkManager is running set INTERNET_IFACE as unmanaged
        # 3) create BRIDGE_IFACE and attach INTERNET_IFACE to it
        # 4) set the previously saved IPs and route table to BRIDGE_IFACE
        #
        # we need the above because BRIDGE_IFACE is the master interface from now on
        # and it must know where is connected, otherwise connection is lost.
        if ! is_bridge_interface $INTERNET_IFACE; then
            echo -n "Create a bridge interface... "
            OLD_IFS="$IFS"
            IFS=$'\n'

            IP_ADDRS=( $(ip addr show $INTERNET_IFACE | grep -A 1 -E 'inet[[:blank:]]' | paste - -) )
            ROUTE_ADDRS=( $(ip route show dev $INTERNET_IFACE) )

            IFS="$OLD_IFS"

            if networkmanager_is_running; then
                networkmanager_add_unmanaged $INTERNET_IFACE
                networkmanager_wait_until_unmanaged $INTERNET_IFACE
            fi

            # create bridge interface
            ip link add name $BRIDGE_IFACE type bridge || die
            ip link set dev $BRIDGE_IFACE up || die
            # set 0ms forward delay
            echo 0 > /sys/class/net/$BRIDGE_IFACE/bridge/forward_delay

            # attach internet interface to bridge interface
            ip link set dev $INTERNET_IFACE promisc on || die
            ip link set dev $INTERNET_IFACE up || die
            ip link set dev $INTERNET_IFACE master $BRIDGE_IFACE || die

            ip addr flush $INTERNET_IFACE
            for x in "${IP_ADDRS[@]}"; do
                x="${x/inet/}"
                x="${x/secondary/}"
                x="${x/dynamic/}"
                x=$(echo $x | sed 's/\([0-9]\)sec/\1/g')
                x="${x/${INTERNET_IFACE}/}"
                ip addr add $x dev $BRIDGE_IFACE || die
            done

            # remove any existing entries that were added from 'ip addr add'
            ip route flush dev $INTERNET_IFACE
            ip route flush dev $BRIDGE_IFACE

            # we must first add the entries that specify the subnets and then the
            # gateway entry, otherwise 'ip addr add' will return an error
            for x in "${ROUTE_ADDRS[@]}"; do
                [[ "$x" == default* ]] && continue
                ip route add $x dev $BRIDGE_IFACE || die
            done

            for x in "${ROUTE_ADDRS[@]}"; do
                [[ "$x" != default* ]] && continue
                ip route add $x dev $BRIDGE_IFACE || die
            done

            echo "$BRIDGE_IFACE created."
        fi
    fi
else
    echo "No Internet sharing"
fi

# start dns + dhcp server
if [[ "$SHARE_METHOD" != "bridge" ]]; then
    iptables -I INPUT -p tcp -m tcp --dport 53 -j ACCEPT || die
    iptables -I INPUT -p udp -m udp --dport 53 -j ACCEPT || die
    iptables -I INPUT -p udp -m udp --dport 67 -j ACCEPT || die
    umask 0033
    dnsmasq -C $CONFDIR/dnsmasq.conf -x $CONFDIR/dnsmasq.pid -l $CONFDIR/dnsmasq.leases || die
    umask $SCRIPT_UMASK
fi

# start access point
echo "hostapd command-line interface: hostapd_cli -p $CONFDIR/hostapd_ctrl"

if [[ $NO_HAVEGED -eq 0 ]]; then
    haveged_watchdog &
    HAVEGED_WATCHDOG_PID=$!
fi

# start hostapd
hostapd $CONFDIR/hostapd.conf &
HOSTAPD_PID=$!
echo $HOSTAPD_PID > $CONFDIR/hostapd.pid

if ! wait $HOSTAPD_PID; then
    echo -e "\nError: Failed to run hostapd, maybe a program is interfering." >&2
    if networkmanager_is_running; then
        echo "If an error like 'n80211: Could not configure driver mode' was thrown" >&2
        echo "try running the following before starting create_ap:" >&2
        if [[ $NM_OLDER_VERSION -eq 1 ]]; then
            echo "    nmcli nm wifi off" >&2
        else
            echo "    nmcli r wifi off" >&2
        fi
        echo "    rfkill unblock wlan" >&2
    fi
    die
fi

clean_exit

# Local Variables:
# tab-width: 4
# indent-tabs-mode: nil
# End:

# vim: et sts=4 sw=4