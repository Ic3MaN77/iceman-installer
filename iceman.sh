#!/bin/bash
# ==============================================================================
# ICEMAN INSTALLER — Arch Linux + Kernel CachyOS
# Objetivo: PC Gaming/Uso diario — AMD Ryzen 9 5950X / Radeon RX 7600 XT
# Optimización: Uso agresivo de RAM (tmpfs) para descargas y compilación.
# Idioma del sistema resultante: es_ES.UTF-8 · Zona horaria: Europe/Madrid
# ==============================================================================

set -uo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------------------
# 0. VARIABLES GLOBALES
# ------------------------------------------------------------------------------
LOG_FILE="/var/log/iceman_install.log"
: > "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/iceman_install.log"; : > "$LOG_FILE"

C_BLUE="\033[1;34m"; C_CYAN="\033[1;36m"; C_GREEN="\033[1;32m"
C_RED="\033[1;31m";  C_YELLOW="\033[1;33m"; C_MAGENTA="\033[1;35m"; C_NC="\033[0m"

TIMEZONE="Europe/Madrid"
LOCALE_NAME="es_ES.UTF-8"
KEYMAP="es"
XKB_LAYOUT="es"

WORK_DIR="$(mktemp -d /tmp/iceman.XXXXXX)"
STEP_COUNT=0
TOTAL_STEPS=34

# ------------------------------------------------------------------------------
# 1. UTILIDADES DE SALIDA / LOG / ERRORES / PROGRESO VISUAL
# ------------------------------------------------------------------------------
log()      { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE"; }
step()     { STEP_COUNT=$((STEP_COUNT+1)); echo -e "\n${C_BLUE}[Paso ${STEP_COUNT}/${TOTAL_STEPS}]${C_NC} ${C_CYAN}${1}${C_NC}"; log "PASO ${STEP_COUNT}: ${1}"; }
msg_ok()   { echo -e "  ${C_GREEN}✔${C_NC} ${1}"; log "OK: ${1}"; }
msg_warn() { echo -e "  ${C_YELLOW}⚠${C_NC} ${1}"; log "WARN: ${1}"; }
msg_info() { echo -e "  ${C_MAGENTA}ℹ${C_NC} ${1}"; log "INFO: ${1}"; }
die()      {
    echo -e "\n${C_RED}✘ FALLO CRÍTICO:${C_NC} ${1}" >&2
    echo -e "${C_YELLOW}--- Últimas 25 líneas del log (${LOG_FILE}) ---${C_NC}" >&2
    tail -n 25 "$LOG_FILE" >&2 2>/dev/null
    echo -e "${C_RED}Instalación abortada.${C_NC}" >&2
    cleanup_on_exit
    exit 1
}

run_spin() {
    local desc="$1"; shift
    log "CMD(spin): $*"
    ( "$@" ) >> "$LOG_FILE" 2>&1 &
    local pid=$!
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0 start=$SECONDS last=""
    while kill -0 "$pid" 2>/dev/null; do
        local elapsed=$((SECONDS-start))
        last="$(tail -n 1 "$LOG_FILE" 2>/dev/null | cut -c1-55)"
        printf "\r  ${C_CYAN}%s${C_NC} %s ${C_YELLOW}(%ds)${C_NC} %s\033[K" \
            "${spin:i++%${#spin}:1}" "$desc" "$elapsed" "$last"
        sleep 0.15
    done
    wait "$pid"; local rc=$?
    if [ "$rc" -eq 0 ]; then
        printf "\r  ${C_GREEN}✔${C_NC} %s ${C_YELLOW}(%ds)${C_NC}\033[K\n" "$desc" "$((SECONDS-start))"
        log "OK: $desc"
    else
        printf "\r  ${C_RED}✘${C_NC} %s\033[K\n" "$desc"
        die "$desc (comando: $*)"
    fi
}

run_visible() {
    local desc="$1"; shift
    log "CMD(visible): $*"
    echo -e "  ${C_CYAN}▶ ${desc}...${C_NC}"
    "$@" 2>&1 | tee -a "$LOG_FILE"
    local rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ]; then
        die "$desc (comando: $*)"
    fi
    msg_ok "$desc"
}

cleanup_on_exit() {
    umount /mnt/tmp 2>/dev/null || true
    umount /mnt/var/cache/pacman/pkg 2>/dev/null || true
    umount -R /mnt 2>/dev/null || true
    [ -e /dev/mapper/cryptroot ] && cryptsetup close cryptroot 2>/dev/null || true
    rm -rf "$WORK_DIR" 2>/dev/null || true
}
trap cleanup_on_exit EXIT

clear
echo -e "${C_BLUE}================================================================${C_NC}"
echo -e "${C_BLUE}       ICEMAN INSTALLER — Arch Linux + CachyOS Kernel           ${C_NC}"
echo -e "${C_BLUE}================================================================${C_NC}"
echo "Log completo en: $LOG_FILE"
log "Iniciando Iceman Installer"

# ------------------------------------------------------------------------------
# 2. PRE-VUELO
# ------------------------------------------------------------------------------
step "Comprobaciones previas del entorno"
[ "$EUID" -eq 0 ] || die "Este script debe ejecutarse como root."
[ -d /sys/firmware/efi/efivars ] || die "Este script requiere arranque en modo UEFI."
command -v curl >/dev/null || die "curl no está disponible."
command -v pacstrap >/dev/null || die "Entorno inválido (falta pacstrap)."

if ! ping -c 2 -W 3 archlinux.org >/dev/null 2>&1; then
    die "Sin conexión a Internet."
fi
msg_ok "Conexión a Internet verificada."
run_spin "Sincronizando reloj (NTP)" timedatectl set-ntp true

FREE_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
if [ "$FREE_RAM_MB" -lt 16000 ]; then
    msg_warn "Se recomiendan al menos 16GB de RAM para aceleración tmpfs. (Detectado: ${FREE_RAM_MB}MB)"
else
    msg_ok "RAM abundante detectada. Se activará la aceleración extrema en tmpfs."
fi

# ------------------------------------------------------------------------------
# 3. DETECCIÓN DE ENTORNO
# ------------------------------------------------------------------------------
step "Detectando entorno de hardware (Metal / VM)"
VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || echo none)"
if [ "$VIRT_TYPE" = "none" ]; then
    IS_VM=0; msg_ok "Hardware físico (Metal) detectado."
else
    IS_VM=1; msg_warn "Entorno virtualizado: ${VIRT_TYPE}."
fi

CPU_VENDOR="$(grep -m1 -oP 'vendor_id\s*:\s*\K.*' /proc/cpuinfo)"
case "$CPU_VENDOR" in
    *AMD*)   MICROCODE_PKG="amd-ucode" ;;
    *Intel*) MICROCODE_PKG="intel-ucode" ;;
    *)       MICROCODE_PKG="amd-ucode intel-ucode" ;;
esac

GPU_INFO="$(lspci -nn 2>/dev/null | grep -Ei 'vga|3d|display' || true)"
if [ "$IS_VM" -eq 0 ] && echo "$GPU_INFO" | grep -qi 'amd\|ati'; then
    GPU_VENDOR="amd"; msg_ok "GPU AMD/Radeon detectada."
elif [ "$IS_VM" -eq 0 ] && echo "$GPU_INFO" | grep -qi 'nvidia'; then
    GPU_VENDOR="nvidia"
else
    GPU_VENDOR="generic"
fi

# ------------------------------------------------------------------------------
# 4. RECOLECCIÓN DE DATOS
# ------------------------------------------------------------------------------
step "Selección de disco de instalación"
lsblk -d -p -n -o NAME,SIZE,MODEL,TRAN | grep -v -E 'loop|sr0'
read -rp "$(echo -e ${C_CYAN}'Ruta del disco a usar (ej. /dev/nvme0n1): '${C_NC})" DISK < /dev/tty
[ -b "$DISK" ] || die "‘$DISK’ no es válido."

echo -e "${C_RED}\n¡ATENCIÓN! Vas a BORRAR POR COMPLETO ${DISK}${C_NC}"
read -rp "$(echo -e ${C_RED}'Escribe BORRAR para confirmar: '${C_NC})" CONFIRM1 < /dev/tty
[ "$CONFIRM1" = "BORRAR" ] || die "Abortado."

DISK_BASE="$(basename "$DISK")"
ROTA=$(cat "/sys/block/${DISK_BASE}/queue/rotational" 2>/dev/null || echo 1)
[ "$ROTA" = "0" ] && IS_SSD=1 || IS_SSD=0

step "Datos de usuario y sistema"
read -rp "Nombre de usuario [Iceman]: " USER_NAME < /dev/tty; USER_NAME="${USER_NAME:-Iceman}"
read -rp "Nombre del equipo [Arch-Gaming-Rig]: " HOSTNAME_DEF < /dev/tty; HOSTNAME_DEF="${HOSTNAME_DEF:-Arch-Gaming-Rig}"

while true; do
    read -rsp "Contraseña para ${USER_NAME} y root: " PASSWORD < /dev/tty; echo
    read -rsp "Repite la contraseña: " PASSWORD2 < /dev/tty; echo
    [ -n "$PASSWORD" ] && [ "$PASSWORD" = "$PASSWORD2" ] && break
    msg_warn "Las contraseñas no coinciden o están vacías."
done

LUKS_OPT=0
read -rp "¿Cifrar partición con LUKS2? (s/N): " LUKS_ANS < /dev/tty
if [[ "$LUKS_ANS" =~ ^[Ss]$ ]]; then
    LUKS_OPT=1
    while true; do
        read -rsp "Contraseña LUKS: " LUKS_PASS < /dev/tty; echo
        read -rsp "Repite contraseña LUKS: " LUKS_PASS2 < /dev/tty; echo
        [ -n "$LUKS_PASS" ] && [ "$LUKS_PASS" = "$LUKS_PASS2" ] && break
    done
fi

# ------------------------------------------------------------------------------
# 5. REPOSITORIOS: MULTILIB + CACHYOS
# ------------------------------------------------------------------------------
step "Optimizando pacman.conf del entorno Live"
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 15/' /etc/pacman.conf
sed -i '/^#\[multilib\]/,/^#Include/{s/^#//}' /etc/pacman.conf
run_visible "Sincronizando pacman" pacman -Sy

step "Instalando repositorios CachyOS"
cd "$WORK_DIR"
run_visible "Descargando cachyos-repo" curl -# -fL "https://mirror.cachyos.org/cachyos-repo.tar.xz" -o cachyos-repo.tar.xz
mkdir -p cachyos-repo
run_spin "Extrayendo cachyos-repo" tar -xf cachyos-repo.tar.xz -C cachyos-repo --strip-components=1
cd cachyos-repo
chmod +x cachyos-repo.sh
run_visible "Inyectando repositorio CachyOS" ./cachyos-repo.sh --install
cd "$WORK_DIR"
run_visible "Sincronizando listas" pacman -Syy

KERNEL_PKG="linux-cachyos"

# ------------------------------------------------------------------------------
# 6. PARTICIONADO Y SISTEMA DE ARCHIVOS
# ------------------------------------------------------------------------------
step "Preparando almacenamiento"
umount -R /mnt 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true

run_spin "Particionando $DISK" bash -c "sgdisk -Z \"$DISK\" && sgdisk -n 1:0:+1G -t 1:ef00 -c 1:\"EFI\" \"$DISK\" && sgdisk -n 2:0:0 -t 2:8300 -c 2:\"ROOT\" \"$DISK\""
partprobe "$DISK" >> "$LOG_FILE" 2>&1 || true
sleep 2

if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"mmcblk"* ]]; then
    PART_EFI="${DISK}p1"; PART_ROOT="${DISK}p2"
else
    PART_EFI="${DISK}1";  PART_ROOT="${DISK}2"
fi

run_spin "Formateando EFI" mkfs.fat -F32 -n EFI "$PART_EFI"

if [ "$LUKS_OPT" -eq 1 ]; then
    run_spin "Cifrando LUKS2" bash -c "printf '%s' \"$LUKS_PASS\" | cryptsetup -q luksFormat --type luks2 --pbkdf pbkdf2 \"$PART_ROOT\" -"
    run_spin "Abriendo LUKS2" bash -c "printf '%s' \"$LUKS_PASS\" | cryptsetup open \"$PART_ROOT\" cryptroot -"
    MAPPER_ROOT="/dev/mapper/cryptroot"
    ROOT_UUID="$(blkid -s UUID -o value "$PART_ROOT")"
else
    MAPPER_ROOT="$PART_ROOT"
    ROOT_UUID=""
fi

run_spin "Formateando BTRFS" mkfs.btrfs -f -L ArchCachy "$MAPPER_ROOT"
mount "$MAPPER_ROOT" /mnt
for sv in @ @home @log @pkg @snapshots; do btrfs subvolume create "/mnt/${sv}" >/dev/null; done
umount /mnt

[ "$IS_SSD" -eq 1 ] && MOUNT_OPTS="noatime,compress=zstd:1,space_cache=v2,discard=async" || MOUNT_OPTS="noatime,compress=zstd:1,space_cache=v2"
mount -o "${MOUNT_OPTS},subvol=@" "$MAPPER_ROOT" /mnt
mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,boot/efi,tmp}
mount -o "${MOUNT_OPTS},subvol=@home"      "$MAPPER_ROOT" /mnt/home
mount -o "${MOUNT_OPTS},subvol=@log"       "$MAPPER_ROOT" /mnt/var/log
mount -o "${MOUNT_OPTS},subvol=@pkg"       "$MAPPER_ROOT" /mnt/var/cache/pacman/pkg
mount -o "${MOUNT_OPTS},subvol=@snapshots" "$MAPPER_ROOT" /mnt/.snapshots
mount "$PART_EFI" /mnt/boot/efi

# --- ACELERACIÓN TMPFS EN RAM ---
step "Activando aceleración en memoria RAM (tmpfs)"
msg_info "Asignando espacios temporales en RAM para acelerar pacstrap y makepkg..."
mount -t tmpfs -o size=16G,mode=1777 tmpfs /mnt/tmp
mount -t tmpfs -o size=8G tmpfs /mnt/var/cache/pacman/pkg
msg_ok "TMPFS montado. Operaciones intensivas ocurrirán en memoria RAM."

# ------------------------------------------------------------------------------
# 7. INSTALACIÓN BASE
# ------------------------------------------------------------------------------
step "Instalando sistema base (pacstrap acelerado por RAM)"
BASE_PKGS=(
    base base-devel linux-cachyos linux-cachyos-headers linux-cachyos-lts linux-cachyos-lts-headers
    linux-firmware ${MICROCODE_PKG} cachyos-keyring cachyos-hooks cachyos-settings
    btrfs-progs grub grub-btrfs efibootmgr os-prober networkmanager nano vim git curl wget rsync
    zram-generator sbctl plymouth ntfs-3g exfatprogs dosfstools
)
run_visible "pacstrap" pacstrap -K /mnt "${BASE_PKGS[@]}"

run_spin "Generando fstab" genfstab -U /mnt >> /mnt/etc/fstab
[ "$LUKS_OPT" -eq 0 ] || echo "# cryptdevice UUID=$ROOT_UUID en GRUB" >> /mnt/etc/fstab
cp /etc/pacman.conf /mnt/etc/pacman.conf
bash -c 'cp -a /etc/pacman.d/cachyos*-mirrorlist /mnt/etc/pacman.d/ 2>/dev/null || true'

# ------------------------------------------------------------------------------
# 8. PREPARACIÓN CHROOT
# ------------------------------------------------------------------------------
step "Preparando script de configuración chroot"
install -d -m 700 /mnt/root
{
    printf 'USER_NAME=%q\n'    "$USER_NAME"
    printf 'HOSTNAME_DEF=%q\n' "$HOSTNAME_DEF"
    printf 'PASSWORD=%q\n'     "$PASSWORD"
    printf 'TIMEZONE=%q\n'     "$TIMEZONE"
    printf 'LOCALE_NAME=%q\n'  "$LOCALE_NAME"
    printf 'KEYMAP=%q\n'       "$KEYMAP"
    printf 'XKB_LAYOUT=%q\n'   "$XKB_LAYOUT"
    printf 'LUKS_OPT=%q\n'     "$LUKS_OPT"
    printf 'ROOT_UUID=%q\n'    "$ROOT_UUID"
    printf 'IS_VM=%q\n'        "$IS_VM"
    printf 'VIRT_TYPE=%q\n'    "$VIRT_TYPE"
    printf 'GPU_VENDOR=%q\n'   "$GPU_VENDOR"
} > /mnt/root/iceman_vars.sh

cat > /mnt/root/iceman_chroot.sh <<'CHROOT_EOF'
#!/bin/bash
set -uo pipefail
source /root/iceman_vars.sh
LOG=/root/iceman_chroot.log
: > "$LOG"

C_CYAN="\033[1;36m"; C_GREEN="\033[1;32m"; C_RED="\033[1;31m"; C_YELLOW="\033[1;33m"; C_NC="\033[0m"
log(){ echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; }

run_spin() {
    local desc="$1"; shift
    ( "$@" ) >> "$LOG" 2>&1 &
    local pid=$!
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0 start=$SECONDS
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${C_CYAN}%s${C_NC} %s ${C_YELLOW}(%ds)${C_NC}\033[K" "${spin:i++%${#spin}:1}" "$desc" "$((SECONDS-start))"
        sleep 0.15
    done
    wait "$pid"; local rc=$?
    if [ "$rc" -eq 0 ]; then
        printf "\r  ${C_GREEN}✔${C_NC} %s ${C_YELLOW}(%ds)${C_NC}\033[K\n" "$desc" "$((SECONDS-start))"
    else
        printf "\r  ${C_RED}✘${C_NC} FALLO CRÍTICO: %s\033[K\n" "$desc"
        echo "ERROR en: $desc" >&2
        exit 1
    fi
}

run_spin_soft() {
    local desc="$1"; shift
    ( "$@" ) >> "$LOG" 2>&1 &
    local pid=$!
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${C_CYAN}%s${C_NC} %s (opcional)\033[K" "${spin:i++%${#spin}:1}" "$desc"
        sleep 0.15
    done
    wait "$pid"; local rc=$?
    if [ "$rc" -eq 0 ]; then
        printf "\r  ${C_GREEN}✔${C_NC} %s\033[K\n" "$desc"
    else
        printf "\r  ${C_YELLOW}⚠${C_NC} %s (Omitido)\033[K\n" "$desc"
    fi
}

run_visible() {
    local desc="$1"; shift
    echo -e "  ${C_CYAN}▶ ${desc}...${C_NC}"
    "$@" 2>&1 | tee -a "$LOG"
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        echo -e "  ${C_RED}✘ FALLO: ${desc}${C_NC}" >&2
        exit 1
    fi
}

run_visible_soft() {
    local desc="$1"; shift
    echo -e "  ${C_CYAN}▶ ${desc}...${C_NC}"
    "$@" 2>&1 | tee -a "$LOG"
    if [ "${PIPESTATUS[0]}" -ne 0 ]; then
        echo -e "  ${C_YELLOW}⚠ AVISO: ${desc} falló, continuando...${C_NC}"
    fi
}

echo -e "${C_CYAN}==> [chroot] Locales y Red${C_NC}"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime && hwclock --systohc
echo "${LOCALE_NAME} UTF-8" > /etc/locale.gen
locale-gen >> "$LOG" 2>&1
echo "LANG=${LOCALE_NAME}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
echo "${HOSTNAME_DEF}" > /etc/hostname

echo -e "${C_CYAN}==> [chroot] Pacman e Inicialización de Llaves${C_NC}"
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 15/' /etc/pacman.conf
run_spin "Inicializando pacman-key" pacman-key --init
run_spin "Poblando llaves" pacman-key --populate archlinux cachyos
run_spin "Sincronizando bases" pacman -Syy

echo -e "${C_CYAN}==> [chroot] Usuarios${C_NC}"
echo "root:${PASSWORD}" | chpasswd
run_spin "Creando ${USER_NAME}" useradd -m -G wheel,input,video,audio,storage,optical -s /bin/bash "${USER_NAME}"
echo "${USER_NAME}:${PASSWORD}" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
echo "${USER_NAME} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/90-temp-installer
chmod 440 /etc/sudoers.d/*

echo -e "${C_CYAN}==> [chroot] Optimización de Makepkg en RAM${C_NC}"
sed -i 's/^CFLAGS=.*/CFLAGS="-march=native -O3 -pipe -fno-plt -fexceptions -Wp,-D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security -fstack-clash-protection -fcf-protection"/' /etc/makepkg.conf
sed -i 's/^CXXFLAGS=.*/CXXFLAGS="\$CFLAGS"/' /etc/makepkg.conf
sed -i 's/^#MAKEFLAGS=.*/MAKEFLAGS="-j\$(nproc)"/' /etc/makepkg.conf
sed -i 's/^MAKEFLAGS=.*/MAKEFLAGS="-j\$(nproc)"/' /etc/makepkg.conf
echo "BUILDDIR=/tmp/makepkg" >> /etc/makepkg.conf

cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

echo -e "${C_CYAN}==> [chroot] Drivers y GNOME${C_NC}"
COMMON_MEDIA=(gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav ffmpeg a52dec faac faad2 x264 x265 xvidcore libdvdcss)
if [ "$IS_VM" -eq 0 ] && [ "$GPU_VENDOR" = "amd" ]; then
    run_visible "Instalando AMD + Codecs" pacman -S --noconfirm --needed mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon libva-mesa-driver lib32-libva-mesa-driver corectrl "${COMMON_MEDIA[@]}"
else
    run_visible "Instalando Gráficos + Codecs" pacman -S --noconfirm --needed mesa lib32-mesa "${COMMON_MEDIA[@]}"
fi

run_visible "GNOME + GDM" pacman -S --noconfirm --needed gnome gnome-tweaks gdm xdg-desktop-portal-gnome xdg-user-dirs bluez bluez-utils ufw gufw
run_spin "Habilitando servicios base" bash -c "systemctl enable NetworkManager gdm fstrim.timer bluetooth ufw"

echo -e "${C_CYAN}==> [chroot] mkinitcpio y GRUB${C_NC}"
[ "${LUKS_OPT}" -eq 1 ] && HOOKS="base udev autodetect microcode modconf kms keyboard keymap consolefont block plymouth encrypt btrfs filesystems fsck" || HOOKS="base udev autodetect microcode modconf kms keyboard keymap consolefont block plymouth btrfs filesystems fsck"
sed -i "s|^HOOKS=(.*|HOOKS=(${HOOKS})|" /etc/mkinitcpio.conf
plymouth-set-default-theme -R bgrt >> "$LOG" 2>&1 || true
run_visible "Generando initramfs" mkinitcpio -P

sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=4/' /etc/default/grub
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0"/' /etc/default/grub
sed -i 's/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
if [ "${LUKS_OPT}" -eq 1 ]; then
    sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=${ROOT_UUID}:cryptroot root=/dev/mapper/cryptroot\"|" /etc/default/grub
    echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
fi

run_spin "grub-install" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ArchCachy --recheck
run_spin "grub-mkconfig" grub-mkconfig -o /boot/grub/grub.cfg

echo -e "${C_CYAN}==> [chroot] Snapper / BTRFS${C_NC}"
run_visible "Instalando Snapper" pacman -S --noconfirm --needed snapper snap-pac btrfs-assistant
run_spin "Configurando Snapper" snapper --no-dbus -c root create-config /
btrfs subvolume delete /.snapshots >> "$LOG" 2>&1 || true
mkdir -p /.snapshots
mount -a >> "$LOG" 2>&1 || true
run_spin "Habilitando Snapper" systemctl enable snapper-timeline.timer snapper-cleanup.timer grub-btrfsd

echo -e "${C_CYAN}==> [chroot] Secure Boot${C_NC}"
if sbctl status 2>/dev/null | grep -qi "Setup Mode:.*Enabled"; then
    run_spin "Creando llaves Secure Boot" sbctl create-keys
    run_spin "Inscribiendo llaves" sbctl enroll-keys --microsoft
    for f in /boot/vmlinuz-linux-cachyos /boot/vmlinuz-linux-cachyos-lts /boot/efi/EFI/ArchCachy/grubx64.efi /boot/grub/x86_64-efi/core.efi; do
        [ -f "$f" ] && sbctl sign -s "$f" >> "$LOG" 2>&1
    done
fi

echo -e "${C_CYAN}==> [chroot] Gaming y Flatpak${C_NC}"
run_visible "Instalando software extra" pacman -S --noconfirm --needed firefox thunderbird qbittorrent steam lutris mangohud lib32-mangohud goverlay gamemode lib32-gamemode gamescope wine-staging winetricks flatpak grub-btrfs power-profiles-daemon
systemctl enable power-profiles-daemon >> "$LOG" 2>&1
run_spin "Remoto Flathub" flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

echo -e "${C_CYAN}==> [chroot] YAY y AUR (En RAM tmpfs)${C_NC}"
run_visible_soft "Compilando YAY (RAM)" su - "${USER_NAME}" -c '
    git clone --depth 1 https://aur.archlinux.org/yay-bin.git /tmp/yay-bin
    cd /tmp/yay-bin && makepkg -si --noconfirm
'

if su - "${USER_NAME}" -c 'command -v yay' >/dev/null 2>&1; then
    run_visible_soft "Compilando ofimática y gaming AUR (RAM)" su - "${USER_NAME}" -c 'yay -S --noconfirm --needed pamac-all onlyoffice-desktopeditors heroic-games-launcher-bin protonup-qt game-devices-udev snapd'
fi

if command -v snap >/dev/null 2>&1 || pacman -Qq snapd >/dev/null 2>&1; then
    ln -sf /var/lib/snapd/snap /snap 2>/dev/null || true
    run_spin_soft "Habilitando Snapd" bash -c "systemctl enable snapd.socket && systemctl enable snapd.apparmor"
fi

echo -e "${C_CYAN}==> [chroot] Limpieza Final${C_NC}"
rm -f /etc/sudoers.d/90-temp-installer
run_spin_soft "Limpiando huérfanos" bash -c 'orphans=$(pacman -Qtdq); [ -n "$orphans" ] && pacman -Rns --noconfirm $orphans || true'

exit 0
CHROOT_EOF
chmod 700 /mnt/root/iceman_chroot.sh

# ------------------------------------------------------------------------------
# 9. EJECUCIÓN CHROOT
# ------------------------------------------------------------------------------
step "Iniciando configuración interna (Chroot)"
arch-chroot /mnt /root/iceman_chroot.sh || die "Fallo en chroot. Revisa el log."

# ------------------------------------------------------------------------------
# 10. DESMONTAJE Y LIMPIEZA
# ------------------------------------------------------------------------------
step "Limpieza y desmontaje de memoria/discos"
rm -f /mnt/root/iceman_vars.sh /mnt/root/iceman_chroot.sh /mnt/root/iceman_chroot.log
cp "$LOG_FILE" /mnt/var/log/iceman_install.log 2>/dev/null || true

# Desmontamos expresamente los tmpfs para poder desmontar el resto
umount /mnt/tmp 2>/dev/null || true
umount /mnt/var/cache/pacman/pkg 2>/dev/null || true
umount -R /mnt
[ "$LUKS_OPT" -eq 1 ] && cryptsetup close cryptroot

echo -e "\n${C_GREEN}================================================================${C_NC}"
echo -e "${C_GREEN} INSTALACIÓN SUPER-RÁPIDA COMPLETADA (Arch Linux + CachyOS) ${C_NC}"
echo -e "${C_GREEN}================================================================${C_NC}"
echo -e "  Usuario: ${USER_NAME} | Equipo: ${HOSTNAME_DEF}"
echo -e "\n  Escribe 'reboot' para arrancar el nuevo sistema.\n"
exit 0
