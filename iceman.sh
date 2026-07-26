#!/usr/bin/env bash
# ==============================================================================
# ICEMAN INSTALL - Arquitectura AMD Zen 3 (Ryzen 9 5950X + Radeon) / Bazzite-like
# ==============================================================================
# Autor: Arquitecto de Sistemas (Refactorizado)
# Objetivo: Despliegue automatizado, seguro y ultrarrápido sin LUKS.
# Compatibilidad: Hardware Físico (AMD) y Entornos Virtuales (QEMU/Virt-Manager)
# ==============================================================================

set -e # Salir inmediatamente si un comando falla

LOG_FILE="iceman_install.log"
exec > >(tee -i "$LOG_FILE") 2>&1

# --- 1. CONFIGURACIÓN VISUAL Y UX ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

msg() { echo -e "${GREEN}[INFO]${NC} $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
err() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# --- 2. VALIDACIONES PREVIAS (UEFI Y RED) ---
msg "Validando entorno del sistema..."
if [ ! -d "/sys/firmware/efi" ]; then
    err "El sistema no ha arrancado en modo UEFI. Abortando instalación."
fi

if ! ping -c 1 archlinux.org &> /dev/null; then
    err "No hay conexión a internet. Configura tu red antes de continuar."
fi

# --- 3. DETECCIÓN DINÁMICA DE HARDWARE (VM vs FÍSICO) ---
msg "Analizando capacidades del procesador..."
CPU_V3=false
if /lib/ld-linux-x86-64.so.2 --help | grep -q "x86_64-v3 (supported, searched)"; then
    msg "Soporte AVX2 (x86_64-v3) detectado. Se utilizarán repositorios optimizados."
    CPU_V3=true
else
    warn "El entorno actual (posible VM genérica) NO soporta x86_64-v3."
    warn "Se utilizarán repositorios genéricos para evitar fallos de instrucción ilegal."
fi

# --- 4. INTERFAZ DE USUARIO: CREDENCIALES ---
msg "Configuración de credenciales (Doble validación)..."
while true; do
    read -s -p "Introduce contraseña para ROOT: " ROOT_PASS; echo
    read -s -p "Confirma contraseña para ROOT: " ROOT_PASS2; echo
    [ "$ROOT_PASS" = "$ROOT_PASS2" ] && break
    warn "Las contraseñas no coinciden. Inténtalo de nuevo."
done

read -p "Introduce el nombre del nuevo usuario: " USER_NAME
while true; do
    read -s -p "Introduce contraseña para $USER_NAME: " USER_PASS; echo
    read -s -p "Confirma contraseña para $USER_NAME: " USER_PASS2; echo
    [ "$USER_PASS" = "$USER_PASS2" ] && break
    warn "Las contraseñas no coinciden. Inténtalo de nuevo."
done

# --- 5. SELECCIÓN Y PREPARACIÓN DE ALMACENAMIENTO ---
msg "Discos disponibles:"
mapfile -t DISK_ARRAY < <(lsblk -d -n -o NAME,SIZE,TYPE | grep disk)
for i in "${!DISK_ARRAY[@]}"; do
    echo "$i) /dev/${DISK_ARRAY[$i]}"
done

read -p "Selecciona el NÚMERO del disco a instalar: " DISK_INDEX
if ! [[ "$DISK_INDEX" =~ ^[0-9]+$ ]] || [ "$DISK_INDEX" -ge "${#DISK_ARRAY[@]}" ]; then
    err "Selección inválida."
fi

TARGET_DISK="/dev/$(echo "${DISK_ARRAY[$DISK_INDEX]}" | awk '{print $1}')"
msg "Disco seleccionado: $TARGET_DISK"

# Adaptación de nomenclatura (NVMe vs SATA/VirtIO)
if [[ "$TARGET_DISK" == *nvme* ]] || [[ "$TARGET_DISK" == *mmcblk* ]]; then
    PART_PREFIX="${TARGET_DISK}p"
    IS_SSD=true
else
    PART_PREFIX="${TARGET_DISK}"
    # Detección heurística simple para discos SATA/Virtuales
    if [ "$(cat /sys/block/$(basename $TARGET_DISK)/queue/rotational)" -eq 0 ]; then
        IS_SSD=true
    else
        IS_SSD=false
    fi
fi

BOOT_PART="${PART_PREFIX}1"
ROOT_PART="${PART_PREFIX}2"

# Destrucción y Particionamiento (Sin LUKS)
msg "Particionando $TARGET_DISK..."
umount -R /mnt 2>/dev/null || true
sgdisk -Z "$TARGET_DISK"
sgdisk -n 1:0:+1024M -t 1:ef00 -c 1:"EFI" "$TARGET_DISK"
sgdisk -n 2:0:0      -t 2:8300 -c 2:"ROOT" "$TARGET_DISK"

msg "Formateando particiones..."
mkfs.fat -F32 "$BOOT_PART"
mkfs.btrfs -f -L ArchRoot "$ROOT_PART"

# --- 6. ESTRUCTURACIÓN AVANZADA BTRFS ---
msg "Creando subvolúmenes Btrfs..."
mount "$ROOT_PART" /mnt
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@cache
btrfs subvolume create /mnt/@tmp
btrfs subvolume create /mnt/@var_tmp
umount /mnt

msg "Montando estructura de directorios..."
BTRFS_OPTS="rw,noatime,compress=zstd,space_cache=v2,discard=async"
mount -o subvol=@,$BTRFS_OPTS "$ROOT_PART" /mnt
mkdir -p /mnt/{boot/efi,home,.snapshots,var/log,var/cache,tmp,var/tmp}
mount -o subvol=@home,$BTRFS_OPTS "$ROOT_PART" /mnt/home
mount -o subvol=@snapshots,$BTRFS_OPTS "$ROOT_PART" /mnt/.snapshots
mount -o subvol=@var_log,$BTRFS_OPTS "$ROOT_PART" /mnt/var/log
mount -o subvol=@cache,$BTRFS_OPTS "$ROOT_PART" /mnt/var/cache
mount -o subvol=@tmp,$BTRFS_OPTS "$ROOT_PART" /mnt/tmp
mount -o subvol=@var_tmp,$BTRFS_OPTS "$ROOT_PART" /mnt/var/tmp
mount "$BOOT_PART" /mnt/boot/efi

# --- 7. INYECCIÓN DEL KERNEL Y BASE ---
msg "Inyectando repositorios CachyOS para la instalación base..."
wget -qO cachyos-repo.sh https://mirror.cachyos.org/cachyos-repo.sh
chmod +x cachyos-repo.sh
./cachyos-repo.sh -v > /dev/null 2>&1

msg "Instalando sistema base (Linux CachyOS)..."
pacstrap /mnt base base-devel linux-cachyos linux-cachyos-headers linux-firmware amd-ucode btrfs-progs nano wget git wget curl sudo networkmanager

# Generar fstab
genfstab -U /mnt >> /mnt/etc/fstab

# --- 8. PREPARACIÓN DEL SCRIPT CHROOT ---
msg "Generando script de configuración chroot..."
cat <<EOF > /mnt/chroot_config.sh
#!/usr/bin/env bash
set -e

# Configuración Base
ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
hwclock --systohc
echo "es_ES.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
echo "LANG=es_ES.UTF-8" > /etc/locale.conf
echo "KEYMAP=es" > /etc/vconsole.conf
echo "iceman-pc" > /etc/hostname

# Red y Seguridad
systemctl enable NetworkManager
systemctl enable ufw
ufw default deny incoming
ufw default allow outgoing

# systemd-resolved (Enlace DNS estricto)
systemctl enable systemd-resolved
ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

# Repositorios CachyOS y Optimización Pacman
wget -qO cachyos-repo.sh https://mirror.cachyos.org/cachyos-repo.sh
chmod +x cachyos-repo.sh
./cachyos-repo.sh -v
sed -i 's/^#Color/Color\nILoveCandy/' /etc/pacman.conf
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/' /etc/pacman.conf

# Optimizaciones de Compilación para 5950X
sed -i 's/^#MAKEFLAGS="-j2"/MAKEFLAGS="-j32"/' /etc/makepkg.conf
sed -i 's/^COMPRESSZSTD=(zstd -c -z -q -)/COMPRESSZSTD=(zstd -c -z -q - --threads=0)/' /etc/makepkg.conf

EOF

# Forzar CachyOS v3 si la CPU lo soporta (Bypass para VM)
if [ "$CPU_V3" = true ]; then
cat <<EOF >> /mnt/chroot_config.sh
sed -i 's/Architecture = auto/Architecture = auto\n\n[cachyos-v3]\nInclude = \/etc\/pacman.d\/cachyos-v3-mirrorlist\n/' /etc/pacman.conf
pacman -Sy
EOF
fi

cat <<EOF >> /mnt/chroot_config.sh
# Usuarios y Contraseñas
echo "root:$ROOT_PASS" | chpasswd
useradd -m -G wheel,video,audio,input,storage -s /bin/bash $USER_NAME
echo "$USER_NAME:$USER_PASS" | chpasswd
echo "%wheel ALL=(ALL) ALL" > /etc/sudoers.d/wheel

# --- INSTALACIÓN DEL ECOSISTEMA BAZZITE-LIKE ---
# Pila Gráfica AMD, Audio y Multimedia
pacman -S --noconfirm mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon libva-mesa-driver mesa-vdpau corectrl
pacman -S --noconfirm pipewire pipewire-pulse pipewire-alsa pipewire-jack wireplumber bluez bluez-utils
pacman -S --noconfirm ffmpeg gst-plugins-base gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav

# Suite Gaming y Rendimiento
pacman -S --noconfirm steam lutris wine gamemode lib32-gamemode mangohud lib32-mangohud gamescope vkbasalt obs-studio obs-vkcapture input-remapper

# Contenedores, Virtualización y Herramientas del Sistema
pacman -S --noconfirm podman distrobox squashfs-tools libvirt qemu-base virt-manager dnsmasq bridge-utils iptables-nft edk2-ovmf
pacman -S --noconfirm fastfetch ufw fwupd snapper snap-pac grub grub-btrfs efibootmgr

# Habilitar servicios gaming / virt
systemctl enable bluetooth
systemctl enable libvirtd

# --- CONFIGURACIÓN DE MEMORIA Y ALMACENAMIENTO ---
# ZRAM Optimizada
cat <<ZRAM > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
ZRAM
cat <<SYSCTL > /etc/sysctl.d/99-zram.conf
vm.swappiness = 150
vm.page-cluster = 0
SYSCTL

EOF

if [ "$IS_SSD" = true ]; then
cat <<EOF >> /mnt/chroot_config.sh
systemctl enable fstrim.timer
EOF
fi

cat <<EOF >> /mnt/chroot_config.sh
# --- RUTINA CRÍTICA SNAPPER (Prevención de colisiones) ---
umount /.snapshots || true
rm -rf /.snapshots
snapper -c root create-config /
btrfs subvolume delete /.snapshots
mkdir /.snapshots
mount -a
chmod 750 /.snapshots

# --- GESTOR DE ARRANQUE (GRUB SIN LUKS) ---
#mkinitcpio (Ganchos base sin encrypt)
sed -i 's/^HOOKS=.*/HOOKS=(base udev plymouth autodetect modconf kms keyboard keymap consolefont block btrfs filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
# Asegurar que GRUB_CMDLINE_LINUX está limpio
sed -i 's/^GRUB_CMDLINE_LINUX=.*/GRUB_CMDLINE_LINUX=""/' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg

EOF

# --- 9. EJECUCIÓN Y LIMPIEZA ---
msg "Entrando al entorno Chroot (esto tomará un tiempo)..."
arch-chroot /mnt /bin/bash /chroot_config.sh
rm /mnt/chroot_config.sh

# --- 10. RESGUARDO DE LOGS Y DESMONTAJE ---
msg "Resguardando logs de instalación..."
cp "$LOG_FILE" /mnt/var/log/iceman_install.log
chmod 644 /mnt/var/log/iceman_install.log

msg "Sincronizando discos y desmontando particiones..."
sync
umount -R /mnt

msg "Instalación completada con éxito. Ya puedes reiniciar."
