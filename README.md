# Multitool
SD/eMMC card helper Multitool for TV boxes and alike

# Building

This assumes a Debian-derived system, adapt to your system as appropriate. First, install required packages:
```sh
sudo apt install multistrap squashfs-tools parted dosfstools ntfs-3g dialog
```

Fetch the source code:
```sh
git clone https://github.com/paolosabatino/multitool
```

Then build an image for the appropriate board (root is required, as the script must have enough permissions to set up and manipulate loop devices for the target image):
```sh
sudo ./create_image.sh
```

The script will present an interactive menu to select the target board configuration from the available `sources/*.conf` files. The resulting image can be found at `dist-$board/multitool.img`.

# Logging

Build logs are written to the `logs/` directory under the project root, named `build-YYYYMMDD-HHMMSS-{board}.log`. Logs include all commands executed, their output, and a summary with partition PARTUUIDs and build duration. The last 10 logs are kept automatically.

# Cleanup

The script registers a cleanup handler that automatically unmounts any loop devices and temporary mount points on exit, including on failure. No manual cleanup should be necessary in case of a failed build.