#/bin/bash

BACKTITLE="SD/eMMC card helper Multitool for TV Boxes and alike - Paolo Sabatino"
TITLE_MAIN_MENU="Multitool Menu"

CHOICE_FILE="/tmp/choice"

FAT_PARTITION="/dev/mmcblk0p2"

MOUNT_POINT="/mnt"
WORK_LED="/sys/class/leds/led:state1"

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
		DEVICE_TYPE=$(cat $DEVICE/type)
		if [ "$DEVICE_TYPE" = "MMC" ]; then
			DEVICES_MMC+=($DEVICE)
		elif [ "$DEVICE_TYPE" = "SD" ]; then
			DEVICES_SD+=($DEVICE)
		elif [ "$DEVICE_TYPE" = "SDIO" ]; then
			DEVICES_SDIO+=($DEVICE)
		fi
	done

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
	DEVICES=$2
	STR_DEVICES=""
	TTY_CONSOLE=$(fgconsole)
	TTY_CONSOLE="/dev/tty${TTY_CONSOLE}"

	for IDX in ${!DEVICES[@]}; do
		BASENAME=$(basename ${DEVICES[$IDX]})
		BLKDEVICE=$(get_block_device ${DEVICES[$IDX]})
		NAME=$(cat ${DEVICES[$IDX]}/name)
		STR_DEVICES="$STR_DEVICES $IDX $BLKDEVICE($BASENAME,$NAME)"
	done
	
	dialog --backtitle "$BACKTITLE" \
		--title "$TITLE" \
		--menu "Choose an option" 20 40 18\
		$STR_DEVICES \
		> $TTY_CONSOLE \
		2> $CHOICE_FILE

	# No choice, return error code 1
	if [ $? -ne 0 ]; then
		return 1
	fi

	# When the user selects a choice, print the real choice (ie: the device path)
	CHOICE=$(cat $CHOICE_FILE)

	echo ${DEVICES[$CHOICE]}

	return 0

}

# Function to inform the user, but does not wait for its ok (returns immediately)
# First argument is the text
function inform() {
	
	TEXT=$1

	dialog --backtitle "$BACKTITLE" \
		--infobox "$TEXT" 7 60

}


# Function to inform the user and wait for its ok.
# First argument is the text
function inform_wait() {

	TEXT=$1

	dialog --backtitle "$BACKTITLE" \
		--msgbox "$TEXT" 7 60

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
	BACKUP_DEVICE=$(choose_mmc_device "Backup eMMC device" $DEVICES_MMC)

	if [ $? -ne 0 ]; then
		return 2 # User cancelled
	fi

	if [ -z "$BACKUP_DEVICE" ]; then
		return 2 # No backup device, user cancelled?
	fi

	BASENAME=$(basename $BACKUP_DEVICE)
	BLK_DEVICE=$(get_block_device $BACKUP_DEVICE)
	DEVICE_NAME=$(echo $BASENAME | cut -d ":" -f 1)

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

	# Do the backup!
	set_led_state "$DEVICE_NAME"

	(pv -n /dev/$BLK_DEVICE | pigz | dd of="$MOUNT_POINT/backups/backup.gz" iflag=fullblock oflag=direct bs=512k 2>/dev/null) 2>&1 | dialog \
		--backtitle "$BACKTITLE" \
		--gauge "Backup of device $BLK_DEVICE is in progress, please wait..." 10 70 0

	#dd if="/dev/$BASENAME" bs=512k 2>/dev/null | gzip | dd of="$MOUNT_POINT/backups/backup.gz" oflag=direct bs=512k iflag=fullblock 2>/dev/null
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
	RESTORE_DEVICE=$(choose_mmc_device "Restore to eMMC device" $DEVICES_MMC)

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

	BACKUP_COUNT=$(find "${MOUNT_POINT}/backups" -iname 'backup*.gz' | wc -l)
	if [ $BACKUP_COUNT -eq 0 ]; then
		unmount_fat_partition
		inform_wait "There are no backups on FAT partition, restore cannot continue"
		return 3
        fi

	declare -a BACKUPS
	COUNTER=1
	STR_BACKUPS=""

	for FILE in ${MOUNT_POINT}/backups/backup*.gz; do
		BACKUPS+=($FILE)
		BASENAME=$(basename $FILE)
		STR_BACKUPS="$STR_BACKUPS $COUNTER $BASENAME"
		COUNTER=$(($COUNTER + 1))
	done

	dialog --backtitle "$BACKTITLE" \
		--title "Restore a backup file to $BLK_DEVICE" \
		--menu "Choose a backup file" 20 40 18 \
		$STR_BACKUPS \
		2> $CHOICE_FILE

	if [ $? -ne 0 ]; then
		unmount_fat_partition
		return 2
	fi

	CHOICE=$(<$CHOICE_FILE)
	RESTORE_SOURCE=${BACKUPS[$CHOICE]}
	BASENAME=$(basename $RESTORE_SOURCE)
	
	set_led_state "$DEVICE_NAME"

	(pv -n $RESTORE_SOURCE | pigz -d | dd of=/dev/$BLK_DEVICE bs=512k iflag=fullblock oflag=direct 2>/dev/null) | dialog \
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

function do_erase_mmc() {

	# Verify there is at least one suitable device
        if [ ${#DEVICES_MMC[@]} -eq 0 ]; then
                inform_wait "There are not eMMC device suitable"
                return 3 # Not available
        fi

	 # Ask the user which device she wants to erase
        ERASE_DEVICE=$(choose_mmc_device "Erase MMC device" $DEVICES_MMC)

        if [ $? -ne 0 ]; then
                return 2 # User cancelled
        fi

        if [ -n "$ERASE_DEVICE" ]; then
                return 2 # No backup device, user cancelled?
        fi

        BASENAME=$(basename $ERASE_DEVICE)
	BLK_DEVICE=$(get_block_device $ERASE_DEVICE)
	DEVICENAME=$(echo $BASENAME | cut -d ":" -f 1)

	# First try with blkdiscard, which uses MMC command to erase pages
	# without programming them. It is faster and it is the best way to
	# erase an eMMC
	inform "Erasing eMMC device $BLK_DEVICE using blkdiscard..."

	if [ -n "$DEVICENAME" ] && [ -e ; then
		set_led_state "$DEVICENAME"
	fi

	blkdiscard "/dev/$BLK_DEVICE" 

	if [ $? -eq 0 ]; then
		inform_wait "Success! Device $BLK_DEVICE has been erased!"
		return 0
	fi

	# Try to erase using dd
	ERASE_SIZE=$(cat $ERASE_DEVICE/preferred_erase_size)
	DEVICE_SIZE=$(cat /sys/block/$BLK_DEVICE/size)
	DEVICE_SIZE=$((DEVICE_SIZE / 2)) # convert sectors to kilobytes
	(pv -n -s ${DEVICE_SIZE}K /dev/zero | dd of="/dev/$BLK_DEVICE" iflag=fullblock bs=$ERASE_SIZE oflag=direct 2>/dev/null) 2>&1 | dialog --gauge "Erase is in progress, please wait..." 10 70 0

	inform_wait "Success! Device $BLK_DEVICE has been erased!"

	return 0

}

# Give a shell to the user
function do_give_shell() {

	echo -e "Drop to a bash shell. Exit the shell to return to Multitool\n"

	/bin/bash -i

}

# ----- Entry point -----

find_mmc_devices

while true; do

	set_led_state "timer"

	dialog --backtitle "$BACKTITLE" \
		--title "$TITLE_MAIN_MENU" \
		--menu "Choose an option" 20 40 18 \
		1 "Backup" \
		2 "Restore" \
		3 "Erase eMMC" \
		4 "Drop to shell" \
		2>$CHOICE_FILE

	CHOICE=$(cat $CHOICE_FILE)
	CHOICE=${CHOICE:-0}

	if [ $CHOICE -eq 1 ]; then
		do_backup
	elif [ $CHOICE -eq 2 ]; then
		do_restore
	elif [ $CHOICE -eq 3 ]; then
		do_erase_mmc
	elif [ $CHOICE -eq 4 ]; then
		do_give_shell
	fi

done
