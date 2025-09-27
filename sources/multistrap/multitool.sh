#!/bin/bash

# In case of SSH session, TTY console is the SSH allocated PTY, otherwise
# use the regular TTY foreground terminal
if [[ -n "$SSH_TTY" ]]; then
	TTY_CONSOLE="$SSH_TTY"
else
	TTY_CONSOLE="/dev/tty$(fgconsole)"
fi

BACKTITLE="TVBox Project - IFSP Salto | Multitool by Paolo Sabatino"
TITLE_MAIN_MENU="Multitool Menu"

ISSUE="unknown" # Will be read later from /mnt/ISSUE
TARGET_CONF="unknown" # Will be read later from /mnt/TARGET

# Taken from https://stackoverflow.com/questions/5947742/how-to-change-the-output-color-of-echo-in-linux
BOLD="\Zb"
RED="\Z1"
NC="\Z0"
RESET="\Zn"

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

COMMAND_RATE_WARNING="${RED}Do this only if you are really aware of what you are going to do!${NC}\n\n\
Some DDR memories can be programmed with any Command Rate (1T or 2T\n\
clock cycles), but some other DDR memories only work with 1T or 2T.\n\
Setting the wrong value on boards with picky DDR memories may make\n\
the board ${RED}unstable${NC} or even ${RED}refuse it to boot${NC}.\n\n\
This menu option allows you to alter Command Rate timing value to\n
try avoid instabilities.\n"

IDBLOADER_SKIP_QUESTION="${RED}WARNING!!${NC}\n\nAn idbloader signature is present in the source image.\n\
The current driver is not able to write idbloader sectors to NAND device\n\
It is ${RED}heavily suggested${NC} to skip the idbloader sectors writing on NAND\n\n\
Do you want to skip idbloader sectors?"

ERROR_ARCHIVE_WITHOUT_IMG_FILE="${RED}Error${NC}\n\nA compressed archive has been detected, but the archive\n\
does not contain any .img file to be burned. Process cannot continue\n"

ERROR_TAR_UNKNOWN_FORMAT="${RED}Error${NC}\n\nA compressed TAR archive has been detected, but the archive\n\
is in an unknown format and cannot be decompressed.\n"

CHOICE_FILE="/tmp/choice"

# The FAT/NTFS/EXT partition must have MULTITOOL label name. blkid is handy in this case because it will detect
# the FAT/NTFS/EXT partition on any device (mmc/usb) it is
MULTITOOL_PARTITION=$(blkid -l --label "MULTITOOL")
BOOT_DEVICE="/dev/$(lsblk -n -o PKNAME $MULTITOOL_PARTITION)"

MOUNT_POINT="/mnt"
WORK_LED="/sys/class/leds/led:state1"

IDBLOADER_SIGNATURE=" 3b 8c dc fc be 9f 9d 51 eb 30 34 ce 24 51 1f 98"

declare -a DEVICES_MMC
declare -a DEVICES_SD
declare -a DEVICES_SDIO

# Finds all devices attached to the MMC bus
#
# This function scans the /sys/bus/mmc/devices directory and categorizes
# all detected MMC devices into three global arrays based on their type:
# - DEVICES_MMC: MMC devices (eMMC)
# - DEVICES_SD: SD card devices
# - DEVICES_SDIO: SDIO devices
#
# These arrays are used throughout the application for device selection
# in backup and restore operations.
#
# @author Paolo Sabatino
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

# Finds devices with special/proprietary paths
#
# This function searches for storage devices that use proprietary drivers
# and have specific device paths that are not detected through the standard
# MMC bus enumeration. Currently supports Rockchip NAND devices (/dev/rknand0).
#
# When a special device is found, it displays a warning about limitations
# of proprietary drivers and adds the device to the DEVICES_MMC array
# for use in backup/restore operations.
#
# @author Paolo Sabatino
function find_special_devices() {

    SYS_RKNAND_BLK_DEV="/dev/rknand0"

    if [ -b "$SYS_RKNAND_BLK_DEV" ]; then

        inform_wait "$RKNAND_WARNING"

        SYS_RKNAND_DEVICE=$(realpath /sys/block/rknand0/device)
        DEVICES_MMC+=($SYS_RKNAND_DEVICE)

    fi	

}

# Gets the block device name from a sysfs device path
#
# This function takes a device path from /sys/bus/mmc/devices/* and returns
# the corresponding block device name (e.g., mmcblk0, mmcblk1) that can be
# used for block device operations.
#
# @param string $1 The sysfs device path (e.g., /sys/bus/mmc/devices/mmc0:0001)
# @return string The block device name (e.g., mmcblk0)
# @author Paolo Sabatino
function get_block_device() {

    DEVICE=$1
    BLK=$(ls "$DEVICE/block" | head -n 1)

    echo $BLK

}

# Mounts the MULTITOOL partition for file operations
#
# This function mounts the partition labeled "MULTITOOL" (FAT/NTFS/EXT) to /mnt,
# allowing access to backup files and configuration data. It first attempts a
# remount (for already mounted partitions) and falls back to a regular mount
# if the remount fails.
#
# @return 0 on successful mount, 1 on mount failure
# @author Paolo Sabatino
function mount_mt_partition() {

    # Try to do a remount: if partition is already mounted
    # it will succeed, otherwise we will try to mount again
    # but regularly this time.
    mount "$MULTITOOL_PARTITION" "$MOUNT_POINT" -o remount > /dev/null 2>/dev/null
    [[ $? -eq 0 ]] && return 0

    mount "$MULTITOOL_PARTITION" "$MOUNT_POINT" > /dev/null 2>/dev/null
    [[ $? -eq 0 ]] && return 0

    return 1

}

# Unmounts the MULTITOOL partition safely
#
# This function safely unmounts the MULTITOOL partition from /mnt after ensuring
# all pending data is written to disk. It suppresses error output and is designed
# to be called after operations that required access to the multitool partition.
#
# @return 0 always (errors are suppressed)
# @author Paolo Sabatino
function unmount_mt_partition() {

    # Ensure all data is written
    sync
    umount "$MOUNT_POINT" 2>/dev/null

    return 0

}

# Reboots the system safely
#
# This function ensures all data is written to disk, unmounts the multitool partition,
# and triggers a system reboot using the sysrq mechanism with proper sequencing.
# The implementation includes graceful process termination, data synchronization,
# filesystem remounting as read-only, and safe reboot using sysrq triggers with
# appropriate delays between each step to ensure system stability.
#
# @author Paolo Sabatino
# @modified Pedro Rigolin - Enhanced with sysrq sequence and safety delays
function do_reboot() {

    # Ensure all data is written
    sync
    unmount_mt_partition

    # Show reboot message
    dialog --backtitle "$BACKTITLE" \
        --title "Reboot" \
        --infobox "\nSystem is going down for reboot..." 6 50

    # Allow time for the infobox to be read
    sleep 2

    # E - Terminate all processes gracefully
    echo e > /proc/sysrq-trigger

    # Pause to allow processes to terminate
    sleep 1

    # I - Kill all processes that did not terminate
    echo i > /proc/sysrq-trigger

    # Pause to ensure processes are killed
    sleep 1

    # S - Sync all data to disks
    echo s > /proc/sysrq-trigger

    # Pause to allow the sync to complete
    sleep 1

    # U - Remount all filesystems as read-only
    echo u > /proc/sysrq-trigger

    # Pause to allow filesystems to be remounted
    sleep 1

    # B - Reboot the system
    echo b > /proc/sysrq-trigger

}

# Shuts down the system safely
#
# This function ensures all data is written to disk, unmounts the multitool partition,
# and triggers a system shutdown using the sysrq mechanism with proper sequencing.
# The implementation includes graceful process termination, data synchronization,
# filesystem remounting as read-only, and safe power-off using sysrq triggers with
# appropriate delays between each step to ensure system stability.
#
# @author Paolo Sabatino
# @modified Pedro Rigolin - Enhanced with sysrq sequence and safety delays
function do_shutdown() {

    # Ensure all data is written
    sync
    unmount_mt_partition

    # Show shutdown message
    dialog --backtitle "$BACKTITLE" \
        --title "Shutdown" \
        --infobox "\nSystem is going down for shutdown..." 6 50

    # Allow time for the infobox to be read
    sleep 2

    # E - Terminate all processes gracefully
    echo e > /proc/sysrq-trigger

    # Pause to allow processes to terminate
    sleep 1

    # I - Kill all processes that did not terminate
    echo i > /proc/sysrq-trigger

    # Pause to ensure processes are killed
    sleep 1

    # S - Sync all data to disks
    echo s > /proc/sysrq-trigger

    # Pause to allow the sync to complete
    sleep 1

    # U - Remount all filesystems as read-only
    echo u > /proc/sysrq-trigger

    # Pause to allow filesystems to be remounted
    sleep 1

    # O - Power Off the system
    echo o > /proc/sysrq-trigger

}

# Provides an interactive shell for advanced operations
#
# This function drops the user into an interactive bash shell, allowing them
# to execute arbitrary commands for debugging, troubleshooting, or advanced
# operations. The user can exit the shell to return to the multitool menu.
#
# @author Paolo Sabatino
function do_give_shell() {

    echo -e "Drop to a bash shell. Exit the shell to return to Multitool\n"

    /bin/bash -il

}

# Creates the backups directory on the MULTITOOL partition
#
# This function ensures the "backups" directory exists on the mounted MULTITOOL
# partition at /mnt/backups. It creates the directory if it doesn't exist and
# verifies the operation was successful.
#
# @requires MULTITOOL partition must be already mounted
# @return 0 on success, 1 on failure
# @author Paolo Sabatino
function prepare_backup_directory() {

    mkdir -p "$MOUNT_POINT/backups"

    if [ $? -ne 0 ]; then
        return 1
    fi

    return 0

}

# Gets the command rate offset from an image file or device
#
# This function searches for a specific signature (a7866565) in the first 128KB
# of the target image file or device. If found, it calculates the command rate
# offset as 16 bytes before the signature location. This offset is used for
# DDR memory timing configuration.
#
# @param string $1 The target image file or device path
# @return 0 on success (offset printed to stdout), 1 on failure
# @author Paolo Sabatino
function get_command_rate_offset() {

    TARGET="$1" # target device/file
    
    # Find the signature "a7866565" in the first 128k of the image
    SIGNATURE_OFFSET=$(dd if=$TARGET bs=128k count=1 2>/dev/null | od -A o -w4 -tx4 | grep 'a7866565' | cut -d " " -f 1)
    
    # Error in command execution, return error
    [[ $? -ne 0 ]] && return 1
    
    # Signature not found, return error
    [[ -z $SIGNATURE_OFFSET ]] && return 1
    
    # Calculate the command rate offset, which is 16 bytes before the signature
    CMD_RATE_OFFSET=$(($SIGNATURE_OFFSET - 16))
    
    echo $CMD_RATE_OFFSET
    
    return 0

}

# Gets the command rate value from an image file or device
#
# This function reads the command rate byte from the calculated offset in the
# target image file or device. It interprets the byte value (0 = 1T, 1 = 2T)
# and returns the command rate as a string. This is used for DDR memory timing
# configuration where command rate determines clock cycle timing.
#
# @param string $1 The target image file or device path
# @return 0 on success ("1T" or "2T" printed to stdout), 1 on failure
# @author Paolo Sabatino
function get_command_rate() {

    TARGET="$1"
    
    CMD_RATE_OFFSET=$(get_command_rate_offset $TARGET)
    
    [[ $? -ne 0 ]] && return 1
    
    # Get the Command rate byte
    CMD_RATE_BYTE=$(od -A n -t dI -j $CMD_RATE_OFFSET -N 1 $TARGET)
    
    # Error in command execution, return error
    [[ $? -ne 0 ]] && return 1
    
    # No value for cmd rate byte, return error
    [[ -z $CMD_RATE_BYTE ]] && return 1
    
    # Command rate byte should be 0 or 1, otherwise return error
    [[ "$CMD_RATE_BYTE" -ne 0 && "$CMD_RATE_BYTE" -ne 1 ]] && return 1
    
    [[ "$CMD_RATE_BYTE" -eq 0 ]] && echo "1T"
    [[ "$CMD_RATE_BYTE" -eq 1 ]] && echo "2T"
    
    return 0
    
}

# Sets the command rate value in an image file or device
#
# This function writes the specified command rate value (1T or 2T) to the
# calculated offset in the target image file or device. It first verifies
# that the existing command rate can be read successfully before making
# changes. This is used for DDR memory timing configuration.
#
# @param string $1 The target image file or device path
# @param string $2 The command rate value ("1T" or "2T")
# @return 0 on success, 1 on failure
# @author Paolo Sabatino
function set_command_rate() {

    TARGET="$1"
    COMMAND_RATE_VALUE="$2" # "1T" or "2T"
    
    # Verify the existing command rate value is right, exit code is non-zero 
    # if any check fail
    PREV_COMMAND_RATE=$(get_command_rate $TARGET)
    
    [[ $? -ne 0 ]] && return 1
    
    CMD_RATE_OFFSET=$(get_command_rate_offset $TARGET)
    
    [[ $? -ne 0 ]] && return 1
    
    [[ $COMMAND_RATE_VALUE = "1T" ]] && HEX_VALUE="\x00"
    [[ $COMMAND_RATE_VALUE = "2T" ]] && HEX_VALUE="\x01"
    
    echo -e $HEX_VALUE | dd of=$TARGET bs=1 seek=$CMD_RATE_OFFSET count=1 conv=notrunc 2>/dev/null
    
    [[ $? -ne 0 ]] && return 1
    
    return 0
    
}


# Sets the LED state for visual feedback during operations
#
# This function changes the TV Box LED behavior to provide visual feedback
# during various operations. It safely checks if the LED is controllable
# before attempting to change its state, avoiding error messages if the
# LED cannot be controlled.
#
# @param string $1 The LED state (e.g., "timer", "mmc0", "mmc1", "mmc2")
# @author Paolo Sabatino
function set_led_state() {

    # This code tries to change the behavior of the TV Box LED. 
    # Before doing that, it first checks if the LED is controllable. 
    # If it is, it changes the LED state; if not, it simply does nothing, 
    # which is why the conditional was added, avoiding the script showing an error message.
    #
    # @author: Pedro Rigolin
    if [ -w "$WORK_LED/trigger" ]; then
        
        echo $1 > "$WORK_LED/trigger"

    fi

}

# Displays a menu for selecting an MMC device
#
# This function presents an interactive dialog menu allowing the user to
# select from available MMC devices. It builds a user-friendly menu showing
# device information including block device names, device names (if available),
# and device paths. The selected device path is returned for use in operations
# like backup, restore, or image burning.
#
# @param string $1 The dialog title
# @param string $2 The menu title
# @param array $3 Array of device paths to choose from
# @return 0 on success (selected device path printed to stdout), 1 on user cancel
# @author Paolo Sabatino
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

# Displays a menu for selecting a file from a glob pattern
#
# This function presents an interactive dialog menu allowing the user to
# select from files matching a given glob pattern. It expands the glob to
# find available files, builds a menu showing just the filenames (not full paths),
# and returns the selected file's full path for use in operations like restore
# or image burning.
#
# @param string $1 The dialog title
# @param string $2 The menu title
# @param string $3 File glob pattern (e.g., "${MOUNT_POINT}/backups/*.gz")
# @return 0 on success (selected file path printed to stdout), 1 on user cancel
# @author Paolo Sabatino
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

# Displays an informational message without waiting for user confirmation
#
# This function shows a dialog infobox with the provided text message.
# The dialog appears and the function returns immediately without requiring
# user interaction, making it suitable for status updates or progress information
# that doesn't need acknowledgment.
#
# @param string $1 The text message to display
# @author Paolo Sabatino
function inform() {
    
    TEXT=$1

    dialog --colors \
        --backtitle "$BACKTITLE" \
        --infobox "$TEXT" 12 74

}

# Displays an informational message and waits for user confirmation
#
# This function shows a dialog message box with the provided text message
# and waits for the user to press OK before continuing execution. It is used
# for important notifications, warnings, or confirmations that require user
# acknowledgment before proceeding.
#
# @param string $1 The text message to display
# @author Paolo Sabatino
function inform_wait() {

    TEXT=$1

    dialog --colors \
        --backtitle "$BACKTITLE" \
        --msgbox "$TEXT" 12 74

}

# Performs a complete backup of an MMC device to a compressed file
#
# This function guides the user through the entire backup process:
# - Selects the source MMC device to backup
# - Prompts for a backup filename
# - Creates the backup directory on the multitool partition
# - Handles file overwrite confirmation
# - Performs the backup using compression and progress monitoring
# - Provides user feedback throughout the process
#
# The backup is stored as a compressed .gz file on the multitool partition.
#
# @return 0 on success, 1 on error, 2 on user cancel, 3 if no suitable devices
# @author Paolo Sabatino
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

    # Mount the multitool partition
    mount_mt_partition

    if [ $? -ne 0 ]; then
        inform_wait "There has been an error mounting the MULTITOOL partition, backup aborted"
        unmount_mt_partition
        return 1
    fi

    # Create the backup directory
    prepare_backup_directory

    if [ $? -ne 0 ]; then
        inform_wait "Could not create backups directory on MULTITOOL partion, backup aborted"
        unmount_mt_partition
        return 1
    fi

    # Check if the file proposed by the user does already exist
    if [ -e "$BACKUP_PATH" ]; then
        dialog --backtitle "$BACKTITLE" \
            --title ="Backup flash" \
            --yesno "A backup file with the same name already exists, do you want to proceed to overwrite it?" 7 60

        if [ $? -ne 0 ]; then
            unmount_mt_partition
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
        unmount_mt_partition
        return 1
    fi

    unmount_mt_partition

    inform_wait "Backup has been completed!"

    return 0

}

# Performs a complete restore of a backup image to an MMC device
#
# This function guides the user through the entire restore process:
# - Selects the destination MMC device for restore
# - Verifies backup files are available on the multitool partition
# - Allows user to choose which backup file to restore
# - Performs the restore using decompression and progress monitoring
# - Provides user feedback throughout the process
#
# The restore uses compressed .gz backup files from the multitool partition.
#
# @return 0 on success, 1 on error, 2 on user cancel, 3 if no backups available
# @author Paolo Sabatino
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

    # Mount the multitool partition
    mount_mt_partition

    if [ $? -ne 0 ]; then
        inform_wait "There has been an error mounting the MULTITOOL partition, restore cannot continue"
        unmount_mt_partition
        return 1
    fi

    # Search the backup path on the MULTITOOL partition
    if [ ! -d "${MOUNT_POINT}/backups" ]; then
        unmount_mt_partition
        inform_wait "There are no backups on MULTITOOL partition, restore cannot continue"
        return 3
    fi

    BACKUP_COUNT=$(find "${MOUNT_POINT}/backups" -iname '*.gz' | wc -l)
    if [ $BACKUP_COUNT -eq 0 ]; then
        unmount_mt_partition
        inform_wait "There are no backups on MULTITOOL partition, restore cannot continue"
        return 3
    fi

    RESTORE_SOURCE=$(choose_file "Restore a backup image to $BLK_DEVICE" "Choose a backup image" "${MOUNT_POINT}/backups/*.gz")

    if [ $? -ne 0 ]; then
        unmount_mt_partition
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
        unmount_mt_partition
        inform_wait "An error occurred ($ERR) restoring backup, process has not been completed"
        return 1
    fi

    unmount_mt_partition

    inform_wait "Backup restored to device $BLK_DEVICE"

    return 0

}

# Display the current auto-restore configuration
#
# This function mounts the multitool partition, reads the auto_restore.flag file,
# and displays a dialog box showing whether auto-restore is currently configured
# and which backup file is set for automatic restoration (if any).
#
# @author Pedro Rigolin
# @return 0 on success, 1 on mount error
function show_current_auto_restore() {

    # Mount the multitool partition
    mount_mt_partition

    if [ $? -ne 0 ]; then

        inform_wait "\nThere has been an error mounting the MULTITOOL partition, process cannot continue"
        
        # Ensure data is written and unmount the partition
        sync
        unmount_mt_partition

        return 1

    fi

    local FLAG_FILE="${MOUNT_POINT}/auto_restore.flag"

    # Create the flag file if it doesn't exist
    if [ ! -f "$FLAG_FILE" ]; then

        echo -n "" > "$FLAG_FILE"

    fi

    if [ [ "$FLAG_CONTENTS" != *.gz ] ]; then

        inform_wait "\nThe auto-restore flag file does not contain a valid .gz filename, resetting it to empty."

        echo -n "" > "$FLAG_FILE"

    fi

    # Read the contents of the flag file
    local FLAG_CONTENTS=$(cat "$FLAG_FILE" | xargs)

    # Display appropriate dialog based on flag contents
    if [ -z "$FLAG_CONTENTS" ]; then

        dialog --backtitle "$BACKTITLE" \
            --title "Current Auto-Restore" \
            --ok-label "OK" \
            --msgbox "\n\nNo Auto-Restore file is defined." 10 60

    else

        dialog --backtitle "$BACKTITLE" \
            --title "Current Auto-Restore" \
            --ok-label "OK" \
            --msgbox "\nAuto-Restore file is set to:\n\n${FLAG_CONTENTS}" 10 60

    fi

    # Ensure data is written and unmount the partition
    sync
    unmount_mt_partition

    return 0

}

# Set an automatic restore at next boot
#
# This function provides an interactive menu to configure automatic restore settings.
# It mounts the multitool partition, scans for available .gz backup files, and presents
# a dialog menu allowing the user to select a backup for automatic restoration on next boot
# or to unset the auto-restore configuration.
#
# The selected backup filename is stored in the auto_restore.flag file on the multitool partition.
# If "Unset" is chosen, the flag file is emptied, disabling auto-restore.
#
# @author Pedro Rigolin
# @return 0 on success, 1 on mount error or no backups found, 2 on user cancel
function set_auto_restore() {

    # Mount the multitool partition
    mount_mt_partition

    if [ $? -ne 0 ]; then

        inform_wait "There has been an error mounting the MULTITOOL partition, process cannot continue"
        
        # Ensure data is written and unmount the partition
        sync
        unmount_mt_partition

        return 1

    fi

    # Prepare variables for the dialog menu
    declare -a FILES

    declare -a STR_FILES

    local GLOB="${MOUNT_POINT}/backups/*.gz"

    local COUNTER=0

    local FLAG_FILE="${MOUNT_POINT}/auto_restore.flag"

    if [ ! -f "$FLAG_FILE" ]; then

        # If the flag file does not exist, create an empty one
        echo -n "" > "$FLAG_FILE"

    fi

    local FLAG_CONTENTS=$(cat "$FLAG_FILE" | xargs)

    if [ -n "$FLAG_CONTENTS" ]; then

        # Add the "Unset" option as the first menu item
        STR_FILES+=("UNSET" "Unset auto-restore (leave flag empty)")

    fi

    # Loop to find backup files and add them to the menu
    for FILE in $GLOB; do

        if [ -f "$FILE" ]; then

            # Add file to the arrays for menu display
            FILES+=($FILE)

            local BASENAME=$(basename "$FILE")

            STR_FILES+=($COUNTER "$BASENAME")

            COUNTER=$(($COUNTER + 1))

        fi

    done

    if [ ${#STR_FILES[@]} -eq 0 ]; then

        inform_wait "No backup images found in the multitool partition and no auto-restore file is defined.\n\nPlease add .gz files to enable auto-restore."
        
        # Ensure data is written and unmount the partition
        sync
        unmount_mt_partition

        return 1

    fi

    # Build and display the custom menu
    local TITLE="Set up automatic restore"

    local MENU_TITLE="Choose a backup image for next boot or Unset"

    local MENU_CMD=(dialog --backtitle "$BACKTITLE" --title "$TITLE" --menu "$MENU_TITLE" 24 0 18)

    # Display the menu and capture user choice
    CHOICE=$("${MENU_CMD[@]}" "${STR_FILES[@]}" 2>&1 >$TTY_CONSOLE)

    # If the user pressed Cancel or ESC, just exit the function
    if [ $? -ne 0 ]; then

        # Ensure data is written and unmount the partition
        sync
        unmount_mt_partition

        return 2

    fi

    # Decision logic based on user choice
    if [ "$CHOICE" = "UNSET" ]; then

        # Clear the auto-restore configuration
        echo -n "" > "${MOUNT_POINT}/auto_restore.flag"

        inform_wait "Auto-restore has been UNSET.\n\nThe flag file is now empty."

    else

        # If a file was selected, save the name in the auto restore flag
        local RESTORE_SOURCE=${FILES[$CHOICE]}

        local BACKUP_FILENAME=$(basename "$RESTORE_SOURCE")

        # Write the selected backup filename to the flag file
        echo -n "$BACKUP_FILENAME" > "${MOUNT_POINT}/auto_restore.flag"

        inform_wait "Auto-restore set to: $BACKUP_FILENAME\n\nIt will be restored on the next boot."

    fi

    # Ensure data is written and unmount the partition
    sync
    unmount_mt_partition

    return 0

}

# Performs automatic restore of a backup image to the device based on the auto_restore.flag file.
#
# This function mounts the multitool partition, reads the backup filename from the flag file,
# verifies the backup exists, selects a suitable eMMC device, and restores the compressed
# backup image to the device using dd, pigz, and pv for progress monitoring.
#
# @author Pedro Rigolin
# @return 0 on success, 1 on error, 3 if no suitable device
function do_auto_restore() {

    # Mount the multitool partition
    mount_mt_partition

    if [ $? -ne 0 ]; then

        inform_wait "There has been an error mounting the MULTITOOL partition, auto-restore cannot continue"
        
        # Ensure data is written and unmount the partition
        sync
        unmount_mt_partition

        return 1

    fi

    if [ ! -f "${MOUNT_POINT}/auto_restore.flag" ]; then
        
        # Ensure data is written and unmount the partition
        sync
        unmount_mt_partition
        
        # No auto-restore file, nothing to do
        return 0
    
    fi

    BACKUP_FILENAME=$(cat "${MOUNT_POINT}/auto_restore.flag" | xargs)

    if [ -z "$BACKUP_FILENAME" ]; then

        inform_wait "No auto-restore file is defined, auto-restore cannot continue"
        
        # Ensure data is written and unmount the partition
        sync
        unmount_mt_partition
        
        # No auto-restore file, nothing to do
        return 0

    fi

    if [ [ "$FLAG_CONTENTS" != *.gz ] ]; then

        inform_wait "The auto-restore flag file does not contain a valid .gz filename, resetting it to empty."
        
        echo -n "" > "${MOUNT_POINT}/auto_restore.flag"

        # Ensure data is written and unmount the partition
        sync
        unmount_mt_partition

        return 1

    fi

    if [ ! -f "${MOUNT_POINT}/backups/${BACKUP_FILENAME}" ]; then

        inform_wait "The auto-restore file (${BACKUP_FILENAME}) does not exist, auto-restore cannot continue"
        
        # Ensure data is written and unmount the partition
        sync
        unmount_mt_partition

        return 1

    fi

    BASENAME=$(basename $BACKUP_FILENAME)

    RESTORE_SOURCE="${MOUNT_POINT}/backups/${BACKUP_FILENAME}"

    # Verify there is at least one suitable device
    if [ ${#DEVICES_MMC[@]} -eq 0 ]; then

        inform_wait "There are no eMMC devices suitable for auto-restore"

        # Ensure data is written and unmount the partition
        sync
        unmount_mt_partition

        # Not available
        return 3

    fi

    # TODO: Consider adding a device selection menu
    # but keep the first device as default

    # Select the first available device for restore
    RESTORE_DEVICE=${DEVICES_MMC[0]}

    # Extract device information
    DEVICE_BASENAME=$(basename $RESTORE_DEVICE)

    BLK_DEVICE=$(get_block_device $RESTORE_DEVICE)

    DEVICE_NAME=$(echo $DEVICE_BASENAME | cut -d ":" -f 1)

    # Get device size in sectors and convert to kilobytes
    DEVICE_SIZE=$(cat /sys/block/$BLK_DEVICE/size 2>/dev/null)

    DEVICE_SIZE=$((DEVICE_SIZE / 2)) # convert sectors to kilobytes
    
    # Set LED state to indicate activity
    set_led_state "$DEVICE_NAME"

    # Perform the restore operation with progress monitoring
    # Pipeline: read compressed backup -> decompress -> show progress -> write to device
    (dd if="$RESTORE_SOURCE" bs=256K | pigz -d | pv -n -s ${DEVICE_SIZE}K | dd of="/dev/$BLK_DEVICE" bs=512K iflag=fullblock oflag=direct 2>/dev/null) 2>&1 | dialog \
        --backtitle "$BACKTITLE" \
        --gauge "Restore of backup $BASENAME to device $BLK_DEVICE in progress, please wait..." 10 70 0

    # Capture the exit code from the restore operation
    ERR=$?

    # Ensure data is written and unmount the partition
    sync
    unmount_mt_partition

    # Check if the restore operation was successful
    if [ $ERR -ne 0 ]; then

        inform_wait "An error occurred ($ERR) restoring backup, process has not been completed"

        return 1

    fi

    # Show completion dialog with shutdown options
    dialog --backtitle "$BACKTITLE" \
        --timeout 10 \
        --yes-label "Shutdown now" \
        --no-label "Shutdown later" \
        --title "Auto-restore completed!" \
        --yesno "\nBackup restored to device $BLK_DEVICE\n\nIn 10 seconds the system will shutdown automatically" 10 70

    # Capture the exit code to know the decision
    EXIT_CODE=$?

    # If the exit code is 1 (user pressed "Shutdown Later"), do nothing.
    # If it is 0 (Shutdown Now) or 255 (Timeout/ESC), the system shuts down.
    if [ "$EXIT_CODE" -ne 1 ]; then
        do_shutdown
    fi

    return 0    

}

# Detects the compression format of an archive file
#
# This function tests a file against various compression formats (gzip, xz, bzip2, lzma)
# to determine which compression algorithm was used. It returns the format name as a string
# if successfully detected, or returns an error if the format is unknown or unsupported.
#
# @param string $1 The path to the archive file to test
# @return 0 on success (format name printed to stdout), 1 on failure/unknown format
# @author Paolo Sabatino
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

    bzip2 -t "$TARGET" >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        echo "bzip2"
        return 0
    fi

    lzma -t "$TARGET" >/dev/null 2>&1

    if [ $? -eq 0 ]; then
        echo "lzma"
        return 0
    fi

    return 1

}

# Generates the decompression command line for various archive formats
#
# This function analyzes an archive file and determines the appropriate
# decompression/extraction command line based on the archive type. It supports
# multiple formats including 7z, zip, tar (with various compressions), and
# single compressed files (gzip, xz, bzip2, lzma). For archives containing
# multiple files, it looks for .img files to extract.
#
# The function populates global variables:
# - D_COMMAND_LINE: The full command line for decompression
# - D_FORMAT: Description of the archive format
# - D_REAL_FILE: The actual filename being extracted (for archives)
# - D_ERROR_TEXT: Error message if extraction fails
#
# @param string $1 The path to the archive file
# @return 0 on success, 1 on failure (unsupported format or no .img file)
# @author Paolo Sabatino
function get_decompression_cli() {

    local TARGET=$1
    local FILES_LIST
    local CANDIDATE_STR
    local CANDIDATE_UNCOMPRESSED_SIZE
    local CANDIDATE_IMAGE
    local FORMAT
    local TAR_FORMAT_SWITCH

    # 7z archive

    FILES_LIST=$(7zr l -t7z "$TARGET" 2>/dev/null)

    if [[ $? -eq 0 ]]; then

        CANDIDATE_STR=$(grep -m 1 -i -e ".img$" <<< $FILES_LIST)

        if [[ "$CANDIDATE_STR" = "" ]]; then
            D_ERROR_TEXT="$ERROR_ARCHIVE_WITHOUT_IMG_FILE"
            return 1
        fi

        CANDIDATE_UNCOMPRESSED_SIZE=$(echo $CANDIDATE_STR | cut -d " " -f 4)
        CANDIDATE_IMAGE=$(echo $CANDIDATE_STR | cut -d " " -f 6)

        D_COMMAND_LINE="7zr e -bb0 -bd -so -mmt4 '$TARGET' '$CANDIDATE_IMAGE' | pv -n -s $CANDIDATE_UNCOMPRESSED_SIZE"
        D_FORMAT="7z archive"
        D_REAL_FILE="$CANDIDATE_IMAGE"

        return 0

    fi

    # Zip archive

    FILES_LIST=$(unzip -l "$TARGET" 2>/dev/null)

    if [[ $? -eq 0 ]]; then

        CANDIDATE_STR=$(grep -m 1 -i -e ".img$" <<< $FILES_LIST)

        if [[ "$CANDIDATE_STR" = "" ]]; then
            D_ERROR_TEXT="$ERROR_ARCHIVE_WITHOUT_IMG_FILE"
            return 1
        fi

        CANDIDATE_UNCOMPRESSED_SIZE=$(echo $CANDIDATE_STR | cut -d " " -f 1)
        CANDIDATE_IMAGE=$(echo $CANDIDATE_STR | cut -d " " -f 4)

        D_COMMAND_LINE="unzip -e -p '$TARGET' '$CANDIDATE_IMAGE' | pv -n -s $CANDIDATE_UNCOMPRESSED_SIZE"
        D_FORMAT="zip archive"
        D_REAL_FILE="$CANDIDATE_IMAGE"

        return 0

    fi

    # Try to understand if it is a common unix file format.
    FORMAT=$(get_compression_format $TARGET)

    # Now check if tar is able to give us a list of files.
    # If so, this is a tar archive and, maybe it is also compressed with some
    # standard unix pipe compressors. We look into for an .img file and select 
    # it as the target image
    FILES_LIST=$(tar taf "$TARGET" 2>/dev/null)

    if [[ $? -eq 0 ]]; then

        CANDIDATE_IMAGE=$(grep -m 1 -i -e ".img$" <<< $FILES_LIST)

        if [[ "$CANDIDATE_IMAGE" = "" ]]; then
            D_ERROR_TEXT="$ERROR_ARCHIVE_WITHOUT_IMG_FILE"
            return 1
        fi

        TAR_FMT_SWITCH=""

        [[ "$FORMAT" = "gzip" ]] && TAR_FMT_SWITCH="-z"
        [[ "$FORMAT" = "xz" ]] && TAR_FMT_SWITCH="-J"
        [[ "$FORMAT" = "bzip2" ]] && TAR_FMT_SWITCH="-j"
        [[ "$FORMAT" = "lzma" ]] && TAR_FMT_SWITCH="--lzma"

        D_COMMAND_LINE="pv -n '$TARGET' | tar -O -x ${TAR_FMT_SWITCH} -f - '$CANDIDATE_IMAGE'"
        D_FORMAT="tar archive"
        D_REAL_FILE="$CANDIDATE_IMAGE"

        return 0

    fi

    if [[ "$FORMAT" = "gzip" ]]; then
        D_COMMAND_LINE="pv -n '$TARGET' | pigz -d"
        D_FORMAT="gzip compressed image"
        return 0
    fi

    if [[ "$FORMAT" = "xz" ]]; then
        D_COMMAND_LINE="pv -n '$TARGET' | xz -d -T4"
        D_FORMAT="xz compressed image"
        return 0
    fi

    if [[ "$FORMAT" = "bzip2" ]]; then
        D_COMMAND_LINE="pv -n '$TARGET' | bzip2 -d -c"
        D_FORMAT="bzip2 compressed image"
        return 0
    fi

    if [[ "$FORMAT" = "lzma" ]]; then
        D_COMMAND_LINE="pv -n '$TARGET' | lzma -d -c"
        D_FORMAT="lzma compressed image"
        return 0
    fi

    D_COMMAND_LINE="pv -n '$TARGET'"
    D_FORMAT="raw image"

    return 0

}

# Restore an image and burns it onto an eMMC device
# This function handles the complete process of burning an image file to an MMC/eMMC device.
# It supports various archive formats (7z, zip, tar with compression, single compressed files)
# and automatically detects the format to use appropriate decompression tools.
# For special Rockchip NAND devices, it performs additional bootloader burning steps.
# The function provides progress monitoring during the burning process and handles
# DDR command rate preservation for compatible devices.
#
# @param None
# @return 0 on success, 1 on failure (error during burning or device operations)
# @author Paolo Sabatino
function do_burn() {

    # Verify there is at least one suitable device
    if [ ${#DEVICES_MMC[@]} -eq 0 ]; then

        inform_wait "There are no eMMC devices suitable for image burn"

        # Not available
        return 3

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

    # Mount the multitool partition
    mount_mt_partition

    if [ $? -ne 0 ]; then
        inform_wait "There has been an error mounting the MULTITOOL partition."
        unmount_mt_partition
        return 1
    fi

    # Search the images path on the MULTITOOL partition
    if [ ! -d "${MOUNT_POINT}/images" ]; then
        unmount_mt_partition
        inform_wait "There are no images on MULTITOOL partition."
        return 3
    fi

    IMAGES_COUNT=$(find "${MOUNT_POINT}/images" -type f -iname '*' 2>/dev/null | wc -l)
    
    if [ $IMAGES_COUNT -eq 0 ]; then
        unmount_mt_partition
        inform_wait "There are no images on MULTITOOL partition."
        return 3
    fi

    IMAGE_SOURCE=$(choose_file "Burn an image to $BLK_DEVICE" "Choose the source image file" "${MOUNT_POINT}/images/*")

    if [ $? -ne 0 ]; then
        unmount_mt_partition
        return 2
    fi

    BASENAME=$(basename $IMAGE_SOURCE)

    inform "Scanning the source image file, this could take a while, please wait..."

    get_decompression_cli $IMAGE_SOURCE

    if [[ $? -ne 0 ]]; then
        inform_wait "$D_ERROR_TEXT"
        unmount_mt_partition
        return 1
    fi

    SKIP_BLOCKS=0
    SEEK_BLOCKS=0
    IDBLOADER_SKIP=0

    # If the block device is rknand*, we look the signature of the source image and
    # in case we find the idbloader, we ask the user to skip the first 0x2000
    # sectors
    if [[ "$BLK_DEVICE" =~ "rknand" ]]; then

        SIGNATURE_CLI="$D_COMMAND_LINE | od -A none -j $((0x40 * 0x200)) -N 16 -tx1"
        SIGNATURE=$(eval "$SIGNATURE_CLI" 2>/dev/null)
    
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
    
    OPERATION_CLI="$D_COMMAND_LINE | dd of='/dev/$BLK_DEVICE' skip=$SKIP_BLOCKS seek=$SEEK_BLOCKS bs=512K iflag=fullblock oflag=direct 2>/dev/null"

    if [[ -n "$D_REAL_FILE" ]]; then
        OPERATION_TEXT="${BOLD}Source archive:${RESET} $BASENAME\n${BOLD}Source format:${RESET} $D_FORMAT\n${BOLD}Image file:${RESET} $D_REAL_FILE\n${BOLD}Destination:${RESET} $BLK_DEVICE\n\nOperation in progress, please wait..."
    else
        OPERATION_TEXT="${BOLD}Image file:${RESET} $BASENAME\n${BOLD}Source format:${RESET} $D_FORMAT\n${BOLD}Destination:${RESET} $BLK_DEVICE\n\nOperation in progress, please wait..."
    fi
    
    # Get the DDR command rate (if possible) from the target device
    # Note: only some platforms needs or support this. Keep the item as
    # a zero-length string to skip command rate writing later.
    COMMAND_RATE_VALUE=""
    
    if [[ $TARGET_CONF = "rk322x" ]]; then
        COMMAND_RATE_VALUE=$(get_command_rate "/dev/$BLK_DEVICE")
    fi

    (eval "$OPERATION_CLI") 2>&1 | dialog \
        --colors \
        --backtitle "$BACKTITLE" \
        --gauge "$OPERATION_TEXT" 18 70 0

    ERR=$?

    if [ $ERR -ne 0 ]; then
        unmount_mt_partition
        inform_wait "An error occurred ($ERR) while burning image, process has not been completed"
        return 1
    fi
    
    # In case idbloader is written, rewrite the command rate if possible
    if [[ $IDBLOADER_SKIP -eq 0 ]]; then
    
        [[ -n "$COMMAND_RATE_VALUE" ]] && set_command_rate "/dev/$BLK_DEVICE" "$COMMAND_RATE_VALUE"
    
    fi
    
    # In case idbloader is skipped, we also copy the first 64 sectors from the source image
    # to restore the partition table. It should be safe.
    if [ $IDBLOADER_SKIP -eq 1 ]; then

        inform "Restoring partition table and installing custom u-boot loader. This will take a moment..."
        
        OPERATION_CLI="$D_COMMAND_LINE 2>/dev/null | dd of='/dev/$BLK_DEVICE' bs=32k count=1 iflag=fullblock oflag=direct 2>/dev/null"
        (eval "$OPERATION_CLI")

        ERR=$?

        if [ $ERR -ne 0 ]; then
            unmount_mt_partition
            inform_wait "An error occurred ($ERR) while restoring partition table, image may not boot"
            return 1
        fi

        dd if="${MOUNT_POINT}/bsp/legacy-uboot.img" of="/dev/$BLK_DEVICE" bs=4M seek=1 oflag=direct >/dev/null 2>&1
            ERR=$?

        if [ $ERR -ne 0 ]; then
            unmount_mt_partition
            inform_wait "An error occurred ($ERR) while burning bootloader on device, image may not boot"
            return 1
        fi
                
    fi

    unmount_mt_partition

    inform_wait "Image has been burned to device $BLK_DEVICE"

    return 0

}

# Install Armbian image via steP-nand method for NAND devices
# This function handles the installation of Armbian images to NAND-based devices using
# the steP-nand approach. It performs special sector offset handling for NAND devices,
# creates GPT partition tables, and installs legacy bootloader and TEE components.
# The function supports various archive formats and provides progress monitoring.
#
# @param None
# @return 0 on success, 1 on error, 2 on user cancellation, 3 if no images available
# @author Paolo Sabatino
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

    # Mount the multitool partition
    mount_mt_partition

    if [ $? -ne 0 ]; then
        inform_wait "There has been an error mounting the MULTITOOL partition."
        unmount_mt_partition
        return 1
    fi

    # Search the images path on the MULTITOOL partition
    if [ ! -d "${MOUNT_POINT}/images" ]; then
        unmount_mt_partition
        inform_wait "There are no images on MULTITOOL partition."
        return 3
    fi

    IMAGES_COUNT=$(find "${MOUNT_POINT}/images" -type f -iname '*' 2>/dev/null | wc -l)
    
    if [ $IMAGES_COUNT -eq 0 ]; then
        unmount_mt_partition
        inform_wait "There are no images on MULTITOOL partition."
        return 3
    fi

    IMAGE_SOURCE=$(choose_file "Burn Armbian image via steP-nand to $BLK_DEVICE" "Choose the source image file" "${MOUNT_POINT}/images/*")

    if [ $? -ne 0 ]; then
        unmount_mt_partition
        return 2
    fi

    BASENAME=$(basename $IMAGE_SOURCE)

    inform "Scanning the source image file, this could take a while, please wait..."

    get_decompression_cli $IMAGE_SOURCE

    if [[ $? -ne 0 ]]; then
        inform_wait "$D_ERROR_TEXT"
        unmount_mt_partition
        return 1
    fi

    set_led_state "$DEVICE_NAME"

    # Armbian rootfs must be copied from sector 0x2000, which is naturally allocated,
    # to sector 0x8000 on NAND. That is so because the first 0x8000 sectors are used
    # for legacy u-boot and trustos.
    OPERATION_CLI="$D_COMMAND_LINE | dd of='/dev/$BLK_DEVICE' skip=8 seek=32 bs=512K iflag=fullblock oflag=direct 2>/dev/null"

    if [[ -n "$D_REAL_FILE" ]]; then
        OPERATION_TEXT="${BOLD}Source archive:${RESET} $BASENAME\n${BOLD}Source format:${RESET} $D_FORMAT\n${BOLD}Image file:${RESET} $D_REAL_FILE\n${BOLD}Destination:${RESET} $BLK_DEVICE\n\nOperation in progress, please wait..."
    else
        OPERATION_TEXT="${BOLD}Image file:${RESET} $BASENAME\n${BOLD}Source format:${RESET} $D_FORMAT\n${BOLD}Destination:${RESET} $BLK_DEVICE\n\nOperation in progress, please wait..."
    fi

    (eval "$OPERATION_CLI") 2>&1 | dialog \
        --colors \
        --backtitle "$BACKTITLE" \
        --gauge "$OPERATION_TEXT" 18 70 0

    ERR=$?

    if [ $ERR -ne 0 ]; then
        unmount_mt_partition
        inform_wait "An error occurred ($ERR) while burning image, process has not been completed"
        return 1
    fi

    inform "Installing legacy bootloader and creating GPT partitions, this will take a moment ..."

    dd if="${MOUNT_POINT}/bsp/legacy-uboot.img" of="/dev/$BLK_DEVICE" bs=4M seek=1 oflag=direct >/dev/null 2>&1
   
    ERR=$?

    if [ $ERR -ne 0 ]; then
        unmount_mt_partition
        inform_wait "An error occurred ($ERR) while burning bootloader on device, process has not been completed"
        return 1
    fi

    dd if="${MOUNT_POINT}/bsp/trustos.img" of="/dev/$BLK_DEVICE" bs=4M seek=2 oflag=direct >/dev/null 2>&1
    
    ERR=$?

    if [ $ERR -ne 0 ]; then
        unmount_mt_partition
        inform_wait "An error occurred ($ERR) while burning TEE on device, process has not been completed"
        return 1
    fi

    sync
    sleep 1

    # Create the GPT partition table and a partition starting from sector 0x8000
    # Note: we need to manually clear the MBR because sgdisk complaints if it finds
    # an existing partition table, even with --zap-all argument
    # TODO: fix the 4G size with the real origin partition size
    dd if=/dev/zero of="/dev/$BLK_DEVICE" bs=32k count=1 conv=sync,fsync >/dev/null 2>&1
    sgdisk -o "/dev/$BLK_DEVICE" >/dev/null 2>&1
    sgdisk --zap-all -n 0:32768:+4G "/dev/$BLK_DEVICE" >/dev/null 2>&1

    ERR=$?

    if [ $ERR -ne 0 ]; then
        unmount_mt_partition
        inform_wait "An error occurred ($ERR) while creating GPT partition table, process has not been completed"
        return 1
    fi

    unmount_mt_partition

    inform_wait "Image has been burned to device $BLK_DEVICE"

    return 0

}

# Erase an MMC device completely
# This function securely erases MMC/eMMC devices using the most efficient method available.
# It first attempts to use blkdiscard (MMC erase command) for fast, secure erasure,
# then falls back to overwriting with zeros using dd and pv for progress monitoring.
# The function provides visual feedback and handles device selection through dialog menus.
#
# @param None
# @return 0 on success, 2 on user cancellation, 3 if no suitable devices available
# @author Paolo Sabatino
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

# Install jump start for Armbian on NAND devices
# This function performs a jump start installation for Armbian on NAND-based devices.
# It transfers the bootloader and TEE (Trusted Execution Environment) from the boot device
# to specific NAND sectors, enabling the device to boot Armbian. The function requires
# user confirmation and provides feedback during the transfer process.
#
# @param None
# @return 0 on success, 1 on transfer error, 2 on user cancellation
# @author Paolo Sabatino
function do_install_jump_start() {

    dialog --backtitle "$BACKTITLE" --yesno "$JUMPSTART_WARNING" 0 0

    if [ $? -ne 0 ]; then
        return 2
    fi

    inform "Transferring boot loader, please wait..."

    dd if="$BOOT_DEVICE" of=/dev/rknand0 skip=$((0x4000)) seek=$((0x2000)) count=$((0x4000)) conv=sync,fsync >/dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        inform_wait "Could not transfer U-boot on NAND device"
        return 1
    fi

    dd if="$BOOT_DEVICE" of=/dev/rknand0 skip=$((0x8000)) seek=$((0x6000)) count=$((0x4000)) conv=sync,fsync >/dev/null 2>&1
    
    if [ $? -ne 0 ]; then
        inform_wait "Could not transfer TEE on NAND device"
        return 1
    fi

    sync
    
    sleep 1

    inform_wait "Jump start installed!"

    return 0

}

# Change DDR Command Rate timing value on MMC devices
# This function allows users to modify the DDR command rate timing on compatible MMC devices.
# It reads the current timing value, presents a menu to select between 1T and 2T timing,
# and applies the change. This is useful for optimizing device performance or compatibility.
# The function handles device selection and provides user feedback throughout the process.
#
# @param None
# @return 0 on success, 1 on error (can't read/write timing), 2 on user cancellation
# @author Paolo Sabatino
function do_change_command_rate() {

    inform_wait "$COMMAND_RATE_WARNING"
    
    TITLE="Alter Command Rate timing value"

    TARGET_DEVICE=$(choose_mmc_device "$TITLE" "Select destination device:" $DEVICES_MMC)

    if [ $? -ne 0 ]; then
        return 2 # User cancelled
    fi

    if [ -z "$TARGET_DEVICE" ]; then
        return 2 # No restore device, user cancelled?
    fi
    
    BASENAME=$(basename $TARGET_DEVICE)
    BLK_DEVICE=$(get_block_device $TARGET_DEVICE)
    
    # Read existing command rate from the target device.
    # If we can't read, we inform the user that, since the command rate
    # cannot be read, it cannot be set also
    COMMAND_RATE_VALUE=$(get_command_rate "/dev/${BLK_DEVICE}")
    
    if [[ -z $COMMAND_RATE_VALUE ]]; then
        inform_wait "Can't read current Command Rate value from the device $BLK_DEVICE\n\nCommand Rate cannot be changed."
        return 1
    fi
    
    declare -a CHOICE_ITEMS

    MENU_TITLE="$COMMAND_RATE_WARNING\n\nCurrent Command Rate value is ${RED}${COMMAND_RATE_VALUE}${NC}"
    CHOICE_ITEMS+=("1T" "1 clock cycle")
    CHOICE_ITEMS+=("2T" "2 clock cycles")
    
    CHOICE_CMD=(dialog --colors --backtitle "$BACKTITLE" --title "$TITLE" --menu "$MENU_TITLE" 24 74 18)
    
    CHOICE=$("${CHOICE_CMD[@]}" "${CHOICE_ITEMS[@]}" 2>&1 >$TTY_CONSOLE)    
    
    if [ $? -ne 0 ]; then
        return 2 # User cancelled
    fi
    
    set_command_rate "/dev/${BLK_DEVICE}" "$CHOICE"
    
    if [[ $? -ne 0 ]]; then
        inform_wait "An error occurred altering Command Rate timing value"
        return 1
    fi
    
    inform_wait "Command Rate timing value has been changed"
    
    return 0

}

# ----- Entry point -----

# Mount the multitool partition
mount_mt_partition

ISSUE=$(</mnt/ISSUE)
TARGET_CONF=$(</mnt/TARGET)

BACKTITLE="$BACKTITLE - Platform: $TARGET_CONF - Build: $ISSUE"

# Show the credits, that can be hold by the user to read them carefull
# or it can be agreed and closed, or it can be timed out after 5 seconds
dialog --backtitle "$BACKTITLE" \
       --title "License Agreement" \
       --timeout 5 \
       --yes-label "I Agree" \
       --no-label "See License" \
       --yesno "\nBy proceeding, you agree to the software license terms.\n\nPress 'See License' to read the full terms." 10 70

EXIT_CODE=$?

# If the user pressed cancel (hold), we show the credits again and wait for her
# to press ok
if [ "$EXIT_CODE" -eq 1 ]; then

    dialog --backtitle "$BACKTITLE" \
        --exit-label "I Agree" \
        --textbox "${MOUNT_POINT}/CREDITS" 0 0

fi

# Detect available eMMC devices
find_mmc_devices

# Detect special devices (NAND, SPI, etc)
find_special_devices

# Store the name of the auto-restore file
FLAG_FILE="${MOUNT_POINT}/auto_restore.flag"

# Check if the auto-restore flag exists
if [ -f "$FLAG_FILE" ]; then

    # Read the flag contents and remove whitespace
    FLAG_CONTENTS=$(cat "$FLAG_FILE" | xargs)

    # Check if the content is not empty
    if [ -n "$FLAG_CONTENTS" ]; then

        if [ [ "$FLAG_CONTENTS" != *.gz ] ]; then

            inform_wait "\nThe auto-restore file ($FLAG_CONTENTS) is not a valid backup file (must end with .gz).\n\nThe flag file will be cleared."

            # Clear the auto-restore configuration
            echo -n "" > "$FLAG_FILE"

        else

            # Check if the file specified in the flag exists
            RESTORE_FILE="${MOUNT_POINT}/backups/${FLAG_CONTENTS}"

            # If the file exists, start the restoration process
            if [ -f "$RESTORE_FILE" ]; then

                dialog --backtitle "$BACKTITLE" \
                    --timeout 10 \
                    --yes-label "Proceed" \
                    --no-label "Cancel" \
                    --title "Auto-Restore Backup" \
                    --yesno "\nAn auto-restore operation is configured.\n\nBackup file: $FLAG_CONTENTS\n\nIn 10 seconds the restore will start automatically.\n\nPress 'Cancel' to abort the auto-restore." 15 70

                EXIT_CODE=$?

                # If the exit code is 1 (user pressed "Cancel"), do nothing.
                if [ "$EXIT_CODE" -ne 1 ]; then

                    do_auto_restore

                fi

            fi

        fi

    fi

# If the flag file does not exist, create it
else

    # Create an empty flag file
    echo -n "" > "$FLAG_FILE"

fi

# Unmount the multitool partition
sync
unmount_mt_partition

declare -a MENU_ITEMS

MENU_ITEMS+=(1 "Backup flash")

MENU_ITEMS+=(2 "Restore flash")

MENU_ITEMS+=(3 "Erase flash")

MENU_ITEMS+=(4 "Drop to Bash shell")

MENU_ITEMS+=(5 "Burn image to flash")

MENU_ITEMS+=(6 "Configure auto restore file image")

MENU_ITEMS+=(7 "Show Current Auto-Restore")

[[ "${DEVICES_MMC[@]}" =~ "nandc" ]] && MENU_ITEMS+=(8 "Install Jump start on NAND")

[[ "${DEVICES_MMC[@]}" =~ "nandc" ]] && MENU_ITEMS+=(9 "Install Armbian via steP-nand")

[[ ! "${DEVICES_MMC[@]}" =~ "nandc" && "${TARGET_CONF}" = "rk322x" ]] && MENU_ITEMS+=(A "Change DDR Command Rate")

MENU_ITEMS+=(B "Reboot")

MENU_ITEMS+=(C "Shutdown")

MENU_CMD=(dialog --backtitle "$BACKTITLE" --title "$TITLE_MAIN_MENU" --menu "Choose an option" 24 74 18)

while true; do

    set_led_state "timer"

    CHOICE=$("${MENU_CMD[@]}" "${MENU_ITEMS[@]}" 2>&1 >$TTY_CONSOLE)

    CHOICE=${CHOICE:-0}

    if [[ $CHOICE = "0" ]]; then
	break
    elif [[ $CHOICE = "1" ]]; then
        do_backup
    elif [[ $CHOICE = "2" ]]; then
        do_restore
    elif [[ $CHOICE = "3" ]]; then
        do_erase_mmc
    elif [[ $CHOICE = "4" ]]; then
        do_give_shell
    elif [[ $CHOICE = "5" ]]; then
        do_burn
    elif [[ $CHOICE = "6" ]]; then
        set_auto_restore
    elif [[ $CHOICE = "7" ]]; then
        show_current_auto_restore
    elif [[ $CHOICE = "8" ]]; then
        do_install_jump_start
    elif [[ $CHOICE = "9" ]]; then
        do_install_stepnand
    elif [[ $CHOICE = "A" ]]; then
        do_change_command_rate
    elif [[ $CHOICE = "B" ]]; then
        do_reboot
    elif [[ $CHOICE = "C" ]]; then
        do_shutdown
    fi

done

clear