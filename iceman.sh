#!/usr/bin/env bash
# ==============================================================================
# iceman.sh
# ==============================================================================
set -Eeuo pipefail

# ==============================================================================
# 1. CONFIGURACIÓN GLOBAL Y VARIABLES
# ==============================================================================
LOG_FILE="/tmp/iceman_install.log"
STATE_DIR="/tmp/iceman_install_state"
MNT_DIR="/mnt"
TOTAL_STEPS=10
CURRENT_STEP=0
START_TIME=$(date +%s)

# Colores
C_RESET="\033[0m"
C_INFO="\033[1;36m"
C_SUCCESS="\033[1;32m"
C_WARN="\033[1;33m"
C_ERR="\033[1;31m"
C_STEP="\033[1;34m"

mkdir -p "$STATE_DIR"
exec 3>&1 4>&2
exec 1>>"$LOG_FILE" 2>&1

# ==============================================================================
# 2. FUNCIONES DE INTERFAZ Y UTILIDAD
# ==============================================================================
log() { echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }
is_done() { [ -f "$STATE_DIR/$1" ]; }
mark_done() { touch "$STATE_DIR/$1"; }

ui_msg() { echo -e "${C_INFO}>> $*${C_RESET}" >&3; log "MSG: $*"; }
ui_success() { echo -e "${C_SUCCESS}>> [OK] $*${C_RESET}" >&3; log "SUCCESS: $*"; }
ui_error() { echo -e "${C_ERR}>> [ERROR] $*${C_RESET}" >&3; log "ERROR: $*"; }

update_progress() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local step_name=$1
    local elapsed=$(( $(date +%s) - START_TIME ))
    local eta=0
    if [ "$CURRENT_STEP" -gt 0 ]; then
        eta=$(( (elapsed / CURRENT_STEP) * (TOTAL_STEPS - CURRENT_STEP) ))
    fi
    local perc=$(( (CURRENT_STEP * 100) / TOTAL_STEPS ))
    echo -e "\n${C_STEP}[ $CURRENT_STEP/$TOTAL_STEPS | $perc% ]${C_RESET} ${C_INFO}$step_name${C_RESET} | Tiempo: ${elapsed}s | ETA: ${eta}s" >&3
    log "STEP $CURRENT_STEP: $step_name"
}

run_with_spinner() {
    local pid
    local delay=0.1
    local spinstr='|/-\'
    "$@" &
    pid=$!
    while kill -0 $pid 2>/dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr" >&3
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b" >&3
    done
    wait $pid
    return $?
}

trap_error() {
    local line=$1
    local code=$2
    ui_error "Fallo en la línea $line con código $code."
    ui_error "Revisa el log completo en $LOG_FILE"
    exit "$code"
}
trap 'trap_error ${LINENO} $?' ERR

# ==============================================================================
# 3. VERIFICACIONES INICIALES
# ==============================================================================
check_uefi() {
    update_progress "Verificando entorno UEFI"
    if [ ! -d "/sys/firmware/efi/efivars" ]; then
        ui_error "El sistema no está arrancado en modo UEFI."
        exit 1
    fi
}

detect_hardware() {
    update_progress "Detectando hardware y almacenamiento"
    
    TARGET_DISK=$(lsblk -d -n -o NAME,TYPE | awk '$2=="disk"{print $1}' | grep -E '^nvme' | head -n 1 || true)
    if [ -z "$TARGET_DISK" ]; then
        TARGET_DISK=$(lsblk -d -n -o NAME,TYPE | awk '$2=="disk"{print $1}' | head -n 1)
    fi
    TARGET_DISK="/dev/$TARGET_DISK"
    
    if [ ! -b "$TARGET_DISK" ]; then
        ui_error "No se encontró ningún disco válido."
        exit 1
    fi

    ROTA=$(lsblk -n -d -o ROTA "$TARGET_DISK")
    IS_SSD=false
    if [ "$ROTA" == "0" ]; then
        IS_SSD=true
        ui_msg "Detectado SSD/NVMe: $TARGET_DISK"
    else
        ui_msg "Detectado HDD: $TARGET_DISK"
    fi

    SUPPORTS_V3=false
    if /lib/ld-linux-x86-64.so.2 --help | grep -q "x86-64-v3 (supported, searched)"; then
        SUPPORTS_V3=true
        ui_msg "Arquitectura x86-64-v3 soportada y detectada."
    else
        ui_msg "Arquitectura x86-64-v3 NO soportada. Se utilizará x86-64 estándar."
    fi
}

prompt_user_data() {
    if ! is_done "user_data"; then
        update_progress "Recopilando datos del usuario"
        echo -e "\n${C_WARN}=== DATOS DE INSTALACIÓN ===${C_RESET}" >&3
        # Redirección a /dev/tty para permitir curl | bash sin devorar el stdin
        read -r -p "Nombre de usuario: " USER_NAME < /dev/tty
        read -r -s -p "Contraseña: " USER_PASS < /dev/tty
        echo >&3
        read -r -p "Hostname: " HOST_NAME < /dev/tty
        
        echo "$USER_NAME" > "$STATE_DIR/user_name"
        echo "$USER_PASS" > "$STATE_DIR/user_pass"
        echo "$HOST_NAME" > "$STATE_DIR/host_name"
        mark_done "user_data"
    else
        USER_NAME=$(cat "$STATE_DIR/user_name")
        USER_PASS=$(cat "$STATE_DIR/user_pass")
        HOST_NAME=$(cat "$STATE_DIR/host_name")
        update_progress "Datos de usuario cargados desde el estado anterior"
    fi
}

# ==============================================================================
# 4. PREPARACIÓN DE DISCOS Y BTRFS
# ==============================================================================
partition_and_format() {
    if is_done "partitioning"; then return; fi
    update_progress "Particionando y formateando ($TARGET_DISK)"
    
    umount -R "$MNT_DIR" 2>/dev/null || true
    swapoff -a 2>/dev/null || true
    
    run_with_spinner wipefs -a -f "$TARGET_DISK"
    run_with_spinner sgdisk -Z "$TARGET_DISK"
    run_with_spinner sgdisk -n 1:0:+1024M -t 1:ef00 -c 1:"EFI" "$TARGET_DISK"
    run_with_spinner sgdisk -n 2:0:0 -t 2:8300 -c 2:"ROOT" "$TARGET_DISK"
    run_with_spinner partprobe "$TARGET_DISK"
    sleep 3

    if [[ "$TARGET_DISK" == *nvme* || "$TARGET_DISK" == *mmcblk* ]]; then
        PART_EFI="${TARGET_DISK}p1"
        PART_ROOT="${TARGET_DISK}p2"
    else
        PART_EFI="${TARGET_DISK}1"
        PART_ROOT="${TARGET_DISK}2"
    fi

    run_with_spinner mkfs.fat -F32 -n "EFI" "$PART_EFI"
    run_with_spinner mkfs.btrfs -f -L "ARCH" "$PART_ROOT"
    
    mark_done "partitioning"
    echo "$PART_EFI" > "$STATE_DIR/part_efi"
    echo "$PART_ROOT" > "$STATE_DIR/part_root"
}

setup_btrfs() {
    if is_done "btrfs_setup"; then return; fi
    update_progress "Configurando Btrfs y montando subvolúmenes"
    
    PART_EFI=$(cat "$STATE_DIR/part_efi")
    PART_ROOT=$(cat "$STATE_DIR/part_root")
    
    mount "$PART_ROOT" "$MNT_DIR"
    btrfs subvolume create "$MNT_DIR/@" >/dev/null
    btrfs subvolume create "$MNT_DIR/@home" >/dev/null
    btrfs subvolume create "$MNT_DIR/@snapshots" >/dev/null
    btrfs subvolume create "$MNT_DIR/@var_log" >/dev/null
    btrfs subvolume create "$MNT_DIR/@cache" >/dev/null
    btrfs subvolume create "$MNT_DIR/@tmp" >/dev/null
    btrfs subvolume create "$MNT_DIR/@var_tmp" >/dev/null
    umount "$MNT_DIR"

    BTRFS_OPTS="compress=zstd,noatime"
    if [ "$IS_SSD" = true ]; then
        BTRFS_OPTS="${BTRFS_OPTS},discard=async"
    fi

    mount -o "${BTRFS_OPTS},subvol=@" "$PART_ROOT" "$MNT_DIR"
    mkdir -p "$MNT_DIR"/{boot/efi,home,.snapshots,var/log,var/cache,tmp,var/tmp}
    
    mount -o "${BTRFS_OPTS},subvol=@home" "$PART_ROOT" "$MNT_DIR/home"
    mount -o "${BTRFS_OPTS},subvol=@snapshots" "$PART_ROOT" "$MNT_DIR/.snapshots"
    mount -o "${BTRFS_OPTS},subvol=@var_log" "$PART_ROOT" "$MNT_DIR/var/log"
    mount -o "${BTRFS_OPTS},subvol=@cache" "$PART_ROOT" "$MNT_DIR/var/cache"
    mount -o "${BTRFS_OPTS},subvol=@tmp" "$PART_ROOT" "$MNT_DIR/tmp"
    mount -o "${BTRFS_OPTS},subvol=@var_tmp" "$PART_ROOT" "$MNT_DIR/var/tmp"
    
    mount "$PART_EFI" "$MNT_DIR/boot/efi"
    
    mark_done "btrfs_setup"
}

# ==============================================================================
# 5. INSTALACIÓN BASE Y CHROOT
# ==============================================================================
install_base() {
    if is_done "pacstrap_base"; then return; fi
    update_progress "Instalando sistema base (pacstrap)"
    
    run_with_spinner pacman -Sy --noconfirm archlinux-keyring
    
    sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/g' /etc/pacman.conf
    sed -i 's/^#Color/Color\nILoveCandy/g' /etc/pacman.conf

    local BASE_PKGS=(
        base base-devel linux-firmware amd-ucode
        btrfs-progs grub efibootmgr grub-btrfs
        networkmanager git wget curl rsync sudo
        nano vim zram-generator
    )
    
    run_with_spinner pacstrap -K "$MNT_DIR" "${BASE_PKGS[@]}"
    run_with_spinner genfstab -U "$MNT_DIR" >> "$MNT_DIR/etc/fstab"
    
    mark_done "pacstrap_base"
}

prepare_chroot_script() {
    update_progress "Generando script para Chroot"
    
    cat << 'EOF' > "$MNT_DIR/root/chroot_install.sh"
#!/usr/bin/env bash
set -Eeuo pipefail

# Recuperar variables
USER_NAME=$1
USER_PASS=$2
HOST_NAME=$3
SUPPORTS_V3=$4
IS_SSD=$5

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# 1. Configuración Básica
ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
hwclock --systohc
sed -i 's/^#es_ES.UTF-8 UTF-8/es_ES.UTF-8 UTF-8/' /etc/locale.gen
locale-gen
echo "LANG=es_ES.UTF-8" > /etc/locale.conf
echo "KEYMAP=es" > /etc/vconsole.conf
echo "$HOST_NAME" > /etc/hostname

cat << HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   $HOST_NAME.localdomain $HOST_NAME
HOSTS

# 2. Usuarios y Permisos
if ! id "$USER_NAME" &>/dev/null; then
    useradd -m -G wheel,video,audio,kvm,libvirt -s /bin/bash "$USER_NAME"
fi
echo "root:$USER_PASS" | chpasswd
echo "$USER_NAME:$USER_PASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# 3. Pacman & Multilib
sed -i 's/^#Color/Color\nILoveCandy/g' /etc/pacman.conf
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/g' /etc/pacman.conf
sed -i '/\[multilib\]/,/Include = /s/^#//' /etc/pacman.conf

# 4. Integración CachyOS Repos
pacman-key --init
pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com
pacman-key --lsign-key F3B607488DB35A47

cat << TEMP_CONF > /tmp/cachy-temp.conf
[cachyos]
Server = https://mirror.cachyos.org/repo/x86_64/cachyos
TEMP_CONF

pacman --config <(cat /etc/pacman.conf /tmp/cachy-temp.conf) -Sy --noconfirm cachyos-keyring cachyos-mirrorlist

if [ "$SUPPORTS_V3" = "true" ]; then
    sed -i '/\[core\]/i \[cachyos-v3\]\nInclude = /etc/pacman.d/cachyos-v3-mirrorlist\n\n\[cachyos\]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n' /etc/pacman.conf
else
    sed -i '/\[core\]/i \[cachyos\]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n' /etc/pacman.conf
fi

pacman -Syu --noconfirm

# 5. Kernel CachyOS
pacman -S --noconfirm linux-cachyos linux-cachyos-headers

# 6. Optimizaciones Makepkg
sed -i 's/-j2/-j32/g' /etc/makepkg.conf
sed -i 's/^#MAKEFLAGS="-j2"/MAKEFLAGS="-j32"/g' /etc/makepkg.conf
sed -i 's/COMPRESSZST=(zstd -c -T0 --ultra -20 -)/COMPRESSZST=(zstd -c -T0 --ultra -20 -)/' /etc/makepkg.conf

# 7. Instalación de Paquetes Base, Multimedia y Gaming
PKGS=(
    gnome gnome-tweaks xdg-desktop-portal-gnome
    mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon
    xf86-video-amdgpu vulkan-icd-loader lib32-vulkan-icd-loader
    pipewire lib32-pipewire pipewire-pulse pipewire-alsa pipewire-jack lib32-pipewire-jack
    wireplumber gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav
    ffmpeg bluez bluez-utils ttf-liberation ttf-dejavu noto-fonts
    steam lutris wine-staging winetricks gamemode lib32-gamemode
    mangohud lib32-mangohud gamescope vkbasalt lib32-vkbasalt
    obs-studio obs-vkcapture lib32-obs-vkcapture input-remapper corectrl
    podman distrobox squashfs-tools
    qemu-full libvirt virt-manager edk2-ovmf dnsmasq bridge-utils iptables-nft vde2
    ufw fwupd power-profiles-daemon bash-completion xdg-user-dirs
    snapper snap-pac btrfs-assistant
)

pacman -S --noconfirm --needed "${PKGS[@]}"

# 8. GRUB Bootloader
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
grub-mkconfig -o /boot/grub/grub.cfg

# 9. Configuración ZRAM y Sysctl
cat << ZRAM > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
ZRAM

cat << SYSCTL > /etc/sysctl.d/99-zram.conf
vm.swappiness = 150
vm.page-cluster = 0
SYSCTL

mkdir -p /etc/systemd/journald.conf.d
cat << JOURNAL > /etc/systemd/journald.conf.d/persist.conf
[Journal]
Storage=persistent
JOURNAL

# 10. Corrección y Configuración de Snapper
umount /.snapshots || true
rm -rf /.snapshots
snapper --no-dbus -c root create-config /
btrfs subvolume delete /.snapshots || true
mkdir /.snapshots
mount -a
chmod 750 /.snapshots

# 11. Habilitación de Servicios
systemctl enable NetworkManager
systemctl enable bluetooth
systemctl enable libvirtd
systemctl enable ufw
systemctl enable systemd-resolved
systemctl enable power-profiles-daemon
systemctl enable gdm

if [ "$IS_SSD" = "true" ]; then
    systemctl enable fstrim.timer
fi
EOF
    chmod +x "$MNT_DIR/root/chroot_install.sh"
}

run_chroot() {
    if is_done "chroot_install"; then return; fi
    update_progress "Instalando y configurando CachyOS, GNOME y herramientas"
    
    run_with_spinner arch-chroot "$MNT_DIR" /root/chroot_install.sh "$USER_NAME" "$USER_PASS" "$HOST_NAME" "$SUPPORTS_V3" "$IS_SSD"
    
    rm "$MNT_DIR/root/chroot_install.sh"
    mark_done "chroot_install"
}

# ==============================================================================
# 6. FINALIZACIÓN Y LIMPIEZA
# ==============================================================================
finalize() {
    update_progress "Finalizando instalación y guardando logs"
    
    cp "$LOG_FILE" "$MNT_DIR/var/log/iceman_install.log"
    
    umount -R "$MNT_DIR" 2>/dev/null || true
    
    ui_success "Instalación completada con éxito."
    ui_success "Sistema Bazzite-Like CachyOS instalado en $TARGET_DISK."
    ui_success "Log guardado en /var/log/iceman_install.log en el nuevo sistema."
    ui_msg "Ya puedes reiniciar el sistema."
}

# ==============================================================================
# 7. EJECUCIÓN PRINCIPAL
# ==============================================================================
main() {
    check_uefi
    detect_hardware
    prompt_user_data
    partition_and_format
    setup_btrfs
    install_base
    prepare_chroot_script
    run_chroot
    finalize
}

main "$@"
