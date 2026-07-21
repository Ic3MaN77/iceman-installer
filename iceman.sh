#!/bin/bash
# ==============================================================================
# ARCH LINUX + CACHYOS INSTALLER (EDICIÓN ICEMAN)
# Hardware Target: Ryzen 9 5950X, AMD RX 7600 XT, B550 Aorus
# ==============================================================================

set -eo pipefail

# --- Variables Globales y Colores ---
C_BLUE="\033[1;34m"
C_CYAN="\033[1;36m"
C_GREEN="\033[1;32m"
C_RED="\033[1;31m"
C_YELLOW="\033[1;33m"
C_NC="\033[0m"

LOG_FILE="/var/log/iceman_install.log"
USER_NAME="Iceman"
HOSTNAME_DEF="Arch-Gaming-Rig"
TIMEZONE="Europe/Madrid"
LOCALE="es_ES.UTF-8"
KEYMAP="es"

# --- Sistema de Control de Errores ---
exec 3>&1 4>&2 # Guardar stdout y stderr originales
trap 'manejar_error $LINENO' ERR

manejar_error() {
    local linea=$1
    echo -e "${C_RED}\n[!] FALLO CRÍTICO EN LA LÍNEA ${linea}.${C_NC}" >&3
    echo -e "${C_YELLOW}--- ÚLTIMAS 15 LÍNEAS DEL LOG ---${C_NC}" >&3
    tail -n 15 "$LOG_FILE" >&3
    echo -e "${C_RED}\nInstalación abortada. Revisa el log completo en $LOG_FILE${C_NC}" >&3
    exit 1
}

msg() { echo -e "${C_CYAN}:: ${1}${C_NC}" >&3; echo ":: ${1}" >> "$LOG_FILE"; }
msg_ok() { echo -e "${C_GREEN} [OK] ${1}${C_NC}" >&3; echo "[OK] ${1}" >> "$LOG_FILE"; }

clear >&3
echo -e "${C_BLUE}=================================================${C_NC}" >&3
echo -e "${C_BLUE}    INSTALADOR ARCH LINUX + CACHYOS (ICEMAN)     ${C_NC}" >&3
echo -e "${C_BLUE}=================================================${C_NC}" >&3
echo "Iniciando log en $LOG_FILE" > "$LOG_FILE"

# ==============================================================================
# FASE 1: PRE-VUELO Y RECOLECCIÓN DE DATOS
# ==============================================================================
msg "Comprobando entorno UEFI..."
if [ ! -d /sys/firmware/efi/efivars ]; then
    echo -e "${C_RED}ERROR: Este script REQUIERE arrancar en modo UEFI.${C_NC}" >&3
    exit 1
fi
msg_ok "Entorno UEFI detectado."

msg "Comprobando conexión a internet..."
if ! ping -c 3 archlinux.org >/dev/null 2>&1; then 
    echo -e "${C_RED}ERROR: No hay conexión a internet.${C_NC}" >&3
    exit 1
fi
msg_ok "Conexión a internet establecida."

echo -e "\n${C_YELLOW}Discos disponibles en el sistema:${C_NC}" >&3
lsblk -d -p -n -l -o NAME,SIZE,MODEL | grep -v loop >&3
echo -n -e "\n${C_CYAN}Introduce la ruta del disco a formatear (ej. /dev/sda o /dev/nvme0n1): ${C_NC}" >&3
read -r DISK
if [ ! -b "$DISK" ]; then
    echo -e "${C_RED}ERROR: Disco no válido o no encontrado.${C_NC}" >&3
    exit 1
fi

echo -n -e "${C_RED}¡ADVERTENCIA! Todos los datos en $DISK serán DESTRUIDOS. Escribe 'SI' para continuar: ${C_NC}" >&3
read -r CONFIRM
if [ "$CONFIRM" != "SI" ]; then 
    echo "Operación cancelada por el usuario." >&3
    exit 1
fi

echo -n -e "\n${C_CYAN}Introduce la contraseña para $USER_NAME y ROOT: ${C_NC}" >&3
read -s PASSWORD
echo "" >&3
echo -n -e "${C_CYAN}Repite la contraseña: ${C_NC}" >&3
read -s PASSWORD2
echo "" >&3
if [ "$PASSWORD" != "$PASSWORD2" ] || [ -z "$PASSWORD" ]; then
    echo -e "${C_RED}ERROR: Las contraseñas no coinciden o están vacías.${C_NC}" >&3
    exit 1
fi

LUKS_OPT=0
echo -n -e "\n${C_CYAN}¿Deseas encriptar la partición principal con LUKS? (s/N): ${C_NC}" >&3
read -r LUKS_ANS
if [[ "$LUKS_ANS" =~ ^[Ss]$ ]]; then
    LUKS_OPT=1
    echo -n -e "${C_CYAN}Introduce contraseña para LUKS: ${C_NC}" >&3
    read -s LUKS_PASS
    echo "" >&3
fi

# ==============================================================================
# FASE 2: PREPARACIÓN DEL ENTORNO LIVE E INYECCIÓN DE CACHYOS
# ==============================================================================
msg "Sincronizando relojes del sistema (NTP)..."
timedatectl set-ntp true >> "$LOG_FILE" 2>&1

msg "Optimizando pacman.conf del entorno Live..."
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/' /etc/pacman.conf
grep -q "ILoveCandy" /etc/pacman.conf || sed -i '/#VerbosePkgLists/a ILoveCandy' /etc/pacman.conf

msg "Inyectando repositorios oficiales de CachyOS (Auto-detección de CPU)..."
cd /tmp
curl -sO https://mirror.cachyos.org/cachyos-repo.tar.xz >> "$LOG_FILE" 2>&1
tar xf cachyos-repo.tar.xz >> "$LOG_FILE" 2>&1
cd cachyos-repo
./cachyos-repo.sh >> "$LOG_FILE" 2>&1
cd /

msg_ok "Repositorios CachyOS añadidos correctamente."

# ==============================================================================
# FASE 3: PARTICIONADO Y BTRFS
# ==============================================================================
msg "Desmontando particiones existentes en $DISK..."
umount -A --recursive /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true

msg "Limpiando y particionando $DISK..."
sgdisk -Z "$DISK" >> "$LOG_FILE" 2>&1
sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI" "$DISK" >> "$LOG_FILE" 2>&1
sgdisk -n 2:0:0 -t 2:8300 -c 2:"ROOT" "$DISK" >> "$LOG_FILE" 2>&1

# Detección dinámica de nomenclatura de particiones (SATA vs NVMe vs VBox)
if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"loop"* ]]; then
    PART_EFI="${DISK}p1"
    PART_ROOT="${DISK}p2"
else
    PART_EFI="${DISK}1"
    PART_ROOT="${DISK}2"
fi

msg "Formateando partición EFI en FAT32..."
mkfs.fat -F32 "$PART_EFI" >> "$LOG_FILE" 2>&1

if [ $LUKS_OPT -eq 1 ]; then
    msg "Configurando cifrado LUKS en $PART_ROOT..."
    echo -n "$LUKS_PASS" | cryptsetup -q luksFormat "$PART_ROOT" - >> "$LOG_FILE" 2>&1
    echo -n "$LUKS_PASS" | cryptsetup open "$PART_ROOT" cryptroot - >> "$LOG_FILE" 2>&1
    MAPPER_ROOT="/dev/mapper/cryptroot"
else
    MAPPER_ROOT="$PART_ROOT"
fi

msg "Formateando BTRFS y creando subvolúmenes oficiales..."
mkfs.btrfs -f -L "ArchCachy" "$MAPPER_ROOT" >> "$LOG_FILE" 2>&1
mount "$MAPPER_ROOT" /mnt

btrfs subvolume create /mnt/@ >> "$LOG_FILE" 2>&1
btrfs subvolume create /mnt/@home >> "$LOG_FILE" 2>&1
btrfs subvolume create /mnt/@log >> "$LOG_FILE" 2>&1
btrfs subvolume create /mnt/@pkg >> "$LOG_FILE" 2>&1
btrfs subvolume create /mnt/@snapshots >> "$LOG_FILE" 2>&1
umount /mnt

msg "Montando estructura de directorios BTRFS..."
MOUNT_OPTS="noatime,compress=zstd:1,space_cache=v2,discard=async"
mount -o "$MOUNT_OPTS",subvol=@ "$MAPPER_ROOT" /mnt
mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,boot/efi}
mount -o "$MOUNT_OPTS",subvol=@home "$MAPPER_ROOT" /mnt/home
mount -o "$MOUNT_OPTS",subvol=@log "$MAPPER_ROOT" /mnt/var/log
mount -o "$MOUNT_OPTS",subvol=@pkg "$MAPPER_ROOT" /mnt/var/cache/pacman/pkg
mount -o "$MOUNT_OPTS",subvol=@snapshots "$MAPPER_ROOT" /mnt/.snapshots
mount "$PART_EFI" /mnt/boot/efi

# ==============================================================================
# FASE 4: INSTALACIÓN BASE Y CHROOT
# ==============================================================================
msg "Instalando sistema base, Kernel CachyOS y Firmware..."
pacstrap -K /mnt base base-devel linux-cachyos linux-cachyos-headers linux-firmware amd-ucode btrfs-progs grub efibootmgr networkmanager nano git curl wget zram-generator sbctl plymouth >> "$LOG_FILE" 2>&1

msg "Generando FSTAB..."
genfstab -U /mnt >> /mnt/etc/fstab

msg "Clonando pacman.conf del LiveCD al nuevo sistema..."
cp /etc/pacman.conf /mnt/etc/pacman.conf

msg "Iniciando configuración interna (Chroot)..."
arch-chroot /mnt /bin/bash <<EOF
set -e

# 1. Configuración Regional y Red
ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime
hwclock --systohc
echo "${LOCALE} UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=${LOCALE}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
echo "${HOSTNAME_DEF}" > /etc/hostname

# 2. Refrescar llaves de pacman en el entorno chroot
pacman-key --init
pacman-key --populate archlinux cachyos
pacman -Sy

# 3. Usuarios y Permisos
echo "root:${PASSWORD}" | chpasswd
useradd -m -G wheel -s /bin/bash ${USER_NAME}
echo "${USER_NAME}:${PASSWORD}" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/wheel

# 4. Optimizaciones Makepkg para Ryzen 5950X
sed -i 's/^CFLAGS=.*/CFLAGS="-march=znver3 -mtune=znver3 -O3 -pipe -fno-plt -fexceptions -Wp,-D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security -fstack-clash-protection -fcf-protection"/' /etc/makepkg.conf
sed -i 's/^CXXFLAGS=.*/CXXFLAGS="\$CFLAGS"/' /etc/makepkg.conf
sed -i 's/^MAKEFLAGS=.*/MAKEFLAGS="-j16"/' /etc/makepkg.conf

# 5. Configurar ZRAM Automático
cat <<ZRAM > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
ZRAM

# 6. Drivers AMD (RX 7600 XT) y Multimedia
pacman -S --noconfirm mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon libva-mesa-driver mesa-vdpau gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav corectrl

# 7. Entorno Gráfico (GNOME), Red y Seguridad
pacman -S --noconfirm gnome gnome-tweaks gdm xdg-desktop-portal-gnome ufw gufw
systemctl enable NetworkManager
systemctl enable gdm
systemctl enable fstrim.timer
systemctl enable ufw

# 8. Plymouth y MKINITCPIO
sed -i 's/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block filesystems fsck)/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block plymouth filesystems fsck)/g' /etc/mkinitcpio.conf
pacman -S --noconfirm plymouth-theme-arch-logo
plymouth-set-default-theme -R arch-logo
mkinitcpio -P

# 9. GRUB y Tema Dinámico
mkdir -p /boot/grub/themes
git clone https://github.com/yeyushengfan258/Particle-circle-grub-theme.git /tmp/particle-grub
cp -r /tmp/particle-grub/Particle-circle /boot/grub/themes/

sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=5/' /etc/default/grub
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0 amdgpu.ppfeaturemask=0xffffffff"/' /etc/default/grub
sed -i 's|^#GRUB_THEME=.*|GRUB_THEME="/boot/grub/themes/Particle-circle/theme.txt"|' /etc/default/grub
sed -i 's/^#GRUB_DISABLE_OS_PROBER=false/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
echo 'GRUB_GFXMODE="2560x1440,auto"' >> /etc/default/grub

if [ ${LUKS_OPT} -eq 1 ]; then
    UUID=\$(blkid -s UUID -o value ${PART_ROOT})
    sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=\$UUID:cryptroot root=/dev/mapper/cryptroot\"|" /etc/default/grub
fi

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ArchCachy
grub-mkconfig -o /boot/grub/grub.cfg

# 10. Software Base, Gaming y Mantenimiento
pacman -S --noconfirm firefox thunderbird qbittorrent steam lutris mangohud gamemode flatpak snapper btrfs-assistant grub-btrfs waypaper swww sudo base-devel

# 11. Compilar e Instalar YAY (como usuario sin privilegios)
su - ${USER_NAME} -c "cd /tmp && git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm"

# 12. Instalar dependencias AUR y Extras
su - ${USER_NAME} -c "yay -S --noconfirm onlyoffice-bin pamac-aur heroic-games-launcher-bin protonup-qt"
EOF
msg_ok "Configuración Chroot finalizada con éxito."

# ==============================================================================
# FASE 5: LIMPIEZA FINAL
# ==============================================================================
msg "Limpiando archivos temporales..."
rm -rf /mnt/tmp/*
rm -rf /mnt/var/cache/pacman/pkg/*

msg_ok "¡INSTALACIÓN COMPLETADA!"
echo -e "${C_GREEN}=================================================${C_NC}" >&3
echo -e "${C_GREEN}  El sistema base ha sido instalado y optimizado ${C_NC}" >&3
echo -e "${C_GREEN}  Escribe 'reboot' para iniciar tu nueva máquina ${C_NC}" >&3
echo -e "${C_GREEN}=================================================${C_NC}" >&3
