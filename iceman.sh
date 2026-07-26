#!/usr/bin/env bash
# ==============================================================================
# ARCH LINUX + CACHYOS KERNEL - BAZZITE LIKE AUTO-INSTALLER (AMD EDITION)
# ==============================================================================

set -Eeuo pipefail

# ==============================================================================
# 1. CONFIGURACIÓN GLOBAL Y ESTADOS
# ==============================================================================
LOG_FILE="/tmp/bazzite_arch_install.log"
STATE_DIR="/tmp/bazzite_arch_state"
MNT_DIR="/mnt"
START_TIME=$(date +%s)
TOTAL_STEPS=17
CURRENT_STEP=0

# Colores ANSI
C_RESET="\033[0m"
C_INFO="\033[1;36m"
C_SUCCESS="\033[1;32m"
C_WARN="\033[1;33m"
C_ERR="\033[1;31m"
C_STEP="\033[1;35m"
C_PROMPT="\033[1;34m"
C_BOLD="\033[1m"

mkdir -p "$STATE_DIR"
exec 3>&1 4>&2
exec 1>>"$LOG_FILE" 2>&1

# ==============================================================================
# 2. SISTEMA DE LOGS E INTERFAZ UI
# ==============================================================================
log() { echo -e "[$(date +'%Y-%m-%d %H:%M:%S')] $*"; }

ui_msg() { echo -e "${C_INFO}>> $*${C_RESET}" >&3; log "INFO: $*"; }
ui_success() { echo -e "${C_SUCCESS}>> [OK] $*${C_RESET}" >&3; log "SUCCESS: $*"; }
ui_warn() { echo -e "${C_WARN}>> [WARNING] $*${C_RESET}" >&3; log "WARNING: $*"; }
ui_error() { echo -e "${C_ERR}>> [ERROR] $*${C_RESET}" >&3; log "ERROR: $*"; }

update_progress() {
    CURRENT_STEP=$((CURRENT_STEP + 1))
    local step_name="$1"
    local elapsed=$(( $(date +%s) - START_TIME ))
    local eta=0
    if [ "$CURRENT_STEP" -gt 0 ]; then
        eta=$(( (elapsed / CURRENT_STEP) * (TOTAL_STEPS - CURRENT_STEP) ))
    fi
    local perc=$(( (CURRENT_STEP * 100) / TOTAL_STEPS ))
    echo -e "\n${C_STEP}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}" >&3
    echo -e "${C_STEP}▶ PASO [ $CURRENT_STEP / $TOTAL_STEPS ] | ${perc}% | Tiempo: ${elapsed}s | ETA: ${eta}s${C_RESET}" >&3
    echo -e "${C_STEP}▶ ${C_BOLD}${step_name}${C_RESET}" >&3
    echo -e "${C_STEP}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${C_RESET}" >&3
    log "STARTING STEP $CURRENT_STEP: $step_name"
}

run_with_spinner() {
    local cmd_desc="$1"
    shift
    local pid
    local delay=0.1
    local spinstr='|/-\'
    
    log "RUNNING: $*"
    "$@" &
    pid=$!
    
    printf "${C_INFO} %s ${C_RESET}" "$cmd_desc" >&3
    while kill -0 $pid 2>/dev/null; do
        local temp=${spinstr#?}
        printf " [%c] " "$spinstr" >&3
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b" >&3
    done
    
    wait $pid
    local ret=$?
    if [ $ret -eq 0 ]; then
        echo -e " ${C_SUCCESS}[Hecho]${C_RESET}" >&3
        log "COMPLETED SUCCESSFULLY: $*"
    else
        echo -e " ${C_ERR}[Fallo]${C_RESET}" >&3
        log "FAILED WITH CODE $ret: $*"
    fi
    return $ret
}

trap_error() {
    local line=$1
    local code=$2
    local cmd=$3
    echo -e "\n${C_ERR}================ ERROR CRÍTICO ================${C_RESET}" >&3
    ui_error "Ha ocurrido un error fatal y la instalación debe detenerse."
    ui_error "Paso actual: $CURRENT_STEP / $TOTAL_STEPS"
    ui_error "Comando fallido: $cmd"
    ui_error "Código de salida: $code"
    ui_error "Línea del script: $line"
    ui_error "Log file completo en: $LOG_FILE"
    echo -e "${C_WARN}--- Últimas líneas relevantes del log ---${C_RESET}" >&3
    tail -n 20 "$LOG_FILE" >&3
    echo -e "${C_ERR}===============================================${C_RESET}" >&3
    
    ui_msg "Intentando desmontar sistemas de archivos de forma segura..."
    umount -R "$MNT_DIR" 2>/dev/null || true
    swapoff -a 2>/dev/null || true
    
    exit "$code"
}
trap 'trap_error ${LINENO} $? "$BASH_COMMAND"' ERR

is_done() { [ -f "$STATE_DIR/$1" ]; }
mark_done() { touch "$STATE_DIR/$1"; }
save_state() { echo "$2" > "$STATE_DIR/$1"; mark_done "$1"; }
load_state() { cat "$STATE_DIR/$1" 2>/dev/null || echo ""; }

# ==============================================================================
# 3. INTERACCIÓN Y ENTRADA DE DATOS (COMPATIBLE CON CURL | BASH)
# ==============================================================================
read_input() {
    local prompt="$1"
    local var_name="$2"
    local is_secret="${3:-false}"
    local val=""
    while [ -z "$val" ]; do
        echo -en "${C_PROMPT}${prompt}${C_RESET} " >&3
        if [ "$is_secret" = true ]; then
            read -r -s val < /dev/tty
            echo >&3
        else
            read -r val < /dev/tty
        fi
        
        if [ -z "$val" ]; then
            ui_warn "El valor no puede estar vacío. Inténtalo de nuevo."
        fi
    done
    eval "$var_name=\"\$val\""
}

# ==============================================================================
# 4. FUNCIONES DEL INSTALADOR
# ==============================================================================

step_checks() {
    if is_done "step_checks"; then return; fi
    update_progress "Verificaciones iniciales del sistema"
    
    run_with_spinner "Verificando conexión a Internet" ping -c 1 archlinux.org
    
    if [ ! -d "/sys/firmware/efi/efivars" ]; then
        ui_error "El sistema NO está arrancado en modo UEFI. Abortando."
        exit 1
    fi
    ui_success "Modo UEFI detectado."
    
    SUPPORTS_V3=false
    if /lib/ld-linux-x86-64.so.2 --help | grep -q "x86-64-v3 (supported, searched)"; then
        SUPPORTS_V3=true
        ui_success "CPU soporta x86-64-v3 (AVX2). Se usarán repositorios CachyOS optimizados."
    else
        ui_warn "CPU NO soporta x86-64-v3 (Entorno VM o HW antiguo). Se usarán repositorios CachyOS estándar."
    fi
    save_state "supports_v3" "$SUPPORTS_V3"
    
    mark_done "step_checks"
}

step_select_disk() {
    if is_done "step_select_disk"; then return; fi
    update_progress "Selección de disco de instalación"
    
    echo -e "\n${C_INFO}Discos disponibles detectados:${C_RESET}" >&3
    local i=1
    local -A DISK_MAP
    
    while read -r name size model; do
        if [ -n "$name" ] && [[ ! "$name" == loop* ]]; then
            echo -e "  ${C_BOLD}$i)${C_RESET} /dev/$name - $size - $model" >&3
            DISK_MAP[$i]="/dev/$name"
            ((i++))
        fi
    done <<< "$(lsblk -d -n -o NAME,SIZE,MODEL | awk '$1!="loop"')"
    
    local sel=""
    while [[ -z "${DISK_MAP[$sel]:-}" ]]; do
        read_input "Selecciona el número del disco para instalar Arch Linux: " sel false
    done
    
    TARGET_DISK="${DISK_MAP[$sel]}"
    
    # Comprobar si es SSD o HDD
    local rota
    rota=$(lsblk -n -d -o ROTA "$TARGET_DISK")
    if [ "$rota" == "0" ]; then
        IS_SSD=true
        ui_msg "El disco seleccionado es SSD/NVMe."
    else
        IS_SSD=false
        ui_msg "El disco seleccionado es HDD/SATA rotacional."
    fi
    
    echo -e "\n${C_ERR}${C_BOLD}!!! ATENCIÓN PELIGRO DE PÉRDIDA DE DATOS !!!${C_RESET}" >&3
    echo -e "${C_WARN}Has seleccionado el disco: ${C_INFO}$TARGET_DISK${C_RESET}" >&3
    echo -e "${C_WARN}Todos los datos y particiones actuales en este disco serán DESTRUIDOS de forma irreversible.${C_RESET}" >&3
    
    local confirm=""
    while [[ "$confirm" != "BORRAR" ]]; do
        read_input "Para continuar, escribe la palabra exacta 'BORRAR' (en mayúsculas): " confirm false
    done
    
    ui_success "Confirmación aceptada. El disco $TARGET_DISK será borrado."
    
    save_state "target_disk" "$TARGET_DISK"
    save_state "is_ssd" "$IS_SSD"
    mark_done "step_select_disk"
}

step_user_data() {
    if is_done "step_user_data"; then return; fi
    update_progress "Recopilación de datos del usuario"
    
    local usr p1 p2 host
    while true; do
        read_input "Nombre del nuevo usuario (ej: jose): " usr false
        if [[ ! "$usr" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
            ui_warn "Nombre de usuario inválido. Usa solo minúsculas y números sin espacios."
        else
            break
        fi
    done
    
    while true; do
        read_input "Contraseña para el usuario (y root): " p1 true
        read_input "Repite la contraseña: " p2 true
        if [ "$p1" == "$p2" ]; then
            break
        else
            ui_warn "Las contraseñas no coinciden. Inténtalo de nuevo."
        fi
    done
    
    read_input "Nombre del equipo (Hostname, ej: arch-bazzite): " host false
    
    save_state "user_name" "$usr"
    save_state "user_pass" "$p1"
    save_state "host_name" "$host"
    mark_done "step_user_data"
}

step_partitioning() {
    if is_done "step_partitioning"; then return; fi
    update_progress "Particionando el disco objetivo"
    
    local disk
    disk=$(load_state "target_disk")
    
    umount -R "$MNT_DIR" 2>/dev/null || true
    swapoff -a 2>/dev/null || true
    
    run_with_spinner "Limpiando firmas del disco" wipefs -a -f "$disk"
    run_with_spinner "Creando tabla GPT" sgdisk -Z "$disk"
    run_with_spinner "Creando partición EFI (1GB)" sgdisk -n 1:0:+1024M -t 1:ef00 -c 1:"EFI" "$disk"
    run_with_spinner "Creando partición ROOT (Resto)" sgdisk -n 2:0:0 -t 2:8300 -c 2:"ROOT" "$disk"
    run_with_spinner "Notificando al kernel" partprobe "$disk"
    sleep 3
    
    if [[ "$disk" == *nvme* || "$disk" == *mmcblk* ]]; then
        PART_EFI="${disk}p1"
        PART_ROOT="${disk}p2"
    else
        PART_EFI="${disk}1"
        PART_ROOT="${disk}2"
    fi
    
    run_with_spinner "Formateando EFI a FAT32" mkfs.fat -F32 -n "EFI" "$PART_EFI"
    run_with_spinner "Formateando ROOT a BTRFS" mkfs.btrfs -f -L "ARCH" "$PART_ROOT"
    
    save_state "part_efi" "$PART_EFI"
    save_state "part_root" "$PART_ROOT"
    mark_done "step_partitioning"
}

step_btrfs() {
    if is_done "step_btrfs"; then return; fi
    update_progress "Configurando Subvolúmenes Btrfs"
    
    local root_part=$(load_state "part_root")
    local efi_part=$(load_state "part_efi")
    local is_ssd=$(load_state "is_ssd")
    
    mount "$root_part" "$MNT_DIR"
    run_with_spinner "Creando subvolumen @" btrfs subvolume create "$MNT_DIR/@"
    run_with_spinner "Creando subvolumen @home" btrfs subvolume create "$MNT_DIR/@home"
    run_with_spinner "Creando subvolumen @snapshots" btrfs subvolume create "$MNT_DIR/@snapshots"
    run_with_spinner "Creando subvolumen @var_log" btrfs subvolume create "$MNT_DIR/@var_log"
    run_with_spinner "Creando subvolumen @cache" btrfs subvolume create "$MNT_DIR/@cache"
    run_with_spinner "Creando subvolumen @tmp" btrfs subvolume create "$MNT_DIR/@tmp"
    run_with_spinner "Creando subvolumen @var_tmp" btrfs subvolume create "$MNT_DIR/@var_tmp"
    umount "$MNT_DIR"
    
    local MNT_OPTS="compress=zstd,noatime"
    if [ "$is_ssd" = true ] || [ "$is_ssd" = "true" ]; then
        MNT_OPTS="${MNT_OPTS},discard=async"
    fi
    
    run_with_spinner "Montando raíz (@)" mount -o "${MNT_OPTS},subvol=@" "$root_part" "$MNT_DIR"
    mkdir -p "$MNT_DIR"/{boot/efi,home,.snapshots,var/log,var/cache,tmp,var/tmp}
    
    run_with_spinner "Montando @home" mount -o "${MNT_OPTS},subvol=@home" "$root_part" "$MNT_DIR/home"
    run_with_spinner "Montando @snapshots" mount -o "${MNT_OPTS},subvol=@snapshots" "$root_part" "$MNT_DIR/.snapshots"
    run_with_spinner "Montando @var_log" mount -o "${MNT_OPTS},subvol=@var_log" "$root_part" "$MNT_DIR/var/log"
    run_with_spinner "Montando @cache" mount -o "${MNT_OPTS},subvol=@cache" "$root_part" "$MNT_DIR/var/cache"
    run_with_spinner "Montando @tmp" mount -o "${MNT_OPTS},subvol=@tmp" "$root_part" "$MNT_DIR/tmp"
    run_with_spinner "Montando @var_tmp" mount -o "${MNT_OPTS},subvol=@var_tmp" "$root_part" "$MNT_DIR/var/tmp"
    
    run_with_spinner "Montando EFI" mount "$efi_part" "$MNT_DIR/boot/efi"
    
    mark_done "step_btrfs"
}

step_pacstrap() {
    if is_done "step_pacstrap"; then return; fi
    update_progress "Instalando sistema base de Arch Linux"
    
    run_with_spinner "Actualizando llaves del LiveUSB" pacman -Sy --noconfirm archlinux-keyring
    
    sed -i 's/^#Color/Color\nILoveCandy/g' /etc/pacman.conf
    sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/g' /etc/pacman.conf
    
    local BASE_PKGS=(
        base base-devel btrfs-progs grub efibootmgr grub-btrfs
        networkmanager wget curl rsync sudo nano vim git
        amd-ucode zram-generator xdg-user-dirs bash-completion
    )
    
    run_with_spinner "Ejecutando pacstrap" pacstrap -K "$MNT_DIR" "${BASE_PKGS[@]}"
    run_with_spinner "Generando fstab" genfstab -U "$MNT_DIR" >> "$MNT_DIR/etc/fstab"
    
    mark_done "step_pacstrap"
}

step_prepare_chroot() {
    if is_done "step_prepare_chroot"; then return; fi
    update_progress "Generando script interno para Chroot"
    
    # Exportar variables necesarias para el chroot
    cat << EOF > "$MNT_DIR/root/chroot_vars.env"
USER_NAME="$(load_state "user_name")"
USER_PASS="$(load_state "user_pass")"
HOST_NAME="$(load_state "host_name")"
SUPPORTS_V3="$(load_state "supports_v3")"
IS_SSD="$(load_state "is_ssd")"
EOF

    # Crear el script de chroot sin expandir variables locales aquí ($)
    cat << 'CHROOT_SCRIPT' > "$MNT_DIR/root/chroot_install.sh"
#!/usr/bin/env bash
set -Eeuo pipefail
source /root/chroot_vars.env

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
exec 1>>/var/log/chroot_install.log 2>&1

echo "---- CONFIGURACIÓN BÁSICA ----"
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

echo "---- USUARIOS ----"
if ! id "$USER_NAME" &>/dev/null; then
    useradd -m -G wheel,video,audio,kvm,libvirt,input -s /bin/bash "$USER_NAME"
fi
echo "root:$USER_PASS" | chpasswd
echo "$USER_NAME:$USER_PASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

echo "---- PACMAN Y MULTILIB ----"
sed -i 's/^#Color/Color\nILoveCandy/g' /etc/pacman.conf
sed -i 's/^#ParallelDownloads = 5/ParallelDownloads = 10/g' /etc/pacman.conf
sed -i '/\[multilib\]/,/Include = /s/^#//' /etc/pacman.conf

echo "---- INTEGRACIÓN CACHYOS REPOS ----"
pacman-key --init
pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com || true
pacman-key --lsign-key F3B607488DB35A47 || true

KEYRING_URL=$(curl -s https://mirror.cachyos.org/repo/x86_64/cachyos/ | grep -o 'cachyos-keyring-[0-9\-]*any\.pkg\.tar\.zst' | head -n 1 || true)
MIRRORLIST_URL=$(curl -s https://mirror.cachyos.org/repo/x86_64/cachyos/ | grep -o 'cachyos-mirrorlist-[0-9\-]*any\.pkg\.tar\.zst' | head -n 1 || true)

if [ -z "$KEYRING_URL" ]; then
    echo "Fallo obteniendo las URLs de CachyOS dinámicamente. Usando método estático."
    pacman -U --noconfirm 'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-keyring-20240331-1-any.pkg.tar.zst' 'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-mirrorlist-18-1-any.pkg.tar.zst'
else
    pacman -U --noconfirm "https://mirror.cachyos.org/repo/x86_64/cachyos/$KEYRING_URL" "https://mirror.cachyos.org/repo/x86_64/cachyos/$MIRRORLIST_URL"
fi

# Configurar pacman.conf para inyectar repositorios CachyOS
if [ "$SUPPORTS_V3" = "true" ]; then
    sed -i '/\[core\]/i \[cachyos-v3\]\nInclude = /etc/pacman.d/cachyos-v3-mirrorlist\n\n\[cachyos\]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n' /etc/pacman.conf
else
    sed -i '/\[core\]/i \[cachyos\]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n' /etc/pacman.conf
fi

pacman -Syu --noconfirm

echo "---- KERNEL CACHYOS ----"
pacman -S --noconfirm linux-cachyos linux-cachyos-headers

echo "---- OPTIMIZACIÓN MAKEPKG ----"
sed -i 's/-j2/-j32/g' /etc/makepkg.conf
sed -i 's/^#MAKEFLAGS="-j2"/MAKEFLAGS="-j32"/g' /etc/makepkg.conf
sed -i 's/COMPRESSZST=(zstd -c -T0 --ultra -20 -)/COMPRESSZST=(zstd -c -T0 --ultra -20 -)/' /etc/makepkg.conf
sed -i 's/COMPRESSXZ=(xz -c -z -)/COMPRESSXZ=(xz -c -z - --threads=0)/' /etc/makepkg.conf

echo "---- ZRAM ----"
cat << ZRAM > /etc/systemd/zram-generator.conf
[zram0]
zram-size = ram / 2
compression-algorithm = zstd
swap-priority = 100
ZRAM

cat << SYSCTL > /etc/sysctl.d/99-zram.conf
vm.swappiness = 150
vm.page-cluster = 0
SYSCTL

echo "---- RED Y DNS ----"
mkdir -p /etc/systemd/resolved.conf.d
cat << DNS > /etc/systemd/resolved.conf.d/dns.conf
[Resolve]
DNS=1.1.1.1 1.0.0.1 8.8.8.8
DNSSEC=allow-downgrade
DNSOverTLS=opportunistic
MulticastDNS=yes
LLMNR=yes
DNS
rm -f /etc/resolv.conf
ln -rsf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf

CHROOT_SCRIPT
    chmod +x "$MNT_DIR/root/chroot_install.sh"
    mark_done "step_prepare_chroot"
}

step_chroot_base() {
    if is_done "step_chroot_base"; then return; fi
    update_progress "Configurando Chroot: Base, CachyOS, Kernel y ZRAM"
    
    cp /etc/resolv.conf "$MNT_DIR/etc/resolv.conf"
    run_with_spinner "Ejecutando script base chroot" arch-chroot "$MNT_DIR" /root/chroot_install.sh
    
    mark_done "step_chroot_base"
}

step_chroot_packages() {
    if is_done "step_chroot_packages"; then return; fi
    update_progress "Instalando paquetes: GNOME, AMD, Gaming, Virt y Multimedia"
    
    # Creamos un segundo script para instalar la paquetería sin matar pacman
    cat << 'PKG_SCRIPT' > "$MNT_DIR/root/chroot_pkgs.sh"
#!/usr/bin/env bash
set -Eeuo pipefail
exec 1>>/var/log/chroot_pkgs.log 2>&1

PKGS=(
    # GNOME Wayland Base
    gnome gnome-tweaks gnome-software gnome-software-packagekit-plugin 
    gnome-software-plugin-flatpak xdg-desktop-portal-gnome gdm wayland
    
    # Drivers AMD Puros
    mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon xf86-video-amdgpu
    vulkan-icd-loader lib32-vulkan-icd-loader
    
    # Multimedia (PipeWire completo)
    pipewire lib32-pipewire pipewire-pulse pipewire-alsa pipewire-jack lib32-pipewire-jack
    wireplumber gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav
    ffmpeg bluez bluez-utils ttf-liberation ttf-dejavu noto-fonts
    
    # Gaming Bazzite-like
    steam lutris wine-staging winetricks gamemode lib32-gamemode
    mangohud lib32-mangohud gamescope vkbasalt lib32-vkbasalt
    obs-studio obs-vkcapture lib32-obs-vkcapture corectrl input-remapper
    
    # Virtualización y Contenedores
    podman distrobox squashfs-tools libvirt virt-manager qemu-full
    edk2-ovmf dnsmasq bridge-utils iptables-nft vde2
    
    # Herramientas de sistema, Snapshots y Seguridad
    flatpak ufw fwupd power-profiles-daemon snapper snap-pac btrfs-assistant
)

pacman -S --noconfirm --needed "${PKGS[@]}"

# Setup Flatpak flathub
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

# UFW setup
ufw default deny incoming
ufw default allow outgoing
PKG_SCRIPT
    chmod +x "$MNT_DIR/root/chroot_pkgs.sh"
    
    run_with_spinner "Instalando todos los paquetes requeridos" arch-chroot "$MNT_DIR" /root/chroot_pkgs.sh
    
    mark_done "step_chroot_packages"
}

step_snapper() {
    if is_done "step_snapper"; then return; fi
    update_progress "Configurando Snapper (Snapshots Btrfs)"
    
    cat << 'SNAPPER_SCRIPT' > "$MNT_DIR/root/chroot_snapper.sh"
#!/usr/bin/env bash
set -Eeuo pipefail
exec 1>>/var/log/chroot_snapper.log 2>&1

# Corrección del problema .snapshots already mounted
umount /.snapshots || true
rm -rf /.snapshots
snapper --no-dbus -c root create-config /
btrfs subvolume delete /.snapshots || true
mkdir /.snapshots
mount -a
chmod 750 /.snapshots

# Configurar timeline
sed -i 's/^TIMELINE_MIN_AGE=.*/TIMELINE_MIN_AGE="1800"/g' /etc/snapper/configs/root
sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/g' /etc/snapper/configs/root
sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/g' /etc/snapper/configs/root
sed -i 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="0"/g' /etc/snapper/configs/root
sed -i 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="0"/g' /etc/snapper/configs/root
sed -i 's/^TIMELINE_LIMIT_YEARLY=.*/TIMELINE_LIMIT_YEARLY="0"/g' /etc/snapper/configs/root
SNAPPER_SCRIPT
    chmod +x "$MNT_DIR/root/chroot_snapper.sh"
    
    run_with_spinner "Ejecutando configuración de Snapper" arch-chroot "$MNT_DIR" /root/chroot_snapper.sh
    
    mark_done "step_snapper"
}

step_bootloader() {
    if is_done "step_bootloader"; then return; fi
    update_progress "Instalando y configurando GRUB"
    
    cat << 'BOOT_SCRIPT' > "$MNT_DIR/root/chroot_boot.sh"
#!/usr/bin/env bash
set -Eeuo pipefail
exec 1>>/var/log/chroot_boot.log 2>&1

# Eliminamos referencias fallidas a hooks de encripción por si acaso
sed -i 's/ encrypt / /g' /etc/mkinitcpio.conf
mkinitcpio -P

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB --recheck
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=3/' /etc/default/grub
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="loglevel=3 quiet splash amdgpu.ppfeaturemask=0xffffffff"/' /etc/default/grub
grub-mkconfig -o /boot/grub/grub.cfg
BOOT_SCRIPT
    chmod +x "$MNT_DIR/root/chroot_boot.sh"
    
    run_with_spinner "Generando mkinitcpio e instalando GRUB" arch-chroot "$MNT_DIR" /root/chroot_boot.sh
    
    mark_done "step_bootloader"
}

step_services() {
    if is_done "step_services"; then return; fi
    update_progress "Habilitando Servicios de Systemd"
    
    local IS_SSD
    IS_SSD=$(load_state "is_ssd")
    
    cat << SVC_SCRIPT > "$MNT_DIR/root/chroot_svc.sh"
#!/usr/bin/env bash
set -Eeuo pipefail
exec 1>>/var/log/chroot_svc.log 2>&1

systemctl enable gdm
systemctl enable NetworkManager
systemctl enable systemd-resolved
systemctl enable bluetooth
systemctl enable libvirtd
systemctl enable ufw
systemctl enable power-profiles-daemon
systemctl enable grub-btrfsd
systemctl enable snapper-timeline.timer
systemctl enable snapper-cleanup.timer

if [ "$IS_SSD" = "true" ]; then
    systemctl enable fstrim.timer
fi
SVC_SCRIPT
    chmod +x "$MNT_DIR/root/chroot_svc.sh"
    
    run_with_spinner "Habilitando daemons" arch-chroot "$MNT_DIR" /root/chroot_svc.sh
    
    mark_done "step_services"
}

step_cleanup() {
    if is_done "step_cleanup"; then return; fi
    update_progress "Limpieza final y preparado para reinicio"
    
    run_with_spinner "Limpiando archivos temporales" rm -f \
        "$MNT_DIR/root/chroot_vars.env" \
        "$MNT_DIR/root/chroot_install.sh" \
        "$MNT_DIR/root/chroot_pkgs.sh" \
        "$MNT_DIR/root/chroot_snapper.sh" \
        "$MNT_DIR/root/chroot_boot.sh" \
        "$MNT_DIR/root/chroot_svc.sh"
        
    mkdir -p "$MNT_DIR/var/log/iceman_install"
    cp "$LOG_FILE" "$MNT_DIR/var/log/iceman_install/main_install.log"
    cp "$MNT_DIR"/var/log/chroot_*.log "$MNT_DIR/var/log/iceman_install/" 2>/dev/null || true
    
    run_with_spinner "Desmontando sistemas de archivos" umount -R "$MNT_DIR"
    
    mark_done "step_cleanup"
}

step_finish() {
    echo -e "\n${C_SUCCESS}========================================================================${C_RESET}" >&3
    echo -e "${C_SUCCESS}     INSTALACIÓN COMPLETADA CON ÉXITO - SISTEMA ARCH/CACHYOS LISTO      ${C_RESET}" >&3
    echo -e "${C_SUCCESS}========================================================================${C_RESET}" >&3
    echo -e "${C_INFO}El sistema está optimizado para AMD (Ryzen 5950X / RX7600XT).${C_RESET}" >&3
    echo -e "${C_INFO}Basado en Btrfs, GNOME Wayland, CachyOS Kernel y repositorios.${C_RESET}" >&3
    echo -e "${C_INFO}Logs guardados en: /var/log/iceman_install/ dentro del nuevo sistema.${C_RESET}" >&3
    echo -e "${C_WARN}Ya puedes retirar el USB de instalación y reiniciar tu equipo.${C_RESET}\n" >&3
}

# ==============================================================================
# 5. EJECUCIÓN PRINCIPAL DE FLUJO
# ==============================================================================
main() {
    echo -e "${C_BOLD}${C_STEP}INICIANDO INSTALADOR BAZZITE-LIKE ARCH + CACHYOS${C_RESET}" >&3
    
    step_checks
    step_select_disk
    step_user_data
    step_partitioning
    step_btrfs
    step_pacstrap
    step_prepare_chroot
    step_chroot_base
    step_chroot_packages
    step_snapper
    step_bootloader
    step_services
    step_cleanup
    step_finish
}

main "$@"
