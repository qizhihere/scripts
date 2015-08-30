#!/usr/bin/env bash

LOCK=/tmp/.$(basename "$0").lock
exec 200<>"$LOCK"
flock -n 200 || abort

# btrfs paritition which contains snapshots
BTRFS_DEV=/dev/sda1

# target paritition where backup archives will be saved
BACKUP_DEV=/dev/sdb7

# arguments passed when mounting the backup parition
BACKUP_MOUNT_ARGS=

# where snapshots are stored, a relative path to the root of the btrfs paritition
SNAPSHOT_SUBVOLS=(arch/snapshots/rootfs arch/snapshots/homefs)

# a temporary mountpoint for the above parititions
TMP_MOUNTPOINT=/mnt/BACKUP_$(date +%Y%m%d%H%M%S)

# the prefix of saved backup archives
ARCHIVE_PREFIX="archives/arch-"

# if backup partition tables in the meanwhile
BACKUP_PART_TBL=1
# if the system backup failed, then don't backup partition table
SKIP_IF_FAILED=1

# tar --exclude-from list
EXCLUDE_FILE=/tmp/backup-exclude-$(date "+%Y%m%d%H:%M:%S").txt
cat <<'EOF' > $EXCLUDE_FILE
var/cache/pacman/*
.snapshots/*
var/cache/pkgfile/*
*cache*
var/lib/systemd/coredump/*
chrom*/Default/Session
Storage/*
.local/share/Trash/*
Downloads/*
Video/*
EOF

# for internel use, don't modify
BACKUP_DIR="$TMP_MOUNTPOINT/BACKUP"
BTRFS_DIR="$TMP_MOUNTPOINT/BTRFS"

# check if a specific device has been mount
is-mounted () {
    if [ $# -eq 1 ]; then
        if [ ! -b "$1" ]; then
            echo "error: invalid device: $1"
            return 1
        elif df | awk '{print $1}' | grep "$1" &>/dev/null; then
            return 0
        else
            return 1
        fi
    elif [ $# -eq 2 ]; then
        if [ ! -b "$1" ]; then
            echo "error: invalid device: $1"
            return 1
        elif df | awk '{print $1,$6}' | grep "^$1 $2$" &>/dev/null; then
            return 0
        else
            return 1
        fi
    else
        echo "error: invalid arguments"
        echo "Usage: is-mounted /dev/sdxN [directory]"
    fi
}

grep-latest-snp () {
    # get the most recent snapshot's path from snapshots directory
    local _keyword="$1"
    local latest_snp=$(btrfs subvolume list "$2" |\
                         grep -iP "${_keyword%/}/" |\
                           awk '{print $9}' |\
                             awk -F/ '{print $(NF-1),$0}' |\
                               sort -rn | awk '{print $2}' | head -1)
    if [ ! $latest_snp ]; then
        return 1
    else
        echo $latest_snp
    fi
}

# get snapshot time from info.xml
get-snp-time () {
    local _xd=$(grep -iPo "(?<=<date>)(.+)(?=</date>)" "$1")
    if [ "$_xd" ]; then
        echo $(date +%Y%m%d_%H:%M:%S -d "$_xd 8 hours")
    else
        return 1
    fi
}

# snapshot archiving
compress-snp () {
    # check arguments
    if [ $# -lt 2 ]; then
        echo "error: invalid arguments: $*"
        echo "Usage: compress-snp path/to/snapshot path/to/archive [options...]"
        return 1
    fi

    local _dir="$1" _arch="$2"
    _arch="${_arch%%.tgz*}.tgz"
    shift 2

    if [ ! -f "$_arch" ]; then
        tar -C "$_dir" -cvpzf "$_arch" . "$@"
        return 0
    else
        echo "Archive $_arch has been existed, skipping..."
        return
    fi
}

# clean all garbages made by this script
clean-all () {
    umount -Rl "$TMP_MOUNTPOINT"/{BACKUP,BTRFS} &>/dev/null
    rmdir "$TMP_MOUNTPOINT"/{BACKUP,BTRFS} "$TMP_MOUNTPOINT" &>/dev/null
    rm "$EXCLUDE_FILE" &>/dev/null
    exec 200>&-
    rm "$LOCK" &>/dev/null
}

abort () {
    clean-all
    exit 1
}

# check if this script is run as root
[ $EUID -ne 0 ] && {
    echo "This script must be run with root privilege."
    abort
}

# validate the devices
for i in "$BTRFS_DEV" "$BACKUP_DEV"; do
    [ ! -b $i ] && {
        echo "error: invalid device $i"
        abort
    }
done

# check temporary mountpoints
[ ! -e "$TMP_MOUNTPOINT" ] && mkdir -p "$TMP_MOUNTPOINT"/{BACKUP,BTRFS}

# mount devices and check permissions
is-mounted "$BACKUP_DEV" && umount -l "$BACKUP_DEV"
if ! (mount "$BACKUP_DEV" "$BACKUP_DIR" ${BACKUP_MOUNT_ARGS:-} && [ -r "$BACKUP_DIR" -a -w "$BACKUP_DIR" ]); then
    echo "Failed to access $BACKUP_DEV, aborting..."
    abort
fi
if ! (mount "$BTRFS_DEV" "$BTRFS_DIR" -o subvol=/ && [ -r "$BTRFS_DIR" ]); then
    echo "Failed to read or write $BTRFS_DEV, aborting..."
    abort
fi

# iteratively do backup actions
is_finished=1
for i in "${SNAPSHOT_SUBVOLS[@]}"; do
    latest_snp=$(grep-latest-snp "$i" "$BTRFS_DIR" 2>/dev/null)
    snp_time=$(get-snp-time "$BTRFS_DIR/${latest_snp%/*}/info.xml" 2>/dev/null)
    archive_path="$BACKUP_DIR/${ARCHIVE_PREFIX}${i##*/}_${snp_time}"

    [ -d "${archive_path%/*}" ] || mkdir -p "${archive_path%/*}"

    # check if archive name is invalid
    ! [ "$latest_snp" -a "$snp_time" ] && {
        echo "Failed to get latest snapshot info from $i, skiping..."
        is_finished=0
        break
    }

    # clean old archives
    find "$BACKUP_DIR/" -name "*.tgz" -o -name "*.tbl" -type f -mtime +30 -exec rm -f \{\} \;

    # run backup action
    ! compress-snp "$BTRFS_DIR/$latest_snp" "$archive_path" --exclude-from="$EXCLUDE_FILE" && {
        is_finished=0
    }
done

# backup partition tables
[ "$BACKUP_PART_TBL" -eq 1 ] && {
    if [ $is_finished -eq 1 ] || [ "$SKIP_IF_FAILED" -eq 0 ]; then
        partbls_dir="$BACKUP_DIR/partbls"
        [ -d "$partbls_dir" ] || mkdir "$partbls_dir"
        for dev in "${BTRFS_DEV::-1}" "${BACKUP_DEV::-1}"; do
            model=$(lsblk -o model $dev | sed -n 2p | tr 'A-Z' 'a-z' | grep -oP '[^\s]*$')
            sfdisk -d $dev > $partbls_dir/${dev##*/}_${model%-*}_$(date "+%Y%m%d_%H:%M:%S").tbl
        done
    fi
}


# in the end...
clean-all
if [ $is_finished -eq 1 ]; then
    echo "Backup finished!"
    exit 0
else
    echo "Backup failed."
    abort
fi
