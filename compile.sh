#!/bin/bash

function round_sectors() {

	SECTORS="$1"

	ROUNDED=$(((($SECTORS / 8) + 1) * 8))

	echo $ROUNDED

}

BACKTITLE="TUI Multitool Image Builder"

FINAL_MESSAGE=""
RUN_START_EPOCH="$(date +%s)"
LOGS_DIR=""
LOG_FILE=""
CURRENT_STAGE="startup"
LAST_CMD_STATUS=""
LAST_CMD_TEXT=""

function show_error() {

    local explicit_status="$2"
    local status_to_log="${explicit_status:-${LAST_CMD_STATUS:-$?}}"
    log_error "$1" "$status_to_log"

    dialog \
        --backtitle "$BACKTITLE" \
        --title "Error" \
        --ok-label "Exit" \
        --msgbox "\n$1" 8 50

    exit 1

}

function show_wait(){

    log_stage "$1"

    dialog \
        --backtitle "$BACKTITLE" \
        --title "Please wait" \
        --infobox "\n$1" 8 50

}

function show_info() {

    dialog \
        --backtitle "$BACKTITLE" \
        --title "Info" \
        --ok-label "OK" \
        --msgbox "\n$1" 8 50

}

function show_warning() {

    dialog \
        --backtitle "$BACKTITLE" \
        --title "Warning" \
        --ok-label "OK" \
        --msgbox "\n$1" 8 50

}

function log_write() {

    local level="$1"
    local message="$2"

    if [ -z "$LOG_FILE" ]; then
        return 0
    fi

    printf "%s [%s] %s\n" "$(date "+%Y-%m-%d %H:%M:%S")" "$level" "$message" >> "$LOG_FILE" 2>/dev/null

}

function log_stage() {

    CURRENT_STAGE="$1"
    log_write "INFO" "stage: $1"

}

function log_error() {

    local message="$1"
    local status_code="$2"

    log_write "ERROR" "stage: $CURRENT_STAGE | status: ${status_code:-unknown} | message: $message"

}

function log_vars() {

    local scope="$1"
    shift

    local details="$*"
    log_write "VARS" "$scope | $details"

}

function run_logged() {

    local status

    log_write "CMD" "$*"
    LAST_CMD_TEXT="$*"

    if [ -n "$LOG_FILE" ]; then
        log_write "CMD_OUT_START" "$*"
        "$@" >> "$LOG_FILE" 2>&1
        log_write "CMD_OUT_END" "$*"
    else
        "$@" >/dev/null 2>&1
    fi

    status=$?
    LAST_CMD_STATUS="$status"
    log_write "CMD_RET" "exit=$status :: $*"

    return $status

}

function run_logged_capture() {

    local output_var="$1"
    shift

    local output
    local status

    log_write "CMD" "$*"
    LAST_CMD_TEXT="$*"

    if [ -n "$LOG_FILE" ]; then
        output="$("$@" 2>> "$LOG_FILE")"
    else
        output="$("$@" 2>/dev/null)"
    fi

    status=$?
    LAST_CMD_STATUS="$status"
    log_write "CMD_RET" "exit=$status :: $*"

    if [ -n "$output" ]; then
        log_write "RAW_CAPTURE" "$output"
    fi

    printf -v "$output_var" '%s' "$output"

    return $status

}

function run_logged_to_file() {

    local dest_file="$1"
    shift

    local status

    log_write "CMD" "$* > $dest_file"
    LAST_CMD_TEXT="$* > $dest_file"

    if [ -n "$LOG_FILE" ]; then
        log_write "CMD_OUT_START" "$* > $dest_file"
        "$@" > "$dest_file" 2>> "$LOG_FILE"
        log_write "CMD_OUT_END" "$* > $dest_file"
    else
        "$@" > "$dest_file" 2>/dev/null
    fi

    status=$?
    LAST_CMD_STATUS="$status"
    log_write "CMD_RET" "exit=$status :: $* > $dest_file"

    return $status

}

function rotate_logs() {

    local files=()

    if [ ! -d "$LOGS_DIR" ]; then
        return 0
    fi

    mapfile -t files < <(ls -1t "$LOGS_DIR"/build-*.log 2>/dev/null)

    if [ "${#files[@]}" -le 10 ]; then
        return 0
    fi

    for old_log in "${files[@]:10}"; do
        rm -f "$old_log" >/dev/null 2>&1
    done

}

function init_logs() {

    local run_timestamp

    mkdir -p "$LOGS_DIR" >/dev/null 2>&1

    if [ $? -ne 0 ]; then
        return 1
    fi

    run_timestamp="$(date "+%Y%m%d-%H%M%S")"
    LOG_FILE="$LOGS_DIR/build-${run_timestamp}-unknown.log"

    touch "$LOG_FILE" >/dev/null 2>&1

    if [ $? -ne 0 ]; then
        return 1
    fi

    rotate_logs

    log_write "INFO" "build started"
    log_write "INFO" "cwd: $CWD"

    return 0

}

function log_summary() {

    local status="$1"
    local elapsed_seconds="$(($(date +%s) - RUN_START_EPOCH))"

    log_write "SUMMARY" "status: $status"
    log_write "SUMMARY" "image: $DEST_IMAGE"
    log_write "SUMMARY" "duration_seconds: $elapsed_seconds"

    if [ -n "$SQUASHFS_PARTITION_PARTUUID" ]; then
        log_write "SUMMARY" "squashfs_partuuid: $SQUASHFS_PARTITION_PARTUUID"
    fi

    if [ -n "$FAT_PARTITION_PARTUUID" ]; then
        log_write "SUMMARY" "fat_partuuid: $FAT_PARTITION_PARTUUID"
    fi

}

CWD=$(pwd)
SOURCES_PATH="$CWD/sources"
TOOLS_PATH="$CWD/tools"
LOGS_DIR="$CWD/logs"

USERID=$(id -u)

if [ "$USERID" != "0" ]; then
	echo "This script can only work with root permissions"
	exit 26
fi

MOUNTED_DEVICES=()

LOOP_DEVICES=()

MOUNTED_POINTS=()

function cleanup() {

    log_write "INFO" "cleanup started"

    for device in "${MOUNTED_DEVICES[@]}"; do
        log_vars "cleanup-mount" "candidate=$device"

        if mountpoint -q "$device"; then
            log_write "INFO" "cleanup unmounting mountpoint=$device"

            umount "$device" >/dev/null 2>&1

        fi

    done

    for loop in "${LOOP_DEVICES[@]}"; do
        log_vars "cleanup-loop" "candidate=$loop"

        if losetup -l | grep -q "$loop"; then
            log_write "INFO" "cleanup detaching loop=$loop"

            losetup -d "$loop" >/dev/null 2>&1

        fi

    done

    for point in "${MOUNTED_POINTS[@]}"; do
        log_vars "cleanup-temp" "removing=$point"

        rm -rf "$point" >/dev/null 2>&1

    done

    clear

    echo "Script finished. All temporary devices cleaned up."

    log_write "INFO" "cleanup finished"

}

trap cleanup EXIT

function mount_device() {

    local device="$1"
    local mount_point="$2"

    run_logged mount "$device" "$mount_point"

    if [ $? -ne 0 ]; then
        return $?
    fi

    MOUNTED_DEVICES+=("$mount_point")
    MOUNTED_POINTS+=("$mount_point")

}

function unmount_device() {

    local device="$1"

    if mountpoint -q "$device"; then

        run_logged umount "$device"

        if [ $? -ne 0 ]; then
            return $?        
        fi

        for i in "${!MOUNTED_DEVICES[@]}"; do

            if [ "${MOUNTED_DEVICES[$i]}" == "$device" ]; then
                unset 'MOUNTED_DEVICES[i]'
                break
            fi

        done

    fi

}

function attach_loop() {

    local file="$1"

    local loop=""

    run_logged_capture loop losetup -fP --show "$file"

    if [ $? -ne 0 ]; then
        return $?
    fi

    LOOP_DEVICE="$loop"
    LOOP_DEVICES+=("$loop")

    return 0

}

function detach_loop() {

    local loop="$1"

    if losetup -l | grep -q "$loop"; then

        run_logged losetup -d "$loop"

        if [ $? -ne 0 ]; then
            return $?
        fi

        for i in "${!LOOP_DEVICES[@]}"; do

            if [ "${LOOP_DEVICES[$i]}" == "$loop" ]; then
                unset 'LOOP_DEVICES[i]'
                break
            fi

        done

    fi

}

if ! init_logs; then

    LOG_FILE=""
    show_warning "Could not initialize log file in $LOGS_DIR"

fi

shopt -s nullglob

conf_files=(sources/*.conf)
log_vars "config-discovery" "found_conf_files=${#conf_files[@]}"

if [ "${#conf_files[@]}" -eq 0 ]; then

    show_error "No configuration files found in sources/ directory"

    exit 1

fi

options=()

for i in "${!conf_files[@]}"; do

  file="${conf_files[$i]}"

  base="$(basename "$file" .conf)"

  pretty="$(echo "$base" | sed -E 's/[_-]+/ /g')"

  options+=("$i" "$pretty")

done

choice=$(dialog \
        --clear \
        --stdout \
        --backtitle "$BACKTITLE" \
        --title "Choose" \
        --ok-label "Select" \
        --cancel-label "Exit" \
        --menu "\nChoose a configuration" 15 70 12 "${options[@]}")

status=$?
log_vars "config-selection" "dialog_status=$status selected_index=$choice"

if [ "$status" -ne 0 ]; then

    log_write "INFO" "configuration selection canceled by user"

	echo "Please specify a target configuration"

	exit 40

fi

TARGET_CONF="$CWD/${conf_files[$choice]}"
log_vars "config-selection" "target_conf=$TARGET_CONF"

if [ ! -f "$TARGET_CONF" ]; then

    show_error "Could not find ${conf_files[$choice]} target configuration file"

	exit 42

fi

. "${TARGET_CONF}"

if [ $? -ne 0 ]; then

    show_error "Could not source ${TARGET_CONF}"

	exit 41

fi

BOARD_NAME=$(echo "$TARGET_CONF" | sed -E 's/.*sources\/(.*)\.conf/\1/')

log_write "INFO" "target conf: $TARGET_CONF"

log_vars "board" "board_name=$BOARD_NAME"

NEW_LOG_FILENAME="${LOG_FILE/-unknown/-${BOARD_NAME}}"
mv "$LOG_FILE" "$NEW_LOG_FILENAME" >/dev/null 2>&1
if [ $? -ne 0 ]; then

    log_write "WARNING" "Could not rename log file to include board name"

else

    LOG_FILE="$NEW_LOG_FILENAME"
    log_write "INFO" "Log file renamed to $LOG_FILE"

fi

# Target-specific sources path
TS_SOURCES_PATH="$CWD/sources/${BOARD_NAME}"

# Destination path and image
DIST_PATH="${CWD}/dist-${BOARD_NAME}"
DEST_IMAGE="${DIST_PATH}/multitool.img"

log_vars "paths" "ts_sources_path=$TS_SOURCES_PATH dist_path=$DIST_PATH dest_image=$DEST_IMAGE"

run_logged mkdir -p "$DIST_PATH"

if [ ! -f "$DIST_PATH/root.img" ]; then

    show_wait "Creating debian base rootfs. This will take a while..."

    cd "${SOURCES_PATH}/multistrap"
    run_logged multistrap -f multistrap.conf

	if [ $? -ne 0 ]; then

        show_error "Failed to run multistrap. Check log file for details"
		
	fi    

    show_wait "Creating squashfs from rootfs..."

    run_logged mksquashfs rootfs "$DIST_PATH/root.img" -noappend -all-root

    if [ $? -ne 0 ]; then

        show_error "Failed to create squashfs from rootfs"

    fi

fi

ROOTFS_SIZE=$(du "$DIST_PATH/root.img" | cut -f 1)
log_write "RAW" "rootfs_size_kb=$ROOTFS_SIZE"
ROOTFS_SECTORS_RAW=$(($ROOTFS_SIZE * 2))
ROOTFS_SECTORS=$(round_sectors $ROOTFS_SECTORS_RAW)
log_vars "rootfs" "rootfs_size_kb=$ROOTFS_SIZE rootfs_sectors_raw=$ROOTFS_SECTORS_RAW rootfs_sectors_rounded=$ROOTFS_SECTORS"

if [ $? -ne 0 ]; then

    show_error "Could not determine size of squashfs root filesystem"

fi

cd "$CWD"

show_wait "Creating empty image in $DEST_IMAGE"

run_logged fallocate -l 512M "$DEST_IMAGE"

if [ $? -ne 0 ]; then

    show_error "Error while creating $DEST_IMAGE empty file"

fi

show_wait "Mounting as loop device"

LOOP_DEVICE=""
attach_loop "$DEST_IMAGE"

if [ $? -ne 0 ]; then

    show_error "Could not loop mount $DEST_IMAGE"

fi

log_vars "loop" "loop_device=$LOOP_DEVICE"

show_wait "Creating partition table and partitions..."

run_logged parted -s -- "$LOOP_DEVICE" mktable msdos

if [ $? -ne 0 ]; then

    show_error "Could not create partitions table"

fi

START_ROOTFS=$BEGIN_USER_PARTITIONS
END_ROOTFS=$(($START_ROOTFS + $ROOTFS_SECTORS - 1))
START_FAT=$(round_sectors $END_ROOTFS)
END_FAT=$(($START_FAT + 131072 - 1)) # 131072 sectors = 64Mb
START_NTFS=$(round_sectors $END_FAT)
log_vars "partition-layout" "begin_user_partitions=$BEGIN_USER_PARTITIONS start_rootfs=$START_ROOTFS end_rootfs=$END_ROOTFS start_fat=$START_FAT end_fat=$END_FAT start_ntfs=$START_NTFS"
run_logged parted -s -- "$LOOP_DEVICE" unit s mkpart primary ntfs $START_NTFS -1s

if [ $? -ne 0 ]; then

	show_error "Could not create ntfs partition"

fi

run_logged parted -s -- "$LOOP_DEVICE" unit s mkpart primary fat32 $START_FAT $END_FAT

if [ $? -ne 0 ]; then

	show_error "Could not create fat partition"

fi

run_logged parted -s -- "$LOOP_DEVICE" unit s mkpart primary $START_ROOTFS $END_ROOTFS

if [ $? -ne 0 ]; then

	show_error "Could not create rootfs partition"

fi

run_logged parted -s -- "$LOOP_DEVICE" set 1 boot off set 2 boot on set 3 boot off

if [ $? -ne 0 ]; then

	show_error "Could not set partition flags"

fi

sync
sleep 1

# First check: in containers, it may happen that loop device partitions
# spawns as soon as they are created. We check their presence. If they already
# are there, we don't remount the device
SQUASHFS_PARTITION="${LOOP_DEVICE}p3"
NTFS_PARTITION="${LOOP_DEVICE}p1"
FAT_PARTITION="${LOOP_DEVICE}p2"
log_vars "partitions-initial" "squashfs_partition=$SQUASHFS_PARTITION fat_partition=$FAT_PARTITION ntfs_partition=$NTFS_PARTITION"

if [ ! -b "$SQUASHFS_PARTITION" -o ! -b "$FAT_PARTITION" -o ! -b "$NTFS_PARTITION" ]; then

    show_wait "Remounting loop device with partitions..."

    detach_loop "$LOOP_DEVICE"
	sleep 1

    if [ $? -ne 0 ]; then

        show_error "Could not umount loop device $LOOP_DEVICE"

    fi

    LOOP_DEVICE=""
    attach_loop "$DEST_IMAGE"

    if [ $? -ne 0 ]; then

        show_error "Could not remount loop device $LOOP_DEVICE"

    fi

	SQUASHFS_PARTITION="${LOOP_DEVICE}p3"
	NTFS_PARTITION="${LOOP_DEVICE}p1"
	FAT_PARTITION="${LOOP_DEVICE}p2"
    log_vars "partitions-remount" "loop_device=$LOOP_DEVICE squashfs_partition=$SQUASHFS_PARTITION fat_partition=$FAT_PARTITION ntfs_partition=$NTFS_PARTITION"
    run_logged lsblk "$LOOP_DEVICE"

    sleep 1    

else

    log_write "INFO" "remount not required; partitions already present"

fi

if [ ! -b "$SQUASHFS_PARTITION" ]; then

	show_error "Could not find expected partition $SQUASHFS_PARTITION"

fi

if [ ! -b "$FAT_PARTITION" ]; then

	show_error "Could not find expected partition $FAT_PARTITION"

fi

if [ ! -b "$NTFS_PARTITION" ]; then

	show_error "Could not find expected partition $NTFS_PARTITION"

fi

show_wait "Copying squashfs rootfilesystem..."
run_logged dd if="${DIST_PATH}/root.img" of="$SQUASHFS_PARTITION" bs=4k conv=sync,fsync

if [ $? -ne 0 ]; then

	show_error "Could not install squashfs filesystem"

fi

# ---- boot install -----
log_write "CMD" "source ${TS_SOURCES_PATH}/boot_install"
if [ -n "$LOG_FILE" ]; then
    log_write "CMD_OUT_START" "source ${TS_SOURCES_PATH}/boot_install"
    source "${TS_SOURCES_PATH}/boot_install" >> "$LOG_FILE" 2>&1
    log_write "CMD_OUT_END" "source ${TS_SOURCES_PATH}/boot_install"
else
    source "${TS_SOURCES_PATH}/boot_install" >/dev/null 2>&1
fi
LAST_CMD_STATUS="$?"
LAST_CMD_TEXT="source ${TS_SOURCES_PATH}/boot_install"
log_write "CMD_RET" "exit=$LAST_CMD_STATUS :: source ${TS_SOURCES_PATH}/boot_install"

if [ "$LAST_CMD_STATUS" -ne 0 ]; then

    show_error "Could not execute boot_install" "$LAST_CMD_STATUS"

fi

show_wait "Formatting FAT32 partition..."

run_logged mkfs.vfat -s 16 -n "BOOTSTRAP" "$FAT_PARTITION"

if [ $? -ne 0 ]; then

	show_error "Could not format FAT32 partition"

fi

show_wait "Formatting NTFS partition..."

run_logged mkfs.ntfs -f -L "MULTITOOL" -p $START_NTFS "$NTFS_PARTITION"

if [ $? -ne 0 ]; then

	show_error "Could not format NTFS partition"

fi

TEMP_DIR=$(mktemp -d)
log_vars "mount" "temp_dir=$TEMP_DIR"

show_wait "Mounting NTFS partition..."

mount_device "$NTFS_PARTITION" "$TEMP_DIR"

if [ $? -ne 0 ]; then

	show_error "Could not mount $NTFS_PARTITION to $TEMP_DIR"

fi

show_wait "Populating partition..."

run_logged cp "${CWD}/LICENSE" "${TEMP_DIR}/LICENSE"

if [ $? -ne 0 ]; then

	show_error "Could not copy LICENSE to partition"

fi

run_logged_to_file "${TEMP_DIR}/CHANGELOG" git log --no-merges --pretty="%as: %s"

if [ $? -ne 0 ]; then

	show_error "Could not store CHANGELOG to partition"

fi

run_logged_to_file "${TEMP_DIR}/ISSUE" git log -1 --pretty="%h - %aD"

if [ $? -ne 0 ]; then

	show_error "Could not store ISSUE to paritition"

fi

printf "%s\n" "${BOARD_NAME}" > "${TEMP_DIR}/TARGET"

if [ $? -ne 0 ]; then

	show_error "Could not store TARGET to partition"

fi

run_logged mkdir -p "${TEMP_DIR}/backups"

if [ $? -ne 0 ]; then

	show_error "Could not create backup directory"

fi

run_logged mkdir -p "${TEMP_DIR}/images"

if [ $? -ne 0 ]; then

	show_error "Could not create images directory"

fi

run_logged mkdir -p "${TEMP_DIR}/bsp"

if [ $? -ne 0 ]; then

	show_error "Could not create bsp directory"

fi

show_wait "Copying board support package blobs into bsp directory..."

run_logged cp "${DIST_PATH}/uboot.img" "${TEMP_DIR}/bsp/uboot.img"

if [ -f "${DIST_PATH}/trustos.img" ]; then
    run_logged cp "${DIST_PATH}/trustos.img" "${TEMP_DIR}/bsp/trustos.img"
fi

if [ -f "${DIST_PATH}/legacy-uboot.img" ]; then
    run_logged cp "${DIST_PATH}/legacy-uboot.img" "${TEMP_DIR}/bsp/legacy-uboot.img"
fi

show_wait "Unmount NTFS partition..."

unmount_device "$TEMP_DIR"

if [ $? -ne 0 ]; then

	show_error "Could not umount $NTFS_PARTITION"

fi

show_wait "Mounting FAT32 partition..."

if [ $? -ne 0 ]; then

	show_error "Could not create temporary directory"

fi

mount_device "$FAT_PARTITION" "$TEMP_DIR"

if [ $? -ne 0 ]; then

	show_error "Could not mount $FAT_PARTITION to $TEMP_DIR"

fi

show_wait "Populating partition..."

run_logged cp "${TS_SOURCES_PATH}/${KERNEL_IMAGE}" "${TEMP_DIR}/kernel.img"

if [ $? -ne 0 ]; then

	show_error "Could not copy kernel"
    
fi

run_logged cp "${TS_SOURCES_PATH}/${DEVICE_TREE}" "${TEMP_DIR}/${DEVICE_TREE}"

if [ $? -ne 0 ]; then

	show_error "Could not copy device tree"

fi

run_logged mkdir -p "${TEMP_DIR}/extlinux"

if [ $? -ne 0 ]; then

	show_error "Could not create extlinux directory"

fi

run_logged cp "${TS_SOURCES_PATH}/extlinux.conf" "${TEMP_DIR}/extlinux/extlinux.conf"

if [ $? -ne 0 ]; then

	show_error "Could not copy extlinux.conf"

fi

# Gather the PARTUUID of the squashfs partition loop device
# blkid is friendlier in case of containers, so we use it here in place of lsblk
run_logged_capture SQUASHFS_PARTITION_PARTUUID blkid -o value -s PARTUUID "$SQUASHFS_PARTITION"
log_vars "partuuid" "squashfs_partition_partuuid=$SQUASHFS_PARTITION_PARTUUID"

if [ $? -ne 0 ]; then

	show_error "Could not get SQUASHFS PARTUUID"

fi

[[ -z $SQUASHFS_PARTITION_PARTUUID ]] && FINAL_MESSAGE+="\n\n--- warning: empty squashfs partition PARTUUID ---"

FINAL_MESSAGE+="\n\nSquashfs partition partuuid: $SQUASHFS_PARTITION_PARTUUID"

# Gather the PARTUUID of the FAT partition of the loop device
# blkid is friendlier in case of containers, so we use it here in place of lsblk
run_logged_capture FAT_PARTITION_PARTUUID blkid -o value -s PARTUUID "$FAT_PARTITION"
log_vars "partuuid" "fat_partition_partuuid=$FAT_PARTITION_PARTUUID"

if [ $? -ne 0 ]; then

	show_error "Could not get FAT PARTUUID"

fi

[[ -z $FAT_PARTITION_PARTUUID ]] && FINAL_MESSAGE+="\n\n--- warning: empty FAT boot partition PARTUUID ---"

FINAL_MESSAGE+="\n\nFat partition partuuid: $FAT_PARTITION_PARTUUID"

run_logged sed -i "s/#SQUASHFS_PARTUUID#/$SQUASHFS_PARTITION_PARTUUID/g" "${TEMP_DIR}/extlinux/extlinux.conf"

if [ $? -ne 0 ]; then

	show_error "Could not substitute SQUASHFS PARTUUID in extlinux.conf"

fi

run_logged sed -i "s/#FAT_PARTUUID#/$FAT_PARTITION_PARTUUID/g" "${TEMP_DIR}/extlinux/extlinux.conf"

if [ $? -ne 0 ]; then

	show_error "Could not substitute FAT PARTUUID in extlinux.conf"

fi

show_wait "Unmount FAT32 partition..."

unmount_device "$TEMP_DIR"

if [ $? -ne 0 ]; then

	show_error "Could not umount $FAT_PARTITION"

fi

run_logged rm -rf "$TEMP_DIR"

if [ $? -ne 0 ]; then

	show_error "Could not remove temporary directory $TEMP_DIR"

fi

show_wait "Unmounting loop device..."

detach_loop "$LOOP_DEVICE"

if [ $? -ne 0 ]; then

	show_error "Could not unmount $LOOP_DEVICE"

fi

sync
sleep 2

log_summary "success"

FINAL_MESSAGE="\nDone! Available image in ${DEST_IMAGE}${FINAL_MESSAGE}"

if [ -n "$LOG_FILE" ]; then
    FINAL_MESSAGE+="\n\nLog file: ${LOG_FILE}"
fi

dialog \
    --backtitle "$BACKTITLE" \
    --title "Success" \
    --ok-label "OK" \
    --msgbox "$FINAL_MESSAGE" 15 60