#!/bin/bash
set -e  # Exit on error

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print section headers
print_header() {
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${GREEN}========================================${NC}\n"
}

# Function to print and execute commands
run_cmd() {
    echo -e "${BLUE}Running: ${YELLOW}$@${NC}"
    "$@"
    echo ""
}

# Function to pause and wait for user
pause() {
    read -p "Press Enter to continue..."
}

# ============================================
# MANUAL PARTITIONING SECTION
# ============================================
print_header "STEP 1: MANUAL PARTITIONING"
echo "Use cfdisk to create:"
echo "  - nvme0n1p2: 1GB (for /boot)"
echo "  - nvme0n1p3: ~89GB (for encrypted root)"
echo ""
read -p "Have you completed partitioning? (y/n): " answer
if [[ $answer != "y" ]]; then
    echo "Please complete partitioning first, then run this script again."
    exit 1
fi

# ============================================
# ENCRYPTION
# ============================================
print_header "STEP 2: SETTING UP ENCRYPTION"
echo "This will encrypt nvme0n1p3 with LUKS2"
pause

run_cmd cryptsetup luksFormat --type luks2 /dev/nvme0n1p3
run_cmd cryptsetup open /dev/nvme0n1p3 cryptroot

# ============================================
# FILESYSTEM CREATION
# ============================================
print_header "STEP 3: CREATING BTRFS FILESYSTEM"
pause

run_cmd mkfs.btrfs -L ARCH_ROOT /dev/mapper/cryptroot

# ============================================
# BTRFS SUBVOLUMES
# ============================================
print_header "STEP 4: CREATING BTRFS SUBVOLUMES"
echo "Creating subvolumes: @, @home, @snapshots, @log, @cache, @tmp, @libvirt"
pause

run_cmd mount /dev/mapper/cryptroot /mnt
run_cmd btrfs subvolume create /mnt/@
run_cmd btrfs subvolume create /mnt/@home
run_cmd btrfs subvolume create /mnt/@snapshots
run_cmd btrfs subvolume create /mnt/@log
run_cmd btrfs subvolume create /mnt/@cache
run_cmd btrfs subvolume create /mnt/@tmp
run_cmd btrfs subvolume create /mnt/@libvirt
run_cmd umount /mnt

# ============================================
# MOUNTING SUBVOLUMES
# ============================================
print_header "STEP 5: MOUNTING SUBVOLUMES WITH OPTIMIZED OPTIONS"
echo "Mounting with compression (zstd:3) and noatime"
pause

run_cmd mount -o subvol=@,compress=zstd:3,noatime /dev/mapper/cryptroot /mnt
run_cmd mkdir -p /mnt/{boot,boot/efi,home,.snapshots,var/log,var/cache,var/tmp,var/lib/libvirt}
run_cmd mount -o subvol=@home,compress=zstd:3,noatime /dev/mapper/cryptroot /mnt/home
run_cmd mount -o subvol=@snapshots,noatime /dev/mapper/cryptroot /mnt/.snapshots
run_cmd mount -o subvol=@log,compress=zstd:3,noatime /dev/mapper/cryptroot /mnt/var/log
run_cmd mount -o subvol=@cache,compress=zstd:3,noatime /dev/mapper/cryptroot /mnt/var/cache
run_cmd mount -o subvol=@tmp,noatime /dev/mapper/cryptroot /mnt/var/tmp
run_cmd mount -o subvol=@libvirt,compress=zstd:3,noatime /dev/mapper/cryptroot /mnt/var/lib/libvirt

# ============================================
# BOOT PARTITIONS
# ============================================
print_header "STEP 6: SETTING UP BOOT PARTITIONS"
pause

run_cmd mkfs.ext4 -L ARCH_BOOT /dev/nvme0n1p2
run_cmd mount /dev/nvme0n1p2 /mnt/boot
run_cmd mkdir -p /mnt/boot/efi
run_cmd mount /dev/nvme0n1p1 /mnt/boot/efi

# ============================================
# VERIFY MOUNTS
# ============================================
print_header "STEP 7: VERIFYING MOUNT POINTS"
run_cmd findmnt /mnt
pause

# ============================================
# INSTALL BASE SYSTEM
# ============================================
# Configure Singapore mirrors
print_header "CONFIGURING MIRRORS"
echo "Setting up Singapore mirrors..."
pause

cat > /etc/pacman.d/mirrorlist << 'EOF'
Server = "http://sg.mirrors.cicku.me/archlinux/$repo/os/$arch",
Server = "https://sg.mirrors.cicku.me/archlinux/$repo/os/$arch",
Server = "http://mirror.aktkn.sg/archlinux/$repo/os/$arch",
Server = "https://mirror.aktkn.sg/archlinux/$repo/os/$arch",
Server = "http://mirror.guillaumea.fr/archlinux/$repo/os/$arch",
Server = "https://mirror.guillaumea.fr/archlinux/$repo/os/$arch",
Server = "http://mirror.jingk.ai/archlinux/$repo/os/$arch",
Server = "https://mirror.jingk.ai/archlinux/$repo/os/$arch",
Server = "http://ossmirror.mycloud.services/os/linux/archlinux/$repo/os/$arch",
Server = "http://mirror.sg.gs/archlinux/$repo/os/$arch",
Server = "https://mirror.sg.gs/archlinux/$repo/os/$arch",
Server = "https://singapore.mirror.pkgbuild.com/$repo/os/$arch",
Server = "https://sg.arch.niranjan.co/$repo/os/$arch",
Server = "http://mirror.freedif.org/archlinux/$repo/os/$arch",
Server = "https://mirror.freedif.org/archlinux/$repo/os/$arch",
Server = "http://mirror.sg.cdn-perfprod.com/archlinux/$repo/os/$arch",
Server = "https://mirror.sg.cdn-perfprod.com/archlinux/$repo/os/$arch"
EOF

run_cmd cat /etc/pacman.d/mirrorlist
print_header "STEP 8: INSTALLING BASE SYSTEM"
echo "Installing: base, kernels, firmware, and essential packages"
pause

run_cmd pacstrap -K /mnt base linux linux-lts linux-firmware btrfs-progs cryptsetup \
    intel-ucode networkmanager pipewire pipewire-pulse pipewire-alsa \
    bluez bluez-utils vim nano angelfish

# ============================================
# GENERATE FSTAB
# ============================================
print_header "STEP 9: GENERATING FSTAB"
pause

run_cmd genfstab -U /mnt >> /mnt/etc/fstab
echo "Generated fstab contents:"
cat /mnt/etc/fstab
pause

# ============================================
# CHROOT CONFIGURATION
# ============================================
print_header "STEP 10: CONFIGURING SYSTEM (CHROOT)"
echo "Creating chroot configuration script..."
pause

cat > /mnt/configure_system.sh << 'CHROOT_EOF'
#!/bin/bash
set -e

GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m'

print_header() {
    echo -e "\n${GREEN}========================================${NC}"
    echo -e "${GREEN}$1${NC}"
    echo -e "${GREEN}========================================${NC}\n"
}

run_cmd() {
    echo -e "${BLUE}Running: ${YELLOW}$@${NC}"
    "$@"
    echo ""
}

# TIMEZONE & LOCALE
print_header "CONFIGURING TIMEZONE AND LOCALE"
run_cmd ln -sf /usr/share/zoneinfo/Asia/Singapore /etc/localtime
run_cmd hwclock --systohc
run_cmd sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
run_cmd locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf
echo "KEYMAP=us" > /etc/vconsole.conf
echo "wl" > /etc/hostname

# HOSTS FILE
print_header "CONFIGURING HOSTS FILE"
cat >> /etc/hosts << EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   wl.localdomain wl
EOF
cat /etc/hosts

# MKINITCPIO
print_header "CONFIGURING MKINITCPIO"
echo "You need to manually edit /etc/mkinitcpio.conf"
echo "Change HOOKS line to:"
echo "HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block encrypt filesystems fsck)"
read -p "Press Enter to open editor..."
vim /etc/mkinitcpio.conf
run_cmd mkinitcpio -P

# ROOT PASSWORD
print_header "SETTING ROOT PASSWORD"
passwd

# SYSTEMD-BOOT
print_header "INSTALLING SYSTEMD-BOOT"
run_cmd bootctl install

# BOOTLOADER CONFIG
print_header "CONFIGURING BOOTLOADER"
cat > /boot/loader/loader.conf << EOF
default arch.conf
timeout 3
console-mode auto
editor no
EOF
echo "Created loader.conf:"
cat /boot/loader/loader.conf

# GET UUID
print_header "GETTING UUID FOR BOOT ENTRIES"
UUID=$(blkid -s UUID -o value /dev/nvme0n1p3)
echo "UUID: $UUID"

# BOOT ENTRIES
print_header "CREATING BOOT ENTRIES"
cat > /boot/loader/entries/arch.conf << EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options cryptdevice=UUID=${UUID}:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet
EOF
echo "Created arch.conf:"
cat /boot/loader/entries/arch.conf

cat > /boot/loader/entries/arch-lts.conf << EOF
title   Arch Linux LTS
linux   /vmlinuz-linux-lts
initrd  /intel-ucode.img
initrd  /initramfs-linux-lts.img
options cryptdevice=UUID=${UUID}:cryptroot root=/dev/mapper/cryptroot rootflags=subvol=@ rw quiet
EOF
echo "Created arch-lts.conf:"
cat /boot/loader/entries/arch-lts.conf

# ENABLE SERVICES
print_header "ENABLING SERVICES"
run_cmd systemctl enable NetworkManager
run_cmd systemctl enable bluetooth

# INSTALL HYPRLAND
print_header "INSTALLING HYPRLAND & DESKTOP ENVIRONMENT"
run_cmd pacman -S --noconfirm hyprland xdg-desktop-portal-hyprland qt5-wayland qt6-wayland \
    kitty wofi waybar ly swaybg polkit-kde-agent

run_cmd systemctl enable ly

print_header "CHROOT CONFIGURATION COMPLETE"
echo "Exit chroot and reboot when ready."
CHROOT_EOF

chmod +x /mnt/configure_system.sh

echo "Entering chroot to configure system..."
run_cmd arch-chroot /mnt /configure_system.sh

# ============================================
# CLEANUP AND REBOOT
# ============================================
print_header "STEP 11: CLEANUP AND REBOOT"
echo "Installation complete!"
echo ""
read -p "Unmount and reboot now? (y/n): " reboot_answer
if [[ $reboot_answer == "y" ]]; then
    run_cmd umount -R /mnt
    run_cmd cryptsetup close cryptroot
    echo "Rebooting..."
    reboot
else
    echo "Skipping reboot. Remember to run:"
    echo "  umount -R /mnt"
    echo "  cryptsetup close cryptroot"
    echo "  reboot"
fi