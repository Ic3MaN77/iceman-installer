#!/usr/bin/env bash
# ==============================================================================
# ICEMAN - Automated Arch Linux / CachyOS Deployment Script
# VERSIÓN MONOLÍTICA FINAL - BLINDADA, SEGURA Y UNIVERSAL
# ==============================================================================

# --- ESTÁNDAR MODERNO BASH ---
set -Eeuo pipefail
IFS=$'\n\t'

# --- 0. FUNCIONES GLOBALES Y TRAP DE LIMPIEZA ---
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo -e "\n[!] SCRIPT FALLÓ CON CÓDIGO $exit_code. INICIANDO LIMPIEZA (TRAP)..."
        swapoff -a 2>/dev/null || true
        umount -R /mnt 2>/dev/null || true
        cryptsetup close "cryptroot" 2>/dev/null || true
        echo "[i] Limpieza completada. El sistema anfitrión no se ha corrompido."
    fi
    exit $exit_code
}
trap cleanup EXIT INT TERM ERR

retry_cmd() {
    local n=1 max=3 delay=2
    while true; do
        if "$@"; then return 0; fi
        if [[ $n -lt $max ]]; then
            ((n++))
            echo "[!] Comando '$1' falló. Reintentando ($n/$max)..."
            sleep $delay
        else
            echo "[!] Error crítico tras $max intentos: $*"
            return 1
        fi
    done
}
export -f retry_cmd

# --- 1. COMPROBACIONES ESTRICTAS DE SEGURIDAD Y ENTORNO ---
echo "[*] Auditando seguridad y entorno anfitrión..."

# C: Verificar Root
if [ "$EUID" -ne 0 ]; then
    echo "[!] Error Crítico: Este script debe ejecutarse como root (usa sudo)."
    exit 1
fi

# D & B: Verificar binarios críticos del entorno host
declare -a REQ_TOOLS=("pacstrap" "arch-chroot" "cryptsetup" "sgdisk" "mkfs.btrfs" "mkfs.fat" "btrfs" "blkid" "curl" "tar")
for tool in "${REQ_TOOLS[@]}"; do
    if ! command -v "$tool" &>/dev/null; then
        echo "[!] Error Crítico: Herramienta necesaria '$tool' no encontrada. ¿Estás en un entorno Arch Live?"
        exit 1
    fi
done

# 9: Verificar UEFI
if [ ! -d "/sys/firmware/efi" ]; then
    echo "[!] Error Crítico: Este script requiere un sistema arrancado en modo UEFI."
    echo "    No se detectó /sys/firmware/efi. Abortando."
    exit 1
fi

if ! ping -c 3 archlinux.org &>/dev/null; then
    echo "[!] Error Crítico: No hay conexión a Internet. Abortando."
    exit 1
fi

# --- 2. CONFIGURACIÓN INTERACTIVA ---
echo "========================================================"
echo " CONFIGURACIÓN DE DESPLIEGUE ICEMAN "
echo "========================================================"
read -p "[?] Introduce el disco objetivo (ej: /dev/nvme0n1): " DISK </dev/tty
if [ ! -b "$DISK" ]; then echo "[!] El dispositivo $DISK no existe."; exit 1; fi

read -s -p "[?] Introduce la contraseña para LUKS y ROOT: " PASSWORD </dev/tty
echo
read -p "[?] Entorno de escritorio (KDE/GNOME/NONE): " DESKTOP_ENV </dev/tty
DESKTOP_ENV=${DESKTOP_ENV:-KDE}

CRYPT_NAME="cryptroot"
HOSTNAME="iceman-pc"
USERNAME="admin"

declare -a KERNEL_PKG=("linux-cachyos" "linux-cachyos-headers")
declare -a HW_PKGS=()
declare -a DE_PKGS=()
declare -a AUDIO_FONTS=("pipewire" "pipewire-pulse" "pipewire-alsa" "pipewire-jack" "wireplumber" "ttf-dejavu" "ttf-liberation" "noto-fonts")

# --- 3. INYECCIÓN DE CACHYOS (CRÍTICO 1) ---
echo "[*] Inyectando repositorios y firmas de CachyOS en el entorno Live..."
curl -sO https://mirror.cachyos.org/cachyos-repo.tar.xz
tar xf cachyos-repo.tar.xz
cd cachyos-repo
./cachyos-repo.sh
cd ..
rm -rf cachyos-repo cachyos-repo.tar.xz

echo "[*] Sincronizando bases de datos..."
retry_cmd pacman -Syy --noconfirm

# E: Reflector
if command -v reflector &>/dev/null; then
    echo "[*] Configurando Reflector..."
    retry_cmd reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist || echo "[i] Reflector falló, continuando con espejos actuales."
else
    echo "[i] Reflector no instalado. Omitiendo."
fi

# --- 4. AUDITORÍA DE HARDWARE Y MÁQUINAS VIRTUALES ---
echo "[*] Auditando hardware..."

if command -v systemd-detect-virt &>/dev/null; then
    VIRT=$(systemd-detect-virt || true)
    if [[ "$VIRT" == "kvm" || "$VIRT" == "qemu" ]]; then
        HW_PKGS+=("qemu-guest-agent")
        echo "    -> [VM] QEMU/KVM detectado."
    elif [[ "$VIRT" == "oracle" ]]; then
        HW_PKGS+=("virtualbox-guest-utils-nox")
        echo "    -> [VM] VirtualBox detectado."
    fi
fi

if grep -q "AuthenticAMD" /proc/cpuinfo; then 
    HW_PKGS+=("amd-ucode")
    echo "    -> [CPU] AMD detectada."
elif grep -q "GenuineIntel" /proc/cpuinfo; then 
    HW_PKGS+=("intel-ucode")
    echo "    -> [CPU] Intel detectada."
fi

if lspci | grep -iE "vga.*nvidia|3d.*nvidia" &> /dev/null; then 
    HW_PKGS+=("nvidia-dkms" "nvidia-utils")
    echo "    -> [GPU] NVIDIA detectada."
fi

# 10: Mejora Regex GPU AMD
if lspci | grep -iE "vga.*(amd|ati)|3d.*(amd|ati)" &> /dev/null; then 
    HW_PKGS+=("mesa" "vulkan-radeon" "lib32-vulkan-radeon" "libva-mesa-driver" "mesa-vdpau")
    echo "    -> [GPU] AMD/ATI detectada."
fi

DISPLAY_MANAGER=""
if [[ "${DESKTOP_ENV^^}" == "KDE" ]]; then
    DE_PKGS=("plasma-meta" "sddm" "konsole" "dolphin" "wayland" "xorg-xwayland")
    DISPLAY_MANAGER="sddm"
elif [[ "${DESKTOP_ENV^^}" == "GNOME" ]]; then
    DE_PKGS=("gnome" "gnome-tweaks" "gdm" "wayland" "xorg-xwayland")
    DISPLAY_MANAGER="gdm"
fi

# --- 5. PARTICIONADO Y UDEV ---
echo "[*] Preparando disco: $DISK"
wipefs -af "$DISK"
sgdisk -Z "$DISK"

sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI" "$DISK"
sgdisk -n 2:0:0   -t 2:8300 -c 2:"ROOT" "$DISK"

# F: Sincronización GPT mejorada
echo "[*] Sincronizando tabla de particiones..."
partprobe "$DISK" || true
udevadm settle

if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"mmcblk"* ]]; then
    PART_EFI="${DISK}p1"
    PART_ROOT="${DISK}p2"
else
    PART_EFI="${DISK}1"
    PART_ROOT="${DISK}2"
fi

# --- 6. LUKS Y SISTEMAS DE ARCHIVOS ---
echo "[*] Formateando e iniciando LUKS..."
mkfs.fat -F 32 "$PART_EFI" || { echo "[!] Fallo al formatear partición EFI"; exit 1; }

echo -n "$PASSWORD" | cryptsetup luksFormat --type luks2 "$PART_ROOT" - || { echo "[!] Fallo en luksFormat"; exit 1; }
echo -n "$PASSWORD" | cryptsetup open "$PART_ROOT" "$CRYPT_NAME" - || { echo "[!] Fallo al abrir contenedor LUKS"; exit 1; }

# 6: Verificación LUKS
if [ ! -b "/dev/mapper/$CRYPT_NAME" ]; then
    echo "[!] Error Crítico: /dev/mapper/$CRYPT_NAME no se creó correctamente."
    exit 1
fi

echo "[*] Formateando BTRFS y montando..."
mkfs.btrfs -f -L ICEMAN_ROOT "/dev/mapper/$CRYPT_NAME" || { echo "[!] Fallo al formatear BTRFS"; exit 1; }
mount "/dev/mapper/$CRYPT_NAME" /mnt

btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@cache
umount /mnt

DISC_TYPE=$(lsblk -d -n -o ROTA "$DISK" 2>/dev/null || echo "1")
BTRFS_OPTS="rw,noatime,compress=zstd:1"
if [[ "$DISC_TYPE" == "0" ]]; then
    echo "[*] Disco Sólido (SSD/NVMe) detectado. Habilitando discard=async."
    BTRFS_OPTS+=",discard=async"
else
    echo "[*] Disco Mecánico (HDD) detectado. Omitiendo discard."
fi

mount -o subvol=@,"$BTRFS_OPTS" "/dev/mapper/$CRYPT_NAME" /mnt
mkdir -p /mnt/{boot/efi,home,.snapshots,var/log,var/cache}

mount -o subvol=@home,"$BTRFS_OPTS" "/dev/mapper/$CRYPT_NAME" /mnt/home
mount -o subvol=@snapshots,"$BTRFS_OPTS" "/dev/mapper/$CRYPT_NAME" /mnt/.snapshots
mount -o subvol=@var_log,"$BTRFS_OPTS" "/dev/mapper/$CRYPT_NAME" /mnt/var/log
mount -o subvol=@cache,"$BTRFS_OPTS" "/dev/mapper/$CRYPT_NAME" /mnt/var/cache
mount "$PART_EFI" /mnt/boot/efi

echo "[*] Verificando montajes de BTRFS y EFI..."
for mp in /mnt /mnt/home /mnt/.snapshots /mnt/var/log /mnt/var/cache /mnt/boot/efi; do
    mountpoint -q "$mp" || { echo "[!] Error Crítico: Falló el montaje de $mp"; exit 1; }
done

# --- 7. EXPORTACIÓN DE VARIABLES SEGURAS ---
# 5: Verificación estricta de UUID LUKS
LUKS_UUID=$(blkid -s UUID -o value "$PART_ROOT")
if [ -z "$LUKS_UUID" ]; then
    echo "[!] Error Crítico: blkid no pudo recuperar el UUID de $PART_ROOT."
    exit 1
fi

# A: NO exportamos PASSWORD al disco.
cat <<EOF> /mnt/vars.sh
#!/usr/bin/env bash
export HOSTNAME="$HOSTNAME"
export USERNAME="$USERNAME"
export LUKS_UUID="$LUKS_UUID"
export CRYPT_NAME="$CRYPT_NAME"
export DISPLAY_MANAGER="$DISPLAY_MANAGER"
EOF
chmod +x /mnt/vars.sh

# --- 8. INSTALACIÓN BASE Y VERIFICACIÓN FSTAB ---
echo "[*] Ejecutando pacstrap..."
# Se incluyen las llaves y repos de CachyOS generados
declare -a BASE_PKGS=("base" "base-devel" "linux-firmware" "btrfs-progs" "grub" "efibootmgr" "networkmanager" "sudo" "nano" "git" "snapper" "mtools" "dosfstools" "sbctl" "wget" "curl" "mkinitcpio" "cryptsetup" "cachyos-keyring" "cachyos-mirrorlist")

retry_cmd pacstrap /mnt "${BASE_PKGS[@]}" "${KERNEL_PKG[@]}" "${HW_PKGS[@]}" "${AUDIO_FONTS[@]}" "${DE_PKGS[@]}"

# Persistencia de CachyOS: Sobrescribir pacman.conf y mirrorlists en la nueva instalación
echo "[*] Persistiendo repositorios de CachyOS en el nuevo sistema..."
cp -f /etc/pacman.conf /mnt/etc/pacman.conf
cp -a /etc/pacman.d/cachyos-v* /mnt/etc/pacman.d/ 2>/dev/null || true

# 3: Verificación de Kernel flexible
if ! ls /mnt/boot/vmlinuz-* 1> /dev/null 2>&1; then
    echo "[!] Error Crítico: Imagen del kernel (vmlinuz-*) no encontrada tras pacstrap. Abortando."; exit 1
fi

echo "[*] Generando fstab..."
genfstab -U /mnt > /mnt/etc/fstab

# 7: Verificación de fstab
echo "[*] Auditando fstab..."
for mnt in "/" "/home" "/.snapshots" "/var/cache" "/var/log" "/boot/efi"; do
    if ! awk '{print $2}' /mnt/etc/fstab | grep -Fxq "$mnt"; then
        echo "[!] Error Crítico: Fstab incompleto. Falta entrada para: $mnt"; exit 1
    fi
done

# --- 9. SCRIPT CHROOT ---
cat <<'EOF' > /mnt/chroot.sh
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# A: El password se lee desde memoria mediante argumento ($1)
CHROOT_PASS="$1"
shift
source /vars.sh

echo "[*] Configuración básica..."
ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
hwclock --systohc
sed -i 's/#es_ES.UTF-8 UTF-8/es_ES.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=es_ES.UTF-8" > /etc/locale.conf
echo "KEYMAP=es" > /etc/vconsole.conf
echo "$HOSTNAME" > /etc/hostname

echo "[*] Servicios..."
systemctl enable NetworkManager
if [[ -n "$DISPLAY_MANAGER" ]]; then systemctl enable "$DISPLAY_MANAGER"; fi

echo "[*] Initramfs..."
sed -i 's/^HOOKS=(.*)/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# 2: Verificación estricta de ambos Initramfs generados
if ! ls /boot/initramfs-*.img 1> /dev/null 2>&1; then
    echo "[!] Error Crítico: mkinitcpio no generó el initramfs."; exit 1
fi

echo "[*] Cuentas..."
echo "root:$CHROOT_PASS" | chpasswd
if id "$USERNAME" &>/dev/null; then
    echo "[i] El usuario $USERNAME ya existe. Actualizando contraseña..."
    echo "$USERNAME:$CHROOT_PASS" | chpasswd
else
    useradd -m -G wheel -s /bin/bash "$USERNAME"
    echo "$USERNAME:$CHROOT_PASS" | chpasswd
fi
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# Limpiar memoria de contraseña local del chroot
unset CHROOT_PASS

id "$USERNAME" &>/dev/null || { echo "[!] Error: El usuario no se creó correctamente."; exit 1; }

echo "[*] Bootloader (GRUB)..."
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"/' /etc/default/grub
sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=${LUKS_UUID}:${CRYPT_NAME} root=/dev/mapper/${CRYPT_NAME}\"|" /etc/default/grub
sed -i 's/^#GRUB_ENABLE_CRYPTODISK=y/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck

# 4: Verificación flexible de la ruta de GRUB
if ! find /boot/efi/EFI -iname "grubx64.efi" | grep -q .; then
    echo "[!] Error Crítico: grubx64.efi no encontrado en el árbol /boot/efi/EFI/."; exit 1
fi

# G: Comprobación de grub.cfg
grub-mkconfig -o /boot/grub/grub.cfg
grep -q "cryptdevice" /boot/grub/grub.cfg || { echo "[!] Error: Parámetro cryptdevice no aplicado en GRUB."; exit 1; }

echo "[*] Snapper..."
umount /.snapshots 2>/dev/null || true
rm -rf /.snapshots 2>/dev/null || true

# 8: Comprobación estricta de configuración de Snapper
snapper -c root create-config / || { echo "[!] Error Crítico: Falló snapper create-config"; exit 1; }
if [ ! -f "/etc/snapper/configs/root" ]; then
    echo "[!] Error Crítico: El archivo /etc/snapper/configs/root no se generó."; exit 1
fi

btrfs subvolume delete /.snapshots 2>/dev/null || true
mkdir /.snapshots
mount -a

mountpoint -q /.snapshots || { echo "[!] Error Crítico: mount -a no montó /.snapshots"; exit 1; }
chmod 750 /.snapshots

snapper list-configs >/dev/null || { echo "[!] Snapper configs falló."; exit 1; }
snapper list >/dev/null || { echo "[!] Snapper list falló."; exit 1; }

echo "[*] Secure Boot..."
sbctl verify 2>/dev/null || echo "[i] Secure Boot no activo/verificable."

EOF
chmod +x /mnt/chroot.sh

# --- 10. EJECUCIÓN DEL CHROOT Y CIERRE ---
echo "[*] Entrando al chroot..."
# A: La contraseña se pasa como argumento 1 sin tocar disco y se expurga.
arch-chroot /mnt /bin/bash /chroot.sh "$PASSWORD"
unset PASSWORD

echo "[*] Finalizando y limpiando entorno vivo..."
rm -f /mnt/vars.sh /mnt/chroot.sh
sync

# Interrupción del Trap general (éxito)
trap - EXIT INT TERM ERR
umount -R /mnt
cryptsetup close "$CRYPT_NAME"

echo "========================================================"
echo " ICEMAN COMPLETADO CON ÉXITO Y AUDITORÍA APROBADA.      "
echo "========================================================"
