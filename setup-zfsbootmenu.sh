#!/bin/bash

# Automatically set other variables
TIMEZONE="America/Chicago"
BOOT_DISK="/dev/vda"
BOOT_PART="1"
POOL_DISK="/dev/vda"
POOL_PART="2"
POOL_NAME="zroot"
KERNEL_VERSION=$(uname -r)  # Automatically get current kernel version
MNT_P="/mnt"
ID=$(source /etc/os-release && echo "$ID")  # Get OS ID from /etc/os-release
export DEBIAN_FRONTEND=noninteractive

get_username_and_password(){
  # Prompt user for variables
  read -p "Enter root password: " ROOT_PASSWORD
  echo
  read -p "Enter encryption passphrase: " ENC_PHRASE
  echo
  read -p "Enter hostname for this system: " HOSTNAME
}

select_disk() {
  echo "Available disks:"
  # List available disks with lsblk and store them in an array
  mapfile -t disks < <(lsblk -dn -o NAME,WWN,TYPE,SIZE | grep 'disk' | awk '{print $1,"wwn-" $2,$3,$4}')

  # Display disks with numbering
  for i in "${!disks[@]}"; do
    echo "$((i + 1)). ${disks[i]}"
  done

  # Prompt user to select a disk by number
  while true; do
    read -p "Enter the number of the disk you want to use for boot and pool (e.g., 1, 2): " choice
    if [[ $choice -gt 0 && $choice -le ${#disks[@]} ]]; then
      # Get the selected disk name (e.g., 'sda' from 'sda 500G disk')
      selected_disk=$(echo "${disks[$((choice - 1))]}" | awk '{print $2}')
      BOOT_DISK="/dev/disk/by-id/$selected_disk"
      POOL_DISK="/dev/disk/by-id/$selected_disk"
      BOOT_DEVICE="${BOOT_DISK}${BOOT_PART}"
      POOL_DEVICE="${POOL_DISK}${POOL_PART}"
      echo "Selected disk: $BOOT_DISK"
      break
    else
      echo "Invalid choice. Please select a number from the list."
    fi
  done
  echo "Boot device is set to $BOOT_DEVICE"
  echo "Pool device is set to $POOL_DEVICE"
}

configure_apt_sources() {
  echo "Configuring APT sources..."
  cat > /etc/apt/sources.list.d/debian.sources <<EOF
Types: deb deb-src
URIs: http://deb.debian.org/debian/
Suites: trixie trixie-updates
Components: main non-free-firmware contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

Types: deb deb-src
URIs: http://security.debian.org/debian-security/
Suites: trixie-security
Components: main non-free-firmware contrib
Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
EOF
}

install_host_packages() {
    echo "Installing necessary packages"
    apt update
    apt install -y debootstrap gdisk dkms linux-headers-$(uname -r)
    apt install -y zfsutils-linux
}

partition_disk() {
    zgenhostid -f 0x00bab10c
    zpool labelclear -f "$POOL_DISK"
    wipefs -a "$POOL_DISK"
    wipefs -a "$BOOT_DISK"
    sgdisk --zap-all "$POOL_DISK"
    sgdisk --zap-all "$BOOT_DISK"
    sgdisk -n "${BOOT_PART}:1m:+512m" -t "${BOOT_PART}:ef00" "$BOOT_DISK"
    sgdisk -n "${POOL_PART}:0:-10m" -t "${POOL_PART}:bf00" "$POOL_DISK"
}

create_zpool() {
    echo "$ENC_PHRASE" > /etc/zfs/zroot.key
    chmod 000 /etc/zfs/zroot.key
    echo "Creating ZFS pool and datasets..."
    zpool create -f -o ashift=12 \
    -O compression=lz4 \
    -O acltype=posixacl \
    -O xattr=sa \
    -O relatime=on \
    -O encryption=aes-256-gcm \
    -O keylocation=file:///etc/zfs/zroot.key \
    -O keyformat=passphrase \
    -o autotrim=on \
    -o compatibility=openzfs-2.2-linux \
    -m none zroot "$POOL_DEVICE"
    zfs create -o mountpoint=none $POOL_NAME/ROOT
    zfs create -o mountpoint=/ -o canmount=noauto $POOL_NAME/ROOT/$ID
    zfs create -o mountpoint=/home $POOL_NAME/home
    zpool set bootfs=$POOL_NAME/ROOT/$ID $POOL_NAME
}

export_import_zpool() {
    echo "Exporting and re-importing ZFS pool for mounting..."
    zpool export zroot
    zpool import -N -R $MNT_P zroot
    zfs load-key -L file:///etc/zfs/zroot.key zroot
    zfs mount zroot/ROOT/${ID}
    zfs mount zroot/home
    udevadm trigger
}

setup_base_system() {
    echo "Installing base system with debootstrap..."
    debootstrap trixie $MNT_P
    cp /etc/hostid $MNT_P/etc/hostid
    cp /etc/resolv.conf $MNT_P/etc/resolv.conf
    mkdir $MNT_P/etc/zfs
    cp /etc/zfs/zroot.key $MNT_P/etc/zfs
}

prepare_chroot() {
    echo "Mounting filesystems for chroot environment..."
    mount -t proc proc $MNT_P/proc
    mount -t sysfs sys $MNT_P/sys
    mount -B /dev $MNT_P/dev
    mount -t devpts pts $MNT_P/dev/pts
}

enter_chroot() {
    echo "Entering chroot environment to configure system..."
    chroot $MNT_P /bin/bash #<<-EOF
    # Set hostname
    echo "$HOSTNAME" > /etc/hostname
    echo "127.0.1.1    $HOSTNAME" >> /etc/hosts

    # Configure apt sources
        cat > /etc/apt/sources.list.d/debian.sources #<<-EOF_APT
        Types: deb deb-src
        URIs: http://deb.debian.org/debian/
        Suites: trixie trixie-updates
        Components: main non-free-firmware contrib
        Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg

        Types: deb deb-src
        URIs: http://security.debian.org/debian-security/
        Suites: trixie-security
        Components: main non-free-firmware contrib
        Signed-By: /usr/share/keyrings/debian-archive-keyring.gpg
        EOF_APT

    # Update and install necessary packages
    export DEBIAN_FRONTEND=noninteractive
    apt update

    # Set locale and timezone
    echo "Configuring locale and timezone."
    echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
    ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
    apt install -y locales tzdata
    update-locale LANG=en_US.UTF-8
    apt install -y keyboard-configuration console-setup

    # Install kernel and ZFS packages
    echo "Installing kernel and ZFS packages..."
    apt install -y locales linux-headers-$KERNEL_VERSION linux-image-amd64 dkms
    apt install -y zfsutils-linux
    apt install -y zfs-dkms zfs-initramfs dosfstools efibootmgr curl
    echo "REMAKE_INITRD=yes" > /etc/dkms/zfs.conf

    # Install system utilities
    echo "Installing system utilities..."
    apt install -y isc-dhcp-client curl

    # Perform system upgrade
    echo "Running dist-upgrade to upgrade all packages to the latest version..."
    apt full-upgrade -y

    # Set root password
    echo "Setting root password..."
    echo "root:$ROOT_PASSWORD" | chpasswd

    # Create user and set password
    echo "Creating user and setting permissions..."
    useradd -m -s /bin/bash -G sudo,audio,cdrom,dip,floppy,netdev,plugdev,video $USERNAME
    echo "$USERNAME:$USER_PASSWORD" | chpasswd

    # Enable systemd ZFS services
    echo "Enabling systemd ZFS services..."
    systemctl enable zfs.target
    systemctl enable zfs-import-cache
    systemctl enable zfs-mount
    systemctl enable zfs-import.target

    # Rebuild initramfs
    echo "Rebuilding initramfs..."
    update-initramfs -c -k all

    # Set ZFSBootMenu command-line arguments for inherited ZFS properties
    echo "Configuring ZFSBootMenu command-line arguments..."
    zfs set org.zfsbootmenu:commandline="quiet" $POOL_NAME/ROOT

    # Set up EFI filesystem
    echo "Setting up EFI filesystem..."
    mkfs.vfat -F32 ${BOOT_DISK}p${BOOT_PART}

    # Configure fstab entry for EFI
    echo "Configuring fstab for EFI partition..."
        cat #<<-EOF_FSTAB >> /etc/fstab
        $(blkid | grep "${BOOT_DISK}p${BOOT_PART}" | cut -d ' ' -f 2) /boot/efi vfat defaults 0 0
        EOF_FSTAB

    # Mount EFI partition
    mkdir -p /boot/efi
    mount /boot/efi

    # Install ZFSBootMenu
    echo "Installing ZFSBootMenu..."
    mkdir -p /boot/efi/EFI/ZBM
    mkdir -p /boot/efi/EFI/BOOT
    curl -o /boot/efi/EFI/ZBM/VMLINUZ.EFI -L https://get.zfsbootmenu.org/efi
    cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/ZBM/VMLINUZ-BACKUP.EFI
    cp /boot/efi/EFI/ZBM/VMLINUZ.EFI /boot/efi/EFI/BOOT/bootx64.efi  # Default path if needed

    # Mount EFI variables if needed
    echo "Mounting efivarfs for boot entry setup..."
    mount -t efivarfs efivarfs /sys/firmware/efi/efivars

    # Install and configure EFI boot manager
    apt install -y efibootmgr
    echo "Configuring EFI boot entries..."
    efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" -L "ZFSBootMenu (Backup)" -l '\EFI\ZBM\VMLINUZ-BACKUP.EFI'
    efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" -L "ZFSBootMenu" -l '\EFI\ZBM\VMLINUZ.EFI'
    efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" -L "ZFSBootMenu" -l '\EFI\BOOT\bootx64.efi'

    # Perform a distribution upgrade
    echo "Running dist-upgrade to upgrade all packages to the latest version..."
    apt full-upgrade -y

    # add full debian setup (tasksel)
    echo "tasksel"
    tasksel install standard

    EOF
}

cleanup_chroot() {
    echo "Cleaning up chroot environment..."
    umount -l $MNT_P/dev/pts
    umount -l $MNT_P/dev
    umount -l $MNT_P/sys
    umount -l $MNT_P/proc
}

final_cleanup() {
    echo "Exporting ZFS pool and completing installation..."
    mount | grep -v zfs | tac | awk '/\/mnt/ {print $3}' | \
        xargs -i{} umount -lf {}
    zpool export -a
}

# Execution sequence
echo "Starting ZFS Boot Menu installation..."
echo "Current kernel version is: $KERNEL_VERSION"
echo "OS ID from /etc/os-release is: $ID"
select_disk
get_username_and_password
configure_apt_sources
install_host_packages
partition_disk
create_zpool
setup_base_system
prepare_chroot
enter_chroot
cleanup_chroot
final_cleanup

echo "ZFS Boot Menu installation complete. You may reboot."
