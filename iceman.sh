#!/bin/bash
# ==============================================================================
# ICEMAN INSTALLER — Arch Linux + Kernel CachyOS (Modo 100% Desatendido)
# Target: AMD Ryzen 9 5950X / Radeon RX 7600 XT — Gaming / Uso diario
# Idioma: es_ES.UTF-8 · Zona horaria: Europe/Madrid
# ==============================================================================

set -uo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------------------
# 0. VARIABLES GLOBALES Y ENTORNO NO INTERACTIVO
# ------------------------------------------------------------------------------
LOG_FILE="/var/log/iceman_install.log"
: > "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/iceman_install.log"; : > "$LOG_FILE"

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

C_BLUE="\033[1;34m"; C_CYAN="\033[1;36m"; C_GREEN="\033[1;32m"
C_RED="\033[1;31m";  C_YELLOW="\033[1;33m"; C_MAGENTA="\033[1;35m"; C_NC="\033[0m"

TIMEZONE="Europe/Madrid"
LOCALE_NAME="es_ES.UTF-8"
KEYMAP="es"
XKB_LAYOUT="es"

WORK_DIR="$(mktemp -d /tmp/iceman.XXXXXX)"
STEP_COUNT=0
TOTAL_STEPS=12

log()      { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE"; }
step()     { STEP_COUNT=$((STEP_COUNT+1)); echo -e "\n${C_BLUE}[Paso ${STEP_COUNT}/${TOTAL_STEPS}]${C_NC} ${C_CYAN}${1}${C_NC}"; log "PASO ${STEP_COUNT}: ${1}"; }
msg_ok()   { echo -e "  ${C_GREEN}✔${C_NC} ${1}"; log "OK: ${1}"; }
msg_warn() { echo -e "  ${C_YELLOW}⚠${C_NC} ${1}"; log "WARN: ${1}"; }
msg_info() { echo -e "  ${C_MAGENTA}ℹ${C_NC} ${1}"; log "INFO: ${1}"; }

die() {
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
    local i=0 start=$SECONDS
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${C_CYAN}%s${C_NC} %s ${C_YELLOW}(%ds)${C_NC}\033[K" "${spin:i++%${#spin}:1}" "$desc" "$((SECONDS-start))"
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
    [ "$rc" -eq 0 ] || die "$desc (comando: $*)"
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
echo -e "${C_BLUE}   ICEMAN INSTALLER — ARCH LINUX + CACHYOS (AUTOMÁTICO)        ${C_NC}"
echo -e "${C_BLUE}================================================================${C_NC}"

# ------------------------------------------------------------------------------
# FASE 0: RECOLECCIÓN ÚNICA DE DATOS (Interrupción CERO a partir de aquí)
# ------------------------------------------------------------------------------
[ "$EUID" -eq 0 ] || die "Este script debe ejecutarse como root."
[ -d /sys/firmware/efi/efivars ] || die "Requiere entorno UEFI."
ping -c 2 -W 3 archlinux.org >/dev/null 2>&1 || die "Sin conexión a Internet."

echo -e "\n${C_YELLOW}Discos detectados:${C_NC}"
lsblk -d -p -n -o NAME,SIZE,MODEL,TRAN | grep -v -E 'loop|sr0'
echo ""
read -rp "$(echo -e ${C_CYAN}'Introduce la ruta del disco a formatear (ej. /dev/nvme0n1): '${C_NC})" DISK < /dev/tty
[ -b "$DISK" ] || die "El dispositivo ‘$DISK’ no existe."

echo -e "${C_RED}\n¡ADVERTENCIA! Se BORRARÁ POR COMPLETO el disco: ${DISK}${C_NC}"
read -rp "$(echo -e ${C_RED}'Escribe BORRAR para confirmar: '${C_NC})" CONFIRM < /dev/tty
[ "$CONFIRM" = "BORRAR" ] || die "Confirmación no válida. Instalación abortada."

read -rp "Nombre de usuario [Iceman]: " USER_NAME < /dev/tty; USER_NAME="${USER_NAME:-Iceman}"
read -rp "Nombre del equipo [Arch-Gaming-Rig]: " HOSTNAME_DEF < /dev/tty; HOSTNAME_DEF="${HOSTNAME_DEF:-Arch-Gaming-Rig}"

while true; do
    read -rsp "Contraseña para ${USER_NAME} y root: " PASSWORD < /dev/tty; echo
    read -rsp "Repite la contraseña: " PASSWORD2 < /dev/tty; echo
    [ -n "$PASSWORD" ] && [ "$PASSWORD" = "$PASSWORD2" ] && break
    msg_warn "Las contraseñas no coinciden o están vacías."
done

LUKS_OPT=0
read -rp "¿Cifrar partición raíz con LUKS2? (s/N): " LUKS_ANS < /dev/tty
if [[ "$LUKS_ANS" =~ ^[Ss]$ ]]; then
    LUKS_OPT=1
    while true; do
        read -rsp "Contraseña de cifrado LUKS: " LUKS_PASS < /dev/tty; echo
        read -rsp "Repite contraseña LUKS: " LUKS_PASS2 < /dev/tty; echo
        [ -n "$LUKS_PASS" ] && [ "$LUKS_PASS" = "$LUKS_PASS2" ] && break
        msg_warn "Contraseñas LUKS no coinciden."
    done
fi

echo -e "\n${C_GREEN}✔ Datos recolectados con éxito. Iniciando modo 100% autónomo...${C_NC}\n"
sleep 2

# ------------------------------------------------------------------------------
# FASE 1: DETECCIÓN Y SINCRONIZACIÓN AUTOMÁTICA
# ------------------------------------------------------------------------------
step "Preparando el entorno y sincronización de reloj"
run_spin "Sincronizando reloj (NTP)" timedatectl set-ntp true

VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || echo none)"
[ "$VIRT_TYPE" = "none" ] && IS_VM=0 || IS_VM=1

CPU_VENDOR="$(grep -m1 -oP 'vendor_id\s*:\s*\K.*' /proc/cpuinfo)"
case "$CPU_VENDOR" in
    *AMD*)   MICROCODE_PKG="amd-ucode" ;;
    *Intel*) MICROCODE_PKG="intel-ucode" ;;
    *)       MICROCODE_PKG="amd-ucode intel-ucode" ;;
esac

GPU_INFO="$(lspci -nn 2>/dev/null | grep -Ei 'vga|3d|display' || true)"
if [ "$IS_VM" -eq 0 ] && echo "$GPU_INFO" | grep -qi 'amd\|ati'; then
    GPU_VENDOR="amd"
elif [ "$IS_VM" -eq 0 ] && echo "$GPU_INFO" | grep -qi 'nvidia'; then
    GPU_VENDOR="nvidia"
else
    GPU_VENDOR="generic"
fi

DISK_BASE="$(basename "$DISK")"
ROTA=$(cat "/sys/block/${DISK_BASE}/queue/rotational" 2>/dev/null || echo 1)
[ "$ROTA" = "0" ] && IS_SSD=1 || IS_SSD=0

# ------------------------------------------------------------------------------
# FASE 2: INYECCIÓN DESATENDIDA DE CACHYOS
# ------------------------------------------------------------------------------
step "Inyectando repositorios CachyOS (Modo Autónomo)"
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 15/' /etc/pacman.conf
sed -i '/^#\[multilib\]/,/^#Include/{s/^#//}' /etc/pacman.conf
run_spin "Sincronizando Pacman base" pacman -Sy --noconfirm

cd "$WORK_DIR"
run_spin "Descargando CachyOS Repo" curl -sSL "https://mirror.cachyos.org/cachyos-repo.tar.xz" -o cachyos-repo.tar.xz
mkdir -p cachyos-repo
tar -xf cachyos-repo.tar.xz -C cachyos-repo --strip-components=1
cd cachyos-repo
chmod +x cachyos-repo.sh
run_spin "Ejecutando cachyos-repo.sh de forma autónoma" bash -c "yes | ./cachyos-repo.sh --install"
cd "$WORK_DIR"
run_spin "Sincronizando repositorios CachyOS" pacman -Syy --noconfirm

# ------------------------------------------------------------------------------
# FASE 3: PARTICIONADO Y MONTAJE BTRFS
# ------------------------------------------------------------------------------
step "Preparando almacenamiento en $DISK"
umount -R /mnt 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true

run_spin "Borrando y re-particionando GPT" bash -c "sgdisk -Z \"$DISK\" && sgdisk -n 1:0:+1G -t 1:ef00 -c 1:\"EFI\" \"$DISK\" && sgdisk -n 2:0:0 -t 2:8300 -c 2:\"ROOT\" \"$DISK\""
partprobe "$DISK" >> "$LOG_FILE" 2>&1 || true
sleep 2

if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"mmcblk"* ]]; then
    PART_EFI="${DISK}p1"; PART_ROOT="${DISK}p2"
else
    PART_EFI="${DISK}1";  PART_ROOT="${DISK}2"
fi

run_spin "Formateando partición EFI" mkfs.fat -F32 -n EFI "$PART_EFI"

if [ "$LUKS_OPT" -eq 1 ]; then
    run_spin "Configurando cifrado LUKS2" bash -c "printf '%s' \"$LUKS_PASS\" | cryptsetup -q luksFormat --type luks2 --pbkdf pbkdf2 \"$PART_ROOT\" -"
    run_spin "Abriendo volumen LUKS2" bash -c "printf '%s' \"$LUKS_PASS\" | cryptsetup open \"$PART_ROOT\" cryptroot -"
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

# ------------------------------------------------------------------------------
# FASE 4: ACELERACIÓN RAM (TMPFS)
# ------------------------------------------------------------------------------
step "Montando aceleradores de rendimiento en RAM (tmpfs)"
mount -t tmpfs -o size=16G,mode=1777 tmpfs /mnt/tmp
mount -t tmpfs -o size=8G tmpfs /mnt/var/cache/pacman/pkg
msg_ok "Caché y área de compilación derivadas a memoria RAM (32GB)."

# ------------------------------------------------------------------------------
# FASE 5: PACSTRAP Y ARCHIVOS DE CONFIGURACIÓN
# ------------------------------------------------------------------------------
step "Instalando sistema base con Pacstrap (en memoria RAM)"
BASE_PKGS=(
    base base-devel linux-cachyos linux-cachyos-headers linux-cachyos-lts linux-cachyos-lts-headers
    linux-firmware ${MICROCODE_PKG} cachyos-keyring cachyos-hooks cachyos-settings
    btrfs-progs grub grub-btrfs efibootmgr os-prober networkmanager nano vim git curl wget rsync
    zram-generator sbctl plymouth ntfs-3g exfatprogs dosfstools
)
run_visible "pacstrap" pacstrap -K /mnt "${BASE_PKGS[@]}" --noconfirm

run_spin "Generando fstab" genfstab -U /mnt >> /mnt/etc/fstab
[ "$LUKS_OPT" -eq 0 ] || echo "# cryptdevice UUID=$ROOT_UUID en GRUB" >> /mnt/etc/fstab
cp /etc/pacman.conf /mnt/etc/pacman.conf
bash -c 'cp -a /etc/pacman.d/cachyos*-mirrorlist /mnt/etc/pacman.d/ 2>/dev/null || true'

# ------------------------------------------------------------------------------
# FASE 6: CONSTRUCCIÓN DEL SCRIPT CHROOT DESATENDIDO
# ------------------------------------------------------------------------------
step "Preparando ejecutable de configuración interna"
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
    printf 'GPU_VENDOR=%q\n'   "$GPU_VENDOR"
} > /mnt/root/iceman_vars.sh

cat > /mnt/root/iceman_chroot.sh <<'CHROOT_EOF'
#!/bin/bash
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
source /root/iceman_vars.sh
LOG=/root/iceman_chroot.log
: > "$LOG"

C_CYAN="\033[1;36m"; C_GREEN="\033[1;32m"; C_RED="\033[1;31m"; C_YELLOW="\033[1;33m"; C_NC="\033[0m"

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
        printf "\r  ${C_RED}✘ FALLO CRÍTICO: %s\033[K\n" "$desc"
        echo "ERROR en: $desc" >&2
        exit 1
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
    "$@" 2>&1 | tee -a "$LOG" || true
}

echo -e "${C_CYAN}==> [chroot] Regionalización y Red${C_NC}"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime && hwclock --systohc
echo "${LOCALE_NAME} UTF-8" > /etc/locale.gen
locale-gen >> "$LOG" 2>&1
echo "LANG=${LOCALE_NAME}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
echo "${HOSTNAME_DEF}" > /etc/hostname

echo -e "${C_CYAN}==> [chroot] Pacman Keys${C_NC}"
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 15/' /etc/pacman.conf
run_spin "Inicializando llaves" pacman-key --init
run_spin "Poblando firmas Arch y CachyOS" pacman-key --populate archlinux cachyos
run_spin "Sincronizando bases de datos" pacman -Syy --noconfirm

echo -e "${C_CYAN}==> [chroot] Cuentas y Accesos${C_NC}"
echo "root:${PASSWORD}" | chpasswd
run_spin "Creando usuario ${USER_NAME}" useradd -m -G wheel,input,video,audio,storage,optical -s /bin/bash "${USER_NAME}"
echo "${USER_NAME}:${PASSWORD}" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
echo "${USER_NAME} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/90-temp-installer
chmod 440 /etc/sudoers.d/*

echo -e "${C_CYAN}==> [chroot] Optimizando Makepkg en RAM${C_NC}"
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

echo -e "${C_CYAN}==> [chroot] Drivers Gráficos, Escritorio y Codecs${C_NC}"
COMMON_MEDIA=(gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav ffmpeg a52dec faac faad2 x264 x265 xvidcore libdvdcss)
if [ "$IS_VM" -eq 0 ] && [ "$GPU_VENDOR" = "amd" ]; then
    run_visible "Drivers AMD + Codecs" pacman -S --noconfirm --needed mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon libva-mesa-driver lib32-libva-mesa-driver corectrl "${COMMON_MEDIA[@]}"
else
    run_visible "Drivers Genéricos + Codecs" pacman -S --noconfirm --needed mesa lib32-mesa "${COMMON_MEDIA[@]}"
fi

run_visible "GNOME + Utilidades" pacman -S --noconfirm --needed gnome gnome-tweaks gdm xdg-desktop-portal-gnome xdg-user-dirs bluez bluez-utils ufw gufw
run_spin "Habilitando servicios de sistema" bash -c "systemctl enable NetworkManager gdm fstrim.timer bluetooth ufw"

echo -e "${C_CYAN}==> [chroot] Configuración de Initramfs y Bootloader${C_NC}"
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

run_spin "Instalando GRUB EFI" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ArchCachy --recheck
run_spin "Generando configuración de GRUB" grub-mkconfig -o /boot/grub/grub.cfg

echo -e "${C_CYAN}==> [chroot] Snapper (Instantáneas BTRFS)${C_NC}"
run_visible "Instalando Snapper" pacman -S --noconfirm --needed snapper snap-pac btrfs-assistant
run_spin "Inicializando Snapper" snapper --no-dbus -c root create-config /
btrfs subvolume delete /.snapshots >> "$LOG" 2>&1 || true
mkdir -p /.snapshots
mount -a >> "$LOG" 2>&1 || true
run_spin "Habilitando Timers de Snapper" systemctl enable snapper-timeline.timer snapper-cleanup.timer grub-btrfsd

echo -e "${C_CYAN}==> [chroot] Firma de Secure Boot${C_NC}"
if sbctl status 2>/dev/null | grep -qi "Setup Mode:.*Enabled"; then
    run_spin "Generando claves Secure Boot" sbctl create-keys
    run_spin "Inscribiendo llaves Microsoft" sbctl enroll-keys --microsoft
    for f in /boot/vmlinuz-linux-cachyos /boot/vmlinuz-linux-cachyos-lts /boot/efi/EFI/ArchCachy/grubx64.efi /boot/grub/x86_64-efi/core.efi; do
        [ -f "$f" ] && sbctl sign -s "$f" >> "$LOG" 2>&1
    done
fi

echo -e "${C_CYAN}==> [chroot] Ecosistema Gaming y Flatpak${C_NC}"
run_visible "Instalando paquetes Gaming" pacman -S --noconfirm --needed firefox thunderbird qbittorrent steam lutris mangohud lib32-mangohud goverlay gamemode lib32-gamemode gamescope wine-staging winetricks flatpak grub-btrfs power-profiles-daemon
systemctl enable power-profiles-daemon >> "$LOG" 2>&1
run_spin "Agregando Flathub" flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

echo -e "${C_CYAN}==> [chroot] AUR (YAY) en RAM${C_NC}"
run_visible_soft "Compilando YAY de forma no interactiva" su - "${USER_NAME}" -c '
    git clone --depth 1 https://aur.archlinux.org/yay-bin.git /tmp/yay-bin
    cd /tmp/yay-bin && makepkg -si --noconfirm
'

if su - "${USER_NAME}" -c 'command -v yay' >/dev/null 2>&1; then
    run_visible_soft "Instalando paquetes AUR automatizados" su - "${USER_NAME}" -c '
        yay -S --noconfirm --needed --answerclean No --answerdiff No --answeredit No \
            pamac-all onlyoffice-desktopeditors heroic-games-launcher-bin protonup-qt game-devices-udev snapd
    '
fi

if command -v snap >/dev/null 2>&1 || pacman -Qq snapd >/dev/null 2>&1; then
    ln -sf /var/lib/snapd/snap /snap 2>/dev/null || true
    run_spin "Habilitando sockets de Snapd" bash -c "systemctl enable snapd.socket && systemctl enable snapd.apparmor"
fi

echo -e "${C_CYAN}==> [chroot] Cierre de Seguridad y Limpieza${C_NC}"
rm -f /etc/sudoers.d/90-temp-installer
run_spin "Limpiando huérfanos de instalación" bash -c 'orphans=$(pacman -Qtdq); [ -n "$orphans" ] && pacman -Rns --noconfirm $orphans || true'

exit 0
CHROOT_EOF
chmod 700 /mnt/root/iceman_chroot.sh

# ------------------------------------------------------------------------------
# FASE 7: EJECUCIÓN AUTÓNOMA DEL CHROOT
# ------------------------------------------------------------------------------
step "Ejecutando configuración completa en el entorno de destino"
arch-chroot /mnt /root/iceman_chroot.sh || die "Fallo durante la ejecución interna. Revisa /mnt/root/iceman_chroot.log."

# ------------------------------------------------------------------------------
# FASE 8: DESMONTAJE Y CONCLUSIÓN
# ------------------------------------------------------------------------------
step "Finalizando instalación y limpiando recursos"
rm -f /mnt/root/iceman_vars.sh /mnt/root/iceman_chroot.sh /mnt/root/iceman_chroot.log
cp "$LOG_FILE" /mnt/var/log/iceman_install.log 2>/dev/null || true

umount /mnt/tmp 2>/dev/null || true
umount /mnt/var/cache/pacman/pkg 2>/dev/null || true
umount -R /mnt
[ "$LUKS_OPT" -eq 1 ] && cryptsetup close cryptroot

echo -e "\n${C_GREEN}================================================================${C_NC}"
echo -e "${C_GREEN} ¡INSTALACIÓN AUTÓNOMA FINALIZADA CON ÉXITO!                    ${C_NC}"
echo -e "${C_GREEN}================================================================${C_NC}"
echo -e "  Usuario: ${USER_NAME} | Hostname: ${HOSTNAME_DEF}"
echo -e "\n  Escribe 'reboot' para iniciar el nuevo sistema.\n"
exit 0
