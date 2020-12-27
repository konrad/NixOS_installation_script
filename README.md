# NixOS installation script

Plain NixOS installation shell script to prepare a drive with LVM and
LUKS (full disc encryption) and to install a very basic NixOS system.

Boot the [NixOS install iso](https://nixos.org/download.html), copy
the script `install_nixos.sh` into the system and adapt variables in
the script as needed. The run the script:

```
sudo sh install_nixos.sh all
```

Alternatively, you can run its steps separately.

```
sudo sh install_nixos.sh generate_partitions
sudo sh install_nixos.sh generate_luks_volume_and_format
sudo sh install_nixos.sh mount_fs_and_generate_config
sudo sh install_nixos.sh adapt_config
sudo sh install_nixos.sh install_nixos
```
