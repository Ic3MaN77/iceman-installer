#!/usr/bin/env bash
# ==============================================================================
# ICEMAN - Automated Arch Linux / CachyOS Deployment Script
# VERSIÓN MONOLÍTICA DEFINITIVA Y BLINDADA - DESATENDIDA Y RESILIENTE
# ==============================================================================

# --- ESTÁNDAR MODERNO BASH ---
set -Eeuo pipefail
IFS=$'\n\t'

# Inicialización de entorno temporal
WORK_DIR=$(mktemp -d)
export WORK_DIR

# --- 0. FUNCIONES GLOBALES Y TRAP DE LIMPIEZA ---
cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo -e "\n[!] SCRIPT FALLÓ CON CÓDIGO $exit_code. INICIANDO LIMPIEZA (TRAP)..."
        swapoff -a 2>/dev/null || true
        umount -R /mnt 2>/dev/null || true
        cryptsetup close "cryptroot" 2>/dev/null || true
        echo "[i] Limpieza de montajes y volúmenes completada."
    fi
    if [ -n "${WORK_DIR:-}" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
        echo "[i] Limpieza de entorno temporal ($WORK_DIR) completada."
    fi
    exit $exit_code
}
trap cleanup EXIT INT TERM ERR

# Reintento con backoff exponencial exclusivo para RED (2s, 4s, 8s)
retry_cmd() {
    local n=1 max=3 delay=2
    while true; do
        if "$@"; then return 0; fi
        if (( n < max )); then
            echo "[!] Comando de red '$1' falló. Reintentando en ${delay}s ($n/$max)..."
            sleep "$delay"
            ((n++))
            ((delay *= 2))
        else
            echo "[!] Error crítico de red tras $max intentos: $*"
            return 1
        fi
    done
}
export -f retry_cmd

# --- 1. COMPROBACIONES ESTRICTAS DE SEGURIDAD Y ENTORNO ---
echo "[*] Auditando seguridad y entorno anfitrión..."

if [ "$EUID" -ne 0 ]; then
    echo "[!] Error Crítico: Este script debe ejecutarse como root (usa sudo)."
    exit 1
fi

declare -a REQ_TOOLS=("pacstrap" "arch-chroot" "cryptsetup" "sgdisk" "mkfs.btrfs" "mkfs.fat" "btrfs" "blkid" "curl" "tar" "lsblk" "lspci")
for tool in "${REQ_TOOLS[@]}"; do
    if ! command -v "$tool" &>/dev/null; then
        echo "[!] Error Crítico: Herramienta necesaria '$tool' no encontrada."
        exit 1
    fi
done

if [ ! -d "/sys/firmware/efi" ]; then
    echo "[!] Error Crítico: Este script requiere un sistema arrancado en modo UEFI."
    exit 1
fi

# Blindaje de curl para comprobación de red
if ! curl --fail --location --silent --show-error --connect-timeout 5 https://archlinux.org &>/dev/null; then
    echo "[!] Error Crítico: No hay conexión a Internet (HTTPS). Abortando."
    exit 1
fi

echo -e "\n[*] Verificando estado de Secure Boot..."
if command -v bootctl >/dev/null 2>&1; then
    if bootctl status 2>/dev/null | grep -iq "Secure Boot: enabled"; then
        echo "    -> [INFO] Secure Boot está HABILITADO. Requerirás firmar el kernel con sbctl al finalizar."
    else
        echo "    -> [INFO] Secure Boot está DESHABILITADO."
    fi
else
    echo "    -> [INFO] Herramienta bootctl no disponible. Omitiendo verificación previa."
fi

# --- 2. ASISTENTE INTERACTIVO DE CONFIGURACIÓN ---
echo "========================================================"
echo "          CONFIGURACIÓN DE DESPLIEGUE ICEMAN            "
echo "========================================================"

echo "[*] Discos disponibles en el sistema:"
echo "--------------------------------------------------------"
lsblk -d -n -o NAME,SIZE,MODEL,ROTA | awk '{printf " /dev/%-10s | %-8s | %-5s | %s\n", $1, $2, ($4=="0"?"SSD/NVMe":"HDD"), $3}'
echo "--------------------------------------------------------"

read -p "[?] Introduce el disco objetivo (ej: /dev/nvme0n1 o /dev/sda): " DISK </dev/tty
if [ ! -b "$DISK" ]; then echo "[!] El dispositivo $DISK no existe."; exit 1; fi

# Protección para evitar sobrescribir el medio de instalación (Live USB/ISO)
if lsblk "$DISK" -n -o MOUNTPOINT 2>/dev/null | grep -qE "^/run/archiso|^/run/miso|^/run/initramfs"; then
    echo "[!] Error Crítico: El disco seleccionado ($DISK) está en uso como medio Live. No puedes instalar sobre él."
    exit 1
fi

read -p "[?] ¿Deseas cifrar el disco con LUKS? (s/N): " USE_LUKS_INPUT </dev/tty
USE_LUKS_INPUT=${USE_LUKS_INPUT:-n}
if [[ "${USE_LUKS_INPUT,,}" == "s" || "${USE_LUKS_INPUT,,}" == "si" ]]; then
    ENABLE_LUKS=true; echo "    -> Cifrado LUKS: ACTIVADO"
else
    ENABLE_LUKS=false; echo "    -> Cifrado LUKS: DESACTIVADO"
fi

read -p "[?] Nombre de usuario [iceman]: " USERNAME </dev/tty
USERNAME=${USERNAME:-iceman}

read -s -p "[?] Contraseña (para usuario y root): " PASSWORD </dev/tty
echo
if [ -z "$PASSWORD" ]; then echo "[!] La contraseña no puede estar vacía."; exit 1; fi

read -p "[?] Nombre del equipo (hostname) [iceman-pc]: " HOSTNAME </dev/tty
HOSTNAME=${HOSTNAME:-iceman-pc}

read -p "[?] Zona horaria [Europe/Madrid]: " TIMEZONE </dev/tty
TIMEZONE=${TIMEZONE:-Europe/Madrid}

read -p "[?] Idioma del sistema [es_ES.UTF-8]: " LOCALE_LANG </dev/tty
LOCALE_LANG=${LOCALE_LANG:-es_ES.UTF-8}

read -p "[?] Mapa de teclado [es]: " KEYMAP_SYS </dev/tty
KEYMAP_SYS=${KEYMAP_SYS:-es}

read -p "[?] Entorno de escritorio (KDE/GNOME/NONE) [KDE]: " DESKTOP_ENV </dev/tty
DESKTOP_ENV=${DESKTOP_ENV:-KDE}

echo "========================================================"
echo " Configuración completada. Iniciando proceso desatendido."
echo "========================================================"

CRYPT_NAME="cryptroot"
declare -a KERNEL_PKG=("linux-cachyos" "linux-cachyos-headers")
declare -a HW_PKGS=()
declare -a DE_PKGS=()
declare -a AUDIO_FONTS=("pipewire" "pipewire-pulse" "pipewire-alsa" "pipewire-jack" "wireplumber" "bluez" "bluez-utils" "ttf-dejavu" "ttf-liberation" "noto-fonts")

# --- 3. INYECCIÓN NATIVA DE REPOSITORIOS CACHYOS ---
echo "[*] Inyectando repositorios de CachyOS de forma nativa..."
cp /etc/pacman.conf /etc/pacman.conf.bak

# Configuración temporal para evadir comprobación de firmas al descargar el keyring original
cat <<EOF >> /etc/pacman.conf

[cachyos]
SigLevel = Never
Server = https://mirror.cachyos.org/repo/\$arch/\$repo
EOF

echo "    -> Descargando keyring y mirrorlist (Fase 1)..."
retry_cmd pacman -Sy --noconfirm cachyos-keyring cachyos-mirrorlist || {
    echo "[!] Error Crítico: Fallo al descargar keyring/mirrorlist de CachyOS."
    mv /etc/pacman.conf.bak /etc/pacman.conf
    exit 1
}

echo "    -> Restaurando seguridad y configurando jerarquía (Fase 2)..."
mv /etc/pacman.conf.bak /etc/pacman.conf

# Determinando soporte de arquitectura x86_64-v3 para máxima optimización
if /lib/ld-linux-x86-64.so.2 --help | grep -q "x86_64-v3 (supported, searched)"; then
    echo "    -> [INFO] CPU compatible con x86_64-v3. Habilitando repositorios optimizados."
    cat <<EOF >> /etc/pacman.conf

[cachyos-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist
[cachyos-core-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist
[cachyos-extra-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist
EOF
fi

# Repositorio genérico base siempre incluido
cat <<EOF >> /etc/pacman.conf

[cachyos]
Include = /etc/pacman.d/cachyos-mirrorlist
EOF

echo "    -> Inicializando e importando llaves pacman..."
retry_cmd pacman-key --init
retry_cmd pacman-key --populate cachyos

echo "[*] Verificando la inyección del repositorio en base de datos (Fail-Fast)..."
retry_cmd pacman -Sy --noconfirm
if ! pacman -Si linux-cachyos >/dev/null 2>&1; then
    echo "[!] Error Crítico: La inyección nativa de CachyOS falló o el paquete no existe."
    exit 1
fi
echo "    -> Repositorios inyectados y validados correctamente."

if command -v reflector &>/dev/null; then
    echo "[*] Optimizando espejos base con Reflector..."
    retry_cmd reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist || echo "[i] Reflector omitido."
fi
retry_cmd pacman -Syy --noconfirm

# --- 4. AUDITORÍA Y DETECCIÓN DE HARDWARE ---
echo "[*] Auditando componentes del sistema..."

if command -v systemd-detect-virt &>/dev/null; then
    VIRT=$(systemd-detect-virt || true)
    if [[ "$VIRT" == "kvm" || "$VIRT" == "qemu" ]]; then HW_PKGS+=("qemu-guest-agent"); echo "    -> [VM] QEMU/KVM detectado."
    elif [[ "$VIRT" == "oracle" ]]; then HW_PKGS+=("virtualbox-guest-utils-nox"); echo "    -> [VM] VirtualBox detectado."
    fi
fi

if grep -q "AuthenticAMD" /proc/cpuinfo; then HW_PKGS+=("amd-ucode"); echo "    -> [CPU] AMD detectada."
elif grep -q "GenuineIntel" /proc/cpuinfo; then HW_PKGS+=("intel-ucode"); echo "    -> [CPU] Intel detectada."
fi

if lspci -nnk | grep -iA 2 -E "VGA|3D|Display" | grep -iq "nvidia"; then 
    HW_PKGS+=("nvidia-dkms" "nvidia-utils"); echo "    -> [GPU] NVIDIA detectada."
fi

# Detección refinada de AMD/ATI mediante módulos del kernel
if lspci -nnk | grep -iA 2 -E "VGA|3D|Display" | grep -iqE "amdgpu|radeon"; then 
    HW_PKGS+=("mesa" "lib32-mesa" "vulkan-radeon" "lib32-vulkan-radeon" "libva-mesa-driver" "mesa-vdpau"); echo "    -> [GPU] AMD/ATI detectada."
fi

if lspci -nnk | grep -iA 2 -E "VGA|3D|Display" | grep -iq "intel"; then 
    HW_PKGS+=("mesa" "intel-media-driver" "vulkan-intel"); echo "    -> [GPU] Intel detectada."
fi

DISPLAY_MANAGER=""
if [[ "${DESKTOP_ENV^^}" == "KDE" ]]; then
    DE_PKGS=("plasma-meta" "sddm" "konsole" "dolphin" "wayland" "xorg-xwayland")
    DISPLAY_MANAGER="sddm"
elif [[ "${DESKTOP_ENV^^}" == "GNOME" ]]; then
    DE_PKGS=("gnome" "gnome-tweaks" "gdm" "wayland" "xorg-xwayland")
    DISPLAY_MANAGER="gdm"
fi

# --- 5. PARTICIONADO Y ESTRUCTURA BTRFS ---
echo "[*] Limpiando y particionando disco: $DISK"
wipefs -af "$DISK"
sgdisk -Z "$DISK"

sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI" "$DISK"
sgdisk -n 2:0:0   -t 2:8300 -c 2:"ROOT" "$DISK"

partprobe "$DISK" || true
udevadm settle
sleep 2

if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"mmcblk"* ]]; then
    PART_EFI="${DISK}p1"; PART_ROOT="${DISK}p2"
else
    PART_EFI="${DISK}1"; PART_ROOT="${DISK}2"
fi

echo "[*] Verificando existencia de particiones..."
if ! lsblk "$PART_EFI" >/dev/null 2>&1 || ! lsblk "$PART_ROOT" >/dev/null 2>&1; then
    echo "[!] Error Crítico: Las particiones no se crearon o udev no las ha expuesto."; exit 1
fi

echo "[*] Formateando partición EFI..."
mkfs.fat -F 32 "$PART_EFI" >/dev/null
blkid -p -u filesystem "$PART_EFI" | grep -iq "vfat" || { echo "[!] Error: Fallo real al crear sistema vfat."; exit 1; }

TARGET_BTRFS_DEV=""
if [ "$ENABLE_LUKS" = true ]; then
    echo "[*] Configurando contenedor cifrado LUKS2..."
    echo -n "$PASSWORD" | cryptsetup luksFormat --type luks2 "$PART_ROOT" - || { echo "[!] Fallo en luksFormat"; exit 1; }
    echo -n "$PASSWORD" | cryptsetup open "$PART_ROOT" "$CRYPT_NAME" - || { echo "[!] Fallo al abrir LUKS"; exit 1; }
    
    if [ ! -b "/dev/mapper/$CRYPT_NAME" ]; then echo "[!] Error Crítico: /dev/mapper/$CRYPT_NAME no existe."; exit 1; fi
    TARGET_BTRFS_DEV="/dev/mapper/$CRYPT_NAME"
else
    echo "[*] Saltando LUKS. Instalación nativa..."
    TARGET_BTRFS_DEV="$PART_ROOT"
fi

echo "[*] Formateando BTRFS..."
mkfs.btrfs -f -L ICEMAN_ROOT "$TARGET_BTRFS_DEV" >/dev/null
blkid -p -u filesystem "$TARGET_BTRFS_DEV" | grep -iq "btrfs" || { echo "[!] Error: Fallo real al crear sistema btrfs."; exit 1; }

mount "$TARGET_BTRFS_DEV" /mnt

echo "[*] Creando subvolúmenes BTRFS..."
btrfs subvolume create /mnt/@
btrfs subvolume create /mnt/@home
btrfs subvolume create /mnt/@snapshots
btrfs subvolume create /mnt/@var_log
btrfs subvolume create /mnt/@cache
umount /mnt

DISC_TYPE=$(lsblk -d -n -o ROTA "$DISK" 2>/dev/null || echo "1")
BTRFS_OPTS="rw,noatime,compress=zstd:1"
if [[ "$DISC_TYPE" == "0" ]]; then BTRFS_OPTS+=",discard=async"; fi

mount -o subvol=@,"$BTRFS_OPTS" "$TARGET_BTRFS_DEV" /mnt
mkdir -p /mnt/{boot/efi,home,.snapshots,var/log,var/cache}

mount -o subvol=@home,"$BTRFS_OPTS" "$TARGET_BTRFS_DEV" /mnt/home
mount -o subvol=@snapshots,"$BTRFS_OPTS" "$TARGET_BTRFS_DEV" /mnt/.snapshots
mount -o subvol=@var_log,"$BTRFS_OPTS" "$TARGET_BTRFS_DEV" /mnt/var/log
mount -o subvol=@cache,"$BTRFS_OPTS" "$TARGET_BTRFS_DEV" /mnt/var/cache
mount "$PART_EFI" /mnt/boot/efi

echo "[*] Verificando montajes de subvolúmenes..."
for mp in /mnt /mnt/home /mnt/.snapshots /mnt/var/log /mnt/var/cache /mnt/boot/efi; do
    mountpoint -q "$mp" || { echo "[!] Error Crítico: El punto de montaje $mp no está activo."; exit 1; }
done

# --- 6. EXPORTACIÓN DE VARIABLES ---
LUKS_UUID=""
if [ "$ENABLE_LUKS" = true ]; then
    LUKS_UUID=$(blkid -s UUID -o value "$PART_ROOT")
    if [ -z "$LUKS_UUID" ]; then echo "[!] Error Crítico: No se pudo obtener UUID de $PART_ROOT."; exit 1; fi
fi

cat <<EOF> /mnt/vars.sh
#!/usr/bin/env bash
export HOSTNAME="$HOSTNAME"
export USERNAME="$USERNAME"
export LUKS_UUID="$LUKS_UUID"
export CRYPT_NAME="$CRYPT_NAME"
export DISPLAY_MANAGER="$DISPLAY_MANAGER"
export ENABLE_LUKS="$ENABLE_LUKS"
export TIMEZONE="$TIMEZONE"
export LOCALE_LANG="$LOCALE_LANG"
export KEYMAP_SYS="$KEYMAP_SYS"
EOF
chmod +x /mnt/vars.sh

# --- 7. INSTALACIÓN BASE Y CONFIGURACIÓN FSTAB ---
echo "[*] Ejecutando pacstrap (Sin reintentos)..."
declare -a BASE_PKGS=("base" "base-devel" "linux-firmware" "btrfs-progs" "grub" "efibootmgr" "networkmanager" "sudo" "nano" "git" "snapper" "mtools" "dosfstools" "sbctl" "wget" "curl" "mkinitcpio" "cryptsetup" "cachyos-keyring" "cachyos-mirrorlist")

pacstrap /mnt "${BASE_PKGS[@]}" "${KERNEL_PKG[@]}" "${HW_PKGS[@]}" "${AUDIO_FONTS[@]}" "${DE_PKGS[@]}" || { echo "[!] Error Crítico: pacstrap falló."; exit 1; }

if [ ! -d "/mnt/etc" ] || [ ! -x "/mnt/usr/bin/bash" ]; then
    echo "[!] Error Crítico: pacstrap no completó la instalación correctamente."; exit 1
fi

echo "[*] Persistiendo configuración completa de repositorios..."
cp -f /etc/pacman.conf /mnt/etc/pacman.conf
# Copiamos de forma estricta solo los espejos de configuración
cp -f /etc/pacman.d/*mirrorlist* /mnt/etc/pacman.d/ 2>/dev/null || true

if [ ! -f "/mnt/boot/vmlinuz-linux-cachyos" ]; then
    echo "[!] Error Crítico: vmlinuz-linux-cachyos no encontrado tras pacstrap."; exit 1
fi

echo "[*] Generando y auditando fstab..."
genfstab -U /mnt > /mnt/etc/fstab || { echo "[!] Error Crítico: genfstab falló."; exit 1; }

for mnt in "/" "/home" "/.snapshots" "/var/cache" "/var/log" "/boot/efi"; do
    if ! awk '{print $2}' /mnt/etc/fstab | grep -Fxq "$mnt"; then
        echo "[!] Error Crítico: El fstab generado no contiene el punto de montaje obligatorio: $mnt"; exit 1
    fi
done

# --- 8. GENERACIÓN DEL SCRIPT EN CHROOT ---
cat <<'EOF' > /mnt/chroot.sh
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

CHROOT_PASS="$1"
shift
source /vars.sh

echo "[*] Aplicando localización..."
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

sed -i "s/#$LOCALE_LANG/$LOCALE_LANG/" /etc/locale.gen
locale-gen
echo "LANG=$LOCALE_LANG" > /etc/locale.conf
echo "KEYMAP=$KEYMAP_SYS" > /etc/vconsole.conf
echo "$HOSTNAME" > /etc/hostname

echo "[*] Habilitando servicios..."
systemctl enable NetworkManager
systemctl enable bluetooth
if [[ -n "$DISPLAY_MANAGER" ]]; then systemctl enable "$DISPLAY_MANAGER"; fi

echo "[*] Configurando Initramfs (Edición Regex robusta)..."
if [ "$ENABLE_LUKS" = true ]; then
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*HOOKS=.*$/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt btrfs filesystems fsck)/' /etc/mkinitcpio.conf
else
    sed -i -E 's/^[[:space:]]*#?[[:space:]]*HOOKS=.*$/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block btrfs filesystems fsck)/' /etc/mkinitcpio.conf
fi

mkinitcpio -P || { echo "[!] Error Crítico: Fallo al generar el initramfs."; exit 1; }

if [ ! -f "/boot/initramfs-linux-cachyos.img" ]; then
    echo "[!] Error Crítico: initramfs-linux-cachyos.img no ha sido generado."; exit 1
fi

echo "[*] Configurando usuarios..."
echo "root:$CHROOT_PASS" | chpasswd
if id "$USERNAME" &>/dev/null; then
    echo "$USERNAME:$CHROOT_PASS" | chpasswd
else
    useradd -m -G wheel -s /bin/bash "$USERNAME"
    echo "$USERNAME:$CHROOT_PASS" | chpasswd
fi
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
unset CHROOT_PASS

echo "[*] Configurando Gestor de Arranque (GRUB)..."
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet"/' /etc/default/grub

if [ "$ENABLE_LUKS" = true ]; then
    sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=${LUKS_UUID}:${CRYPT_NAME} root=/dev/mapper/${CRYPT_NAME}\"|" /etc/default/grub
    sed -i 's/^#GRUB_ENABLE_CRYPTODISK=y/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub
else
    sed -i 's|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=""|' /etc/default/grub
fi

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck || { echo "[!] Error Crítico: grub-install falló."; exit 1; }

if ! find /boot/efi/EFI -iname "grubx64.efi" | grep -q .; then
    echo "[!] Error Crítico: grubx64.efi no se encuentra en la partición EFI."; exit 1
fi

grub-mkconfig -o /boot/grub/grub.cfg || { echo "[!] Error Crítico: grub-mkconfig falló."; exit 1; }

if [ "$ENABLE_LUKS" = true ]; then
    grep -q "cryptdevice" /boot/grub/grub.cfg || { echo "[!] Error: El parámetro cryptdevice no se aplicó en grub.cfg."; exit 1; }
fi

echo "[*] Configurando Snapper y Timers..."
umount /.snapshots 2>/dev/null || true
rm -rf /.snapshots 2>/dev/null || true
snapper -c root create-config / || exit 1

if [ ! -f "/etc/snapper/configs/root" ]; then
    echo "[!] Error: Configuración de Snapper no generada en /etc/snapper/configs/root."; exit 1
fi

btrfs subvolume delete /.snapshots 2>/dev/null || true
mkdir -p /.snapshots
# Montaje explícito sin recurrir a 'mount -a'
mount /.snapshots || { echo "[!] Error: Fallo al montar /.snapshots."; exit 1; }
sync
chmod 750 /.snapshots

systemctl enable snapper-timeline.timer
systemctl enable snapper-cleanup.timer

snapper list-configs >/dev/null || { echo "[!] Error: snapper list-configs ha fallado."; exit 1; }

echo "[*] Verificando Secure Boot final..."
if command -v sbctl >/dev/null 2>&1; then
    sbctl verify 2>/dev/null || echo "[i] Secure Boot no activo o llaves personalizadas pendientes de firma."
fi
EOF
chmod +x /mnt/chroot.sh

# --- 9. EJECUCIÓN CHROOT Y LIMPIEZA FINAL ---
echo "[*] Transfiriendo control al entorno chroot..."

if ! arch-chroot /mnt /bin/bash /chroot.sh "$PASSWORD"; then
    echo "[!] Error Crítico: La ejecución dentro de chroot (arch-chroot) falló."
    exit 1
fi

unset PASSWORD

echo "[*] Desmontando y finalizando..."
sync

trap - EXIT INT TERM ERR
umount -R /mnt
if [ "$ENABLE_LUKS" = true ]; then
    cryptsetup close "$CRYPT_NAME" 2>/dev/null || true
fi

if [ -d "$WORK_DIR" ]; then rm -rf "$WORK_DIR"; fi

echo "========================================================"
echo "   ICEMAN INSTALADO CON ÉXITO Y AUDITORÍA COMPLETA.     "
echo "========================================================"
