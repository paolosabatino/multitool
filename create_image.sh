#!/bin/bash

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
ROOTFS_SIZE=$(((($ROOTFS_SIZE / 1024) + 1) * 1024))
ROOTFS_SECTORS=$(($ROOTFS_SIZE * 2))

if [ $? -ne 0 ]; then
	echo -e "\ncould not determine size of squashfs root filesystem"
	exit 27
fi

cd "$CWD"

echo "-> rootfs size: ${ROOTFS_SIZE}kb"

echo "Creating empty image in $DEST_IMAGE"
#dd if=/dev/zero of="$DEST_IMAGE" bs=1M count=1024 conv=sync,fsync >/dev/null 2>&1
fallocate -l 1G "$DEST_IMAGE" >/dev/null 2>&1

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

START=$BEGIN_USER_PARTITIONS
END=$(($START + $ROOTFS_SECTORS - 1))
parted -s -- "$LOOP_DEVICE" unit s mkpart primary fat32 $(($END + 1)) -1s >/dev/null 2>&1
if [ $? -ne 0 ]; then
	echo "Could not create fat partition"
	exit 3
fi

parted -s -- "$LOOP_DEVICE" unit s mkpart primary $START $END >/dev/null 2>&1 
if [ $? -ne 0 ]; then
	echo "Could not create rootfs partition"
	exit 3
fi


parted -s -- "$LOOP_DEVICE" set 1 boot on set 2 boot off >/dev/null 2>&1
if [ $? -ne 0 ]; then
	echo "Could not set partition flags"
	exit 28
fi

sync
sleep 1

echo "Remounting loop device with partitions"
losetup -d "$LOOP_DEVICE" >/dev/null 2>&1
sleep 1

if [ $? -ne 0 ]; then
	echo "Could not umount loop device $LOOP_DEVICE"
	exit 4
fi

LOOP_DEVICE=$(losetup -f --show -P "$DEST_IMAGE")
SQUASHFS_PARTITION="${LOOP_DEVICE}p2"
FAT_PARTITION="${LOOP_DEVICE}p1"

if [ $? -ne 0 ]; then
	echo "Could not remount loop device $LOOP_DEVICE"
	exit 5
fi

if [ ! -b "$SQUASHFS_PARTITION" ]; then
	echo "Could not find expected partition $SQUASHFS_PARTITION"
	exit 26
fi

if [ ! -b "$FAT_PARTITION" ]; then
	echo "Could not find expected partition $FAT_PARTITION"
	exit 6
fi

echo "Copying squashfs rootfilesystem"
dd if="${DIST_PATH}/root.img" of="$SQUASHFS_PARTITION" bs=256k conv=sync,fsync >/dev/null 2>&1

if [ $? -ne 0 ]; then
	echo "Could not install squashfs filesystem"
	exit 27
fi

# ---- boot install -----
source "${TS_SOURCES_PATH}/boot_install"

echo "Formatting FAT32 partition"
mkfs.vfat "$FAT_PARTITION" -s 32 -n "MULTITOOL" >/dev/null 2>&1

if [ $? -ne 0 ]; then
	echo "Could not format partition"
	exit 7
fi

echo "Mounting FAT32 partition"
TEMP_DIR=$(mktemp -d)

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

PARTITION_UUID=$(lsblk -n -o UUID $FAT_PARTITION)
if [ $? -ne 0 ]; then
	echo "Could not get partition UUID"
	exit 15
fi

sed -i "s/#PARTUUID#/$PARTITION_UUID/g" "${TEMP_DIR}/extlinux/extlinux.conf"
if [ $? -ne 0 ]; then
	echo "Could not substitute partition UUID in extlinux.conf"
	exit 16
fi

cp "${CWD}/LICENSE" "${TEMP_DIR}/LICENSE"
if [ $? -ne 0 ]; then
	echo "Could not copy LICENSE to partition"
	exit 28
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

truncate -s 128M "$DEST_IMAGE"

sync

echo "Done! Available image in $DEST_IMAGE"
