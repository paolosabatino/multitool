#!/bin/bash

# In case of SSH session, TTY console is the SSH allocated PTY, otherwise
# use the regular TTY foreground terminal
if [[ -n "$SSH_TTY" ]]; then
	TTY_CONSOLE="$SSH_TTY"
else
	TTY_CONSOLE="/dev/tty$(fgconsole)"
fi

BACKTITLE="SD/eMMC/NAND card helper Multitool for TV Boxes and alike - Paolo Sabatino"
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

# Mounts MULTITOOL partition on /mnt to allow operations on it
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

# Unmounts MULTITOOL partition
function unmount_mt_partition() {

    umount "$MOUNT_POINT" 2>/dev/null

    return 0

}

# Creates the directory "backups" on the MULTITOOL mount point if it does not already exists.
# Requires the MULTITOOL partition to be already mounted
function prepare_backup_directory() {

    mkdir -p "$MOUNT_POINT/backups"

    if [ $? -ne 0 ]; then
        return 1
    fi

    return 0

}

# Get the command rate offset, looking into the specified image file/device.
# Exit code is 0 and value is given is stdout if successful
# Exit code is 1 in case of failure
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

# Try to get the command rate bit from an existing image. 
# First argument is the target image device/file 
# Exit code is 0 if Command rate is found, 1 if it could not be found.
# Command Rate is returned as 1T or 2T string
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

# Given a target file/device, write the command rate bit to the proper place.
# The function searches for the signature and write the command rate bit only
# after verifying the signature and existing value match, otherwise fails
# First argument is device/file to act over
# Second argument is command rate value (1T or 2T as string)
# Exit code is 0 if successful, 1 if it fails
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

# Test the compression format for an archive
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

# Given a file as first argument, returns the decompressor command line
# also exit code is 0 if the decompressor supports input file from stdin
# otherwise returns 1
# Also populates D_FORMAT, D_COMMAND_LINE, D_REAL_FILE and D_ERROR_TEXT
# global variables to be used by the caller
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

# Give a shell to the user
function do_give_shell() {

    echo -e "Drop to a bash shell. Exit the shell to return to Multitool\n"

    /bin/bash -il

}

function do_reboot() {

    unmount_mt_partition

    sleep 1

    echo b > /proc/sysrq-trigger

}

function do_shutdown() {

    unmount_mt_partition

    sleep 1

    echo o > /proc/sysrq-trigger

}

# ----- Entry point -----

mount_mt_partition

ISSUE=$(</mnt/ISSUE)
TARGET_CONF=$(</mnt/TARGET)

BACKTITLE="$BACKTITLE - Platform: $TARGET_CONF - Build: $ISSUE"

dialog --backtitle "$BACKTITLE" \
    --textbox "/mnt/LICENSE" 0 0

unmount_mt_partition

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
[[ ! "${DEVICES_MMC[@]}" =~ "nandc" && "${TARGET_CONF}" = "rk322x" ]] && MENU_ITEMS+=(A "Change DDR Command Rate")
MENU_ITEMS+=(8 "Reboot")
MENU_ITEMS+=(9 "Shutdown")

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
        do_install_jump_start
    elif [[ $CHOICE = "7" ]]; then
        do_install_stepnand
    elif [[ $CHOICE = "A" ]]; then
        do_change_command_rate
    elif [[ $CHOICE = "8" ]]; then
        do_reboot
    elif [[ $CHOICE = "9" ]]; then
        do_shutdown
    fi

done

clear

