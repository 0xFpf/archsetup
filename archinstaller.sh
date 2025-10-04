#!/bin/bash
set -e

echo "=== Arch Linux Installation Script ==="
echo ""

# --- Pre-flight checks ---
if [[ ! -d /sys/firmware/efi ]]; then
    echo "ERROR: This script requires UEFI boot mode."
    echo "Your system appears to be in BIOS/Legacy mode."
    exit 1
fi

echo "Checking available disk space..."
AVAILABLE_SPACE=$(df -BG / | tail -1 | awk '{print $4}' | sed 's/G//')
if [[ $AVAILABLE_SPACE -lt 20 ]]; then
    echo "WARNING: Less than 20GB available. Installation may fail."
    read -p "Continue anyway? (yes/no): " SPACE_CONTINUE
    if [[ "$SPACE_CONTINUE" != "yes" ]]; then
        exit 1
    fi
fi

# --- Configuration prompts ---
echo "Available timezones - examples:"
echo "  Europe/London, Europe/Paris, America/New_York"
echo "List all: ls /usr/share/zoneinfo/"
read -p "Enter your timezone: " TIMEZONE

# Validate timezone
if [[ ! -f "/usr/share/zoneinfo/$TIMEZONE" ]]; then
    echo "ERROR: Invalid timezone '$TIMEZONE'"
    exit 1
fi

echo ""
echo "Available locales - examples:"
echo "  en_US.UTF-8, en_GB.UTF-8, de_DE.UTF-8, fr_FR.UTF-8"
read -p "Enter your locale: " LOCALE

# Validate locale format
if [[ ! $LOCALE =~ ^[a-z]{2}_[A-Z]{2}\.UTF-8$ ]]; then
    echo "ERROR: Invalid locale format. Use format: en_GB.UTF-8"
    exit 1
fi

echo ""
echo "Available keymaps - examples:"
echo "  us, uk, de, fr, es"
echo "List all: localectl list-keymaps"
read -p "Enter your keyboard layout: " KEYMAP

# Test keymap
if ! loadkeys "$KEYMAP" 2>/dev/null; then
    echo "ERROR: Invalid keymap '$KEYMAP'"
    exit 1
fi

echo ""
read -p "Enter your hostname: " HOSTNAME

echo ""
read -p "Enter your username: " USERNAME

# Validate username
if [[ ! $USERNAME =~ ^[a-z_][a-z0-9_-]*$ ]]; then
    echo "ERROR: Invalid username. Use lowercase letters, numbers, underscore, hyphen."
    exit 1
fi

echo ""
read -sp "Enter your password: " USER_PASSWORD
echo
read -sp "Confirm your password: " USER_PASSWORD_CONFIRM
echo

if [[ "$USER_PASSWORD" != "$USER_PASSWORD_CONFIRM" ]]; then
    echo "ERROR: Passwords don't match."
    exit 1
fi

if [[ ${#USER_PASSWORD} -lt 6 ]]; then
    echo "ERROR: Password must be at least 6 characters."
    exit 1
fi

echo ""
echo "Choose bootloader:"
echo "1) systemd-boot (recommended, simple, UEFI only)"
echo "2) GRUB (traditional, more features)"
read -p "Enter choice (1 or 2): " BOOTLOADER_CHOICE

case $BOOTLOADER_CHOICE in
    1) BOOTLOADER="systemd-boot" ;;
    2) BOOTLOADER="grub" ;;
    *) echo "ERROR: Invalid choice."; exit 1 ;;
esac

echo ""
echo "Choose root filesystem:"
echo "1) ext4 (recommended, stable, proven)"
echo "2) btrfs (modern, snapshots, compression)"
echo "3) xfs (high performance, large files)"
read -p "Enter choice (1, 2, or 3): " FS_CHOICE

case $FS_CHOICE in
    1) FILESYSTEM="ext4" ;;
    2) FILESYSTEM="btrfs" ;;
    3) FILESYSTEM="xfs" ;;
    *) echo "ERROR: Invalid choice."; exit 1 ;;
esac

echo ""
echo "Available disks:"
lsblk -d -o NAME,SIZE,TYPE | grep disk
echo ""
echo "!!! WARNING: THIS WILL WIPE THE TARGET DISK !!!"
read -p "Enter the target disk (e.g., /dev/sda or /dev/nvme0n1): " TARGET_DISK

# Validate disk exists
if [[ ! -b "$TARGET_DISK" ]]; then
    echo "ERROR: Disk '$TARGET_DISK' does not exist."
    exit 1
fi

DISK_SIZE=$(lsblk -b -d -o SIZE -n "$TARGET_DISK")
DISK_SIZE_GB=$((DISK_SIZE / 1024 / 1024 / 1024))
if [[ $DISK_SIZE_GB -lt 32 ]]; then
    echo "ERROR: Disk is too small ($DISK_SIZE_GB GB). Need at least 32GB."
    exit 1
fi

echo ""
echo "=== IMPORTANT SECURITY WARNING ==="
echo "UFW (firewall) will be installed but NOT enabled by default."
echo "After installation, you should enable it with: sudo ufw enable"
echo "This allows you to test your system first before blocking ports."
echo ""
read -p "Type 'I UNDERSTAND' to acknowledge: " UFW_ACK

if [[ "$UFW_ACK" != "I UNDERSTAND" ]]; then
    echo "Aborted."
    exit 1
fi

echo ""
echo "=== Configuration Summary ==="
echo "Timezone: $TIMEZONE"
echo "Locale: $LOCALE"
echo "Keymap: $KEYMAP"
echo "Hostname: $HOSTNAME"
echo "Username: $USERNAME"
echo "Bootloader: $BOOTLOADER"
echo "Filesystem: $FILESYSTEM"
echo "Target disk: $TARGET_DISK ($DISK_SIZE_GB GB)"
echo "Swap: 512MB zram + 2GB swap file"
echo ""
read -p "Are you 100% sure you want to wipe $TARGET_DISK? Type YES to continue: " CONFIRM

if [[ "$CONFIRM" != "YES" ]]; then
    echo "Aborted."
    exit 1
fi

# --- 1. Update mirrorlist with reflector ---
echo "Updating mirrorlist with fastest European mirrors..."
pacman -Sy --noconfirm reflector
reflector --country GB,FR,DE,NL,BE,SE,NO,DK,PL --protocol https --latest 20 --sort rate --save /etc/pacman.d/mirrorlist
echo "Mirrorlist updated!"

# --- Enable parallel downloads ---
echo "Enabling parallel downloads..."
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf

# --- 2. Set keyboard layout for installation ---
loadkeys "$KEYMAP"

# --- 3. Wipe disk ---
echo "Wiping disk..."
sgdisk --zap-all "$TARGET_DISK"
wipefs -a "$TARGET_DISK"
sgdisk -o "$TARGET_DISK"

# --- 4. Create partitions ---
echo "Creating partitions..."
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

# --- 5. Format partitions ---
echo "Formatting partitions..."
mkfs.fat -F32 "$EFI_PART"

case $FILESYSTEM in
    ext4)
        mkfs.ext4 -F "$ROOT_PART"
        ;;
    btrfs)
        mkfs.btrfs -f "$ROOT_PART"
        ;;
    xfs)
        mkfs.xfs -f "$ROOT_PART"
        ;;
esac

# --- 6. Mount partitions ---
echo "Mounting partitions..."
if [[ $FILESYSTEM == "btrfs" ]]; then
    mount "$ROOT_PART" /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    umount /mnt
    mount -o subvol=@,compress=zstd,noatime,space_cache=v2 "$ROOT_PART" /mnt
    mkdir -p /mnt/home
    mount -o subvol=@home,compress=zstd,noatime,space_cache=v2 "$ROOT_PART" /mnt/home
else
    mount "$ROOT_PART" /mnt
fi

mkdir -p /mnt/boot
mount "$EFI_PART" /mnt/boot

# --- 7. Install base system ---
echo "Installing base system (this will take a while)..."
PACKAGES="base base-devel linux linux-firmware intel-ucode neovim git sudo \
networkmanager wpa_supplicant hyprland wayland-protocols wlroots waybar hyprpaper sof-firmware\
mako xdg-desktop-portal-hyprland xorg-xwayland kitty zsh starship \
htop ncdu firefox curl wget pipewire pipewire-pulse pipewire-alsa wireplumber \
pavucontrol playerctl ttf-fira-code noto-fonts noto-fonts-emoji \
libinput xf86-input-libinput greetd greetd-agreety brightnessctl kbdlight swaylock thunar dosfstools \
reflector \
tlp tlp-rdw thermald acpi acpid ntfs-3g exfatprogs unzip polkit polkit-gnome \
xdg-user-dirs grim slurp wl-clipboard satty ufw zram-generator \
man-db man-pages fuzzel"

# Add filesystem tools
case $FILESYSTEM in
    btrfs) PACKAGES="$PACKAGES btrfs-progs" ;;
    xfs) PACKAGES="$PACKAGES xfsprogs" ;;
esac

# Add bootloader packages
if [[ $BOOTLOADER == "grub" ]]; then
    PACKAGES="$PACKAGES grub efibootmgr"
fi

echo "Verifying build dependencies..."
if ! pacman -Si base-devel &>/dev/null; then
    echo "ERROR: base-devel not available in repositories"
    exit 1
fi

pacstrap /mnt $PACKAGES

# --- 8. Generate fstab ---
echo "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab

# --- 9. Configure zram ---
echo "Configuring zram (512MB)..."
cat > /mnt/etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = ram / 8
compression-algorithm = zstd
EOF

# --- 10. Create swap file (2GB) ---
echo "Creating 2GB swap file..."
if [[ $FILESYSTEM == "btrfs" ]]; then
    # Btrfs-specific swap file creation
    truncate -s 0 /mnt/swapfile
    chattr +C /mnt/swapfile
    btrfs property set /mnt/swapfile compression none
    dd if=/dev/zero of=/mnt/swapfile bs=1M count=2048 status=progress
else
    dd if=/dev/zero of=/mnt/swapfile bs=1M count=2048 status=progress
fi
chmod 600 /mnt/swapfile
mkswap /mnt/swapfile
echo "/swapfile none swap defaults 0 0" >> /mnt/etc/fstab

# --- 11. Pass variables to chroot ---
cat > /mnt/root/install_continue.sh <<EOFSCRIPT
#!/bin/bash
set -e

USERNAME="$USERNAME"
USER_PASSWORD="$USER_PASSWORD"
TIMEZONE="$TIMEZONE"
LOCALE="$LOCALE"
KEYMAP="$KEYMAP"
HOSTNAME="$HOSTNAME"
BOOTLOADER="$BOOTLOADER"
FILESYSTEM="$FILESYSTEM"
TARGET_DISK="$TARGET_DISK"
EFI_PART="$EFI_PART"
ROOT_PART="$ROOT_PART"

# --- Enable parallel downloads ---
sed -i 's/^#ParallelDownloads/ParallelDownloads/' /etc/pacman.conf

# --- Timezone ---
echo "Setting timezone..."
ln -sf /usr/share/zoneinfo/\$TIMEZONE /etc/localtime
hwclock --systohc

# --- Locale ---
echo "Setting locale..."
echo "\$LOCALE UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=\$LOCALE" > /etc/locale.conf

# --- Keyboard layout ---
echo "Setting keyboard layout..."
echo "KEYMAP=\$KEYMAP" > /etc/vconsole.conf

# --- Hostname ---
echo "Setting hostname..."
echo "\$HOSTNAME" > /etc/hostname
cat > /etc/hosts <<EOL
127.0.0.1   localhost
::1         localhost
127.0.1.1   \$HOSTNAME.localdomain \$HOSTNAME
EOL

# --- Root password ---
echo "Setting root password..."
echo "root:\$USER_PASSWORD" | chpasswd

# --- Change root shell to zsh ---
chsh -s /bin/zsh root

# --- Configure mkinitcpio ---
echo "Configuring mkinitcpio..."
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# --- Setup bootloader ---
if [[ \$BOOTLOADER == "systemd-boot" ]]; then
    echo "Installing systemd-boot..."
    bootctl --path=/boot install

    cat > /boot/loader/loader.conf <<EOL
default arch.conf
timeout 3
console-mode max
editor no
EOL

    ROOT_UUID=\$(blkid -s UUID -o value \$ROOT_PART)

    if [[ \$FILESYSTEM == "btrfs" ]]; then
        ROOT_OPTIONS="root=UUID=\$ROOT_UUID rootflags=subvol=@ rw"
    else
        ROOT_OPTIONS="root=UUID=\$ROOT_UUID rw"
    fi

    # Main entry
    cat > /boot/loader/entries/arch.conf <<EOL
title   Arch Linux
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux.img
options \$ROOT_OPTIONS quiet splash
EOL

    # Fallback entry
    cat > /boot/loader/entries/arch-fallback.conf <<EOL
title   Arch Linux (Fallback)
linux   /vmlinuz-linux
initrd  /intel-ucode.img
initrd  /initramfs-linux-fallback.img
options \$ROOT_OPTIONS
EOL

elif [[ \$BOOTLOADER == "grub" ]]; then
    echo "Installing GRUB..."
    grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=GRUB
    
    # Ensure Intel microcode is loaded first
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash"/' /etc/default/grub
    
    grub-mkconfig -o /boot/grub/grub.cfg
fi

# --- Verify NVRAM boot entries ---
echo "Verifying NVRAM boot entries..."
efibootmgr -v
if ! efibootmgr | grep -i "arch\|grub"; then
    echo "WARNING: No Arch/GRUB boot entry found in NVRAM!"
    echo "This may indicate a problem with EFI variables."
    echo "Boot entries shown above - please verify manually."
fi

# --- Create regular user ---
echo "Creating user..."
useradd -m -G wheel,audio,video,storage,optical -s /bin/zsh "\$USERNAME"
echo "\$USERNAME:\$USER_PASSWORD" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# --- Create user directories ---
sudo -u "\$USERNAME" xdg-user-dirs-update

# --- Configure zsh for user ---
cat > /home/"\$USERNAME"/.zshrc <<'ZSHEOF'
# Starship prompt
eval "\$(starship init zsh)"

# History
HISTSIZE=10000
SAVEHIST=10000
HISTFILE=~/.zsh_history
setopt SHARE_HISTORY
setopt HIST_IGNORE_DUPS

# Aliases
alias ls='ls --color=auto'
alias ll='ls -lah'
alias grep='grep --color=auto'
alias update='sudo pacman -Syu'
alias cleanup='sudo pacman -Rns \$(pacman -Qtdq) 2>/dev/null || echo "No orphans to remove"'

# Auto-completion
autoload -Uz compinit
compinit

# Key bindings
bindkey '^[[A' history-search-backward
bindkey '^[[B' history-search-forward
ZSHEOF

chown "\$USERNAME:\$USERNAME" /home/"\$USERNAME"/.zshrc

# Basic root zshrc
cat > /root/.zshrc <<'ZSHEOF'
eval "\$(starship init zsh)"
HISTSIZE=10000
SAVEHIST=10000
HISTFILE=~/.zsh_history
alias ls='ls --color=auto'
alias ll='ls -lah'
ZSHEOF

# --- Configure reflector for automatic mirror updates ---
echo "Configuring automatic mirror updates..."
cat > /etc/xdg/reflector/reflector.conf <<EOL
--save /etc/pacman.d/mirrorlist
--country GB,FR,DE,NL,BE,SE,NO,DK
--protocol https
--latest 20
--sort rate
EOL

systemctl enable reflector.timer

# --- Basic Hyprland configuration ---
echo "Creating Hyprland configuration..."
mkdir -p /home/"\$USERNAME"/.config/hypr

cat > /home/"\$USERNAME"/.config/hypr/hyprland.conf <<'HYPREOF'
# Monitor configuration
monitor=,preferred,auto,1

# HiDPI scaling for MacBook Retina displays
env = GDK_SCALE,1.5
env = XCURSOR_SIZE,32

# Autostart
exec-once = waybar
exec-once = mako
exec-once = hyprpaper
exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1

# Input configuration
input {
    kb_layout = KEYMAP_PLACEHOLDER
    follow_mouse = 1
    touchpad {
        natural_scroll = yes
        tap-to-click = yes
        disable_while_typing = yes
    }
    sensitivity = 0
}

# General settings
general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
    col.inactive_border = rgba(595959aa)
    layout = dwindle
}

# Decorations
decoration {
    rounding = 8
    blur {
        enabled = true
        size = 3
        passes = 1
    }
    drop_shadow = yes
    shadow_range = 4
    shadow_render_power = 3
    col.shadow = rgba(1a1a1aee)
}

# Animations
animations {
    enabled = yes
    bezier = myBezier, 0.05, 0.9, 0.1, 1.05
    animation = windows, 1, 7, myBezier
    animation = windowsOut, 1, 7, default, popin 80%
    animation = border, 1, 10, default
    animation = fade, 1, 7, default
    animation = workspaces, 1, 6, default
}

# Layouts
dwindle {
    pseudotile = yes
    preserve_split = yes
}

# Key bindings
\$mainMod = SUPER

bind = \$mainMod, RETURN, exec, kitty
bind = \$mainMod, Q, killactive,
bind = \$mainMod, M, exit,
bind = \$mainMod, E, exec, thunar
bind = \$mainMod, V, togglefloating,
bind = \$mainMod, SPACE, exec, fuzzel
bind = \$mainMod, P, pseudo,
bind = \$mainMod, J, togglesplit,
bind = \$mainMod, F, fullscreen,
bind = \$mainMod, L, exec, swaylock -c 000000

# Screenshot
bind = \$mainMod SHIFT, S, exec, grim -g "\$(slurp)" - | satty --filename - --fullscreen --output-filename ~/Pictures/Screenshots/satty-\$(date '+%Y%m%d-%H:%M:%S').png

# Move focus
bind = \$mainMod, left, movefocus, l
bind = \$mainMod, right, movefocus, r
bind = \$mainMod, up, movefocus, u
bind = \$mainMod, down, movefocus, d

# Switch workspaces
bind = \$mainMod, 1, workspace, 1
bind = \$mainMod, 2, workspace, 2
bind = \$mainMod, 3, workspace, 3
bind = \$mainMod, 4, workspace, 4
bind = \$mainMod, 5, workspace, 5
bind = \$mainMod, 6, workspace, 6
bind = \$mainMod, 7, workspace, 7
bind = \$mainMod, 8, workspace, 8
bind = \$mainMod, 9, workspace, 9
bind = \$mainMod, 0, workspace, 10

# Move to workspace
bind = \$mainMod SHIFT, 1, movetoworkspace, 1
bind = \$mainMod SHIFT, 2, movetoworkspace, 2
bind = \$mainMod SHIFT, 3, movetoworkspace, 3
bind = \$mainMod SHIFT, 4, movetoworkspace, 4
bind = \$mainMod SHIFT, 5, movetoworkspace, 5
bind = \$mainMod SHIFT, 6, movetoworkspace, 6
bind = \$mainMod SHIFT, 7, movetoworkspace, 7
bind = \$mainMod SHIFT, 8, movetoworkspace, 8
bind = \$mainMod SHIFT, 9, movetoworkspace, 9
bind = \$mainMod SHIFT, 0, movetoworkspace, 10

# Scroll through workspaces
bind = \$mainMod, mouse_down, workspace, e+1
bind = \$mainMod, mouse_up, workspace, e-1

# Move/resize windows
bindm = \$mainMod, mouse:272, movewindow
bindm = \$mainMod, mouse:273, resizewindow

# Brightness
bind = , XF86MonBrightnessUp, exec, brightnessctl set +5%
bind = , XF86MonBrightnessDown, exec, brightnessctl set 5%-

# Keyboard backlight
bind = , XF86KbdBrightnessUp, exec, kbdlight up
bind = , XF86KbdBrightnessDown, exec, kbdlight down

# Volume
bind = , XF86AudioRaiseVolume, exec, pactl set-sink-volume @DEFAULT_SINK@ +5%
bind = , XF86AudioLowerVolume, exec, pactl set-sink-volume @DEFAULT_SINK@ -5%
bind = , XF86AudioMute, exec, pactl set-sink-mute @DEFAULT_SINK@ toggle

# Window rules
windowrule = float, ^(pavucontrol)$
windowrule = float, ^(thunar)$
HYPREOF

# Replace keymap placeholder
sed -i "s/KEYMAP_PLACEHOLDER/\$KEYMAP/" /home/"\$USERNAME"/.config/hypr/hyprland.conf

# --- Create basic Waybar configuration ---
echo "Creating Waybar configuration..."
mkdir -p /home/"\$USERNAME"/.config/waybar

cat > /home/"\$USERNAME"/.config/waybar/config <<'WAYBAREOF'
{
    "layer": "top",
    "position": "top",
    "height": 30,
    "modules-left": ["hyprland/workspaces", "hyprland/window"],
    "modules-center": ["clock"],
    "modules-right": ["pulseaudio", "network", "battery", "tray"],
    
    "hyprland/workspaces": {
        "disable-scroll": false,
        "all-outputs": true,
        "format": "{icon}",
        "format-icons": {
            "1": "1",
            "2": "2",
            "3": "3",
            "4": "4",
            "5": "5",
            "6": "6",
            "7": "7",
            "8": "8",
            "9": "9",
            "10": "10"
        }
    },
    
    "clock": {
        "format": "{:%H:%M}",
        "format-alt": "{:%Y-%m-%d}",
        "tooltip-format": "<big>{:%Y %B}</big>\n<tt><small>{calendar}</small></tt>"
    },
    
    "battery": {
        "states": {
            "warning": 30,
            "critical": 15
        },
        "format": "{capacity}% {icon}",
        "format-charging": "{capacity}% ",
        "format-plugged": "{capacity}% ",
        "format-icons": ["", "", "", "", ""]
    },
    
    "network": {
        "format-wifi": "{essid} ",
        "format-ethernet": "{ipaddr} ",
        "format-disconnected": "Disconnected ⚠",
        "tooltip-format": "{ifname}: {ipaddr}"
    },
    
    "pulseaudio": {
        "format": "{volume}% {icon}",
        "format-bluetooth": "{volume}% {icon}",
        "format-muted": "",
        "format-icons": {
            "headphone": "",
            "hands-free": "",
            "headset": "",
            "phone": "",
            "portable": "",
            "car": "",
            "default": ["", ""]
        },
        "on-click": "pavucontrol"
    }
}
WAYBAREOF

cat > /home/"\$USERNAME"/.config/waybar/style.css <<'WAYBARCSS'
* {
    border: none;
    border-radius: 0;
    font-family: "Fira Code", monospace;
    font-size: 13px;
    min-height: 0;
}

window#waybar {
    background: rgba(30, 30, 46, 0.9);
    color: #cdd6f4;
}

#workspaces button {
    padding: 0 10px;
    color: #cdd6f4;
    background: transparent;
}

#workspaces button.active {
    background: rgba(137, 180, 250, 0.3);
    color: #89b4fa;
}

#workspaces button:hover {
    background: rgba(205, 214, 244, 0.2);
}

#clock, #battery, #network, #pulseaudio, #tray {
    padding: 0 10px;
    margin: 0 2px;
}

#battery.charging {
    color: #a6e3a1;
}

#battery.warning:not(.charging) {
    color: #f9e2af;
}

#battery.critical:not(.charging) {
    color: #f38ba8;
}
WAYBARCSS

# --- Create basic hyprpaper configuration ---
echo "Creating hyprpaper configuration..."
cat > /home/"\$USERNAME"/.config/hypr/hyprpaper.conf <<'HYPRPAPEREOF'
preload = ~/.config/hypr/wallpaper.jpg
wallpaper = ,~/.config/hypr/wallpaper.jpg
splash = false
HYPRPAPEREOF

# Download wallpaper or skip if it fails
mkdir -p /home/"\$USERNAME"/.config/hypr
if curl -fsSL -o /home/"\$USERNAME"/.config/hypr/wallpaper.png "https://gruvbox-wallpapers.pages.dev/wallpapers/minimalistic/great-wave-of-kanagawa-gruvbox.png"; then
    sed -i 's/wallpaper.jpg/wallpaper.png/g' /home/"\$USERNAME"/.config/hypr/hyprpaper.conf
    echo "Wallpaper downloaded successfully"
else
    echo "Note: Wallpaper download failed, skipping. Add your own wallpaper later."
    # Create blank hyprpaper config
    cat > /home/"\$USERNAME"/.config/hypr/hyprpaper.conf <<'HYPRPAPEREOF'
# Add your wallpaper configuration here
# preload = ~/.config/hypr/wallpaper.png
# wallpaper = ,~/.config/hypr/wallpaper.png
HYPRPAPEREOF
fi

chown -R "\$USERNAME:\$USERNAME" /home/"\$USERNAME"/.config

# --- Verify polkit-gnome path exists ---
if [[ ! -f /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1 ]]; then
    echo "WARNING: polkit-gnome authentication agent not found at expected path"
    echo "Polkit elevation prompts may not work correctly"
fi

# Create screenshots directory
mkdir -p /home/"\$USERNAME"/Pictures/Screenshots
chown -R "\$USERNAME:\$USERNAME" /home/"\$USERNAME"/Pictures

# --- Install AUR packages ---
echo "Installing AUR packages..."
sudo -u "\$USERNAME" bash <<'EOFUSER'
cd /tmp
git clone https://aur.archlinux.org/yay.git
cd yay
makepkg -si --noconfirm

# Install AUR packages
yay -S --noconfirm mbpfan-git || echo "⚠️  Warning: mbpfan-git failed to install"
yay -S --noconfirm bcwc-pcie-git || echo "⚠️  Warning: bcwc-pcie-git failed to install"
yay -S --noconfirm libinput-gestures || echo "⚠️  Warning: libinput-gestures failed to install"

EOFUSER

# --- Configure mbpfan ---
echo "Configuring mbpfan (MacBook fan control)..."
systemctl enable mbpfan

# --- Configure libinput-gestures ---
echo "Configuring touchpad gestures for user $USERNAME..."
runuser -u "$USERNAME" -- mkdir -p /home/$USERNAME/.config
cat <<EOF > /home/$USERNAME/.config/libinput-gestures.conf
gesture swipe left 3 hyprctl dispatch workspace e-1
gesture swipe right 3 hyprctl dispatch workspace e+1
gesture swipe up 3 hyprctl dispatch fullscreen 1
gesture swipe down 3 hyprctl dispatch fullscreen 0
EOF
chown -R $USERNAME:$USERNAME /home/$USERNAME/.config

# Enable autostart for gestures
runuser -u "$USERNAME" -- libinput-gestures-setup autostart
runuser -u "$USERNAME" -- libinput-gestures-setup start


# --- Enable services ---
echo "Enabling services..."
systemctl enable NetworkManager
systemctl enable systemd-timesyncd
systemctl enable tlp
systemctl enable thermald
systemctl enable acpid
systemctl enable greetd

# --- Disable Bluetooth (not needed) ---
echo "Disabling Bluetooth services..."
systemctl mask bluetooth.service
systemctl mask bluetooth.target

# --- Configure NetworkManager to use wpa_supplicant ---
cat > /etc/NetworkManager/conf.d/wifi_backend.conf <<EOL
[device]
wifi.backend=wpa_supplicant
EOL

# --- Configure UFW (not enabled) ---
echo "Configuring firewall rules (NOT enabling)..."
ufw default deny incoming
ufw default allow outgoing
echo "UFW is installed but NOT enabled. Enable it manually with: sudo ufw enable"

# --- Configure greetd ---
# --- Configure greetd (no autologin, prefilled username) ---
echo "Configuring greetd for manual login with prefilled username..."

cat <<EOF > /etc/greetd/config.toml
[terminal]
vt = 1

[default_session]
command = "agreety --cmd 'Hyprland' --username '$USERNAME'"
user = "greeter"
EOF

# --- Configure TLP for battery optimization ---
echo "Configuring TLP..."
cat > /etc/tlp.d/01-battery.conf <<EOL
# Battery thresholds (helps prolong battery life)
START_CHARGE_THRESH_BAT0=75
STOP_CHARGE_THRESH_BAT0=80

# CPU scaling
CPU_SCALING_GOVERNOR_ON_AC=performance
CPU_SCALING_GOVERNOR_ON_BAT=powersave

# Enable audio power saving
SOUND_POWER_SAVE_ON_AC=0
SOUND_POWER_SAVE_ON_BAT=1
EOL

echo ""
echo "========================================"
echo "Installation complete!"
echo "========================================"
EOFSCRIPT

chmod +x /mnt/root/install_continue.sh
arch-chroot /mnt /root/install_continue.sh

echo ""
echo "========================================"
echo "Installation finished successfully!"
echo "========================================"
echo ""
echo "Configuration Summary:"
echo "- Bootloader: $BOOTLOADER"
echo "- Filesystem: $FILESYSTEM"
echo "- Swap: 512MB zram + 2GB swap file"
echo "- Audio: PipeWire (with PulseAudio compatibility)"
echo "- WiFi: wpa_supplicant via NetworkManager"
echo "- Power: TLP + thermald + acpid enabled"
echo "- Firewall: UFW installed but not enabled"
echo "- Mirror updates: Weekly (European servers)"
echo "- MacBook optimizations: mbpfan, bcwc-pcie, gestures"
echo ""
echo "Next steps:"
echo "1. Run: umount -R /mnt"
echo "2. Run: reboot"
echo "3. Remove the USB drive when prompted"
echo ""
echo "After first boot:"
echo "- Connect to WiFi: nmtui or nmcli"
echo "- Test camera: cheese or firefox"
echo "- Configure gestures: edit ~/.config/libinput-gestures.conf"
echo ""
echo "Hyprland shortcuts:"
echo "- SUPER+Enter: Terminal"
echo "- SUPER+SPACE: Application launcher"
echo "- SUPER+E: File manager"
echo "- SUPER+Q: Close window"
echo "- SUPER+L: Lock screen"
echo "- SUPER+SHIFT+S: Screenshot"
echo ""
echo "========================================"









