#!/bin/bash
# ==============================================================================
# ICEMAN OS ARCHITECT - TITANIUM ULTRA (v6.0 - INTERACTIVE EDITION)
# Hardware: AMD Ryzen 9 5950X | AMD Radeon RX 7600 XT
# Arquitectura: Task Loop (Spinners) + Chroot Injection + Saneamiento Seguro
# ==============================================================================

# ── 0. CONFIGURACIÓN INICIAL (SIN STRICT MODE AÚN) ────────────────────────────
# Desactivamos paradas por error para que la recolección de datos no falle
set +e 

C_CYAN='\033[1;36m'
C_GREEN='\033[1;32m'
C_RED='\033[1;31m'
C_YELLOW='\033[1;33m'
C_DEF='\033[0m'

LOG_FILE="/tmp/iceman-install.log"
ERR_LOG="/tmp/iceman-errors.log"
INSTALL_START=$SECONDS

> "$LOG_FILE"
> "$ERR_LOG"

clear
echo -e "${C_CYAN}======================================================${C_DEF}"
echo -e "${C_GREEN}   ICEMAN OS ARCHITECT - TITANIUM ULTRA (v6.0)        ${C_DEF}"
echo -e "${C_CYAN}======================================================${C_DEF}\n"

# ── 1. SANEAMIENTO SILENCIOSO (PRE-FLIGHT) ────────────────────────────────────
echo -e "${C_YELLOW}[!] Saneando entorno Live para evitar cuelgues...${C_DEF}"
if grep -q "cachyos" /etc/pacman.conf 2>/dev/null; then
    sed -i '/\[cachyos\]/,+2d' /etc/pacman.conf 2>/dev/null || true
    sed -i '/cachyos-mirrorlist/d' /etc/pacman.conf 2>/dev/null || true
fi
sleep 1

# ── 2. RECOLECCIÓN DE DATOS (INTERACTIVA Y DIRECTA EN PANTALLA) ───────────────
echo -e "\n${C_CYAN}--- CONFIGURACIÓN DEL SISTEMA ---${C_DEF}"

# Detección de VM para Perfil
IS_VM=$(systemd-detect-virt 2>/dev/null || echo "none")
if [[ "$IS_VM" == "none" ]]; then
    PROFILE_NAME="Full Gaming Bazzite-like (Ryzen 9 + RX 7600 XT)"
    OPT_PARALLEL="15"
    OPT_MAKEFLAGS="-j$(nproc)"
    OPT_BTRFS="compress=zstd:3,ssd,discard=async,space_cache=v2"
    OPT_KERNEL="quiet splash loglevel=3 amdgpu.ppfeaturemask=0xffffffff amd_pstate=active split_lock_detect=off"
    SECURE_BOOT="YES"
else
    PROFILE_NAME="Desktop Limpio (VM Safe Mode)"
    OPT_PARALLEL="4"
    OPT_MAKEFLAGS="-j2"
    OPT_BTRFS="compress=zstd:1,ssd,space_cache=v2"
    OPT_KERNEL="quiet splash loglevel=3 rcu_cpu_stall_timeout=60"
    SECURE_BOOT="NO"
fi

# Selección de Disco (Sin mapfile ni subshells peligrosas)
echo -e "\n${C_CYAN}Discos detectados:${C_DEF}"
lsblk -d -n -p -o NAME,SIZE,MODEL | grep -v "loop" | awk '{print NR ") " $0}'
echo ""
read -p "➤ Selecciona el número del disco para instalar: " D_SEL
D_SEL=${D_SEL:-1}
TARGET_DISK=$(lsblk -d -n -p -o NAME | grep -v "loop" | sed -n "${D_SEL}p")

if [[ -z "$TARGET_DISK" ]]; then
    echo -e "${C_RED}[!] Disco no válido. Cancelando.${C_DEF}"
    exit 1
fi

# Contraseñas y Usuarios
while true; do
    echo ""
    read -s -p "➤ Contraseña Maestra (Root/User): " MASTER_PASS; echo ""
    read -s -p "➤ Confirma Contraseña:            " CONFIRM_PASS; echo ""
    [[ "$MASTER_PASS" == "$CONFIRM_PASS" && -n "$MASTER_PASS" ]] && break || echo -e "${C_RED}[!] Las contraseñas no coinciden. Inténtalo de nuevo.${C_DEF}"
done

echo ""
read -p "➤ Nombre de Usuario [iceman]: " USERNAME; USERNAME=${USERNAME:-iceman}
read -p "➤ Nombre del Equipo [iceman-pc]: " HOSTNAME_PC; HOSTNAME_PC=${HOSTNAME_PC:-iceman-pc}

# ── 3. MOTOR DE TAREAS Y SPINNER (EL LATIDO) ──────────────────────────────────
# A partir de aquí, activamos la detención por errores graves
set -e 

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

run_task() {
    local msg="$1"
    local cmd="$2"
    echo -ne "${C_YELLOW}[*] ${msg}...${C_DEF}"
    # Ejecutamos el comando, enviando su salida a los logs, y capturamos el PID
    eval "$cmd" >> "$LOG_FILE" 2>> "$ERR_LOG" &
    local pid=$!
    spinner $pid
    wait $pid
    local status=$?
    if [ $status -eq 0 ]; then
        echo -e "\r${C_GREEN}[✓] ${msg} completado.${C_DEF}"
    else
        echo -e "\r${C_RED}[✗] Error en: ${msg}. Revisa $ERR_LOG${C_DEF}"
        exit 1
    fi
}

echo -e "\n${C_CYAN}--- INICIANDO INSTALACIÓN ---${C_DEF}"
echo -e "${C_YELLOW}Perfil detectado: $PROFILE_NAME${C_DEF}\n"

# ── 4. PARTICIONADO Y MONTAJE ──────────────────────────────────────────────────
pre_part() {
    umount -A -R /mnt 2>/dev/null || true
    wipefs -a "$TARGET_DISK"
    sgdisk -Z "$TARGET_DISK"
    sgdisk -n 1:0:+1024M -t 1:ef00 -c 1:EFI "$TARGET_DISK"
    sgdisk -n 2:0:0      -t 2:8300 -c 2:ROOT "$TARGET_DISK"
    partprobe "$TARGET_DISK"
    sleep 2
    
    [[ "$TARGET_DISK" == *"nvme"* || "$TARGET_DISK" == *"mmcblk"* ]] && { P_EFI="${TARGET_DISK}p1"; P_ROOT="${TARGET_DISK}p2"; } || { P_EFI="${TARGET_DISK}1"; P_ROOT="${TARGET_DISK}2"; }
    
    mkfs.fat -F32 -n EFI "$P_EFI"
    mkfs.btrfs -f -L ICEMAN_OS "$P_ROOT"
    
    mount "$P_ROOT" /mnt
    btrfs subvolume create /mnt/@
    btrfs subvolume create /mnt/@home
    btrfs subvolume create /mnt/@var_log
    btrfs subvolume create /mnt/@pkg
    btrfs subvolume create /mnt/@cache
    btrfs subvolume create /mnt/@snapshots
    umount /mnt
    
    MO_OPTS="rw,noatime,$OPT_BTRFS"
    mount -o "$MO_OPTS,subvol=@" "$P_ROOT" /mnt
    mkdir -p /mnt/{boot/efi,home,var/log,var/cache/pacman/pkg,var/cache,.snapshots}
    mount -o "$MO_OPTS,subvol=@home" "$P_ROOT" /mnt/home
    mount -o "$MO_OPTS,subvol=@var_log" "$P_ROOT" /mnt/var/log
    mount -o "$MO_OPTS,subvol=@pkg" "$P_ROOT" /mnt/var/cache/pacman/pkg
    mount -o "$MO_OPTS,subvol=@cache" "$P_ROOT" /mnt/var/cache
    mount -o "$MO_OPTS,subvol=@snapshots" "$P_ROOT" /mnt/.snapshots
    mount "$P_EFI" /mnt/boot/efi
}
run_task "Preparando particiones BTRFS en $TARGET_DISK" "pre_part"

# ── 5. INSTALACIÓN BASE ARCH PURO ──────────────────────────────────────────────
base_install() {
    sed -i "s/^#ParallelDownloads.*/ParallelDownloads = $OPT_PARALLEL/" /etc/pacman.conf
    PKGS_BASE="base base-devel linux linux-headers linux-firmware amd-ucode btrfs-progs networkmanager git nano vim wget curl sudo grub efibootmgr os-prober plymouth zram-generator snapper snap-pac grub-btrfs inotify-tools"
    pacstrap -K /mnt $PKGS_BASE
    genfstab -U /mnt >> /mnt/etc/fstab
}
run_task "Instalando sistema base de Arch Linux" "base_install"

# ── 6. MATRIZ DE INYECCIÓN CHROOT ─────────────────────────────────────────────
# Preparamos las variables para el interior del chroot
cat << EOF > /mnt/root/vars.sh
USERNAME="$USERNAME"
MASTER_PASS="$MASTER_PASS"
HOSTNAME_PC="$HOSTNAME_PC"
OPT_PARALLEL="$OPT_PARALLEL"
OPT_MAKEFLAGS="$OPT_MAKEFLAGS"
OPT_KERNEL="$OPT_KERNEL"
SECURE_BOOT="$SECURE_BOOT"
IS_VM="$IS_VM"
EOF

# Creamos el script interno
cat << 'CHROOT_EOF' > /mnt/root/internal.sh
#!/bin/bash
set -e
source /root/vars.sh
export MAKEFLAGS="$OPT_MAKEFLAGS"

# [A] Pacman & Multilib
sed -i "s/^#ParallelDownloads.*/ParallelDownloads = $OPT_PARALLEL/" /etc/pacman.conf
sed -i 's/^#Color/Color\nILoveCandy/' /etc/pacman.conf
echo -e "\n[multilib]\nInclude = /etc/pacman.d/mirrorlist" >> /etc/pacman.conf

# [B] CachyOS Kernel Injection
pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
pacman-key --lsign-key F3B607488DB35A47
echo -e "\n[cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n" >> /etc/pacman.conf
echo -e "Server = https://mirror.cachyos.org/repo/x86_64/cachyos" > /etc/pacman.d/cachyos-mirrorlist
pacman -Sy --noconfirm cachyos-keyring cachyos-mirrorlist cachyos-settings cachyos-hooks
pacman -Sy --noconfirm linux-cachyos linux-cachyos-headers
pacman -Rns --noconfirm linux linux-headers || true

# [C] Localización y Red
ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
hwclock --systohc
echo -e "es_ES.UTF-8 UTF-8\nen_US.UTF-8 UTF-8" > /etc/locale.gen && locale-gen
echo "LANG=es_ES.UTF-8" > /etc/locale.conf
echo "KEYMAP=es" > /etc/vconsole.conf
echo "$HOSTNAME_PC" > /etc/hostname
printf "127.0.0.1\tlocalhost\n::1\t\tlocalhost\n127.0.1.1\t%s.localdomain %s\n" "$HOSTNAME_PC" "$HOSTNAME_PC" > /etc/hosts

# [D] Usuarios, Grupos y Wayland
echo "root:$MASTER_PASS" | chpasswd
useradd -m -G wheel,video,audio,storage,network,input,gamemode -s /bin/bash "$USERNAME"
echo "$USERNAME:$MASTER_PASS" | chpasswd
echo "%wheel ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-wheel

cat << 'ENV_VARS' >> /etc/environment
ELECTRON_OZONE_PLATFORM_HINT=auto
MOZ_ENABLE_WAYLAND=1
ENV_VARS

# [E] Drivers, Audio y GNOME Core
pacman -S --needed --noconfirm xf86-video-amdgpu mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon libva-mesa-driver lib32-libva-mesa-driver
pacman -S --needed --noconfirm pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber gst-plugins-good gst-plugins-bad gst-plugins-ugly bluez bluez-utils
pacman -S --needed --noconfirm gnome gnome-tweaks gdm xdg-desktop-portal-gnome firefox flatpak unzip tar dconf

# [F] Gaming Stack Bazzite-like
if [[ "$IS_VM" == "none" ]]; then
    pacman -S --needed --noconfirm steam lutris wine-staging winetricks gamemode lib32-gamemode corectrl mangohud vkbasalt ananicy-cpp
fi

mkdir -p /etc/pipewire/pipewire.conf.d
cat << 'PIPEWIRE' > /etc/pipewire/pipewire.conf.d/92-low-latency.conf
context.properties = {
    default.clock.rate = 48000
    default.clock.allowed-rates = [ 44100 48000 88200 96000 ]
    default.clock.min-quantum = 32
    default.clock.max-quantum = 1024
}
PIPEWIRE

# [G] YAY, AUR y Temas
sudo -u "$USERNAME" bash -c "cd /tmp && git clone --depth=1 https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm"
sudo -u "$USERNAME" yay -S --noconfirm pamac-aur btrfs-assistant extension-manager ttf-ms-fonts
sudo -u "$USERNAME" yay -S --noconfirm adw-gtk3-git papirus-icon-theme qogir-cursor-theme gnome-shell-extension-blur-my-shell gnome-shell-extension-vitals

# [H] Inyección de Wallpapers y DCONF Nativo
mkdir -p /usr/share/backgrounds/iceman /usr/share/gnome-background-properties
git clone --depth=1 https://github.com/Ic3MaN77/iceman-installer.git /tmp/iceman_assets || true
if [ -d "/tmp/iceman_assets/wallpapers" ]; then
    cp /tmp/iceman_assets/wallpapers/*.webp /usr/share/backgrounds/iceman/ 2>/dev/null || true
    cp /usr/share/backgrounds/iceman/Cyberpunk_City.webp /usr/share/backgrounds/iceman/default.webp 2>/dev/null || cp /usr/share/backgrounds/iceman/*.webp /usr/share/backgrounds/iceman/default.webp 2>/dev/null || true
    
    echo '<?xml version="1.0" encoding="UTF-8"?><wallpapers>' > /usr/share/gnome-background-properties/iceman.xml
    for wp in /usr/share/backgrounds/iceman/*.webp; do
        echo "<wallpaper><name>$(basename "$wp" .webp)</name><filename>$wp</filename><options>zoom</options></wallpaper>" >> /usr/share/gnome-background-properties/iceman.xml
    done
    echo '</wallpapers>' >> /usr/share/gnome-background-properties/iceman.xml
fi

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

# [I] Optimizaciones Gaming (Sysctl, ZRAM y Polkit)
cat << 'SYSCTL_EOF' > /etc/sysctl.d/99-gaming.conf
vm.swappiness = 10
vm.max_map_count = 2147483642
kernel.split_lock_mitigate = 0
SYSCTL_EOF

cat << 'CORECTRL_EOF' > /etc/polkit-1/rules.d/90-corectrl.rules
polkit.addRule(function(action, subject) {
    if ((action.id == "org.corectrl.helper.init" || action.id == "org.corectrl.helperkiller.init") && subject.local == true && subject.active == true && subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
CORECTRL_EOF

cat << 'ZRAM' > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
ZRAM

# [J] ZSH + Fastfetch
pacman -S --needed --noconfirm zsh fastfetch
sudo -u "$USERNAME" git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git /home/$USERNAME/.oh-my-zsh || true
sudo -u "$USERNAME" bash -c "echo -e 'export ZSH=\"\$HOME/.oh-my-zsh\"\nZSH_THEME=\"robbyrussell\"\nplugins=(git sudo zsh-autosuggestions zsh-syntax-highlighting)\nsource \$ZSH/oh-my-zsh.sh\nfastfetch -l cachyos' > /home/$USERNAME/.zshrc" || true
chsh -s /usr/bin/zsh "$USERNAME" || true

# [K] Arranque, GRUB Particle Circle y Plymouth
sed -i "/^HOOKS=/c\HOOKS=(base udev plymouth autodetect modconf kms keyboard keymap consolefont block filesystems fsck btrfs)" /etc/mkinitcpio.conf
mkinitcpio -P
plymouth-set-default-theme -R bgrt || true

wget -qO /tmp/grubtheme.tar.gz "https://github.com/yeyushengfan258/Particle-circle-grub-theme/archive/refs/heads/main.tar.gz" || true
mkdir -p /usr/share/grub/themes/Particle-circle
tar -xf /tmp/grubtheme.tar.gz --strip-components=1 -C /usr/share/grub/themes/Particle-circle/ || true

RAW_RES=$(cat /sys/class/drm/*/modes 2>/dev/null | head -n 1 || echo "1920x1080")
sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\".*\"|GRUB_CMDLINE_LINUX_DEFAULT=\"$OPT_KERNEL\"|" /etc/default/grub
sed -i 's/^#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
echo "GRUB_GFXMODE=${RAW_RES}x32" >> /etc/default/grub
echo 'GRUB_THEME="/usr/share/grub/themes/Particle-circle/theme.txt"' >> /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ICEMAN_OS
grub-mkconfig -o /boot/grub/grub.cfg

# [L] Secure Boot Auto-Enroll
if [ "$SECURE_BOOT" == "YES" ]; then
    pacman -S --noconfirm sbctl
    sbctl create-keys || true
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
    systemctl enable sb-auto-enroll.service
fi

# [M] Servicios y Limpieza
snapper --no-dbus -c root create-config / || true
chmod 750 /.snapshots || true
sed -i "s/^ALLOW_USERS=.*/ALLOW_USERS=\"$USERNAME\"/" /etc/snapper/configs/root || true

systemctl enable gdm NetworkManager bluetooth systemd-zram-setup@zram0.service btrfs-scrub@-.timer snapper-timeline.timer
if [[ "$IS_VM" == "none" ]]; then
    systemctl enable ananicy-cpp || true
fi

rm -rf /tmp/yay-bin /tmp/iceman_assets /tmp/grubtheme.tar.gz
paccache -rk1 || true
CHROOT_EOF

chmod +x /mnt/root/internal.sh
CHROOT_EOF

run_task "Inyectando y configurando núcleo (puede tardar varios minutos)" "arch-chroot /mnt /root/internal.sh"

# ── 7. SELLADO Y DESMONTAJE ────────────────────────────────────────────────────
post_install() {
    rm -f /mnt/root/vars.sh /mnt/root/internal.sh
    cp "$LOG_FILE" /mnt/var/log/iceman_install.log 2>/dev/null || true
    umount -R /mnt
}
run_task "Finalizando y desmontando particiones" "post_install"

# ── 8. PANTALLA DE RESUMEN FINAL ───────────────────────────────────────────────
ELAPSED=$(( SECONDS - INSTALL_START ))

echo -e "\n${C_GREEN}╔══════════════════════════════════════════╗${C_DEF}"
echo -e "${C_GREEN}║     INSTALACIÓN COMPLETADA CON ÉXITO     ║${C_DEF}"
echo -e "${C_GREEN}╠══════════════════════════════════════════╣${C_DEF}"
printf "${C_GREEN}║${C_DEF}  %-14s: ${C_YELLOW}%s${C_DEF}\n" "Hostname"     "$HOSTNAME_PC"
printf "${C_GREEN}║${C_DEF}  %-14s: ${C_YELLOW}%s${C_DEF}\n" "Usuario"      "$USERNAME"
printf "${C_GREEN}║${C_DEF}  %-14s: ${C_YELLOW}%s${C_DEF}\n" "GRUB Theme"   "Particle Circle"
printf "${C_GREEN}║${C_DEF}  %-14s: ${C_YELLOW}%s${C_DEF}\n" "Perfil"       "$PROFILE_NAME"
printf "${C_GREEN}║${C_DEF}  %-14s: ${C_YELLOW}%d min %d seg${C_DEF}\n" "Tiempo total" "$(( ELAPSED / 60 ))" "$(( ELAPSED % 60 ))"
echo -e "${C_GREEN}╚══════════════════════════════════════════╝${C_DEF}"

if [[ "$SECURE_BOOT" == "YES" ]]; then
    echo -e "\n${C_YELLOW}🚀 PASO FINAL: ACTIVAR SECURE BOOT${C_DEF}"
    echo -e "Tu sistema ha sido firmado digitalmente, pero tu placa base aún necesita reconocerlo."
    echo -e "Sigue estos 3 pasos antes de jugar:"
    echo -e "  ${C_CYAN}1.${C_DEF} Escribe 'reboot' y entra en la BIOS."
    echo -e "  ${C_CYAN}2.${C_DEF} Ve a la sección de Seguridad y pon Secure Boot en 'Setup Mode' (o borra las llaves de fábrica PK/KEK)."
    echo -e "  ${C_CYAN}3.${C_DEF} Inicia el sistema normalmente. El script de Auto-Enrollamiento hará el resto en el primer arranque."
else
    echo -e "\n${C_CYAN}Escribe 'reboot' para entrar en tu nueva estación de combate.${C_DEF}"
fi
