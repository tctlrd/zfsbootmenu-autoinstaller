# ZFSBootMenu Installation Script

This script automates the installation and configuration of ZFSBootMenu on a Linux system from a live installation environment. It has been tested on Debian and sets up a ZFS root with EFI boot using ZFSBootMenu.

## Prerequisites

- A live installation environment (e.g., Debian Live)
- A disk available for partitioning and installation (existing data will be erased)
- Network connection for downloading packages and files

## Features

- Configures Debian repositories and installs necessary packages
- Creates and configures ZFS partitions and filesystems
- Sets up ZFSBootMenu for EFI boot
- Adds a user with sudo privileges and configures the system for basic usage

## Usage

1. **Run the Script**  
   Boot into your live environment, open a terminal, run the following to start the script

   ```bash
   wget https://raw.githubusercontent.com/sartirious/zfsbootmenu-autoinstaller/refs/heads/main/setup-zfsbootmenu.sh
   chmod +x setup-zfsbootmenu.sh
   ./setup-zfsbootmenu.sh
   ```

3. **Follow Prompts**  
   - The script will prompt you for:
     - **Username** and **password** for a new user
     - **Root password**
     - **Hostname**
     - **Disk selection** for the boot and pool partitions

4. **Automatic Steps**  
   - The script will automatically:
     - Configure APT sources
     - Install required packages
     - Partition the selected disk
     - Create and configure ZFS pool and datasets
     - Set up a chroot environment
     - Install and configure ZFSBootMenu and EFI boot entries
     - Perform cleanup

5. **Completion**  
   - After running, the system is ready to reboot into the new ZFSBootMenu setup.

## Configuration

This script sets default variables for installation, including:

- `BOOT_DISK`: Device for the boot partition (default `/dev/nvme0n1`)
- `POOL_DISK`: Device for the ZFS pool (default `/dev/nvme0n1`)
- `POOL_NAME`: Name of the ZFS pool (default `zroot`)

You can modify these defaults directly in the script if needed.

## Important Notes

- **Warning**: This script will erase all data on the selected disk.
- **Compatibility**: This script has been tested on Debian. Usage on other distributions may require modifications.
- **Network**: Ensure a working internet connection, as the script will download packages.

## Troubleshooting

- **Permissions**: Run the script with `sudo` to ensure it has the necessary permissions.
- **Disk Selection**: If no suitable disks are shown, confirm your disks are properly detected (`lsblk` can help).

## License

This script is provided as-is. Feel free to modify and adapt it to suit your needs.
