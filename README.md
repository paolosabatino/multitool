# multitool
SD/eMMC card helper Multitool for TV boxes and alike

# Building

This assumes a Debian-derived system, adapt to your system as appropriate. First, install required packages:
```sh
sudo apt install multistrap squashfs-tools parted dosfstools ntfs-3g
```

Fetch the source code:
```sh
git clone https://github.com/paolosabatino/multitool
```

Then build an image for the appropriate board (root is required, as the script must have enough permissions to set up and manipulate loop devices for the target image):
```sh
sudo ./create_image.sh $board
```
See `sources/*.conf` for supported board configurations; the resulting image can be found at `dist-$board/multitool.img`.
