#!/bin/bash
# ==============================================================================
# ICEMAN OS - ICE-GNOME-ULTRA (v5.0 - THE DEFINITIVE MASTERPIECE)
# Arquitectura: Clean Room (Host -> Chroot Inyectado)
# Target: AMD Ryzen 9 5950X | AMD Radeon RX 7600 XT | CachyOS Kernel
# Contenido: 100% Core + 100% User-Space Apps + Bazzite-like Gaming
# ==============================================================================

set -Eeuo pipefail

LOG_FILE="/tmp/iceman_ultra_install.log"
> "$LOG_FILE"

# --- Funciones de Interfaz ---
print_info() { echo -e "\033[1;36m[i] $1\033[0m"; }
print_success() { echo -e "\033[1;32m[✓] $1\033[0m"; }
print_error() { 
    echo -e "\n\033[1;31m[!] FATAL ERROR: $1\033[0m"
    tail -n 20 "$LOG_FILE"
    exit 1
}

run() {
    echo -n -e "\033[1;33m[...] $1...\033[0m"
    if eval "$2" >> "$LOG_FILE" 2>&1; then
        echo -e "\r\033[1;32m[✓] $1... OK!\033[0m\033[K"
    else
        echo -e "\r\033[1;31m[✗] $1... FALLÓ!\033[0m\033[K"
        print_error "Error en la fase: $1"
    fi
}

# ==============================================================================
# FASE 1: RECOPILACIÓN DE DATOS E INFRAESTRUCTURA (HOST)
# ==============================================================================
clear
echo -e "\033[1;36m==============================================================\033[0m"
echo -e "\033[1;36m          ICEMAN OS - ICE GNOME ULTRA DEPLOYMENT              \033[0m"
echo -e "\033[1;36m==============================================================\033[0m\n"

timedatectl set-ntp true

# Selección de Hardware
mapfile -t DISKS < <(lsblk -d -n -p -o NAME,SIZE,MODEL | grep -v "loop")
for i in "${!DISKS[@]}"; do echo "  $((i+1))) ${DISKS[$i]}"; done
read -p "➤ Selecciona disco de instalación [1]: " D_SEL; D_SEL=${D_SEL:-1}
TARGET_DISK=$(echo "${DISKS[$((D_SEL-1))]}" | awk '{print $1}')

# Credenciales y Seguridad
read -p "➤ ¿Cifrar disco con LUKS2 (Argon2id)? (s/N): " ANS_LUKS
if [[ "${ANS_LUKS,,}" == "s" ]]; then
    USE_LUKS="YES"
    while true; do
        read -s -p "  ➤ Contraseña Maestra (LUKS/Root/User): " MASTER_PASS; echo ""
        read -s -p "  ➤ Confirma Contraseña Maestra:         " CONFIRM_PASS; echo ""
        [[ "$MASTER_PASS" == "$CONFIRM_PASS" && -n "$MASTER_PASS" ]] && break || echo -e "\033[1;31m[!] Las contraseñas no coinciden.\033[0m"
    done
else 
    USE_LUKS="NO"
    while true; do
        read -s -p "  ➤ Contraseña (Root/User): " MASTER_PASS; echo ""
        read -s -p "  ➤ Confirma Contraseña:    " CONFIRM_PASS; echo ""
        [[ "$MASTER_PASS" == "$CONFIRM_PASS" && -n "$MASTER_PASS" ]] && break || echo -e "\033[1;31m[!] Las contraseñas no coinciden.\033[0m"
    done
fi

read -p "➤ Usuario [iceman]: " USERNAME; USERNAME=${USERNAME:-iceman}
read -p "➤ Hostname [iceman-pc]: " HOSTNAME_PC; HOSTNAME_PC=${HOSTNAME_PC:-iceman-pc}

# Enlaces a los Assets
CURSOR_URL="https://github.com/vinceliuice/Qogir-icon-theme/archive/refs/tags/2023-06-05.tar.gz"
GRUB_THEME_URL="https://github.com/yeyushengfan258/Particle-circle-grub-theme/archive/refs/heads/main.tar.gz"

RAW_RES=$(cat /sys/class/drm/*/modes 2>/dev/null | head -n 1 || echo "1920x1080")
GRUB_GFXMODE="${RAW_RES}x32"

# 1.1 Limpieza y Particionado
run "Desmontando sistemas previos" "umount -A -R /mnt 2>/dev/null || true; cryptsetup close cryptroot 2>/dev/null || true"
run "Limpieza de tabla de particiones en $TARGET_DISK" "wipefs -a $TARGET_DISK; sgdisk -Z $TARGET_DISK"
run "Creando particiones GPT (EFI + ROOT)" "
    sgdisk -n 1:0:+1024M -t 1:ef00 -c 1:EFI $TARGET_DISK
    sgdisk -n 2:0:0      -t 2:8300 -c 2:ROOT $TARGET_DISK
    partprobe $TARGET_DISK; sleep 2
"

[[ "$TARGET_DISK" == *"nvme"* || "$TARGET_DISK" == *"mmcblk"* ]] && { P_EFI="${TARGET_DISK}p1"; P_ROOT="${TARGET_DISK}p2"; } || { P_EFI="${TARGET_DISK}1"; P_ROOT="${TARGET_DISK}2"; }

# 1.2 Formateo y LUKS
run "Formateando partición EFI" "mkfs.fat -F32 -n EFI $P_EFI"
if [[ "$USE_LUKS" == "YES" ]]; then
    run "Cifrando partición ROOT (LUKS2 + Argon2id)" "
        echo -n '$MASTER_PASS' | cryptsetup luksFormat --type luks2 --pbkdf argon2id $P_ROOT -
        echo -n '$MASTER_PASS' | cryptsetup open $P_ROOT cryptroot -
    "
    M_ROOT="/dev/mapper/cryptroot"
else M_ROOT="$P_ROOT"; fi

# 1.3 Infraestructura BTRFS
run "Estructurando subvolúmenes BTRFS" "
    mkfs.btrfs -f -L ICEMAN_OS $M_ROOT
    mount $M_ROOT /mnt
    for sv in @ @home @var_log @pkg @cache @snapshots; do btrfs subvolume create /mnt/\$sv; done
    umount /mnt
"

run "Montando árbol final BTRFS" "
    B_OPTS='rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2'
    mount -o \$B_OPTS,subvol=@ $M_ROOT /mnt
    mkdir -p /mnt/{boot/efi,home,var/log,var/cache/pacman/pkg,var/cache,.snapshots}
    mount -o \$B_OPTS,subvol=@home $M_ROOT /mnt/home
    mount -o \$B_OPTS,subvol=@var_log $M_ROOT /mnt/var/log
    mount -o \$B_OPTS,subvol=@pkg $M_ROOT /mnt/var/cache/pacman/pkg
    mount -o \$B_OPTS,subvol=@cache $M_ROOT /mnt/var/cache
    mount -o \$B_OPTS,subvol=@snapshots $M_ROOT /mnt/.snapshots
    mount $P_EFI /mnt/boot/efi
"

# 1.4 Repositorios y Sistema Base (Pacstrap)
run "Configurando repositorios CachyOS en Host" "
    pacman -Sy --noconfirm archlinux-keyring cachyos-keyring
    sed -i '/\[cachyos\]/,+1d' /etc/pacman.conf || true
    printf '\n[cachyos]\nServer = https://mirror.cachyos.org/repo/x86_64/cachyos\n' >> /etc/pacman.conf
    pacman -Sy
"

CORE_PKGS="base base-devel linux-cachyos linux-cachyos-headers linux-firmware amd-ucode cachyos-keyring cachyos-mirrorlist cachyos-settings cachyos-hooks btrfs-progs btrfsmaintenance networkmanager git nano vim wget curl sudo zram-generator ufw apparmor grub efibootmgr os-prober plymouth plymouth-theme-spinner snapper snap-pac grub-btrfs inotify-tools sbctl"
FS_PKGS="ntfs-3g exfatprogs dosfstools mtools fuse3 unzip p7zip rsync"
[[ "$USE_LUKS" == "YES" ]] && CORE_PKGS="$CORE_PKGS cryptsetup"

run "Inyectando Sistema Base (Pacstrap)" "pacstrap -K /mnt $CORE_PKGS $FS_PKGS"

run "Generando fstab y crypttab" "
    genfstab -U /mnt >> /mnt/etc/fstab
    [[ '$USE_LUKS' == 'YES' ]] && echo \"cryptroot UUID=\$(blkid -s UUID -o value $P_ROOT) none luks,discard\" > /mnt/etc/crypttab || true
"

# ==============================================================================
# FASE 2: CONSTRUCCIÓN DEL ENTORNO 'CLEAN ROOM' (EL MOTOR CHROOT)
# ==============================================================================
print_info "Ensamblando motor de configuración interna (Arquitectura Aislada)..."

cat << EOF > /mnt/root/install_vars.sh
USERNAME="$USERNAME"
MASTER_PASS="$MASTER_PASS"
HOSTNAME_PC="$HOSTNAME_PC"
USE_LUKS="$USE_LUKS"
GRUB_GFXMODE="$GRUB_GFXMODE"
CURSOR_URL="$CURSOR_URL"
GRUB_THEME_URL="$GRUB_THEME_URL"
EOF

cat << 'CHROOT_EOF' > /mnt/root/install_internal.sh
#!/bin/bash
set -Eeuo pipefail
source /root/install_vars.sh
export MAKEFLAGS="-j$(nproc)"

# A. OPTIMIZACIÓN DE PACMAN Y REPOS
sed -i '/^\[core\]/i [cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n' /etc/pacman.conf
echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf
sed -i 's/^#Color/Color\nILoveCandy/' /etc/pacman.conf
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 15/' /etc/pacman.conf
pacman -Sy --noconfirm

# B. LOCALIZACIÓN
ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
hwclock --systohc
echo -e "es_ES.UTF-8 UTF-8\nen_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=es_ES.UTF-8" > /etc/locale.conf
echo "KEYMAP=es" > /etc/vconsole.conf
echo "$HOSTNAME_PC" > /etc/hostname
printf "127.0.0.1\tlocalhost\n::1\t\tlocalhost\n127.0.1.1\t%s.localdomain %s\n" "$HOSTNAME_PC" "$HOSTNAME_PC" > /etc/hosts

# C. USUARIO Y VARIABLES GLOBALES (Wayland Nativo)
echo "root:$MASTER_PASS" | chpasswd
useradd -m -G wheel,video,audio,storage,network,input,gamemode -s /bin/bash "$USERNAME"
echo "$USERNAME:$MASTER_PASS" | chpasswd
echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-wheel

cat << 'ENV_VARS' >> /etc/environment
# Forzar Electron/Chromium en Wayland Nativo
ELECTRON_OZONE_PLATFORM_HINT=auto
MOZ_ENABLE_WAYLAND=1
ENV_VARS

# D. INSTALACIÓN DE MÓDULOS (AMD, UI, Multimedia Pro)
PACMAN_CMD="pacman -S --needed --noconfirm"

# D.1 Drivers AMD y Multimedia (GStreamer Full)
$PACMAN_CMD xf86-video-amdgpu mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon libva-mesa-driver lib32-libva-mesa-driver
$PACMAN_CMD pipewire pipewire-audio pipewire-alsa pipewire-pulse pipewire-jack wireplumber gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav bluez bluez-utils

# D.2 Audio Low-Latency (Pro Audio Bazzite-like)
mkdir -p /etc/pipewire/pipewire.conf.d
cat << 'PIPEWIRE' > /etc/pipewire/pipewire.conf.d/92-low-latency.conf
context.properties = {
    default.clock.rate = 48000
    default.clock.allowed-rates = [ 44100 48000 88200 96000 ]
    default.clock.min-quantum = 32
    default.clock.max-quantum = 1024
}
PIPEWIRE

# D.3 Entorno GNOME y Flatpak
$PACMAN_CMD gnome gnome-tweaks gdm xdg-desktop-portal-gnome firefox gnome-shell-extension-dash-to-dock gnome-shell-extension-appindicator flatpak
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true

# D.4 Gaming Bazzite-Like
$PACMAN_CMD steam steam-native-runtime lutris wine-staging winetricks gamemode lib32-gamemode corectrl mangohud vkbasalt ananicy-cpp

# E. COMPILACIÓN AUR Y GESTIÓN (THE MISSING PIECES RESTORED)
sudo -u "$USERNAME" bash -c "cd /tmp && git clone --depth=1 https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm"

# E.1 Herramientas de Gestión Gráfica y Productividad
sudo -u "$USERNAME" yay -S --noconfirm pamac-aur libpamac-flatpak-plugin btrfs-assistant mission-center stacer-bin onlyoffice-bin extension-manager ttf-ms-fonts

# E.2 Drivers de Mandos Xbox/PS, Extensiones y Temas Visuales
sudo -u "$USERNAME" yay -S --noconfirm xone-dkms xpadneo-dkms input-remapper-git \
    adw-gtk3-git papirus-icon-theme qogir-cursor-theme \
    gnome-shell-extension-blur-my-shell gnome-shell-extension-vitals

# F. BLINDAJE Y RENDIMIENTO (UFW, AppArmor, ZRAM)
ufw default deny incoming
ufw default allow outgoing
cat << 'ZRAM' > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
ZRAM

# F.2 Auto-Limpieza de Shaders (Mantenimiento Automático)
cat << 'SHADERS_SH' > /usr/local/bin/clean-shaders.sh
#!/bin/bash
find /home/*/.cache/mesa_shader_cache -type f -atime +30 -delete 2>/dev/null || true
SHADERS_SH
chmod +x /usr/local/bin/clean-shaders.sh

cat << 'SHADERS_SRV' > /etc/systemd/system/clean-shaders.service
[Unit]
Description=Limpieza de Cache de Shaders AMD
[Service]
Type=oneshot
ExecStart=/usr/local/bin/clean-shaders.sh
SHADERS_SRV

cat << 'SHADERS_TMR' > /etc/systemd/system/clean-shaders.timer
[Unit]
Description=Timer Semanal para Shaders
[Timer]
OnCalendar=weekly
Persistent=true
[Install]
WantedBy=timers.target
SHADERS_TMR

# F.3 Health Check System (Notificador de Errores en Boot)
cat << 'HEALTH_SH' > /usr/local/bin/iceman-health.sh
#!/bin/bash
FAILED=\$(systemctl --failed --no-legend | wc -l)
if [ "\$FAILED" -gt 0 ]; then
    logger -p user.err "ICEMAN HEALTH: \$FAILED servicios fallaron en el arranque. Se sugiere verificar Snapper."
fi
HEALTH_SH
chmod +x /usr/local/bin/iceman-health.sh

cat << 'HEALTH_SRV' > /etc/systemd/system/iceman-health.service
[Unit]
Description=Iceman OS Health Check
After=multi-user.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/iceman-health.sh
[Install]
WantedBy=multi-user.target
HEALTH_SRV

# G. INYECCIÓN VISUAL Y FLATPAK OVERRIDES
# Global Flatpak Overrides para integrar Temas en Apps
flatpak override --system --filesystem=~/.themes
flatpak override --system --filesystem=~/.icons
flatpak override --system --env=XCURSOR_PATH=/usr/share/icons:~/.local/share/icons

mkdir -p /usr/share/backgrounds/iceman /usr/share/gnome-background-properties
git clone --depth=1 https://github.com/Ic3MaN77/iceman-installer.git /tmp/iceman_assets
cp /tmp/iceman_assets/wallpapers/*.webp /usr/share/backgrounds/iceman/ 2>/dev/null || true
cp /usr/share/backgrounds/iceman/*.webp /usr/share/backgrounds/iceman/default.webp 2>/dev/null || true

echo '<?xml version="1.0" encoding="UTF-8"?><wallpapers>' > /usr/share/gnome-background-properties/iceman.xml
for wp in /usr/share/backgrounds/iceman/*.webp; do
    echo "<wallpaper><name>$(basename "$wp" .webp)</name><filename>$wp</filename><options>zoom</options></wallpaper>" >> /usr/share/gnome-background-properties/iceman.xml
done
echo '</wallpapers>' >> /usr/share/gnome-background-properties/iceman.xml

mkdir -p /etc/dconf/profile /etc/dconf/db/local.d
echo -e "user-db:user\nsystem-db:local" > /etc/dconf/profile/user
cat << 'DCONF_EOF' > /etc/dconf/db/local.d/01-iceman-core
[org/gnome/desktop/interface]
color-scheme='prefer-dark'
gtk-theme='adw-gtk3-dark'
icon-theme='Papirus-Dark'
cursor-theme='Qogir-dark'

[org/gnome/desktop/background]
picture-uri='file:///usr/share/backgrounds/iceman/default.webp'
picture-uri-dark='file:///usr/share/backgrounds/iceman/default.webp'

[org/gnome/shell]
disable-user-extensions=false
enabled-extensions=['dash-to-dock@micxgx.gmail.com', 'blur-my-shell@aunetx', 'Vitals@CoreCoding.com', 'appindicatorsupport@rgcjonas.gmail.com']
DCONF_EOF
dconf update

# H. MOTOR DE ARRANQUE (Mkinitcpio, AMD P-State, GRUB, Plymouth)
if [ "$USE_LUKS" == "YES" ]; then
    sed -i '/^HOOKS=/c\HOOKS=(base udev plymouth autodetect modconf kms keyboard keymap consolefont block encrypt filesystems fsck btrfs)' /etc/mkinitcpio.conf
else
    sed -i '/^HOOKS=/c\HOOKS=(base udev plymouth autodetect modconf kms keyboard keymap consolefont block filesystems fsck btrfs)' /etc/mkinitcpio.conf
fi
sed -i '/^MODULES=/c\MODULES=(btrfs amdgpu)' /etc/mkinitcpio.conf
mkinitcpio -P

plymouth-set-default-theme -R bgrt || true

# Extracción de Tema Particle
wget -qO /tmp/grubtheme.tar.gz "$GRUB_THEME_URL" || true
mkdir -p /usr/share/grub/themes/Particle-circle
tar -xf /tmp/grubtheme.tar.gz --strip-components=1 -C /usr/share/grub/themes/Particle-circle/ || true

sed -i 's/^#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
# AMD P-State EPP Active inyectado para latencia ultra-baja
CMD="quiet splash loglevel=3 amdgpu.ppfeaturemask=0xffffffff amd_pstate=active apparmor=1 lsm=landlock,lockdown,yama,integrity,apparmor,bpf"
sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\".*\"|GRUB_CMDLINE_LINUX_DEFAULT=\"$CMD\"|" /etc/default/grub
echo "GRUB_GFXMODE=$GRUB_GFXMODE" >> /etc/default/grub
echo 'GRUB_THEME="/usr/share/grub/themes/Particle-circle/theme.txt"' >> /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ICEMAN_OS
grub-mkconfig -o /boot/grub/grub.cfg

# I. SECURE BOOT AUTO-ENROLL
sbctl create-keys
sbctl sign -s /boot/vmlinuz-linux-cachyos || true
sbctl sign -s /boot/efi/EFI/ICEMAN_OS/grubx64.efi || true

cat << 'SBAUTO_SH' > /usr/local/bin/sb-auto-enroll.sh
#!/bin/bash
if sbctl status | grep -q "Setup Mode:.*Enabled"; then
    sbctl enroll-keys -m
    systemctl disable sb-auto-enroll.service
    rm /etc/systemd/system/sb-auto-enroll.service /usr/local/bin/sb-auto-enroll.sh
fi
SBAUTO_SH
chmod +x /usr/local/bin/sb-auto-enroll.sh

cat << 'SBAUTO_SRV' > /etc/systemd/system/sb-auto-enroll.service
[Unit]
Description=Iceman Secure Boot Auto-Enroll
After=network.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/sb-auto-enroll.sh
RemainAfterExit=yes
[Install]
WantedBy=multi-user.target
SBAUTO_SRV

# J. MANTENIMIENTO ACTIVO (Snapper y ZSH)
snapper --no-dbus -c root create-config /
chmod 750 /.snapshots
sed -i "s/^ALLOW_USERS=.*/ALLOW_USERS=\"$USERNAME\"/" /etc/snapper/configs/root

pacman -S --needed --noconfirm zsh fastfetch
sudo -u "$USERNAME" git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git /home/$USERNAME/.oh-my-zsh
sudo -u "$USERNAME" bash -c "echo -e 'export ZSH=\"\$HOME/.oh-my-zsh\"\nZSH_THEME=\"robbyrussell\"\nplugins=(git sudo zsh-autosuggestions zsh-syntax-highlighting)\nsource \$ZSH/oh-my-zsh.sh\nfastfetch -l cachyos' > /home/$USERNAME/.zshrc"
chsh -s /usr/bin/zsh "$USERNAME"

# K. ACTIVACIÓN DE SERVICIOS
systemctl enable gdm NetworkManager bluetooth ufw apparmor ananicy-cpp reflector.timer
systemctl enable grub-btrfsd systemd-zram-setup@zram0.service btrfs-scrub@-.timer snapper-timeline.timer
systemctl enable input-remapper clean-shaders.timer iceman-health.service sb-auto-enroll.service

# Limpieza Profunda
rm -rf /tmp/yay-bin /tmp/iceman_assets /tmp/grubtheme.tar.gz
paccache -rk1 || true
CHROOT_EOF

chmod +x /mnt/root/install_internal.sh

# ==============================================================================
# FASE 3: INYECCIÓN Y CIERRE
# ==============================================================================
run "Iniciando despliegue Chroot Nativo" "arch-chroot /mnt /root/install_internal.sh"

run "Sellando entorno y limpiando logs" "
    rm -f /mnt/root/install_vars.sh /mnt/root/install_internal.sh
    cp $LOG_FILE /mnt/var/log/iceman_ultra_install.log
    umount -R /mnt
"

echo -e "\n\033[1;32m==============================================================\033[0m"
echo -e "\033[1;32m   ICE-GNOME-ULTRA DESPLEGADO CON ÉXITO ABSOLUTO              \033[0m"
echo -e "\033[1;32m==============================================================\033[0m"
echo -e "\033[1;33m[i] AUTO-ENROLL PREPARADO:\033[0m"
echo -e "Las llaves están creadas y el servicio 'oneshot' está armado."
echo -e "Si reinicias y tu BIOS está en Setup Mode, el sistema registrará las llaves"
echo -e "automáticamente y destruirá el script de registro para no dejar rastro."
echo -e "¡Tu estación de combate te espera! Escribe 'reboot'."
