#!/bin/sh
#
# CC0 - Konrad Förstner <konrad@foerstner>, 2020
# https://creativecommons.org/publicdomain/zero/1.0/legalcode.txt
# 
# The code was build using the following sources:
# - https://qfpl.io/posts/installing-nixos/ 
# - https://discourse.nixos.org/t/nixos-on-luks-encrypted-partition-with-zfs-and-swap/6873/4
# - https://www.rodsbooks.com/gdisk/sgdisk-walkthrough.html
# - https://fedoramagazine.org/managing-partitions-with-sgdisk/
# - https://linuxconfig.org/list-of-filesystem-partition-type-codes
#
# Structure for the disc
# - partion 1 => Boot
# - partition 2 => LVM (LUKS Container)
#    cryptroot
#   - lvmvg-swap - swap
#   - lvmvg-root - system
#
# e.g.
# $ lsblk
# NAME                 MAJ:MIN RM  SIZE RO TYPE  MOUNTPOINT
# nvme0n1              259:0    0  1.8T  0 disk  
# ├─nvme0n1p1          259:1    0    1G  0 part  /boot
# └─nvme0n1p2          259:2    0  1.8T  0 part  
#   └─root             254:0    0  1.8T  0 crypt 
#     ├─nixos--vg-swap  254:1    0   16G  0 lvm   [SWAP]
#     └─nixos--vg-root 254:2    0  1.8T  0 lvm   /

set -o errexit
set -o nounset
set -o pipefail

main(){
    # Use lsblk - to show available discs
    # Set!
    readonly DISK=/dev/sda  # e.g /dev/sda or /dev/nvme0n1
    readonly USER_NAME=my_awesome_user_name
    readonly SWAP_SIZE=16G
    # readonly LUKS_PASSWORD="XXX" # TODO - does not work    
    
    readonly BOOT_PARTITION=${DISK}1
    readonly LVM_PARTITION=${DISK}2
    readonly SYSTEM_VOLUME=${DISK}2p2 # maybe needs adapation
    readonly TMP_CONFIG_PATH=/mnt/etc/nixos/configuration.nix

    if [ ${#@} -eq 0 ]
    then
	print_help
    else for FUNCTION in "$@"
	 do
	     "${FUNCTION}"
	 done
    fi
}

print_help(){
    echo "Specify function to call - options:"
    echo "- generate_partitions"
    echo "- generate_luks_volume_and_format"
    echo "- mount_fs_and_generate_config"
    echo "- adapt_config"
    echo "- install_nixos"
    echo ""
    echo "or use 'all' to run all the functions"
    echo ""
    echo "Make sure the variable in the script are properly set!"
}

all(){
    generate_partitions
    generate_luks_volume_and_format
    mount_fs_and_generate_config
    adapt_config
    install_nixos
}

generate_partitions(){

    echo "Generate partitions"
    
    # Remove previous partitions
    wipefs -af "$DISK"
    sgdisk -Zo "$DISK"

    # Important for understanding this : For the tool sgdisk the "0"
    # has a special meaning as described here:
    # https://fedoramagazine.org/managing-partitions-with-sgdisk/
    # - partition number field: 0 is placeholder for next available
    #   number (starts at 1)
    # - starting address field: 0 start of the largest available block
    #   of free space
    # - ending address field: 0 is placeholder for the end of the
    #   largest available block of free

    # Create EFI boot partition
    sgdisk -n 0:0:+1G -t 0:EF00 ${DISK}

    # Create LVM partition
    sgdisk -n 0:0:0 -t 0:8e00 ${DISK}
}

generate_luks_volume_and_format(){

    echo "Generate LUKS volumes and format them"
    
    # Generatee LUKS volume
    ### TODO: Use password stored in a variable
    ### echo "${LUKS_PASSWORD}" | cryptsetup luksFormat ${LVM_PARTITION} - # Does not work
    cryptsetup luksFormat ${LVM_PARTITION}
    
    # Decrypt the encrypted partition and call it nixos-enc. The
    # decrypted partition will get mounted at /dev/mapper/nixos-enc
    ### TODO: Use password stored in a variable
    ### echo "${LUKS_PASSWORD}" | cryptsetup luksOpen ${LVM_PARTITION} nixos-enc - # Does not work
    cryptsetup luksOpen ${LVM_PARTITION} nixos-enc

    # Create the LVM physical volume using nixos-enc
    pvcreate /dev/mapper/nixos-enc 
    
    # Create a volume group that will contain our root and swap partitions
    vgcreate nixos-vg /dev/mapper/nixos-enc

    # Create a swap partition labeled "swap"
    lvcreate -L ${SWAP_SIZE} -n swap nixos-vg

    # Create a logical volume labeled "root" for the root filesystem
    # using the remaining free space.
    lvcreate -l "100%FREE" -n root nixos-vg

    # Format boot partition with fat32
    mkfs.vfat -n boot ${BOOT_PARTITION}

    # Format root partition as ext4
    mkfs.ext4 -L nixos /dev/nixos-vg/root

    # Create swap file system
    mkswap -L swap /dev/nixos-vg/swap

    # Switch swap on
    swapon /dev/nixos-vg/swap
}

mount_fs_and_generate_config(){
    
    echo "Mount file system and generater configuration file"
    
    mount /dev/nixos-vg/root /mnt
    mkdir /mnt/boot
    mount $BOOT_PARTITION /mnt/boot
    nixos-generate-config --root /mnt
}

adapt_config(){
    # Makes some very minor adaptions to the configuration
    # file. Should later be further extended after installation has
    # finished.
    
    echo "Adapting ${TMP_CONFIG_PATH}"
    
    # Remove the closing curly bracket
    sed -i "s/^}//" ${TMP_CONFIG_PATH} 
    
    cat << EOF >> ${TMP_CONFIG_PATH}
# LVM needs to be descrypted 
boot.initrd.luks.devices = {
  root = { 
    device = "${LVM_PARTITION}";
    preLVM = true;
  };
};

EOF

    cat << EOF >> ${TMP_CONFIG_PATH}
networking.networkmanager.enable = true;

EOF

    cat << EOF >> ${TMP_CONFIG_PATH}
users.extraUsers.${USER_NAME} = {
  createHome = true;
  extraGroups = ["wheel" "video" "audio" "disk" "networkmanager"];
  group = "users";
  home = "/home/${USER_NAME}";
  isNormalUser = true;
  uid = 1000;
};

EOF

    cat << EOF >> ${TMP_CONFIG_PATH}
services.xserver = {
    enable = true;
    autorun = true;
    layout = "de";

    desktopManager = {
      xterm.enable = false;
    };
   
    displayManager = {
        defaultSession = "none+i3";
	lightdm.enable = true;
    };

    windowManager.i3 = {
      enable = true;
    };
};

EOF
    
    # Add closing curly bracekt
    echo "}" >> ${TMP_CONFIG_PATH}
    
}
    
install_nixos(){

    echo "Install NixOS"
    
    nixos-install
    echo "Done - will reboot in 10 sec"
    sleep 10
    reboot
}

main "$@"
