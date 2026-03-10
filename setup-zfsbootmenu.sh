#!/bin/bash

# Optionally set variables
MLANG=en_US.UTF-8
TIMEZONE="America/Chicago" # timezone variable demands underscore instead of space (e.g., "America/New_York")
#NET_IF=""
#ROOT_PASSWORD=""
#ENC_PHRASE=""
#SSH_KEY=""
#HOSTNAME=""

# Use /dev/disk/by-id/ for persistent device naming or
# use DISK_SUF="" (empty) var for /dev/sdX1 format
BOOT_DISK=""
POOL_DISK=""
BOOT_UUID=""
BOOT_PART="1"
POOL_PART="2"
DISK_SUF="-part"
BOOT_DEVICE="${BOOT_DISK}${DISK_SUF}${BOOT_PART}"
POOL_DEVICE="${POOL_DISK}${DISK_SUF}${POOL_PART}"
POOL_NAME="zroot"
MNT_P="/mnt"
KERNEL_VERSION=$(uname -r)  # Automatically get current kernel version
ID=$(source /etc/os-release && echo "$ID")  # Get OS ID from /etc/os-release

# optionally override variables with those from install.env file
if [ -f "install.env" ]; then
    source install.env
    echo "LOG: Loaded configuration from install.env"
fi
export DEBIAN_FRONTEND=noninteractive

set_credentials(){
  # Check if credentials are already set
  if [[ -n "$ROOT_PASSWORD" && -n "$ENC_PHRASE" && -n "$HOSTNAME" && -n "$SSH_KEY" ]]; then
    echo "Credentials have been set."
    echo "Hostname: $HOSTNAME"
    echo "Root password: [SET]"
    echo "Encryption passphrase: [SET]"
	echo "SSH key: [SET]"
    return
  fi
  
  # Prompt user for variables
  [[ -z "$HOSTNAME" ]] && read -p "Enter hostname for this system: " HOSTNAME
  echo
  [[ -z "$ROOT_PASSWORD" ]] && read -p "Enter root password: " ROOT_PASSWORD
  echo
  [[ -z "$ENC_PHRASE" ]] && read -p "Enter encryption passphrase: " ENC_PHRASE
  echo
  [[ -z "$SSH_KEY" ]] && read -p "Enter SSH public key: " SSH_KEY
}

select_disk() {
  # Check if disk is already selected
  if [[ -n "$BOOT_DISK" && -n "$POOL_DISK" ]]; then
    echo "LOG: Boot device is $BOOT_DEVICE"
    echo "LOG: Pool device is $POOL_DEVICE"
    return
  fi
  echo "LOG: Available disks:"
  # List available disks with lsblk and store them in an array
  mapfile -t disks < <(lsblk -dn -o NAME,ID-LINK,TYPE,SIZE | grep 'disk' | awk '{print $1,$2,$3,$4}')

  # Display disks with numbering
  for i in "${!disks[@]}"; do
    echo "$((i + 1)). ${disks[i]}"
  done

  # Prompt user to select a disk by number
  while true; do
    read -p "Enter the number of the disk you want to use (e.g., 1): " choice
    if [[ $choice -gt 0 && $choice -le ${#disks[@]} ]]; then
      # Get the selected disk name (e.g., 'sda' from 'sda 500G disk')
      selected_disk=$(echo "${disks[$((choice - 1))]}" | awk '{print $2}')
      BOOT_DISK="/dev/disk/by-id/$selected_disk"
      POOL_DISK="/dev/disk/by-id/$selected_disk"
      BOOT_DEVICE="${BOOT_DISK}${DISK_SUF}${BOOT_PART}"
      POOL_DEVICE="${POOL_DISK}${DISK_SUF}${POOL_PART}"
      echo "LOG: Selected boot disk: $BOOT_DISK"
      break
    else
      echo "Invalid choice. Please select a number from the list."
    fi
  done
  echo "[[LOG]] Boot device is set to $BOOT_DEVICE"
  echo "[[LOG]] Pool device is set to $POOL_DEVICE"
}

select_network_interface() {
  # Check if network interface is already selected
  if [[ -n "$NET_IF" ]]; then
    echo "[[LOG]] Network interface selected: $NET_IF"
    return
  fi
  
  echo "[[LOG]] Available network interfaces:"
  # List available network interfaces and store them in an array
  mapfile -t interfaces < <(ip link show | grep -E '^[0-9]+:' | awk -F': ' '{print $2}' | grep -v lo)

  # Display interfaces with numbering
  for i in "${!interfaces[@]}"; do
    echo "$((i + 1)). ${interfaces[i]}"
  done

  # Prompt user to select an interface by number
  while true; do
    read -p "Enter the number of the network interface you want to use (e.g., 1): " choice
    if [[ $choice -gt 0 && $choice -le ${#interfaces[@]} ]]; then
      NET_IF="${interfaces[$((choice - 1))]}"
      echo "[[LOG]] Selected network interface: $NET_IF"
      break
    else
      echo "Invalid choice. Please select a number from the list."
    fi
  done
}

configure_apt_sources() {
  echo "Configuring APT sources..."
  cat > /etc/apt/sources.list <<EOF
deb http://deb.debian.org/debian trixie main contrib non-free-firmware
deb-src http://deb.debian.org/debian trixie main contrib non-free-firmware

deb http://deb.debian.org/debian-security trixie-security main contrib non-free-firmware
deb-src http://deb.debian.org/debian-security/ trixie-security main contrib non-free-firmware

deb http://deb.debian.org/debian trixie-updates main contrib non-free-firmware
deb-src http://deb.debian.org/debian trixie-updates main contrib non-free-firmware
EOF
}

install_host_packages() {
  echo "Installing necessary packages"
  apt update
	apt full-upgrade -y
  apt install -y debootstrap gdisk dosfstools dkms linux-headers-$(uname -r)
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
  sleep 2
  count=0
  while [ ! -e "$POOL_DEVICE" ]; do
    echo "Waiting for pool device to appear: $POOL_DEVICE"
    sleep 1
    count=$((count + 1))
    if [ $count -ge 5 ]; then
      echo "Timeout waiting for pool device"
      exit 1
    fi
  done
  echo "[[LOG]] Pool device found: $POOL_DEVICE"
  # Format boot partition early to get UUID
  echo "[[LOG]] Formatting boot partition..."
  mkfs.vfat -F32 "$BOOT_DEVICE"
  # Get UUID after formatting
  BOOT_UUID=$(blkid -s UUID -o value "$BOOT_DEVICE")
  echo "[[LOG]] Boot UUID after formatting: $BOOT_UUID"
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
  -m none $POOL_NAME "$POOL_DEVICE"
  zfs create -o mountpoint=none $POOL_NAME/ROOT
  zfs create -o mountpoint=/ -o canmount=noauto $POOL_NAME/ROOT/$ID
  zfs create -o mountpoint=/home $POOL_NAME/home
  zpool set bootfs=$POOL_NAME/ROOT/$ID $POOL_NAME
}

export_import_zpool() {
  echo "[[LOG]] Exporting and re-importing ZFS pool for mounting..."
  zpool export $POOL_NAME
  zpool import -N -R $MNT_P $POOL_NAME
  zfs load-key -L file:///etc/zfs/zroot.key $POOL_NAME
  zfs mount $POOL_NAME/ROOT/${ID}
  zfs mount $POOL_NAME/home
  echo "[[LOG]] CURRENT MOUNTS:"
  mount | grep mnt
  udevadm trigger
}

setup_base_system() {
  echo "Installing base system with debootstrap..."
  debootstrap trixie $MNT_P
  cp /etc/hostid $MNT_P/etc/hostid
  cp /etc/resolv.conf $MNT_P/etc/resolv.conf
}

prepare_chroot() {
  echo "Mounting filesystems for chroot environment..."
  mount -t proc proc $MNT_P/proc
  mount -t sysfs sys $MNT_P/sys
  mount -B /dev $MNT_P/dev
  mount -t devpts pts $MNT_P/dev/pts
}

enter_chroot() {
	echo "[[LOG]] Entering chroot environment to configure system..."
	chroot $MNT_P /bin/bash <<-EOF

	# Set hostname
	echo "$HOSTNAME" > /etc/hostname
	echo "127.0.1.1    $HOSTNAME" >> /etc/hosts
	mkdir /etc/zfs
	echo "$ENC_PHRASE" > /etc/zfs/zroot.key
	# Set SSH key
	mkdir -p /root/.ssh
	echo "$SSH_KEY" > /root/.ssh/authorized_keys
	chmod 700 /root/.ssh
	chmod 600 /root/.ssh/authorized_keys
	rm /etc/apt/sources.list
	# Configure apt sources
		cat > /etc/apt/sources.list.d/debian.sources <<-EOF_APT
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
	export LC_ALL=C
	export LANG=C
	apt update

	# Set locale and timezone
	echo "[[LOG]] Configuring locale and timezone."
	echo "LANG UTF-8" > /etc/locale.gen
	ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
	apt install -y locales console-setup
	update-locale LANG=$MLANG

	# Install kernel and ZFS packages
	echo "[[LOG]] Installing kernel and ZFS packages..."
	apt install -y linux-headers-amd64 linux-image-amd64 zfs-initramfs
	echo "REMAKE_INITRD=yes" > /etc/dkms/zfs.conf
  
	# Set root password
	echo "[[LOG]] Setting root password."
	echo "root:$ROOT_PASSWORD" | chpasswd

	# Enable systemd ZFS services
	echo "[[LOG]] Enabling systemd ZFS services..."
	systemctl enable zfs.target
	systemctl enable zfs-import-cache
	systemctl enable zfs-mount
	systemctl enable zfs-import.target

	# Rebuild initramfs
	echo "[[LOG]] Rebuilding initramfs..."
	echo "UMASK=0077" > /etc/initramfs-tools/conf.d/umask.conf
	# update-initramfs -c -k all

	# Set ZFSBootMenu command-line arguments for inherited ZFS properties
	echo "[[LOG]] Configuring ZFSBootMenu command-line arguments..."
	zfs set org.zfsbootmenu:commandline="quiet" $POOL_NAME/ROOT
	zfs set org.zfsbootmenu:keysource="$POOL_NAME/ROOT/$ID" $POOL_NAME

	# Configure fstab entry for EFI
	echo "[[LOG]] Configuring fstab for EFI partition..."
	echo "UUID=$BOOT_UUID /boot/efi vfat defaults 0 0" >> /etc/fstab

	# Mount EFI partition
	mkdir -p /boot/efi
	mount /boot/efi

	# Install ZFSBootMenu
	echo "[[LOG]] Installing dependencies for ZFSBootMenu..."
	apt install -y --no-install-recommends \
	libsort-versions-perl \
	libboolean-perl \
	libyaml-pp-perl \
	git \
	fzf \
	curl \
	mbuffer \
	kexec-tools \
	efibootmgr \
	systemd-boot-efi \
	bsdextrautils \
	dracut-network \
	isc-dhcp-client \
	ssh \
	dropbear-bin

	# Install ZFSBootMenu
	echo "[[LOG]] Installing ZFSBootMenu."
	mkdir -p /usr/local/src/zfsbootmenu
	cd /usr/local/src/zfsbootmenu
	curl -L https://get.zfsbootmenu.org/source | tar -zxv --strip-components=1 -f -
	make core dracut

	# Install dracut-crypt-ssh
	echo "[[LOG]] Installing dracut-crypt-ssh."
	git -C /tmp clone 'https://github.com/dracut-crypt-ssh/dracut-crypt-ssh'
	rm /tmp/dracut-crypt-ssh/modules/60crypt-ssh/Makefile
	rm -r /tmp/dracut-crypt-ssh/modules/60crypt-ssh/helper
	sed -i '/inst \"\$moddir/s/^\(.*\)$/#&/' /tmp/dracut-crypt-ssh/modules/60crypt-ssh/module-setup.sh
	cp -r /tmp/dracut-crypt-ssh/modules/60crypt-ssh /usr/lib/dracut/modules.d

	# Configure dracut for network and dropbear
	echo "[[LOG]] Configuring dracut for network and dropbear."
	mkdir -p /etc/cmdline.d
	echo "ip=dhcp rd.neednet=1" > /etc/cmdline.d/dracut-network.conf
	mkdir -p /etc/dropbear
	for keytype in rsa ecdsa ed25519; do ssh-keygen -t "\$keytype" -f "/etc/dropbear/ssh_host_\${keytype}_key" -N ""; done
	ln -s "/root/.ssh/authorized_keys" /etc/dropbear/root_key

	# Writing dracut.conf.d/...
	echo "[[LOG]] Writing dracut.conf.d/..."
		cat > /etc/zfsbootmenu/dracut.conf.d/dropbear.conf <<-EOF_DRACUT
		add_dracutmodules+=" crypt-ssh "
		install_optional_items+=" /etc/cmdline.d/dracut-network.conf "
		dropbear_acl=/root/.ssh/authorized_keys
		dropbear_rsa_key=/etc/dropbear/ssh_host_rsa_key
		dropbear_ecdsa_key=/etc/dropbear/ssh_host_ecdsa_key
		dropbear_acl=/etc/dropbear/root_key
		EOF_DRACUT
	echo 'omit_dracutmodules+=" crypt-ssh "' > /etc/dracut.conf.d/no-crypt-ssh.conf

	# Configure ZFSBootMenu
	echo "[[LOG]] Configuring ZFSBootMenu."
	sed -i -e 's/^  ManageImages: false$/  ManageImages: true/' \
	  -e '/^Components:/,/^[^ ]/ s/^  Enabled: true$/  Enabled: false/' \
	  -e '/^EFI:/,/^[^ ]/ s/^  Enabled: false$/  Enabled: true/' \
	  /etc/zfsbootmenu/config.yaml

	# Generate ZFSBootMenu
	echo "[[LOG]] Generating ZFSBootMenu."
	generate-zbm

	# Mount EFI variables if needed
	echo "[[LOG]] Mounting efivarfs for boot entry setup..."
	mount -t efivarfs efivarfs /sys/firmware/efi/efivars

	# Configure EFI boot entries
	echo "[[LOG]] Configuring EFI boot entries..."
	efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" -L "ZFSBootMenu (Backup)" -l '\EFI\ZBM\VMLINUZ-BACKUP.EFI'
	efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" -L "ZFSBootMenu" -l '\EFI\ZBM\VMLINUZ.EFI'
	efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" -L "ZFSBootMenu" -l '\EFI\BOOT\bootx64.efi'

	# Configure network
	echo "[[LOG]] Configuring network for DHCP on $NET_IF."
	echo "auto $NET_IF" >> /etc/network/interfaces
	echo "iface $NET_IF inet dhcp" >> /etc/network/interfaces
	EOF
}

final_cleanup() {
  echo "[[LOG]] Exporting ZFS pool and completing installation..."
  umount -n -R /mnt
  zpool export -a
}

# Execution sequence
echo "[[LOG]] Starting ZFS Boot Menu installation..."
echo "[[LOG]] Current kernel version is: $KERNEL_VERSION"
echo "[[LOG]] OS ID from /etc/os-release is: $ID"
set_credentials
select_disk
select_network_interface
configure_apt_sources
install_host_packages
partition_disk
create_zpool
export_import_zpool
setup_base_system
prepare_chroot
enter_chroot
final_cleanup

echo "[[LOG]] ZFS Boot Menu installation complete. You may reboot."
