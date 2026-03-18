#!/bin/bash

# Optionally set variables here or override variables with those from install.env file.
INTERACTIVE=true
ADDON="" # optional: pve, pbs, pmg (proxmox: virtual environment, backup server, mail gateway)
MLANG=en_US.UTF-8
TIMEZONE="America/Chicago" # timezone variable demands underscore instead of space (e.g., "America/New_York")
#ROOT_PASSWORD=""
#ENC_PHRASE=""
#SSH_KEY=""
#HOSTNAME="machine01"
#NET_IF="eno1"
#NET_TYPE="" # static or dhcp (if set to dhcp, manually configure /etc/network/interfaces & /etc/hosts as soon as possible)
#IP_WITH_CIDR="10.0.0.7/24"
#GATEWAY="10.0.0.1"
BRIDGE="vmbr0"

# Use /dev/disk/by-id/xyz123 for persistent device naming or
# for /dev/sdX1 format set disk suffix var to empty DISK_SUF=""
BOOT_DISK=""
POOL_DISK=""
BOOT_PART="1"
POOL_PART="2"
DISK_SUF="-part" # keep as "-part" for by-id disk paths or "" for /dev/sdX1 format
BOOT_DEVICE="${BOOT_DISK}${DISK_SUF}${BOOT_PART}"
POOL_DEVICE="${POOL_DISK}${DISK_SUF}${POOL_PART}"
POOL_NAME="zroot"
ID="" # name for the root dataset
BOOT_UUID="" # autoset and used for the fstab entry

MNT_P="/mnt" # mount point for the root dataset during installation

# Override variables with those from install.env file if it exists.
if [ -f "install.env" ]; then
	source install.env
	echo "[[LOG]] Loaded configuration from install.env"
fi
export DEBIAN_FRONTEND=noninteractive

set_vars(){
	# Prompt for ADDON selection
	if [[ -z "$ADDON" ]]; then
		addon_choice=$(whiptail --title "Select Addon" --menu "Select addon to install:" 15 60 4 \
			"" "None - (standard Debian without an addon)" \
			"pve" "Proxmox Virtual Environment" \
			"pbs" "Proxmox Backup Server" \
			"pmg" "Proxmox Mail Gateway" 3>&1 1>&2 2>&3)
		ADDON="$addon_choice"
	fi
	ID="${ADDON:-$(source /etc/os-release && echo "$ID")}"

	# Check if credentials are already set
	if [[ -n "$ROOT_PASSWORD" && -n "$ENC_PHRASE" && -n "$HOSTNAME" && -n "$SSH_KEY" ]]; then
		echo "[[LOG]] Credentials have been set."
		echo "[[LOG]] Hostname: $HOSTNAME"
		echo "[[LOG]] Root password: [SET]"
		echo "[[LOG]] Encryption passphrase: [SET]"
		echo "[[LOG]] SSH key: $SSH_KEY"
		return
	fi
	
	# Prompt user for variables using whiptail
	[[ -z "$HOSTNAME" ]] && HOSTNAME=$(whiptail --inputbox "Enter hostname for this system:" 10 60 "" 3>&1 1>&2 2>&3)
	[[ -z "$ROOT_PASSWORD" ]] && ROOT_PASSWORD=$(whiptail --passwordbox "Enter root password:" 10 60 3>&1 1>&2 2>&3)
	[[ -z "$ENC_PHRASE" ]] && ENC_PHRASE=$(whiptail --passwordbox "Enter encryption passphrase:" 10 60 3>&1 1>&2 2>&3)
	[[ -z "$SSH_KEY" ]] && SSH_KEY=$(whiptail --inputbox "Enter SSH public key:" 10 60 3>&1 1>&2 2>&3)

}

select_disk() {
	# Check if disk is already selected
	if [[ -n "$BOOT_DISK" && -n "$POOL_DISK" ]]; then
		BOOT_DEVICE="${BOOT_DISK}${DISK_SUF}${BOOT_PART}"
		POOL_DEVICE="${POOL_DISK}${DISK_SUF}${POOL_PART}"
		echo "[[LOG]] Boot device is $BOOT_DEVICE"
		echo "[[LOG]] Pool device is $POOL_DEVICE"
		return
	fi
	
	echo "[[LOG]] Available disks:"
	# List available disks with lsblk and store them in an array
	mapfile -t disks < <(lsblk -dn -o NAME,ID-LINK,TYPE,SIZE | grep 'disk' | awk '{print $1,$2,$3,$4}')

	# Build whiptail menu options
	menu_options=()
	for i in "${!disks[@]}"; do
		menu_options+=("$((i + 1))" "${disks[i]}")
	done

	# Prompt user to select a disk using whiptail
	choice=$(whiptail --title "Select Disk" --menu "Select the disk you want to use:" 20 80 10 "${menu_options[@]}" 3>&1 1>&2 2>&3)
	
	if [[ -n "$choice" && $choice -gt 0 && $choice -le ${#disks[@]} ]]; then
		# Get the selected disk name (e.g., 'sda' from 'sda 500G disk')
		selected_disk=$(echo "${disks[$((choice - 1))]}" | awk '{print $2}')
		BOOT_DISK="/dev/disk/by-id/$selected_disk"
		POOL_DISK="/dev/disk/by-id/$selected_disk"
		BOOT_DEVICE="${BOOT_DISK}${DISK_SUF}${BOOT_PART}"
		POOL_DEVICE="${POOL_DISK}${DISK_SUF}${POOL_PART}"
		echo "[[LOG]] Selected boot disk: $BOOT_DISK"
	else
		echo "No disk selected or invalid selection. Exiting."
		exit 1
	fi
	
	echo "[[LOG]] Boot device is set to $BOOT_DEVICE"
	echo "[[LOG]] Pool device is set to $POOL_DEVICE"
}

network_config() {
	# Check if network interface is already selected
	if [[ -n "$NET_IF" ]]; then
		echo "[[LOG]] Network interface selected: $NET_IF"
		return
	fi
	
	echo "[[LOG]] Available network interfaces:"
	# List available network interfaces and store them in an array
	mapfile -t interfaces < <(ip link show | grep -E '^[0-9]+:' | awk -F': ' '{print $2}' | grep -v lo)

	# Build whiptail menu options
	menu_options=()
	for i in "${!interfaces[@]}"; do
		menu_options+=("$((i + 1))" "${interfaces[i]}")
	done

	# Prompt user to select an interface using whiptail
	choice=$(whiptail --title "Select Network Interface" --menu "Select the network interface you want to use:" 15 60 8 "${menu_options[@]}" 3>&1 1>&2 2>&3)
	
	if [[ -n "$choice" && $choice -gt 0 && $choice -le ${#interfaces[@]} ]]; then
		NET_IF="${interfaces[$((choice - 1))]}"
		echo "[[LOG]] Selected network interface: $NET_IF"
	else
		echo "No network interface selected or invalid selection. Exiting."
		exit 1
	fi
	if [[ -z "$NET_TYPE" ]]; then
		NET_TYPE=$(whiptail --menu "Select network type:" 10 60 2 \
			"static" "Static IP" \
			"dhcp" "DHCP" 3>&1 1>&2 2>&3)
	fi
	# Prompt user for network configuration
	if [[ "$NET_TYPE" == "static" ]]; then
		[[ -z "$IP_WITH_CIDR" ]] && IP_WITH_CIDR=$(whiptail --inputbox "Enter the static IP address with CIDR (e.g., 10.0.0.7/24):" 10 60 "" 3>&1 1>&2 2>&3)
		[[ -z "$GATEWAY" ]] && GATEWAY=$(whiptail --inputbox "Enter the gateway IP address:" 10 60 "" 3>&1 1>&2 2>&3)
	fi
}

installation_summary() {
	# Skip confirmation if INTERACTIVE is false
	if [[ "$INTERACTIVE" == "false" ]]; then
		echo "[[LOG]] Running in non-interactive mode, proceeding with installation..."
		return
	fi
	
	# Build summary message
	addon_display="None"
	case "$ADDON" in
		"pve") addon_display="Proxmox Virtual Environment" ;;
		"pbs") addon_display="Proxmox Backup Server" ;;
		"pmg") addon_display="Proxmox Mail Gateway" ;;
		*) addon_display="None" ;;
	esac
	
	summary="Configuration Summary:\n\n"
	summary+="Addon: $addon_display\n"
	summary+="Hostname: ${HOSTNAME:-[NOT SET]}\n"
	summary+="Root Password: ${ROOT_PASSWORD:+[SET]}\n"
	summary+="Encryption Passphrase: ${ENC_PHRASE:+[SET]}\n"
	summary+="SSH Key: ${SSH_KEY:-[NOT SET]}\n"
	summary+="Boot Device: ${BOOT_DEVICE:-[NOT SELECTED]}\n"
	summary+="Pool Device: ${POOL_DEVICE:-[NOT SELECTED]}\n"
	summary+="Network Interface: ${NET_IF:-[NOT SELECTED]}\n"
	summary+="Network Config: ${NET_TYPE:-[NOT SET]} ${IP_WITH_CIDR:+IP: $IP_WITH_CIDR} ${GATEWAY:+Gateway: $GATEWAY}\n"
	summary+="Timezone: $TIMEZONE\n"
	summary+="Locale: $MLANG\n\n"
	summary+="Proceed with Debian + ZFSBootMenu installation?"
	
	# Show confirmation dialog
	if whiptail --title "Installation Summary" --yesno "$summary" 25 80 3>&1 1>&2 2>&3; then
		echo "[[LOG]] User confirmed installation. Proceeding..."
	else
		echo "[[LOG]] User cancelled installation. Exiting."
		exit 0
	fi
}

configure_apt_sources() {
	echo "[[LOG]] Configuring APT sources..."
	rm -f /etc/apt/sources.list
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
}

install_host_packages() {
	echo "[[LOG]] Installing necessary packages"
	apt update
	apt install -y debootstrap gdisk dosfstools linux-headers-$(uname -r)
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
		echo "[[LOG]] Waiting for pool device to appear: $POOL_DEVICE"
		sleep 1
		count=$((count + 1))
		if [ $count -ge 5 ]; then
			echo "[[LOG]] Timeout waiting for pool device"
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
	echo "[[LOG]] Creating ZFS pool and datasets..."
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
	echo "[[LOG]] Installing base system with debootstrap..."
	debootstrap trixie $MNT_P
	cp /etc/hostid $MNT_P/etc/
	cp /etc/resolv.conf $MNT_P/etc/
	cp /etc/apt/sources.list.d/debian.sources $MNT_P/etc/apt/sources.list.d/
	mkdir -p $MNT_P/usr/local/src/zfsbootmenu
	wget https://get.zfsbootmenu.org/source -O $MNT_P/usr/local/src/zfsbootmenu/zfsbootmenu-source.tar.gz
	[[ "$ADDON" =~ ^(pve|pmg|pbs)$ ]] && \
		wget https://enterprise.proxmox.com/debian/proxmox-archive-keyring-trixie.gpg \
			-O $MNT_P/usr/share/keyrings/proxmox-archive-keyring.gpg
}

prepare_chroot() {
	echo "[[LOG]] Mounting filesystems for chroot environment..."
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
	IP_ADDR=${IP_WITH_CIDR%/*}
	cat > /etc/hosts <<- EOF_HOSTS
		127.0.0.1 localhost.localdomain localhost
		${IP_ADDR:-127.0.1.1} $HOSTNAME

		# The following lines are desirable for IPv6 capable hosts

		::1     ip6-localhost ip6-loopback
		fe00::0 ip6-localnet
		ff00::0 ip6-mcastprefix
		ff02::1 ip6-allnodes
		ff02::2 ip6-allrouters
		ff02::3 ip6-allhosts
		EOF_HOSTS
	mkdir /etc/zfs
	echo "$ENC_PHRASE" > /etc/zfs/zroot.key
	# Set SSH key
	mkdir -p /root/.ssh
	echo "$SSH_KEY" > /root/.ssh/authorized_keys
	chmod 700 /root/.ssh
	chmod 600 /root/.ssh/authorized_keys
	rm -f /etc/apt/sources.list
	if [ "$ADDON" = "pve" ]; then
		cat > /etc/apt/sources.list.d/proxmox.sources <<-EOF_PVE
			Types: deb
			URIs: http://download.proxmox.com/debian/pve
			Suites: trixie
			Components: pve-no-subscription
			Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
			EOF_PVE
	elif [ "$ADDON" = "pbs" ]; then
		cat >> /etc/apt/sources.list.d/proxmox.sources <<-EOF_PBS
			Types: deb
			URIs: http://download.proxmox.com/debian/pbs
			Suites: trixie
			Components: pbs-no-subscription
			Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
			EOF_PBS
	elif [ "$ADDON" = "pmg" ]; then
		cat >> /etc/apt/sources.list.d/proxmox.sources <<-EOF_PMG
			Types: deb
			URIs: http://download.proxmox.com/debian/pmg
			Suites: trixie
			Components: pmg-no-subscription
			Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
			EOF_PMG
	fi
	# Update and install necessary packages
	export LC_ALL=C
	export LANG=C
	apt update

	# Set locale and timezone
	echo "[[LOG]] Configuring locale and timezone."
	echo "$MLANG UTF-8" > /etc/locale.gen
	ln -sf /usr/share/zoneinfo/$TIMEZONE /etc/localtime
	apt install -y locales console-setup
	update-locale LANG=$MLANG

	# Install kernel and ZFS packages
	echo "[[LOG]] Installing kernel and ZFS packages..."
	apt install -y linux-headers-amd64 linux-image-amd64 zfs-initramfs dkms
	echo "REMAKE_INITRD=yes" > /etc/dkms/zfs.conf
	echo "UMASK=0077" > /etc/initramfs-tools/conf.d/umask.conf

	# Set root password
	echo "[[LOG]] Setting root password."
	echo "root:$ROOT_PASSWORD" | chpasswd

	# Enable systemd ZFS services
	echo "[[LOG]] Enabling systemd ZFS services..."
	systemctl enable zfs.target
	systemctl enable zfs-import-cache
	systemctl enable zfs-mount
	systemctl enable zfs-import.target

	# Set ZFSBootMenu command-line arguments for inherited ZFS properties
	echo "[[LOG]] Configuring ZFSBootMenu command-line arguments..."
	zfs set org.zfsbootmenu:commandline="quiet" $POOL_NAME/ROOT
	zfs set org.zfsbootmenu:keysource="$POOL_NAME/ROOT/$ID" $POOL_NAME

	# Configuring EFI
	echo "[[LOG]] Configuring EFI."
	echo "UUID=$BOOT_UUID /boot/efi vfat defaults 0 0" >> /etc/fstab
	mkdir -p /boot/efi
	mount /boot/efi

	# Install ZFSBootMenu
	echo "[[LOG]] Installing dependencies for ZFSBootMenu."
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
	cd /usr/local/src/zfsbootmenu
	tar -zxv --strip-components=1 -f zfsbootmenu-source.tar.gz
	rm zfsbootmenu-source.tar.gz
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
	echo "ip=single-dhcp rd.neednet=1" > /etc/cmdline.d/dracut-network.conf
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

	# Addon setup
	if [[ "$ADDON" =~ ^(pve|pmg|pbs)$ ]]; then
		apt-mark hold grub-common grub-pc-bin grub-pc grub2-common os-prober
		apt install -y proxmox-default-kernel proxmox-default-headers
	fi
	if [ "$ADDON" = "pve" ]; then
		cat > /root/setup-pve.sh <<- EOF_SETPVE
			#!/bin/bash
			apt update
			apt install -y proxmox-ve postfix open-iscsi chrony
			apt remove -y linux-image-amd64 'linux-image-6.12*'
			apt autoremove -y
			rm -f /etc/apt/sources.list.d/pve-enterprise.sources
			[[ -f /etc/network/interfaces.final ]] && mv /etc/network/interfaces.final /etc/network/interfaces
			echo "Proxmox VE installation complete. Reboot to finish."
			sed -i '/\.\/setup-pve\.sh/d' /root/.bashrc
			EOF_SETPVE
		chmod +x /root/setup-pve.sh
		echo "./setup-pve.sh" >> /root/.bashrc
	elif [ "$ADDON" = "pbs" ]; then
		cat > /root/setup-pbs.sh <<- EOF_SETPBS
			#!/bin/bash
			apt update
			apt install -y proxmox-backup
			apt remove -y linux-image-amd64 'linux-image-6.12*'
			apt autoremove -y
			rm -f /etc/apt/sources.list.d/pve-enterprise.sources
			echo "Proxmox backup server installation complete. Reboot to finish."
			sed -i '/\.\/setup-pbs\.sh/d' /root/.bashrc
			EOF_SETPBS
		chmod +x /root/setup-pbs.sh
		echo "./setup-pbs.sh" >> /root/.bashrc
	elif [ "$ADDON" = "pmg" ]; then
		cat > /root/setup-pmg.sh <<- EOF_SETPMG
			#!/bin/bash
			apt update
			apt install -y proxmox-mailgateway
			apt remove -y linux-image-amd64 'linux-image-6.12*'
			apt autoremove -y
			rm -f /etc/apt/sources.list.d/pve-enterprise.sources
			echo "Proxmox mail gateway installation complete. Reboot to finish."
			sed -i '/\.\/setup-pmg\.sh/d' /root/.bashrc
			EOF_SETPMG
		chmod +x /root/setup-pmg.sh
		echo "./setup-pmg.sh" >> /root/.bashrc
	fi

	# Generate ZFSBootMenu
	echo "[[LOG]] Generating ZFSBootMenu."
	generate-zbm

	# Mount EFI variables if needed
	echo "[[LOG]] Mounting efivarfs for boot entry setup..."
	mount -t efivarfs efivarfs /sys/firmware/efi/efivars

	# Configure EFI boot entries
	echo "[[LOG]] Configuring EFI boot entries..."
	for num in \$(efibootmgr | grep -oE 'Boot0[0-9A-F]+' | sed 's/Boot//'); do efibootmgr -B -b \$num; done
	efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" -L "ZFSBootMenu (Backup)" -l '\EFI\ZBM\VMLINUZ-BACKUP.EFI'
	efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" -L "ZFSBootMenu" -l '\EFI\ZBM\VMLINUZ.EFI'
	efibootmgr -c -d "$BOOT_DISK" -p "$BOOT_PART" -L "ZFSBootMenu" -l '\EFI\BOOT\bootx64.efi'

	# Configure network
	if [ "$NET_TYPE" = "dhcp" ]; then
		echo "[[LOG]] Configuring network for DHCP on $NET_IF."
		# Add network configuration
		sed -i "/$NET_IF/d" /etc/network/interfaces
		echo "auto $NET_IF" >> /etc/network/interfaces
		echo "iface $NET_IF inet dhcp" >> /etc/network/interfaces
	elif [ "$NET_TYPE" = "static" ]; then
		echo "[[LOG]] Configuring network for static IP of $IP_WITH_CIDR on $NET_IF."
		# Add network configuration
		sed -i "/$NET_IF/d" /etc/network/interfaces
		[[ "$ADDON" = "pve" ]] && cp /etc/network/interfaces /etc/network/interfaces.final
		cat > /etc/network/interfaces <<- EOF_NET_INIT
			auto $NET_IF
			iface $NET_IF inet static
			    address $IP_WITH_CIDR
			    gateway $GATEWAY
			EOF_NET_INIT
		if [ "$ADDON" = "pve" ]; then
			echo "[[LOG]] Configuring network for Proxmox VE bridge $BRIDGE."
			cat > /etc/network/interfaces.final <<- EOF_NET
				iface $NET_IF inet manual

				auto $BRIDGE
				iface $BRIDGE inet static
				    address $IP_WITH_CIDR
				    gateway $GATEWAY
				    bridge_ports $NET_IF
				    bridge_stp off
				    bridge_fd 0
				EOF_NET
		fi
	fi
	EOF
}

cleanup() {
	echo "[[LOG]] Exporting ZFS pool."
	umount -n -R /mnt
	zpool export -a
}

completion() {
	# Show completion options
	if [[ "$INTERACTIVE" == "true" ]]; then
		choice=$(whiptail --title "Installation Complete" --menu "ZFS Boot Menu installation is complete. Choose an option:" 15 60 3 \
			"1" "Reboot" \
			"2" "Unmount & Export Pool" \
			"3" "Finish Without Unmount" 3>&1 1>&2 2>&3)
		
		case "$choice" in
			"1")
				echo "[[LOG]] Rebooting after cleanup..."
				cleanup
				reboot
				;;
			"2")
				echo "[[LOG]] Performing unmount and export of ZFS pool..."
				cleanup
				;;
			"3")
				echo "[[LOG]] Finishing without unmount..."
				echo "[[LOG]] Re-enter chroot with 'chroot /mnt /bin/bash'."
				;;
			*)
				echo "[[LOG]] No option selected, finishing without unmount..."
				;;
		esac
	else
		cleanup
		echo "[[LOG]] Installation complete. You may reboot."
	fi
}


# Execution sequence
echo "[[LOG]] Starting ZFS Boot Menu installation..."
echo "[[LOG]] Current kernel version is: $(uname -r)"
set_vars
select_disk
network_config
installation_summary
configure_apt_sources
install_host_packages
partition_disk
create_zpool
export_import_zpool
setup_base_system
prepare_chroot
enter_chroot
completion