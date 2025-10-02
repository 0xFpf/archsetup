#!/bin/bash

set -e

echo "!!! WARNING: THIS WILL WIPE THE TARGET DISK !!!"
read -p "Enter the target disk (e.g., /dev/sda or /dev/nvme0n1): " TARGET_DISK
read -p "Enter your username: " USERNAME
read -sp "Enter your password: " USER_PASSWORD
echo
read -sp "Confirm your password: " USER_PASSWORD_CONFIRM
echo

if [[ "$USER_PASSWORD" != "$USER_PASSWORD_CONFIRM" ]]; then
    echo "Passwords don't match. Aborted."
    exit 1
fi

read -p "Are you 100% sure you want to wipe $TARGET_DISK? Type YES to continue: " CONFIRM

if [[ "$CONFIRM" != "YES" ]]; then
    echo "Aborted."
    exit 1
fi

# --- 1. Wipe disk ---
sgdisk --zap-all "$TARGET_DISK"
wipefs -a "$TARGET_DISK"
sgdisk -o "$TARGET_DISK"

# --- 2. Create partitions ---
sgdisk -n 1:0:+512M -t 1:ef00 "$TARGET_DISK"
sgdisk -n 2:0:0 -t 2:8300 "$TARGET_DISK"

# Handle NVMe partition naming
if [[ $TARGET_DISK == *"nvme"* ]]; then
    EFI_PART="${TARGET_DISK}p1"
    ROOT_PART="${TARGET_DISK}p2"
else
    EFI_PART="${TARGET_DISK}1"
    ROOT_PART="${TARGET_DISK}2"
fi

# --- 3. Format partitions ---
mkfs.fat -F32 "$EFI_PART"

echo "Creating LUKS on root partition..."
cryptsetup luksFormat "$ROOT_PART"
cryptsetup open "$ROOT_PART" cryptroot
mkfs.ext4 /dev/mapper/cryptroot

# Get LUKS UUID now (needed later)
LUKS_UUID=$(blkid -s UUID -o value "$ROOT_PART")

# --- 4. Mount partitions ---
mount /dev/mapper/cryptroot /mnt
mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

# --- 5. Install base system ---
pacstrap /mnt base base-devel linux linux-firmware intel-ucode neovim git sudo \
cryptsetup networkmanager hyprland wayland-protocols wlroots waybar \
mako xdg-desktop-portal-wlr xorg-xwayland kitty zsh starship \
htop ncdu firefox curl wget pipewire pavucontrol playerctl ttf-fira-code libinput \
greetd brightnessctl swaylock thunar dosfstools \
broadcom-wl-dkms linux-headers

# --- 6. Generate fstab ---
genfstab -U /mnt >> /mnt/etc/fstab

# Pass variables to chroot
cat > /mnt/root/install_continue.sh <<EOFSCRIPT
#!/bin/bash
set -e

LUKS_UUID="$LUKS_UUID"
USERNAME="$USERNAME"
USER_PASSWORD="$USER_PASSWORD"

# --- Timezone and Locale ---
ln -sf /usr/share/zoneinfo/Europe/London /etc/localtime
hwclock --systohc
echo "en_GB.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=en_GB.UTF-8" > /etc/locale.conf

# --- Hostname ---
echo "icarus" > /etc/hostname
cat > /etc/hosts <<EOL
127.0.0.1   localhost
::1         localhost
127.0.1.1   icarus.localdomain icarus
EOL

# --- Root password (same as user password) ---
echo "root:\$USER_PASSWORD" | chpasswd

# --- Configure mkinitcpio for encryption ---
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# --- Setup systemd-boot ---
bootctl --path=/boot install

cat > /boot/loader/loader.conf <<EOL
default arch.conf
timeout 3
console-mode max
editor no
EOL

cat > /boot/loader/entries/arch.conf <<EOL
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options cryptdevice=UUID=\$LUKS_UUID:cryptroot root=/dev/mapper/cryptroot rw quiet splash
EOL

# --- Create regular user ---
useradd -m -G wheel -s /bin/zsh "\$USERNAME"
echo "\$USERNAME:\$USER_PASSWORD" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" >> /etc/sudoers

# --- Install yay as regular user ---
sudo -u "\$USERNAME" bash <<'EOFUSER'
cd /tmp
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm
yay -S --noconfirm walker-bin hyprpaper-git satty
EOFUSER

# --- Enable services ---
systemctl enable NetworkManager
systemctl enable greetd

# --- Configure Zsh + Starship for root and user ---
echo 'eval "\$(starship init zsh)"' >> /root/.zshrc
echo 'eval "\$(starship init zsh)"' >> /home/"\$USERNAME"/.zshrc
chown "\$USERNAME:\$USERNAME" /home/"\$USERNAME"/.zshrc

# --- Configure greetd ---
cat > /etc/greetd/config.toml <<EOL
[terminal]
vt = 1

[default_session]
command = "agreety --cmd Hyprland"
user = "\$USERNAME"
EOL

echo "Installation complete!"
EOFSCRIPT

chmod +x /mnt/root/install_continue.sh
arch-chroot /mnt /root/install_continue.sh

echo ""
echo "Installation complete! Before rebooting:"
echo "1. Review /mnt/etc/fstab"
echo "2. Check /mnt/boot/loader/entries/arch.conf"
echo "3. Run: umount -R /mnt"
echo "4. Run: cryptsetup close cryptroot"
echo "5. Reboot"