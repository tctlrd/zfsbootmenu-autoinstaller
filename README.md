# ZFSBootMenu Installation Script

This script automates the installation and configuration of ZFSBootMenu on a Linux system from a live installation environment. It has been tested on Debian and sets up a ZFS root with EFI boot using ZFSBootMenu.

## Prerequisites

- A live installation environment (e.g., Debian Live)
- A disk available for partitioning and installation (existing data will be erased)
- Network connection for downloading packages and files
- UEFI boot mode enabled

## Features

- Configures Debian repositories and installs necessary packages
- Creates and configures ZFS partitions and filesystems
- Fully encrypts your zfs pool and root filesystem with a passphrase
- Local or remote (via ssh) entry of encryption passphrase during bootloader to boot
- Sets up ZFSBootMenu for EFI boot
- Adds a user with sudo privileges and configures the system for basic usage
- Configures SSH and other basic system settings
- Optionally installs Proxmox: Virtual Environment, Backup Server, or Mail Gateway


## Usage

1. **Run the Script**  

   Debian Live ISO images are available here: https://cdimage.debian.org/debian-cd/current-live/amd64/iso-hybrid/  
   I usually use the `standard` version.

   Boot into your live environment, get root access, setup ssh (optional).

   ```bash
   sudo -i
   ```
   Optionally setup ssh and connect via ssh for next step.
   ```
   apt install -y ssh
   echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIE3TtIL0HYZxtIwJ0dp3VE33+IBgoUthd0zrSoB3viih root@example" > .ssh/authorized_keys
   ```

   Download and run the script:
   ```bash
   wget https://raw.githubusercontent.com/tctlrd/zfsbootmenu-autoinstaller/refs/heads/main/setup-zfsbootmenu.sh
   chmod +x setup-zfsbootmenu.sh
   ./setup-zfsbootmenu.sh
   ```

## Configuration
The script will promt for essential variables that have not been set.   
You can set variables for the script by creating an `install.env` file with the desired values.  
There is an `example.install.env` file in the repository and browsing the install script will show you all the variables that can be set.

## Remote Disk Unlock
Connect with ssh and use port 222  
Enter "zbm" when prompted.  
Enter your passphrase.  
Hit enter to boot the selected drive.

```
ssh root@10.0.0.7 -p 222
zfsbootmenu ~ > zbm
Enter passphrase for 'zroot': enter_your_passphrase_here
```

## Addon Setup
This only applies if you enable a proxmox addon.  
Upon first boot and login the proxmox addon installation will start automatically.  
If it does not, or fails, you may need to manually (re-)run the script `./root/[pve|pbs|pmg]-setup.sh`   
After they complete, perform a reboot. Make sure your network config and /etc/hosts file are correct.  
If you are running Proxmox VE, the /etc/hosts file needs to contain the machine's ip and hostname for Proxmox VE to start correctly; 127.0.1.1 is not sufficient...    
`10.0.0.7 hostname`

## Important Notes

- **Warning**: This script will erase all data on the selected disk.
- **Compatibility**: This script has been tested on Debian. Usage on other distributions will require modifications.
- **Network**: Ensure a working internet connection, as the script will download packages.

## Troubleshooting

- **Permissions**: Run the script under root user to ensure it has the necessary permissions `sudo -i`.
- **Disk Selection**: If no suitable disks are shown, confirm your disks are properly detected (`lsblk` can help).

## License

This script is provided as-is. Feel free to modify and adapt it to suit your needs.
