#!/bin/bash

function round_sectors() {

	SECTORS="$1"

	ROUNDED=$(((($SECTORS / 8) + 1) * 8))

	echo $ROUNDED

}

BACKTITLE="TUI Multitool Image Builder"

FINAL_MESSAGE=""

function show_error() {

    dialog \
        --backtitle "$BACKTITLE" \
        --title "Error" \
        --ok-label "Exit" \
        --msgbox "\n$1" 8 50

    clear

    exit 1

}

function show_wait(){

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

CWD=$(pwd)
SOURCES_PATH="$CWD/sources"
TOOLS_PATH="$CWD/tools"

USERID=$(id -u)

if [ "$USERID" != "0" ]; then
	echo "This script can only work with root permissions"
	exit 26
fi

MOUNTED_DEVICES=()

LOOP_DEVICES=()

MOUNTED_POINTS=()

function cleanup() {

    for device in "${MOUNTED_DEVICES[@]}"; do

        if mountpoint -q "$device"; then

            umount "$device" >/dev/null 2>&1

        fi

    done

    for loop in "${LOOP_DEVICES[@]}"; do

        if losetup -l | grep -q "$loop"; then

            losetup -d "$loop" >/dev/null 2>&1

        fi

    done

    for point in "${MOUNTED_POINTS[@]}"; do

        rm -rf "$point" >/dev/null 2>&1

    done

    clear

    echo "Script finished. All temporary devices cleaned up."

}

trap cleanup EXIT

function mount_device() {

    local device="$1"
    local mount_point="$2"

    mount "$device" "$mount_point" >/dev/null 2>&1

    if [ $? -ne 0 ]; then
        return $?
    fi

    MOUNTED_DEVICES+=("$mount_point")
    MOUNTED_POINTS+=("$mount_point")

}

function unmount_device() {

    local device="$1"

    if mountpoint -q "$device"; then

        umount "$device" >/dev/null 2>&1

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

    local loop=$(losetup -fP --show "$file" 2>/dev/null)

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

        losetup -d "$loop" >/dev/null 2>&1

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

shopt -s nullglob

conf_files=(sources/*.conf)

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

clear

if [ "$status" -ne 0 ]; then

	echo "Please specify a target configuration"

	exit 40

fi

TARGET_CONF="$CWD/${conf_files[$choice]}"

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

# Target-specific sources path
TS_SOURCES_PATH="$CWD/sources/${BOARD_NAME}"

# Destination path and image
DIST_PATH="${CWD}/dist-${BOARD_NAME}"
DEST_IMAGE="${DIST_PATH}/multitool.img"

mkdir -p "$DIST_PATH"

if [ ! -f "$DIST_PATH/root.img" ]; then

    show_wait "Creating debian base rootfs. This will take a while..."

    cd "${SOURCES_PATH}/multistrap"
    multistrap -f multistrap.conf > /tmp/multistrap.log 2>&1

	if [ $? -ne 0 ]; then

        show_error "Failed: $(tail /tmp/multistrap.log) \nFull log at /tmp/multistrap.log"
		
	fi    

    show_wait "Creating squashfs from rootfs..."

    mksquashfs rootfs "$DIST_PATH/root.img" -noappend -all-root > /dev/null 2>&1

    if [ $? -ne 0 ]; then

        show_error "Failed to create squashfs from rootfs"

    fi

fi

ROOTFS_SIZE=$(du "$DIST_PATH/root.img" | cut -f 1)
ROOTFS_SECTORS=$(($ROOTFS_SIZE * 2))
ROOTFS_SECTORS=$(round_sectors $ROOTFS_SECTORS)

if [ $? -ne 0 ]; then

    show_error "Could not determine size of squashfs root filesystem"

fi

cd "$CWD"

show_wait "Creating empty image in $DEST_IMAGE"

fallocate -l 512M "$DEST_IMAGE" >/dev/null 2>&1

if [ $? -ne 0 ]; then

    show_error "Error while creating $DEST_IMAGE empty file"

fi

show_wait "Mounting as loop device"

LOOP_DEVICE=""
attach_loop "$DEST_IMAGE"

if [ $? -ne 0 ]; then

    show_error "Could not loop mount $DEST_IMAGE"

fi

show_wait "Creating partition table and partitions..."

parted -s -- "$LOOP_DEVICE" mktable msdos >/dev/null 2>&1

if [ $? -ne 0 ]; then

    show_error "Could not create partitions table"

fi

START_ROOTFS=$BEGIN_USER_PARTITIONS
END_ROOTFS=$(($START_ROOTFS + $ROOTFS_SECTORS - 1))
START_FAT=$(round_sectors $END_ROOTFS)
END_FAT=$(($START_FAT + 131072 - 1)) # 131072 sectors = 64Mb
START_NTFS=$(round_sectors $END_FAT)
parted -s -- "$LOOP_DEVICE" unit s mkpart primary ntfs $START_NTFS -1s >/dev/null 2>&1

if [ $? -ne 0 ]; then

	show_error "Could not create ntfs partition"

fi

parted -s -- "$LOOP_DEVICE" unit s mkpart primary fat32 $START_FAT $END_FAT >/dev/null 2>&1

if [ $? -ne 0 ]; then

	show_error "Could not create fat partition"

fi

parted -s -- "$LOOP_DEVICE" unit s mkpart primary $START_ROOTFS $END_ROOTFS >/dev/null 2>&1

if [ $? -ne 0 ]; then

	show_error "Could not create rootfs partition"

fi

parted -s -- "$LOOP_DEVICE" set 1 boot off set 2 boot on set 3 boot off >/dev/null 2>&1

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

    sleep 1    

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
dd if="${DIST_PATH}/root.img" of="$SQUASHFS_PARTITION" bs=4k conv=sync,fsync >/dev/null 2>&1

if [ $? -ne 0 ]; then

	show_error "Could not install squashfs filesystem"

fi

# ---- boot install -----
#TODO: VER ESSE NEGOCIO DE REDIRECIONAMENTO, TALVEZ LOGAR ISSO
source "${TS_SOURCES_PATH}/boot_install" > /dev/null 2>&1

show_wait "Formatting FAT32 partition..."

mkfs.vfat -s 16 -n "BOOTSTRAP" "$FAT_PARTITION" >/dev/null 2>&1

if [ $? -ne 0 ]; then

	show_error "Could not format FAT32 partition"

fi

show_wait "Formatting NTFS partition..."

mkfs.ntfs -f -L "MULTITOOL" -p $START_NTFS "$NTFS_PARTITION" >/dev/null 2>&1

if [ $? -ne 0 ]; then

	show_error "Could not format NTFS partition"

fi

TEMP_DIR=$(mktemp -d)

show_wait "Mounting NTFS partition..."

mount_device "$NTFS_PARTITION" "$TEMP_DIR"

if [ $? -ne 0 ]; then

	show_error "Could not mount $NTFS_PARTITION to $TEMP_DIR"

fi

show_wait "Populating partition..."

cp "${CWD}/LICENSE" "${TEMP_DIR}/LICENSE"

if [ $? -ne 0 ]; then

	show_error "Could not copy LICENSE to partition"

fi

git log --no-merges --pretty="%as: %s" > "${TEMP_DIR}/CHANGELOG"

if [ $? -ne 0 ]; then

	show_error "Could not store CHANGELOG to partition"

fi

git log -1 --pretty="%h - %aD" > "${TEMP_DIR}/ISSUE"

if [ $? -ne 0 ]; then

	show_error "Could not store ISSUE to paritition"

fi

echo "${TARGET_CONF}" > "${TEMP_DIR}/TARGET"

if [ $? -ne 0 ]; then

	show_error "Could not store TARGET to partition"

fi

mkdir -p "${TEMP_DIR}/backups"

if [ $? -ne 0 ]; then

	show_error "Could not create backup directory"

fi

mkdir -p "${TEMP_DIR}/images"

if [ $? -ne 0 ]; then

	show_error "Could not create images directory"

fi

mkdir -p "${TEMP_DIR}/bsp"

if [ $? -ne 0 ]; then

	show_error "Could not create bsp directory"

fi

show_wait "Copying board support package blobs into bsp directory..."

cp "${DIST_PATH}/uboot.img" "${TEMP_DIR}/bsp/uboot.img"

[[ -f "${DIST_PATH}/trustos.img" ]] && cp "${DIST_PATH}/trustos.img" "${TEMP_DIR}/bsp/trustos.img"
[[ -f "${DIST_PATH}/legacy-uboot.img" ]] && cp "${DIST_PATH}/legacy-uboot.img" "${TEMP_DIR}/bsp/legacy-uboot.img"

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

cp "${TS_SOURCES_PATH}/${KERNEL_IMAGE}" "${TEMP_DIR}/kernel.img" > /dev/null 2>&1

if [ $? -ne 0 ]; then

	show_error "Could not copy kernel"
    
fi

cp "${TS_SOURCES_PATH}/${DEVICE_TREE}" "${TEMP_DIR}/${DEVICE_TREE}" >/dev/null 2>&1

if [ $? -ne 0 ]; then

	show_error "Could not copy device tree"

fi

mkdir -p "${TEMP_DIR}/extlinux"

if [ $? -ne 0 ]; then

	show_error "Could not create extlinux directory"

fi

cp "${TS_SOURCES_PATH}/extlinux.conf" "${TEMP_DIR}/extlinux/extlinux.conf" >/dev/null 2>&1

if [ $? -ne 0 ]; then

	show_error "Could not copy extlinux.conf"

fi

#!!WARNING!!: not sure if this works

# Gather the PARTUUID of the squashfs partition loop device
# blkid is friendlier in case of containers, so we use it here in place of lsblk
SQUASHFS_PARTITION_PARTUUID=$(blkid -o value -s PARTUUID $SQUASHFS_PARTITION)

if [ $? -ne 0 ]; then

	show_error "Could not get SQUASHFS PARTUUID"

fi

[[ -z $SQUASHFS_PARTITION_PARTUUID ]] && FINAL_MESSAGE+="\n\n--- warning: empty squashfs partition PARTUUID ---"

FINAL_MESSAGE+="\n\nSquashfs partition partuuid: $SQUASHFS_PARTITION_PARTUUID"

# Gather the PARTUUID of the FAT partition of the loop device
# blkid is friendlier in case of containers, so we use it here in place of lsblk
FAT_PARTITION_PARTUUID=$(blkid -o value -s PARTUUID $FAT_PARTITION)

if [ $? -ne 0 ]; then

	show_error "Could not get FAT PARTUUID"

fi

[[ -z $FAT_PARTITION_PARTUUID ]] && FINAL_MESSAGE+="\n\n--- warning: empty FAT boot partition PARTUUID ---"

FINAL_MESSAGE+="\n\nFat partition partuuid: $FAT_PARTITION_PARTUUID"

sed -i "s/#SQUASHFS_PARTUUID#/$SQUASHFS_PARTITION_PARTUUID/g" "${TEMP_DIR}/extlinux/extlinux.conf"

if [ $? -ne 0 ]; then

	show_error "Could not substitute SQUASHFS PARTUUID in extlinux.conf"

fi

sed -i "s/#FAT_PARTUUID#/$FAT_PARTITION_PARTUUID/g" "${TEMP_DIR}/extlinux/extlinux.conf"

if [ $? -ne 0 ]; then

	show_error "Could not substitute FAT PARTUUID in extlinux.conf"

fi

show_wait "Unmount FAT32 partition..."

unmount_device "$TEMP_DIR"

if [ $? -ne 0 ]; then

	show_error "Could not umount $FAT_PARTITION"

fi

rm -rf "$TEMP_DIR" >/dev/null 2>&1

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

FINAL_MESSAGE="\nDone! Available image in ${DEST_IMAGE}${FINAL_MESSAGE}"

dialog \
    --backtitle "$BACKTITLE" \
    --title "Success" \
    --ok-label "OK" \
    --msgbox "$FINAL_MESSAGE" 15 60