#!/bin/bash

function round_sectors() {

	SECTORS="$1"

	ROUNDED=$(((($SECTORS / 8) + 1) * 8))

	echo $ROUNDED

}

CWD=$(pwd)
SOURCES_PATH="$CWD/sources"
TOOLS_PATH="$CWD/tools"

# Script to create the multitool image for rk322x boards

USERID=$(id -u)

if [ "$USERID" != "0" ]; then
	echo "This script can only work with root permissions"
	exit 26
fi

TARGET_CONF="$1"

if [ -z "$TARGET_CONF" ]; then
	echo "Please specify a target configuration"
	exit 40
fi

if [ ! -f "${SOURCES_PATH}/${TARGET_CONF}.conf" ]; then
	echo "Could not find ${TARGET_CONF}.conf target configuration file"
	exit 42
fi

. "${SOURCES_PATH}/${TARGET_CONF}.conf"

if [ $? -ne 0 ]; then
	echo "Could not source ${TARGET_CONF}.conf"
	exit 41
fi

# Target-specific sources path
TS_SOURCES_PATH="$CWD/sources/${TARGET_CONF}"

# Destination path and image
DIST_PATH="${CWD}/dist-${TARGET_CONF}"
DEST_IMAGE="${DIST_PATH}/multitool.img"

mkdir -p "$DIST_PATH"

if [ ! -f "$DIST_PATH/root.img" ]; then

	echo -n "Creating debian base rootfs. This will take a while..."

	cd "${SOURCES_PATH}/multistrap"
	multistrap -f multistrap.conf > /tmp/multistrap.log 2>&1

	if [ $? -ne 0 ]; then
		echo -e "\nfailed:"
		tail /tmp/multistrap.log
		echo -e "\nFull log at /tmp/multistrap.log"
		exit 25
	fi

	echo "done!"

	echo -n "Creating squashfs from rootfs..."
	mksquashfs rootfs "$DIST_PATH/root.img" -noappend -all-root > /dev/null 2>&1

	if [ $? -ne 0 ]; then
		echo -e "\nfailed"
		exit 26
	fi

	echo "done"

fi

ROOTFS_SIZE=$(du "$DIST_PATH/root.img" | cut -f 1)
ROOTFS_SECTORS=$(($ROOTFS_SIZE * 2))
ROOTFS_SECTORS=$(round_sectors $ROOTFS_SECTORS)

if [ $? -ne 0 ]; then
	echo -e "\ncould not determine size of squashfs root filesystem"
	exit 27
fi

cd "$CWD"

echo "-> rootfs size: ${ROOTFS_SIZE}kb"

echo "Creating empty image in $DEST_IMAGE"
#dd if=/dev/zero of="$DEST_IMAGE" bs=1M count=1024 conv=sync,fsync >/dev/null 2>&1
fallocate -l 512M "$DEST_IMAGE" >/dev/null 2>&1

if [ $? -ne 0 ]; then
	echo "Error while creating $DEST_IMAGE empty file"
	exit 1
fi

echo "Mounting as loop device"
LOOP_DEVICE=$(losetup -f --show "$DEST_IMAGE")

if [ $? -ne 0 ]; then
	echo "Could not loop mount $DEST_IMAGE"
	exit 2
fi

echo "Creating partition table and partitions"
parted -s -- "$LOOP_DEVICE" mktable msdos >/dev/null 2>&1
if [ $? -ne 0 ]; then
	echo "Could not create partitions table"
	exit 3
fi

START_ROOTFS=$BEGIN_USER_PARTITIONS
END_ROOTFS=$(($START_ROOTFS + $ROOTFS_SECTORS - 1))
START_FAT=$(round_sectors $END_ROOTFS)
END_FAT=$(($START_FAT + 131072 - 1)) # 131072 sectors = 64Mb
START_NTFS=$(round_sectors $END_FAT)
parted -s -- "$LOOP_DEVICE" unit s mkpart primary ntfs $START_NTFS -1s >/dev/null 2>&1
if [ $? -ne 0 ]; then
	echo "Could not create ntfs partition"
	exit 3
fi

parted -s -- "$LOOP_DEVICE" unit s mkpart primary fat32 $START_FAT $END_FAT >/dev/null 2>&1
if [ $? -ne 0 ]; then
	echo "Could not create fat partition"
	exit 3
fi

parted -s -- "$LOOP_DEVICE" unit s mkpart primary $START_ROOTFS $END_ROOTFS >/dev/null 2>&1
if [ $? -ne 0 ]; then
	echo "Could not create rootfs partition"
	exit 3
fi


parted -s -- "$LOOP_DEVICE" set 1 boot off set 2 boot on set 3 boot off >/dev/null 2>&1
if [ $? -ne 0 ]; then
	echo "Could not set partition flags"
	exit 28
fi

sync
sleep 1

# First check: in containers, it may happen that loop device partitions
# spawns as soon as they are created. We check their presence. If they already
# are there, we don't remount the device
SQUASHFS_PARTITION="${LOOP_DEVICE}p3"
NTFS_PARTITION="${LOOP_DEVICE}p1"
FAT_PARTITION="${LOOP_DEVICE}p2"
echo "squashfs partition: $SQUASHFS_PARTITION"
echo "fat partition: $FAT_PARTITION"
echo "ntfs partition: $NTFS_PARTITION"

if [ ! -b "$SQUASHFS_PARTITION" -o ! -b "$FAT_PARTITION" -o ! -b "$NTFS_PARTITION" ]; then
	echo "Remounting loop device with partitions"
	losetup -d "$LOOP_DEVICE" >/dev/null 2>&1
	sleep 1

	if [ $? -ne 0 ]; then
		echo "Could not umount loop device $LOOP_DEVICE"
		exit 4
	fi

	LOOP_DEVICE=$(losetup -f --show -P "$DEST_IMAGE")
	if [ $? -ne 0 ]; then
		echo "Could not remount loop device $LOOP_DEVICE"
		exit 5
	fi

	SQUASHFS_PARTITION="${LOOP_DEVICE}p3"
	NTFS_PARTITION="${LOOP_DEVICE}p1"
	FAT_PARTITION="${LOOP_DEVICE}p2"
	echo "squashfs partition after remount: $SQUASHFS_PARTITION"
	echo "fat partition: after remount $FAT_PARTITION"
	echo "ntfs partition: after remount $NTFS_PARTITION"

	sleep 1
fi


if [ ! -b "$SQUASHFS_PARTITION" ]; then
	echo "Could not find expected partition $SQUASHFS_PARTITION"
	exit 26
fi

if [ ! -b "$FAT_PARTITION" ]; then
	echo "Could not find expected partition $FAT_PARTITION"
	exit 6
fi

if [ ! -b "$NTFS_PARTITION" ]; then
	echo "Could not find expected partition $NTFS_PARTITION"
	exit 6
fi

echo "Copying squashfs rootfilesystem"
dd if="${DIST_PATH}/root.img" of="$SQUASHFS_PARTITION" bs=4k conv=sync,fsync >/dev/null 2>&1

if [ $? -ne 0 ]; then
	echo "Could not install squashfs filesystem"
	exit 27
fi

# ---- boot install -----
source "${TS_SOURCES_PATH}/boot_install"

echo "Formatting FAT32 partition"
mkfs.vfat -s 16 -n "BOOTSTRAP" "$FAT_PARTITION" >/dev/null 2>&1

if [ $? -ne 0 ]; then
	echo "Could not format FAT32 partition"
	exit 7
fi

echo "Formatting NTFS partition"
mkfs.ntfs -f -L "MULTITOOL" -p $START_NTFS -H 65535 -S 65535 -c 16384 "$NTFS_PARTITION" >/dev/null 2>&1

if [ $? -ne 0 ]; then
	echo "Could not format NTFS partition"
	exit 7
fi

TEMP_DIR=$(mktemp -d)

echo "Mounting NTFS partition"
mount "$NTFS_PARTITION" "$TEMP_DIR" >/dev/null 2>&1

if [ $? -ne 0 ]; then
	echo "Could not mount $NTFS_PARTITION to $TEMP_DIR"
	exit 9
fi

echo "Populating partition"

cp "${CWD}/LICENSE" "${TEMP_DIR}/LICENSE"
if [ $? -ne 0 ]; then
	echo "Could not copy LICENSE to partition"
	exit 28
fi

git log --no-merges --pretty="%as: %s" > "${TEMP_DIR}/CHANGELOG"
if [ $? -ne 0 ]; then
	echo "Could not store CHANGELOG to partition"
fi

git log -1 --pretty="%h - %aD" > "${TEMP_DIR}/ISSUE"
if [ $? -ne 0 ]; then
	echo "Could not store ISSUE to paritition"
fi

echo "${TARGET_CONF}" > "${TEMP_DIR}/TARGET"
if [ $? -ne 0 ]; then
	echo "Could not store TARGET to partition"
fi

mkdir -p "${TEMP_DIR}/backups"
if [ $? -ne 0 ]; then
	echo "Could not create backup directory"
	exit 28
fi

mkdir -p "${TEMP_DIR}/images"
if [ $? -ne 0 ]; then
	echo "Could not create images directory"
	exit 29
fi

mkdir -p "${TEMP_DIR}/bsp"
if [ $? -ne 0 ]; then
	echo "Could not create bsp directory"
	exit 30
fi

echo "Copying board support package blobs into bsp directory"
cp "${DIST_PATH}/uboot.img" "${TEMP_DIR}/bsp/uboot.img"

[[ -f "${DIST_PATH}/trustos.img" ]] && cp "${DIST_PATH}/trustos.img" "${TEMP_DIR}/bsp/trustos.img"
[[ -f "${DIST_PATH}/legacy-uboot.img" ]] && cp "${DIST_PATH}/legacy-uboot.img" "${TEMP_DIR}/bsp/legacy-uboot.img"

echo "Unmount NTFS partition"
umount "$NTFS_PARTITION" >/dev/null 2>&1

if [ $? -ne 0 ]; then
	echo "Could not umount $NTFS_PARTITION"
	exit 17
fi

echo "Mounting FAT32 partition"
if [ $? -ne 0 ]; then
	echo "Could not create temporary directory"
	exit 8
fi

mount "$FAT_PARTITION" "$TEMP_DIR" >/dev/null 2>&1

if [ $? -ne 0 ]; then
	echo "Could not mount $FAT_PARTITION to $TEMP_DIR"
	exit 9
fi

echo "Populating partition"
cp "${TS_SOURCES_PATH}/${KERNEL_IMAGE}" "${TEMP_DIR}/kernel.img" > /dev/null 2>&1
if [ $? -ne 0 ]; then
	echo "Could not copy kernel"
	exit 10
fi

cp "${TS_SOURCES_PATH}/${DEVICE_TREE}" "${TEMP_DIR}/${DEVICE_TREE}" >/dev/null 2>&1
if [ $? -ne 0 ]; then
	echo "Could not copy device tree"
	exit 12
fi

mkdir -p "${TEMP_DIR}/extlinux"
if [ $? -ne 0 ]; then
	echo "Could not create extlinux directory"
	exit 13
fi

cp "${TS_SOURCES_PATH}/extlinux.conf" "${TEMP_DIR}/extlinux/extlinux.conf" >/dev/null 2>&1
if [ $? -ne 0 ]; then
	echo "Could not copy extlinux.conf"
	exit 14
fi

# Gather the PARTUUID of the squashfs partition loop device
# blkid is friendlier in case of containers, so we use it here in place of lsblk
SQUASHFS_PARTITION_UUID=$(blkid -o value -s PARTUUID $SQUASHFS_PARTITION)
if [ $? -ne 0 ]; then
	echo "Could not get SQUASHFS PARTUUID"
	exit 15
fi

[[ -z $SQUASHFS_PARTITION_UUID ]] && echo "--- warning: empty squashfs partition UUID ---"

echo "squashfs partition uuid: $SQUASHFS_PARTITION_UUID"

# Gather the UUID of the FAT partition of the loop device
# blkid is friendlier in case of containers, so we use it here in place of lsblk
FAT_PARTITION_UUID=$(blkid -o value -s UUID $FAT_PARTITION)
if [ $? -ne 0 ]; then
	echo "Could not get FAT PARTUUID"
	exit 15
fi

[[ -z $FAT_PARTITION_UUID ]] && echo "--- warning: empty FAT boot partition UUID ---"

echo "fat partition uuid: $FAT_PARTITION_UUID"

sed -i "s/#SQUASHFS_PARTUUID#/$SQUASHFS_PARTITION_UUID/g" "${TEMP_DIR}/extlinux/extlinux.conf"
if [ $? -ne 0 ]; then
	echo "Could not substitute SQUASHFS PARTUUID in extlinux.conf"
	exit 16
fi

sed -i "s/#FAT_PARTUUID#/$FAT_PARTITION_UUID/g" "${TEMP_DIR}/extlinux/extlinux.conf"
if [ $? -ne 0 ]; then
	echo "Could not substitute FAT PARTUUID in extlinux.conf"
	exit 16
fi

echo "Unmount FAT32 partition"
umount "$FAT_PARTITION" >/dev/null 2>&1

if [ $? -ne 0 ]; then
	echo "Could not umount $FAT_PARTITION"
	exit 17
fi

rmdir "$TEMP_DIR"

if [ $? -ne 0 ]; then
	echo "Could not remove temporary directory $TEMP_DIR"
	exit 24
fi

echo "Unmounting loop device"
losetup -d "$LOOP_DEVICE" >/dev/null 2>&1

if [ $? -ne 0 ]; then
	echo "Could not unmount $LOOP_DEVICE"
	exit 23
fi

#truncate -s 140M "$DEST_IMAGE"

sync

echo "Done! Available image in $DEST_IMAGE"
