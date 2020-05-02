#/bin/bash

TTY_CONSOLE="/dev/tty$(fgconsole)"

# Taken from https://stackoverflow.com/questions/5947742/how-to-change-the-output-color-of-echo-in-linux

BACKTITLE="SD/eMMC/NAND card helper Multitool for TV Boxes and alike - Paolo Sabatino"
TITLE_MAIN_MENU="Multitool Menu"

RED="\Z1"
NC="\Z0"

RKNAND_WARNING="${RED}WARNING!!${NC}\n\nrknand device has been detected. Please be aware that, due to the \
limitations of the proprietary driver, all the functionalities of this software are \
limited.\n\nYou will probably not able to backup and restore low-level loaders (idbloader) and not \
able to install working images\n"

JUMPSTART_WARNING="Jump start for Armbian\n\nThis feature will install an alternative U-boot bootloader \
on the NAND memory that allows Armbian pristine images to be run from SD card or USB devices\n\nNote that \
your existing firmware will not boot anymore, so please be aware that you may want to do a backup first\n"

STEPNAND_WARNING="steP-nand for Armbian\n\nThis feature will install a legacy U-boot bootloader \
on the NAND memory that allows Armbian pristine images to be run directly from NAND devices\n\nNote that \
must use an Armbian version which is compatible NAND device (ie: at the moment you must use legacy kernel \
releases\n"

IDBLOADER_SKIP_QUESTION="${RED}WARNING!!${NC}\n\nAn idbloader signature is present in the source image.\n\
The current driver is not able to write idbloader sectors to NAND device\n\
It is ${RED}heavily suggested${NC} to skip the idbloader sectors writing on NAND\n\n\
Do you want to skip idbloader sectors?"

CHOICE_FILE="/tmp/choice"

FAT_PARTITION="/dev/mmcblk0p1"

MOUNT_POINT="/mnt"
WORK_LED="/sys/class/leds/led:state1"

IDBLOADER_SIGNATURE=" 3b 8c dc fc be 9f 9d 51 eb 30 34 ce 24 51 1f 98"

declare -a DEVICES_MMC
declare -a DEVICES_SD
declare -a DEVICES_SDIO

# Finds all the devices attached to MMC bus (ie: MMC, SD and SDIO devices)
function find_mmc_devices() {

	SYS_MMC_PATH="/sys/bus/mmc/devices"

	if [ -z "$(ls -A ${SYS_MMC_PATH})" ]; then
   		return
	fi

	for DEVICE in $SYS_MMC_PATH/*; do
		DEVICE_TYPE=$(cat $DEVICE/type 2>/dev/null)
		if [ "$DEVICE_TYPE" = "MMC" ]; then
			DEVICES_MMC+=($DEVICE)
		elif [ "$DEVICE_TYPE" = "SD" ]; then
			DEVICES_SD+=($DEVICE)
		elif [ "$DEVICE_TYPE" = "SDIO" ]; then
			DEVICES_SDIO+=($DEVICE)
		fi
	done

}

# Find devices which have specific paths, like proprietary NAND drivers
function find_special_devices() {

	SYS_RKNAND_BLK_DEV="/dev/rknand0"

	if [ -b "$SYS_RKNAND_BLK_DEV" ]; then

		inform_wait "$RKNAND_WARNING"

		SYS_RKNAND_DEVICE=$(realpath /sys/block/rknand0/device)
		DEVICES_MMC+=($SYS_RKNAND_DEVICE)

	fi	

}

# Given a device path (/sys/bus/mmc/devices/*), return the block device name (mmcblk*)
# The device path is passed as first argument
function get_block_device() {

	DEVICE=$1
	BLK=$(ls "$DEVICE/block" | head -n 1)

	echo $BLK

}

# Mounts FAT partition on /mnt to allow operations on it
function mount_fat_partition() {

	mount "$FAT_PARTITION" "$MOUNT_POINT" > /dev/null 2>/dev/null

	if [ $? -ne 0 ]; then
		return 1
	fi

	return 0

}

# Unmounts FAT partition
function unmount_fat_partition() {

	umount "$MOUNT_POINT" 2>/dev/null

	return 0

}

# Creates the directory "backups" on the FAT mount point if it does not already exists.
# Requires the FAT partition to be already mounted
function prepare_backup_directory() {

	mkdir -p "$MOUNT_POINT/backups"

	if [ $? -ne 0 ]; then
		return 1
	fi

	return 0

}

# Change the WORK_LED state to whatever is passed as argument
# Argument can typically be:
# - timer
# - mmc0, mmc1 or mmc2
function set_led_state() {

	echo $1 > "$WORK_LED/trigger"

}

function choose_mmc_device() {

	TITLE=$1
	MENU_TITLE=$2
	DEVICES=$3

	declare -a ARR_DEVICES

	for IDX in ${!DEVICES[@]}; do
		BASENAME=$(basename ${DEVICES[$IDX]})
		BLKDEVICE=$(get_block_device ${DEVICES[$IDX]})
		NAME=$(cat ${DEVICES[$IDX]}/name 2>/dev/null)
		if [[ -n "$NAME" ]]; then
			ARR_DEVICES+=($IDX "${BLKDEVICE} - $NAME ($BASENAME)")
		else
			ARR_DEVICES+=($IDX "${BLKDEVICE} ($BASENAME)")
		fi
	done

	MENU_CMD=(dialog --backtitle "$BACKTITLE" --title "$TITLE" --menu "$MENU_TITLE" 24 74 18)

	CHOICE=$("${MENU_CMD[@]}" "${ARR_DEVICES[@]}" 2>&1 >$TTY_CONSOLE)

	# No choice, return error code 1
	if [ $? -ne 0 ]; then
		return 1
	fi

	# When the user selects a choice, print the real choice (ie: the device path)
	echo ${DEVICES[$CHOICE]}

	return 0

}

# Shows a menu of files given title as first argument, the menu title as second argument
# and the full path with glob as third argument
function choose_file() {

	declare -a FILES
	declare -a STR_FILES

	TITLE="$1"
	MENU_TITLE="$2"
	GLOB="$3"

        COUNTER=0

        for FILE in $GLOB; do
                FILES+=($FILE)
                BASENAME=$(basename $FILE)
		STR_FILES+=($COUNTER "$BASENAME")
                COUNTER=$(($COUNTER + 1))
        done

	MENU_CMD=(dialog --backtitle "$BACKTITLE" --title "$TITLE" --menu "$MENU_TITLE" 24 0 18)

	CHOICE=$("${MENU_CMD[@]}" "${STR_FILES[@]}" 2>&1 >$TTY_CONSOLE)

	# No choice, return error code 1
	if [ $? -ne 0 ]; then 
		return 1
	fi

	echo ${FILES[$CHOICE]}

	return 0
	
}

# Function to inform the user, but does not wait for its ok (returns immediately)
# First argument is the text
function inform() {
	
	TEXT=$1

	dialog --colors \
		--backtitle "$BACKTITLE" \
		--infobox "$TEXT" 12 74

}


# Function to inform the user and wait for its ok.
# First argument is the text
function inform_wait() {

	TEXT=$1

	dialog --colors \
		--backtitle "$BACKTITLE" \
		--msgbox "$TEXT" 12 74

}

# Do backup procedure.
# Return codes:
# - 0 Ok
# - 1 Error
# - 2 User cancelled
# - 3 No suitable devices
function do_backup() {

	# Verify there is at least one suitable device
	if [ ${#DEVICES_MMC[@]} -eq 0 ]; then
		inform_wait "There are no eMMC devices suitable for backup"
		return 3 # Not available
	fi

	# Ask the user which device she wants to backup
	BACKUP_DEVICE=$(choose_mmc_device "Backup flash" "Select source device:" $DEVICES_MMC)

	if [ $? -ne 0 ]; then
		return 2 # User cancelled
	fi

	if [ -z "$BACKUP_DEVICE" ]; then
		return 2 # No backup device, user cancelled?
	fi

	BASENAME=$(basename $BACKUP_DEVICE)
	BLK_DEVICE=$(get_block_device $BACKUP_DEVICE)
	DEVICE_NAME=$(echo $BASENAME | cut -d ":" -f 1)

	# Ask the user the backup filename
	BACKUP_FILENAME=$(dialog --backtitle "$BACKTITLE" --title "Backup flash" --inputbox "Enter the backup filename" 6 60 "tvbox-backup" 2>&1 >$TTY_CONSOLE)

	if [ $? -ne 0 ]; then
		return 2 # User cancelled
	fi

	BACKUP_PATH="${MOUNT_POINT}/backups/${BACKUP_FILENAME}.gz"

	# Mount the fat partition
	mount_fat_partition

	if [ $? -ne 0 ]; then
		inform_wait "There has been an error mounting the FAT partition, backup aborted"
		unmount_fat_partition
		return 1
	fi

	# Create the backup directory
	prepare_backup_directory

	if [ $? -ne 0 ]; then
		inform_wait "Could not create backups directory on FAT partion, backup aborted"
		unmount_fat_partition
		return 1
	fi

	# Check if the file proposed by the user does already exist
	if [ -e "$BACKUP_PATH" ]; then
		dialog --backtitle "$BACKTITLE" \
			--title ="Backup flash" \
			--yesno "A backup file with the same name already exists, do you want to proceed to overwrite it?" 7 60

		if [ $? -ne 0 ]; then
			unmount_fat_partition
			return 2
		fi
	fi

	# Do the backup!
	set_led_state "$DEVICE_NAME"

	(pv -n "/dev/$BLK_DEVICE" | pigz | dd of="$BACKUP_PATH" iflag=fullblock oflag=direct bs=512k 2>/dev/null) 2>&1 | dialog \
		--backtitle "$BACKTITLE" \
		--gauge "Backup of device $BLK_DEVICE is in progress, please wait..." 10 70 0

	ERR=$?

	if [ $ERR -ne 0 ]; then
		inform_wait "An error occurred ($ERR) while backing up the device, backup aborted"
		unmount_fat_partition
		return 1
	fi

	unmount_fat_partition

	inform_wait "Backup has been completed!"

	return 0

}

# Restores a backup
function do_restore() {

	# Verify there is at least one suitable device
	if [ ${#DEVICES_MMC[@]} -eq 0 ]; then
		inform_wait "There are no eMMC devices suitable for restore"
		return 3 # Not available
	fi

	# Ask the user which device she wants to restore
	RESTORE_DEVICE=$(choose_mmc_device "Restore backup" "Select destination device:" $DEVICES_MMC)

	if [ $? -ne 0 ]; then
		return 2 # User cancelled
	fi

	if [ -z "$RESTORE_DEVICE" ]; then
		return 2 # No restore device, user cancelled?
	fi

	BASENAME=$(basename $RESTORE_DEVICE)
	BLK_DEVICE=$(get_block_device $RESTORE_DEVICE)
	DEVICE_NAME=$(echo $BASENAME | cut -d ":" -f 1)

	# Mount the fat partition
	mount_fat_partition

	if [ $? -ne 0 ]; then
		inform_wait "There has been an error mounting the FAT partition, restore cannot continue"
		unmount_fat_partition
		return 1
	fi

	# Search the backup path on the FAT partition
	if [ ! -d "${MOUNT_POINT}/backups" ]; then
		unmount_fat_partition
                inform_wait "There are no backups on FAT partition, restore cannot continue"
		return 3
        fi

	BACKUP_COUNT=$(find "${MOUNT_POINT}/backups" -iname '*.gz' | wc -l)
	if [ $BACKUP_COUNT -eq 0 ]; then
		unmount_fat_partition
		inform_wait "There are no backups on FAT partition, restore cannot continue"
		return 3
        fi

	RESTORE_SOURCE=$(choose_file "Restore a backup image to $BLK_DEVICE" "Choose a backup image" "${MOUNT_POINT}/backups/*.gz")

	if [ $? -ne 0 ]; then
		unmount_fat_partition
		return 2
	fi

	BASENAME=$(basename $RESTORE_SOURCE)
	DEVICE_SIZE=$(cat /sys/block/$BLK_DEVICE/size 2>/dev/null)
        DEVICE_SIZE=$((DEVICE_SIZE / 2)) # convert sectors to kilobytes
	
	set_led_state "$DEVICE_NAME"

	(dd if="$RESTORE_SOURCE" bs=256K | pigz -d | pv -n -s ${DEVICE_SIZE}K | dd of="/dev/$BLK_DEVICE" bs=512K iflag=fullblock oflag=direct 2>/dev/null) 2>&1 | dialog \
		--backtitle "$BACKTITLE" \
		--gauge "Restore of backup $BASENAME to device $BLK_DEVICE in progress, please wait..." 10 70 0

	ERR=$?

	if [ $ERR -ne 0 ]; then
		unmount_fat_partition
		inform_wait "An error occurred ($ERR) restoring backup, process has not been completed"
		return 1
	fi

	unmount_fat_partition

	inform_wait "Backup restored to device $BLK_DEVICE"

	return 0

}

# Given a file as first argument, returns its compressed format
function get_compression_format() {

	TARGET=$1

	pigz -l "$TARGET" >/dev/null 2>&1

	if [ $? -eq 0 ]; then
		echo "gzip"
		return 0
	fi

	xz -l "$TARGET" >/dev/null 2>&1

	if [ $? -eq 0 ]; then
		echo "xz"
		return 0
	fi

	7zr l "$TARGET" >/dev/null 2>&1

	if [ $? -eq 0 ]; then
		echo "7zip"
		return 0
	fi

	bzip2 -t "$TARGET" >/dev/null 2>&1

	if [ $? -eq 0 ]; then
		echo "bzip2"
		return 0
	fi

	zip -l "$TARGET" >/dev/null 2>&1

	if [ $? -eq 0 ]; then
		echo "zip"
		return 0
	fi

	return 1

}

# Outputs the decompression command line suitable for the given input file
# and format
function get_decompression_cli() {

	TARGET=$1
	FORMAT=$2

	if [ "$FORMAT" = "gzip" ]; then
		echo "pigz -d"
		return 0
	elif [ "$FORMAT" = "xz" ]; then
		echo "xz -d -T4"
		return 0
	elif [ "$FORMAT" = "bzip2" ]; then
		echo "bzip2 -d -c"
		return 0
	elif [ "$FORMAT" = "raw" ]; then
		echo "tee /dev/null"
		return 0
	elif [ "$FORMAT" = "7zip" ]; then
		echo "7zr e -si -so -mmt 4"
		return 0
	elif [ "$FORMAT" = "zip" ]; then
		echo "funzip"
		return 0
	fi

	return 1

}

# Restore an image and burns it onto an eMMC device
function do_burn() {

	# Verify there is at least one suitable device
	if [ ${#DEVICES_MMC[@]} -eq 0 ]; then
		inform_wait "There are no eMMC devices suitable for image burn"
		return 3 # Not available
	fi

	# Ask the user which device she wants to restore
	TARGET_DEVICE=$(choose_mmc_device "Burn image to flash" "Select destination device:" $DEVICES_MMC)

	if [ $? -ne 0 ]; then
		return 2 # User cancelled
	fi

	if [ -z "$TARGET_DEVICE" ]; then
		return 2 # No restore device, user cancelled?
	fi

	BASENAME=$(basename $TARGET_DEVICE)
	BLK_DEVICE=$(get_block_device $TARGET_DEVICE)
	DEVICE_NAME=$(echo $BASENAME | cut -d ":" -f 1)

	# Mount the fat partition
	mount_fat_partition

	if [ $? -ne 0 ]; then
		inform_wait "There has been an error mounting the FAT partition."
		unmount_fat_partition
		return 1
	fi

	# Search the images path on the FAT partition
	if [ ! -d "${MOUNT_POINT}/images" ]; then
		unmount_fat_partition
                inform_wait "There are no images on FAT partition."
		return 3
        fi

	IMAGES_COUNT=$(find "${MOUNT_POINT}/images" -type f -iname '*' 2>/dev/null | wc -l)
	if [ $IMAGES_COUNT -eq 0 ]; then
		unmount_fat_partition
		inform_wait "There are no images on FAT partition."
		return 3
        fi

	IMAGE_SOURCE=$(choose_file "Burn an image to $BLK_DEVICE" "Choose the source image file" "${MOUNT_POINT}/images/*")

	if [ $? -ne 0 ]; then
		unmount_fat_partition
		return 2
	fi

	BASENAME=$(basename $IMAGE_SOURCE)

	COMPRESSION_FORMAT=$(get_compression_format $IMAGE_SOURCE)

	if [ $? -ne 0 ]; then

		dialog --backtitle "$BACKTITLE" \
			--yesno "Do you want to proceed to burn a RAW image?" 10 60

		if [ $? -ne 0 ]; then
			unmount_fat_partition
			return 2
		fi

		COMPRESSION_FORMAT="raw"

	fi

	DECOMPRESSION_CLI=$(get_decompression_cli $IMAGE_SOURCE $COMPRESSION_FORMAT)

	if [ $? -ne 0 ]; then

		inform_wait "Unknown file format, cannot proceed"
		unmount_fat_partition
		return 1

	fi

	SKIP_BLOCKS=0
	SEEK_BLOCKS=0
	IDBLOADER_SKIP=0

	# If the block device is rknand*, we look the signature of the source image and
	# in case we find the idbloader, we ask the user to skip the first 0x2000
	# sectors
	if [[ "$BLK_DEVICE" =~ "rknand" ]]; then

		SIGNATURE=$(cat "$IMAGE_SOURCE" | $DECOMPRESSION_CLI | od -A none -j $((0x40 * 0x200)) -N 16 -tx1)
	
		if [ "$SIGNATURE" = "$IDBLOADER_SIGNATURE" ]; then

			dialog --colors \
				--backtitle "$BACKTITLE" \
				--yesno "$IDBLOADER_SKIP_QUESTION" 12 74	

			if [ $? -eq 0 ]; then
				SKIP_BLOCKS=8
				SEEK_BLOCKS=8
				IDBLOADER_SKIP=1
			fi

		fi

	fi

	set_led_state "$DEVICE_NAME"

	(pv -n "$IMAGE_SOURCE" | $DECOMPRESSION_CLI | dd of="/dev/$BLK_DEVICE" skip=$SKIP_BLOCKS seek=$SEEK_BLOCKS bs=512K iflag=fullblock oflag=direct 2>/dev/null) 2>&1 | dialog \
		--backtitle "$BACKTITLE" \
		--gauge "Burning image $BASENAME to device $BLK_DEVICE in progress, please wait..." 10 70 0

	ERR=$?

	if [ $ERR -ne 0 ]; then
		unmount_fat_partition
		inform_wait "An error occurred ($ERR) while burning image, process has not been completed"
		return 1
	fi

	# In case idbloader is skipped, we also copy the first 64 sectors from the source image
	# to restore the partition table. It should be safe.
	if [ $IDBLOADER_SKIP -eq 1 ]; then

		inform "Restoring partition table and installing custom u-boot loader. This will take a moment..."

		(cat "$IMAGE_SOURCE" | $DECOMPRESSION_CLI | dd of="/dev/$BLK_DEVICE" bs=32k count=1 iflag=fullblock oflag=direct 2>/dev/null)
		ERR=$?

		if [ $ERR -ne 0 ]; then
			unmount_fat_partition
			inform_wait "An error occurred ($ERR) while restoring partition table, image may not boot"
			return 1
		fi

		dd if="${MOUNT_POINT}/bsp/legacy-uboot.img" of="/dev/$BLK_DEVICE" bs=4M seek=1 oflag=direct >/dev/null 2>&1
	        ERR=$?

        	if [ $ERR -ne 0 ]; then
                	unmount_fat_partition
	                inform_wait "An error occurred ($ERR) while burning bootloader on device, image may not boot"
        	        return 1
	        fi

	fi

	unmount_fat_partition

	inform_wait "Image has been burned to device $BLK_DEVICE"

	return 0

}

# Restore an image and burns it onto an eMMC device
function do_install_stepnand() {

	inform_wait "$STEPNAND_WARNING"

	# Ask the user which device she wants to restore
	TARGET_DEVICE=$(choose_mmc_device "Burn Armbian image via steP-nand" "Select destination device:" $DEVICES_MMC)

	if [ $? -ne 0 ]; then
		return 2 # User cancelled
	fi

	if [ -z "$TARGET_DEVICE" ]; then
		return 2 # No restore device, user cancelled?
	fi

	BASENAME=$(basename $TARGET_DEVICE)
	BLK_DEVICE=$(get_block_device $TARGET_DEVICE)
	DEVICE_NAME=$(echo $BASENAME | cut -d ":" -f 1)

	# Mount the fat partition
	mount_fat_partition

	if [ $? -ne 0 ]; then
		inform_wait "There has been an error mounting the FAT partition."
		unmount_fat_partition
		return 1
	fi

	# Search the images path on the FAT partition
	if [ ! -d "${MOUNT_POINT}/images" ]; then
		unmount_fat_partition
                inform_wait "There are no images on FAT partition."
		return 3
        fi

	IMAGES_COUNT=$(find "${MOUNT_POINT}/images" -type f -iname '*' 2>/dev/null | wc -l)
	if [ $IMAGES_COUNT -eq 0 ]; then
		unmount_fat_partition
		inform_wait "There are no images on FAT partition."
		return 3
        fi

	IMAGE_SOURCE=$(choose_file "Burn Armbian image via steP-nand to $BLK_DEVICE" "Choose the source image file" "${MOUNT_POINT}/images/*")

	if [ $? -ne 0 ]; then
		unmount_fat_partition
		return 2
	fi

	BASENAME=$(basename $IMAGE_SOURCE)

	COMPRESSION_FORMAT=$(get_compression_format $IMAGE_SOURCE)

	if [ $? -ne 0 ]; then

		dialog --backtitle "$BACKTITLE" \
			--yesno "Do you want to proceed to burn a RAW image?" 10 60

		if [ $? -ne 0 ]; then
			unmount_fat_partition
			return 2
		fi

		COMPRESSION_FORMAT="raw"

	fi

	DECOMPRESSION_CLI=$(get_decompression_cli $IMAGE_SOURCE $COMPRESSION_FORMAT)

	if [ $? -ne 0 ]; then

		inform_wait "Unknown file format, cannot proceed"
		unmount_fat_partition
		return 1

	fi

	set_led_state "$DEVICE_NAME"

	# Armbian rootfs must be copied from sector 0x2000, which is naturally allocated,
	# to sector 0x8000 on NAND. That is so because the first 0x8000 sectors are used
	# for legacy u-boot and trustos.
	(pv -n "$IMAGE_SOURCE" | $DECOMPRESSION_CLI | dd of="/dev/$BLK_DEVICE" skip=8 seek=32 bs=512K iflag=fullblock oflag=direct 2>/dev/null) 2>&1 | dialog \
		--backtitle "$BACKTITLE" \
		--gauge "Burning image $BASENAME to device $BLK_DEVICE in progress, please wait..." 10 70 0

	ERR=$?

	if [ $ERR -ne 0 ]; then
		unmount_fat_partition
		inform_wait "An error occurred ($ERR) while burning image, process has not been completed"
		return 1
	fi

	inform "Installing legacy bootloader and creating GPT partitions, this will take a moment ..."

	dd if="${MOUNT_POINT}/bsp/legacy-uboot.img" of="/dev/$BLK_DEVICE" bs=4M seek=1 oflag=direct >/dev/null 2>&1
	ERR=$?

	if [ $ERR -ne 0 ]; then
		unmount_fat_partition
		inform_wait "An error occurred ($ERR) while burning bootloader on device, process has not been completed"
		return 1
	fi

	dd if="${MOUNT_POINT}/bsp/trustos.img" of="/dev/$BLK_DEVICE" bs=4M seek=2 oflag=direct >/dev/null 2>&1
	ERR=$?

	if [ $ERR -ne 0 ]; then
		unmount_fat_partition
		inform_wait "An error occurred ($ERR) while burning TEE on device, process has not been completed"
		return 1
	fi

	sync
	sleep 1

	# Create the GPT partition table and a partition starting from sector 0x8000
	# Note: we need to manually clear the MBR because sgdisk complaints if it finds
	# an existing partition table, even with --zap-all argument
	# TODO: fix the 3G size with the real origin partition size
	dd if=/dev/zero of="/dev/$BLK_DEVICE" bs=32k count=1 conv=sync,fsync >/dev/null 2>&1
	sgdisk -o "/dev/$BLK_DEVICE"
	sgdisk --zap-all -n 0:32768:+3G "/dev/$BLK_DEVICE" >/dev/null 2>&1
	ERR=$?

	if [ $ERR -ne 0 ]; then
		unmount_fat_partition
		inform_wait "An error occurred ($ERR) while creating GPT partition table, process has not been completed"
		return 1
	fi

	unmount_fat_partition

	inform_wait "Image has been burned to device $BLK_DEVICE"

	return 0

}

function do_erase_mmc() {

	# Verify there is at least one suitable device
        if [ ${#DEVICES_MMC[@]} -eq 0 ]; then
                inform_wait "There are not eMMC device suitable"
                return 3 # Not available
        fi

	 # Ask the user which device she wants to erase
        ERASE_DEVICE=$(choose_mmc_device "Erase flash" "Select device to erase:" $DEVICES_MMC)

        if [ $? -ne 0 ]; then
                return 2 # User cancelled
        fi

        if [ -z "$ERASE_DEVICE" ]; then
                return 2 # No backup device, user cancelled?
        fi

        BASENAME=$(basename $ERASE_DEVICE)
	BLK_DEVICE=$(get_block_device $ERASE_DEVICE)
	DEVICENAME=$(echo $BASENAME | cut -d ":" -f 1)

	# First try with blkdiscard, which uses MMC command to erase pages
	# without programming them. It is faster and it is the best way to
	# erase an eMMC
	inform "Erasing eMMC device $BLK_DEVICE using blkdiscard..."

	if [ -n "$DEVICENAME" ]; then
		set_led_state "$DEVICENAME"
	fi

	blkdiscard "/dev/$BLK_DEVICE" 

	if [ $? -eq 0 ]; then
		inform_wait "Success! Device $BLK_DEVICE has been erased!"
		return 0
	fi

	# Try to erase using dd
	ERASE_SIZE=$(cat $ERASE_DEVICE/preferred_erase_size >/dev/null 2>&1)
	ERASE_SIZE=${ERASE_SIZE:-"4M"}
	DEVICE_SIZE=$(cat /sys/block/$BLK_DEVICE/size)
	DEVICE_SIZE=$((DEVICE_SIZE / 2)) # convert sectors to kilobytes
	(pv -n -s ${DEVICE_SIZE}K /dev/zero | dd of="/dev/$BLK_DEVICE" iflag=fullblock bs=$ERASE_SIZE oflag=direct 2>/dev/null) 2>&1 | dialog --gauge "Erase is in progress, please wait..." 10 70 0

	inform_wait "Success! Device $BLK_DEVICE has been erased!"

	return 0

}

# Install jump start for armbian on NAND
function do_install_jump_start() {

	dialog --backtitle "$BACKTITLE" --yesno "$JUMPSTART_WARNING" 0 0

	if [ $? -ne 0 ]; then
		return 2
	fi

	inform "Transferring boot loader, please wait..."

	dd if=/dev/mmcblk0 of=/dev/rknand0 skip=$((0x4000)) seek=$((0x2000)) count=$((0x4000)) conv=sync,fsync >/dev/null 2>&1
	if [ $? -ne 0 ]; then
		inform_wait "Could not transfer U-boot on NAND device"
		return 1
	fi

	dd if=/dev/mmcblk0 of=/dev/rknand0 skip=$((0x8000)) seek=$((0x6000)) count=$((0x4000)) conv=sync,fsync >/dev/null 2>&1
	if [ $? -ne 0 ]; then
		inform_wait "Could not transfer TEE on NAND device"
		return 1
	fi

	sync
	
	sleep 1

	inform_wait "Jump start installed!"

	return 0

}

# Give a shell to the user
function do_give_shell() {

	echo -e "Drop to a bash shell. Exit the shell to return to Multitool\n"

	/bin/bash -il

}

function do_reboot() {

	unmount_fat_partition

	sleep 1

	echo b > /proc/sysrq-trigger

}

function do_shutdown() {

	unmount_fat_partition

	sleep 1

	echo o > /proc/sysrq-trigger

}

# ----- Entry point -----

mount_fat_partition

dialog --backtitle "$BACKTITLE" \
	--textbox "/mnt/LICENSE" 0 0

unmount_fat_partition

find_mmc_devices
find_special_devices

declare -a MENU_ITEMS

MENU_ITEMS+=(1 "Backup flash")
MENU_ITEMS+=(2 "Restore flash")
MENU_ITEMS+=(3 "Erase flash")
MENU_ITEMS+=(4 "Drop to Bash shell")
MENU_ITEMS+=(5 "Burn image to flash")
[[ "${DEVICES_MMC[@]}" =~ "nandc" ]] && MENU_ITEMS+=(6 "Install Jump start on NAND")
[[ "${DEVICES_MMC[@]}" =~ "nandc" ]] && MENU_ITEMS+=(7 "Install Armbian via steP-nand")
MENU_ITEMS+=(8 "Reboot")
MENU_ITEMS+=(9 "Shutdown")

MENU_CMD=(dialog --backtitle "$BACKTITLE" --title "$TITLE_MAIN_MENU" --menu "Choose an option" 0 0 0)

while true; do

	set_led_state "timer"

	CHOICE=$("${MENU_CMD[@]}" "${MENU_ITEMS[@]}" 2>&1 >$TTY_CONSOLE)

	CHOICE=${CHOICE:-0}

	if [ $CHOICE -eq 1 ]; then
		do_backup
	elif [ $CHOICE -eq 2 ]; then
		do_restore
	elif [ $CHOICE -eq 3 ]; then
		do_erase_mmc
	elif [ $CHOICE -eq 4 ]; then
		do_give_shell
	elif [ $CHOICE -eq 5 ]; then
		do_burn
	elif [ $CHOICE -eq 6 ]; then
		do_install_jump_start
	elif [ $CHOICE -eq 7 ]; then
		do_install_stepnand
	elif [ $CHOICE -eq 8 ]; then
		do_reboot
	elif [ $CHOICE -eq 9 ]; then
		do_shutdown
	fi

done
