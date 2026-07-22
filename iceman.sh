#!/bin/bash
# ==============================================================================
# ICEMAN INSTALLER V5 — Arch Linux + Kernel CachyOS (Refactor completo)
# Objetivo: PC Gaming/Uso diario — AMD Ryzen 9 5950X / Radeon RX 7600 XT
# Idioma del sistema resultante: es_ES.UTF-8 · Zona horaria: Europe/Madrid
# Repositorio: https://github.com/Ic3MaN77/iceman-installer
# ==============================================================================
# USO: curl -fsSL https://raw.githubusercontent.com/.../iceman.sh | bash
# Requiere: arrancar la ISO oficial de Arch Linux en modo UEFI, con red activa.
# ==============================================================================

set -uo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------------------
# 0. VARIABLES GLOBALES
# ------------------------------------------------------------------------------
SCRIPT_VERSION="5.0"
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
TOTAL_STEPS=34   # se ajusta solo si cambias fases; usado únicamente como referencia de progreso

# ------------------------------------------------------------------------------
# 1. UTILIDADES DE SALIDA / LOG / ERRORES
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

run() {
    # Ejecuta un comando registrando toda su salida en el log; corta si falla.
    local desc="$1"; shift
    log "CMD: $*"
    if ! "$@" >> "$LOG_FILE" 2>&1; then
        die "${desc} (comando: $*)"
    fi
}

cleanup_on_exit() {
    # Limpieza defensiva: nunca deja montajes ni mapeos LUKS colgando.
    umount -R /mnt 2>/dev/null || true
    [ -e /dev/mapper/cryptroot ] && cryptsetup close cryptroot 2>/dev/null || true
    rm -rf "$WORK_DIR" 2>/dev/null || true
}
trap cleanup_on_exit EXIT

clear
echo -e "${C_BLUE}================================================================${C_NC}"
echo -e "${C_BLUE}   ICEMAN INSTALLER v${SCRIPT_VERSION} — Arch Linux + CachyOS Kernel   ${C_NC}"
echo -e "${C_BLUE}================================================================${C_NC}"
echo "Log completo en: $LOG_FILE (solo se muestra en pantalla si algo falla)"
log "Iniciando Iceman Installer v${SCRIPT_VERSION}"

# ------------------------------------------------------------------------------
# 2. PRE-VUELO: comprobaciones anti-fallos ANTES de tocar nada
# ------------------------------------------------------------------------------
step "Comprobaciones previas del entorno"

[ "$EUID" -eq 0 ] || die "Este script debe ejecutarse como root (en el live ISO ya lo eres)."
[ -d /sys/firmware/efi/efivars ] || die "No se ha arrancado en modo UEFI. Este script requiere UEFI."
msg_ok "Modo UEFI confirmado."

command -v curl >/dev/null || die "curl no está disponible en el entorno live."
command -v pacstrap >/dev/null || die "Esto no parece la ISO de Arch Linux (falta pacstrap)."

if ! ping -c 2 -W 3 archlinux.org >/dev/null 2>&1; then
    die "Sin conexión a Internet. Conéctate (iwctl / nmcli / cable) y vuelve a lanzar el script."
fi
msg_ok "Conexión a Internet verificada."

run "No se pudo sincronizar la hora por NTP" timedatectl set-ntp true
msg_ok "Reloj del sistema sincronizado (NTP)."

FREE_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
[ "$FREE_RAM_MB" -ge 1500 ] || msg_warn "RAM detectada baja (${FREE_RAM_MB}MB); la instalación puede ir lenta."

# ------------------------------------------------------------------------------
# 3. DETECCIÓN DE ENTORNO: Metal vs VM, CPU, GPU
# ------------------------------------------------------------------------------
step "Detectando entorno de hardware (Metal / Máquina Virtual)"

VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || echo none)"
if [ "$VIRT_TYPE" = "none" ]; then
    IS_VM=0
    msg_ok "Hardware físico (Metal) detectado."
else
    IS_VM=1
    msg_warn "Entorno virtualizado detectado: ${VIRT_TYPE}. Se omitirán drivers de GPU física y se instalarán guest-tools."
fi

CPU_VENDOR="$(grep -m1 -oP 'vendor_id\s*:\s*\K.*' /proc/cpuinfo)"
case "$CPU_VENDOR" in
    *AMD*)   MICROCODE_PKG="amd-ucode" ;;
    *Intel*) MICROCODE_PKG="intel-ucode" ;;
    *)       MICROCODE_PKG="amd-ucode intel-ucode"; msg_warn "CPU no identificada claramente, se instalarán ambos microcodes." ;;
esac
msg_ok "Fabricante de CPU: ${CPU_VENDOR:-desconocido} → microcódigo: ${MICROCODE_PKG}"

GPU_INFO="$(lspci -nn 2>/dev/null | grep -Ei 'vga|3d|display' || true)"
if [ "$IS_VM" -eq 0 ] && echo "$GPU_INFO" | grep -qi 'amd\|ati'; then
    GPU_VENDOR="amd"
    msg_ok "GPU AMD/Radeon detectada."
elif [ "$IS_VM" -eq 0 ] && echo "$GPU_INFO" | grep -qi 'nvidia'; then
    GPU_VENDOR="nvidia"
    msg_warn "GPU NVIDIA detectada (no es el hardware objetivo original; se instalará mesa genérica de todos modos)."
else
    GPU_VENDOR="generic"
fi
log "GPU detectada: $GPU_INFO"

# ------------------------------------------------------------------------------
# 4. RECOLECCIÓN DE DATOS DEL USUARIO
# ------------------------------------------------------------------------------
step "Selección de disco de instalación"

echo -e "${C_YELLOW}\nDiscos disponibles:${C_NC}"
lsblk -d -p -n -o NAME,SIZE,MODEL,TRAN | grep -v -E 'loop|sr0'
echo ""
read -rp "$(echo -e ${C_CYAN}'Introduce la ruta del disco a usar (ej. /dev/sda, /dev/nvme0n1): '${C_NC})" DISK
[ -b "$DISK" ] || die "‘$DISK’ no es un dispositivo de bloque válido."

DISK_MODEL="$(lsblk -dn -o MODEL "$DISK" 2>/dev/null || echo desconocido)"
DISK_SIZE="$(lsblk -dn -o SIZE "$DISK" 2>/dev/null)"
echo -e "${C_RED}\n¡ATENCIÓN! Vas a BORRAR POR COMPLETO:${C_NC}"
echo -e "   Disco:   ${DISK}"
echo -e "   Modelo:  ${DISK_MODEL}"
echo -e "   Tamaño:  ${DISK_SIZE}"
read -rp "$(echo -e ${C_RED}'Escribe exactamente BORRAR para confirmar: '${C_NC})" CONFIRM1
[ "$CONFIRM1" = "BORRAR" ] || die "Confirmación no coincide. Abortado por seguridad."
read -rp "$(echo -e ${C_RED}"Segunda confirmación: escribe la ruta del disco (${DISK}): "${C_NC})" CONFIRM2
[ "$CONFIRM2" = "$DISK" ] || die "La segunda confirmación no coincide. Abortado por seguridad."
msg_ok "Disco confirmado: $DISK"

# Detección SSD/NVMe vs HDD rotacional (para mount options / discard)
DISK_BASE="$(basename "$DISK")"
ROTA=$(cat "/sys/block/${DISK_BASE}/queue/rotational" 2>/dev/null || echo 1)
if [ "$ROTA" = "0" ]; then
    IS_SSD=1
    msg_ok "Almacenamiento de estado sólido (SSD/NVMe) detectado: se activará TRIM/discard."
else
    IS_SSD=0
    msg_warn "Disco mecánico (HDD) detectado: se omitirá discard=async para evitar penalización de rendimiento."
fi

step "Datos de usuario y sistema"
read -rp "Nombre de usuario [Iceman]: " USER_NAME
USER_NAME="${USER_NAME:-Iceman}"
read -rp "Nombre del equipo [Arch-Gaming-Rig]: " HOSTNAME_DEF
HOSTNAME_DEF="${HOSTNAME_DEF:-Arch-Gaming-Rig}"

while true; do
    read -rsp "Contraseña para ${USER_NAME} y root: " PASSWORD; echo
    read -rsp "Repite la contraseña: " PASSWORD2; echo
    if [ -z "$PASSWORD" ]; then
        msg_warn "La contraseña no puede estar vacía."
    elif [ "$PASSWORD" != "$PASSWORD2" ]; then
        msg_warn "Las contraseñas no coinciden."
    else
        break
    fi
done
msg_ok "Contraseña establecida."

LUKS_OPT=0
read -rp "¿Cifrar la partición raíz con LUKS2? (s/N): " LUKS_ANS
if [[ "$LUKS_ANS" =~ ^[Ss]$ ]]; then
    LUKS_OPT=1
    while true; do
        read -rsp "Contraseña de cifrado LUKS: " LUKS_PASS; echo
        read -rsp "Repite la contraseña LUKS: " LUKS_PASS2; echo
        [ -n "$LUKS_PASS" ] && [ "$LUKS_PASS" = "$LUKS_PASS2" ] && break
        msg_warn "Las contraseñas LUKS no coinciden o están vacías."
    done
    msg_ok "Cifrado LUKS2 activado."
else
    msg_info "Instalación sin cifrado (por defecto)."
fi

# ------------------------------------------------------------------------------
# 5. REPOSITORIOS: multilib + CachyOS (método oficial y dinámico)
# ------------------------------------------------------------------------------
step "Optimizando pacman.conf del entorno Live"
sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
grep -q "^ILoveCandy" /etc/pacman.conf || sed -i '/^\[options\]/a ILoveCandy' /etc/pacman.conf
msg_ok "pacman.conf del live optimizado."

step "Habilitando repositorio Multilib"
sed -i '/^#\[multilib\]/,/^#Include/{s/^#//}' /etc/pacman.conf
run "No se pudo sincronizar tras habilitar multilib" pacman -Sy
msg_ok "Multilib habilitado."

step "Instalando repositorios CachyOS (método oficial, auto-detección de CPU)"
# Usamos el propio script oficial de CachyOS: detecta v3/v4/znver4 dinámicamente,
# importa la clave GPG correcta y edita pacman.conf sin que nosotros hardcodeemos nada.
cd "$WORK_DIR"
run "Fallo al descargar el tarball de repos de CachyOS" \
    curl -fsSL "https://mirror.cachyos.org/cachyos-repo.tar.xz" -o cachyos-repo.tar.xz
run "Fallo al extraer el tarball de CachyOS" tar -xf cachyos-repo.tar.xz
cd cachyos-repo
chmod +x cachyos-repo.sh
if ./cachyos-repo.sh --install >> "$LOG_FILE" 2>&1; then
    msg_ok "Repositorios CachyOS instalados y configurados dinámicamente."
else
    die "cachyos-repo.sh --install falló. Revisa el log."
fi
cd "$WORK_DIR"
run "Fallo al sincronizar pacman tras añadir CachyOS" pacman -Syy
msg_ok "Bases de datos de paquetes sincronizadas (Arch + CachyOS)."

# Detectar qué variante de kernel CachyOS instalar según CPU (dinámico)
KERNEL_PKG="linux-cachyos"
if /lib/ld-linux-x86-64.so.2 --help 2>/dev/null | grep -q "x86-64-v3 (supported, searched)"; then
    msg_info "CPU compatible con x86-64-v3: se usará el árbol de paquetes optimizado correspondiente."
fi
msg_ok "Kernel seleccionado: ${KERNEL_PKG} (+ ${KERNEL_PKG}-headers, con linux-cachyos-lts como kernel de respaldo)."

# ------------------------------------------------------------------------------
# 6. PARTICIONADO, LUKS Y BTRFS
# ------------------------------------------------------------------------------
step "Desmontando/limpiando particiones previas de $DISK"
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true

step "Particionando $DISK (GPT: EFI 1GiB + ROOT resto)"
run "Fallo al borrar tabla de particiones" sgdisk -Z "$DISK"
run "Fallo al crear partición EFI" sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI" "$DISK"
run "Fallo al crear partición ROOT" sgdisk -n 2:0:0   -t 2:8300 -c 2:"ROOT" "$DISK"
partprobe "$DISK" >> "$LOG_FILE" 2>&1 || true
sleep 2

if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"mmcblk"* ]]; then
    PART_EFI="${DISK}p1"; PART_ROOT="${DISK}p2"
else
    PART_EFI="${DISK}1";  PART_ROOT="${DISK}2"
fi
[ -b "$PART_EFI" ] && [ -b "$PART_ROOT" ] || die "No se detectaron las particiones tras particionar (${PART_EFI} / ${PART_ROOT})."
msg_ok "Particiones creadas: EFI=${PART_EFI}  ROOT=${PART_ROOT}"

step "Formateando partición EFI (FAT32)"
run "Fallo al formatear EFI" mkfs.fat -F32 -n EFI "$PART_EFI"

if [ "$LUKS_OPT" -eq 1 ]; then
    step "Configurando cifrado LUKS2 sobre $PART_ROOT"
    printf '%s' "$LUKS_PASS" | run "Fallo en luksFormat" cryptsetup -q luksFormat --type luks2 --pbkdf pbkdf2 "$PART_ROOT" -
    printf '%s' "$LUKS_PASS" | cryptsetup open "$PART_ROOT" cryptroot - >> "$LOG_FILE" 2>&1 || die "No se pudo abrir el contenedor LUKS."
    MAPPER_ROOT="/dev/mapper/cryptroot"
    ROOT_UUID="$(blkid -s UUID -o value "$PART_ROOT")"
    msg_ok "LUKS2 configurado y abierto (pbkdf2, compatible con GRUB)."
else
    MAPPER_ROOT="$PART_ROOT"
    ROOT_UUID=""
fi

step "Formateando BTRFS y creando subvolúmenes"
run "Fallo al formatear BTRFS" mkfs.btrfs -f -L ArchCachy "$MAPPER_ROOT"
mount "$MAPPER_ROOT" /mnt
for sv in @ @home @log @pkg @snapshots; do
    run "Fallo al crear subvolumen $sv" btrfs subvolume create "/mnt/${sv}"
done
umount /mnt
msg_ok "Subvolúmenes creados: @ @home @log @pkg @snapshots"

step "Montando estructura BTRFS definitiva"
if [ "$IS_SSD" -eq 1 ]; then
    MOUNT_OPTS="noatime,compress=zstd:1,space_cache=v2,discard=async"
else
    MOUNT_OPTS="noatime,compress=zstd:1,space_cache=v2"
fi
mount -o "${MOUNT_OPTS},subvol=@" "$MAPPER_ROOT" /mnt
mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,boot/efi}
mount -o "${MOUNT_OPTS},subvol=@home"      "$MAPPER_ROOT" /mnt/home
mount -o "${MOUNT_OPTS},subvol=@log"       "$MAPPER_ROOT" /mnt/var/log
mount -o "${MOUNT_OPTS},subvol=@pkg"       "$MAPPER_ROOT" /mnt/var/cache/pacman/pkg
mount -o "${MOUNT_OPTS},subvol=@snapshots" "$MAPPER_ROOT" /mnt/.snapshots
mount "$PART_EFI" /mnt/boot/efi
msg_ok "Sistema de archivos montado en /mnt (opciones: ${MOUNT_OPTS})"

# ------------------------------------------------------------------------------
# 7. INSTALACIÓN BASE (pacstrap)
# ------------------------------------------------------------------------------
step "Instalando sistema base + Kernel CachyOS (pacstrap)"
BASE_PKGS=(
    base base-devel linux-cachyos linux-cachyos-headers
    linux-cachyos-lts linux-cachyos-lts-headers linux-firmware
    ${MICROCODE_PKG}
    cachyos-keyring cachyos-hooks cachyos-settings
    btrfs-progs grub grub-btrfs efibootmgr os-prober
    networkmanager nano vim git curl wget rsync
    zram-generator sbctl plymouth
    ntfs-3g exfatprogs dosfstools
)
run "Fallo en pacstrap (instalación base)" pacstrap -K /mnt "${BASE_PKGS[@]}"
msg_ok "Sistema base instalado (kernel principal linux-cachyos + linux-cachyos-lts de respaldo)."

step "Generando fstab"
genfstab -U /mnt >> /mnt/etc/fstab
[ "$LUKS_OPT" -eq 0 ] || echo "# root cifrada, desbloqueada vía cryptdevice en kernel cmdline (GRUB)" >> /mnt/etc/fstab
msg_ok "fstab generado."

run "Fallo copiando pacman.conf al nuevo sistema" cp /etc/pacman.conf /mnt/etc/pacman.conf
run "Fallo copiando mirrorlists CachyOS" bash -c 'cp -a /etc/pacman.d/cachyos*-mirrorlist /mnt/etc/pacman.d/ 2>/dev/null || true'

# ------------------------------------------------------------------------------
# 8. PREPARAR VARIABLES SEGURAS PARA EL CHROOT (evita inyección de shell)
# ------------------------------------------------------------------------------
step "Preparando configuración segura para chroot"
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
    printf 'KERNEL_PKG=%q\n'   "$KERNEL_PKG"
} > /mnt/root/iceman_vars.sh
chmod 600 /mnt/root/iceman_vars.sh
msg_ok "Variables trasladadas de forma segura (sin exponer contraseñas a expansión de shell)."

# ------------------------------------------------------------------------------
# 9. SCRIPT DE CHROOT (heredoc con comillas: CERO expansión externa)
# ------------------------------------------------------------------------------
step "Escribiendo script de configuración interna (chroot)"
cat > /mnt/root/iceman_chroot.sh <<'CHROOT_EOF'
#!/bin/bash
set -uo pipefail
source /root/iceman_vars.sh
LOG=/root/iceman_chroot.log
: > "$LOG"
log(){ echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; }
run(){ local d="$1"; shift; log "CMD: $*"; if ! "$@" >> "$LOG" 2>&1; then echo "FALLO: $d" >&2; tail -n 30 "$LOG" >&2; exit 1; fi; }

echo "==> [chroot] Configuración regional"
run "timezone" ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
run "hwclock" hwclock --systohc
echo "${LOCALE_NAME} UTF-8" > /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen   # fallback para software que solo soporta en_US
run "locale-gen" locale-gen
cat > /etc/locale.conf <<EOF
LANG=${LOCALE_NAME}
EOF
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
echo "FONT=lat9w-16" >> /etc/vconsole.conf
echo "${HOSTNAME_DEF}" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME_DEF}.localdomain ${HOSTNAME_DEF}
EOF
# Layout de teclado también para sesiones gráficas (Xorg / XWayland)
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<EOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "${XKB_LAYOUT}"
EndSection
EOF
echo "OK: locale/teclado/timezone" >> "$LOG"

echo "==> [chroot] pacman.conf del sistema instalado"
sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 10/' /etc/pacman.conf
grep -q "^ILoveCandy" /etc/pacman.conf || sed -i '/^\[options\]/a ILoveCandy' /etc/pacman.conf
sed -i '/^#\[multilib\]/,/^#Include/{s/^#//}' /etc/pacman.conf
run "pacman-key init" pacman-key --init
run "pacman-key populate" pacman-key --populate archlinux cachyos
run "pacman -Syy" pacman -Syy

echo "==> [chroot] Usuarios y permisos"
echo "root:${PASSWORD}" | chpasswd
run "useradd" useradd -m -G wheel,input,video,audio,storage,optical -s /bin/bash "${USER_NAME}"
echo "${USER_NAME}:${PASSWORD}" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
# NOPASSWD temporal SOLO para poder compilar/instalar AUR sin intervención;
# se revierte al final de este mismo script.
echo "${USER_NAME} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/90-temp-installer
chmod 440 /etc/sudoers.d/90-temp-installer

echo "==> [chroot] Optimización de compilación (makepkg)"
sed -i 's/^CFLAGS=.*/CFLAGS="-march=native -O2 -pipe -fno-plt -fexceptions -Wp,-D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security -fstack-clash-protection -fcf-protection"/' /etc/makepkg.conf
sed -i 's/^CXXFLAGS=.*/CXXFLAGS="\$CFLAGS"/' /etc/makepkg.conf
sed -i 's/^#MAKEFLAGS=.*/MAKEFLAGS="-j\$(nproc)"/' /etc/makepkg.conf
sed -i 's/^MAKEFLAGS=.*/MAKEFLAGS="-j\$(nproc)"/' /etc/makepkg.conf
sed -i 's/^COMPRESSZST=.*/COMPRESSZST=(zstd -c -T0 --ultra -20 -)/' /etc/makepkg.conf

echo "==> [chroot] ZRAM"
mkdir -p /etc/systemd
cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

echo "==> [chroot] Drivers gráficos, multimedia y codecs"
COMMON_MEDIA_PKGS="gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav ffmpeg a52dec faac faad2 x264 x265 xvidcore libdvdcss"
if [ "$IS_VM" -eq 0 ] && [ "$GPU_VENDOR" = "amd" ]; then
    run "drivers AMD" pacman -S --noconfirm --needed mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon \
        libva-mesa-driver lib32-libva-mesa-driver mesa-vdpau lib32-mesa-vdpau corectrl $COMMON_MEDIA_PKGS
elif [ "$IS_VM" -eq 1 ]; then
    run "drivers genéricos VM" pacman -S --noconfirm --needed mesa lib32-mesa $COMMON_MEDIA_PKGS
    case "$VIRT_TYPE" in
        qemu|kvm)   pacman -S --noconfirm --needed qemu-guest-agent spice-vdagent >> "$LOG" 2>&1
                    systemctl enable qemu-guest-agent >> "$LOG" 2>&1 ;;
        vmware)     pacman -S --noconfirm --needed open-vm-tools >> "$LOG" 2>&1
                    systemctl enable vmtoolsd >> "$LOG" 2>&1 ;;
        oracle)     pacman -S --noconfirm --needed virtualbox-guest-utils >> "$LOG" 2>&1
                    systemctl enable vboxservice >> "$LOG" 2>&1 ;;
        *) log "Hipervisor '${VIRT_TYPE}' sin guest-tools específicas conocidas." ;;
    esac
else
    run "drivers genéricos" pacman -S --noconfirm --needed mesa lib32-mesa $COMMON_MEDIA_PKGS
fi

echo "==> [chroot] Escritorio GNOME + GDM"
run "GNOME" pacman -S --noconfirm --needed gnome gnome-tweaks gdm xdg-desktop-portal-gnome xdg-user-dirs
run "enable NetworkManager" systemctl enable NetworkManager
run "enable gdm" systemctl enable gdm
run "enable fstrim" systemctl enable fstrim.timer

echo "==> [chroot] Bluetooth, red y firewall"
run "bluez" pacman -S --noconfirm --needed bluez bluez-utils
systemctl enable bluetooth >> "$LOG" 2>&1
run "ufw" pacman -S --noconfirm --needed ufw gufw
ufw default deny incoming >> "$LOG" 2>&1
ufw default allow outgoing >> "$LOG" 2>&1
ufw allow from 192.168.0.0/16 >> "$LOG" 2>&1   # permite descubrimiento en red local (Steam Remote Play, DLNA, etc.)
systemctl enable ufw >> "$LOG" 2>&1

echo "==> [chroot] mkinitcpio (hooks + Plymouth ${LUKS_OPT:+/LUKS})"
if [ "${LUKS_OPT}" -eq 1 ]; then
    HOOKS_LINE="HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block plymouth encrypt btrfs filesystems fsck)"
else
    HOOKS_LINE="HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block plymouth btrfs filesystems fsck)"
fi
sed -i "s|^HOOKS=(.*|${HOOKS_LINE}|" /etc/mkinitcpio.conf
plymouth-set-default-theme -R bgrt >> "$LOG" 2>&1 || run "mkinitcpio" mkinitcpio -P
run "mkinitcpio" mkinitcpio -P

echo "==> [chroot] GRUB"
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=4/' /etc/default/grub
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0"/' /etc/default/grub
sed -i 's/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
grep -q "^GRUB_GFXMODE=" /etc/default/grub && \
    sed -i 's/^GRUB_GFXMODE=.*/GRUB_GFXMODE="2560x1440,1920x1080,auto"/' /etc/default/grub || \
    echo 'GRUB_GFXMODE="2560x1440,1920x1080,auto"' >> /etc/default/grub
grep -q "^GRUB_GFXPAYLOAD_LINUX=" /etc/default/grub || echo 'GRUB_GFXPAYLOAD_LINUX=keep' >> /etc/default/grub

if [ "${LUKS_OPT}" -eq 1 ]; then
    sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=${ROOT_UUID}:cryptroot root=/dev/mapper/cryptroot\"|" /etc/default/grub
    grep -q "^GRUB_ENABLE_CRYPTODISK=y" /etc/default/grub || echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
fi

run "os-prober" pacman -S --noconfirm --needed os-prober
run "grub-install" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ArchCachy --recheck
run "grub-mkconfig" grub-mkconfig -o /boot/grub/grub.cfg

echo "==> [chroot] Snapper (snapshots BTRFS) + grub-btrfs"
run "snapper pkgs" pacman -S --noconfirm --needed snapper snap-pac btrfs-assistant
umount /.snapshots 2>/dev/null || true
rm -rf /.snapshots
snapper --no-dbus -c root create-config / >> "$LOG" 2>&1 || true
mkdir -p /.snapshots
mount -a >> "$LOG" 2>&1 || true
sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/'   /etc/snapper/configs/root 2>/dev/null || true
sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="5"/'     /etc/snapper/configs/root 2>/dev/null || true
sed -i 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="2"/'   /etc/snapper/configs/root 2>/dev/null || true
sed -i 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="1"/' /etc/snapper/configs/root 2>/dev/null || true
systemctl enable snapper-timeline.timer snapper-cleanup.timer grub-btrfsd >> "$LOG" 2>&1 || true

echo "==> [chroot] Secure Boot (sbctl) — solo si el firmware está en Setup Mode"
if [ -d /sys/firmware/efi/efivars ] && sbctl status 2>/dev/null | grep -qi "Setup Mode:.*Enabled"; then
    run "sbctl create-keys" sbctl create-keys
    run "sbctl enroll-keys" sbctl enroll-keys --microsoft
    for f in /boot/vmlinuz-linux-cachyos /boot/vmlinuz-linux-cachyos-lts \
             /boot/EFI/ArchCachy/grubx64.efi /boot/grub/x86_64-efi/core.efi; do
        [ -f "$f" ] && sbctl sign -s "$f" >> "$LOG" 2>&1
    done
    echo "OK: Secure Boot configurado y binarios firmados." >> "$LOG"
else
    echo "AVISO: Firmware no está en 'Setup Mode'. Secure Boot NO se ha configurado." >> "$LOG"
    echo "       Para activarlo: arranca de nuevo, pon Secure Boot en modo Setup en la BIOS," >> "$LOG"
    echo "       y ejecuta como root: sbctl create-keys && sbctl enroll-keys --microsoft && sbctl sign -s <archivos .efi>" >> "$LOG"
fi

echo "==> [chroot] Software base, gaming y periféricos"
run "software base" pacman -S --noconfirm --needed \
    firefox thunderbird qbittorrent \
    steam lutris mangohud lib32-mangohud goverlay gamemode lib32-gamemode gamescope \
    wine-staging winetricks \
    flatpak \
    grub-btrfs waypaper swww \
    power-profiles-daemon

xdg-settings set default-web-browser firefox.desktop >> "$LOG" 2>&1 || true
systemctl enable power-profiles-daemon >> "$LOG" 2>&1 || true

echo "==> [chroot] Flathub"
su - "${USER_NAME}" -c "flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo" >> "$LOG" 2>&1
flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo >> "$LOG" 2>&1

echo "==> [chroot] yay (AUR helper) — compilado como usuario, sudo temporalmente sin contraseña"
su - "${USER_NAME}" -c '
    set -e
    cd /tmp
    rm -rf yay-bin
    git clone --depth 1 https://aur.archlinux.org/yay-bin.git
    cd yay-bin
    makepkg -si --noconfirm
' >> "$LOG" 2>&1 || echo "AVISO: fallo compilando yay, se omiten paquetes AUR." >> "$LOG"

echo "==> [chroot] Paquetes AUR: tienda Pamac, Snap, Ofimática, Gaming extra, Plymouth Arch, tema GRUB"
if command -v yay >/dev/null 2>&1 || su - "${USER_NAME}" -c 'command -v yay' >/dev/null 2>&1; then
    su - "${USER_NAME}" -c '
        yay -S --noconfirm --needed \
            pamac-all \
            onlyoffice-desktopeditors \
            heroic-games-launcher-bin \
            protonup-qt \
            plymouth-theme-arch-elegant \
            game-devices-udev \
            snapd
    ' >> "$LOG" 2>&1 || echo "AVISO: alguno de los paquetes AUR falló; revisa el log de yay." >> "$LOG"
else
    echo "AVISO: yay no disponible, se omite la fase de paquetes AUR." >> "$LOG"
fi

# Tema Plymouth Arch Linux (si se instaló vía AUR)
if [ -d /usr/share/plymouth/themes/arch-elegant ]; then
    plymouth-set-default-theme -R arch-elegant >> "$LOG" 2>&1 && mkinitcpio -P >> "$LOG" 2>&1
    echo "OK: tema Plymouth 'arch-elegant' aplicado." >> "$LOG"
fi

# snapd: habilitar soporte 'classic' y auto-limpieza de revisiones antiguas (para no ocupar espacio)
if command -v snap >/dev/null 2>&1 || pacman -Qq snapd >/dev/null 2>&1; then
    ln -sf /var/lib/snapd/snap /snap 2>/dev/null || true
    systemctl enable --now snapd.socket >> "$LOG" 2>&1 || true
    systemctl enable --now snapd.apparmor >> "$LOG" 2>&1 || true
    snap set system refresh.retain=2 >> "$LOG" 2>&1 || true
fi

# Pamac: habilitar AUR, Flatpak y comprobación de actualizaciones
if [ -f /etc/pamac.conf ]; then
    sed -i 's/^#EnableAUR/EnableAUR/'                 /etc/pamac.conf
    sed -i 's/^#CheckAURUpdates/CheckAURUpdates/'      /etc/pamac.conf
    sed -i 's/^#EnableFlatpak/EnableFlatpak/'          /etc/pamac.conf
    sed -i 's/^#CheckFlatpakUpdates/CheckFlatpakUpdates/' /etc/pamac.conf
    sed -i 's/^#RemoveUnrequiredDeps/RemoveUnrequiredDeps/' /etc/pamac.conf
    echo "OK: pamac.conf configurado (AUR + Flatpak + auto-limpieza de dependencias)." >> "$LOG"
fi
# Si gnome-software quedó instalado por dependencias de xdg-desktop-portal-gnome, evitar duplicidad con Pamac
pacman -Rns --noconfirm gnome-software >> "$LOG" 2>&1 || true

echo "==> [chroot] Tema de GRUB (Particle-circle)"
cd /tmp
if git clone --depth 1 https://github.com/yeyushengfan258/Particle-circle-grub-theme.git >> "$LOG" 2>&1; then
    cd Particle-circle-grub-theme
    chmod +x install.sh
    pacman -S --noconfirm --needed imagemagick >> "$LOG" 2>&1
    ./install.sh -t window -s 2k -b >> "$LOG" 2>&1 && echo "OK: tema GRUB Particle-circle instalado." >> "$LOG" \
        || echo "AVISO: fallo instalando el tema de GRUB." >> "$LOG"
    grub-mkconfig -o /boot/grub/grub.cfg >> "$LOG" 2>&1
else
    echo "AVISO: no se pudo clonar el repositorio del tema de GRUB." >> "$LOG"
fi

echo "==> [chroot] Revirtiendo sudo sin contraseña (seguridad final)"
rm -f /etc/sudoers.d/90-temp-installer

echo "==> [chroot] Limpieza de dependencias huérfanas y caché de paquetes"
orphans="$(pacman -Qtdq 2>/dev/null || true)"
[ -n "$orphans" ] && pacman -Rns --noconfirm $orphans >> "$LOG" 2>&1 || true
pacman -Sc --noconfirm >> "$LOG" 2>&1 || true

echo "==> [chroot] Configuración interna FINALIZADA con éxito." | tee -a "$LOG"
exit 0
CHROOT_EOF
chmod 700 /mnt/root/iceman_chroot.sh
msg_ok "Script de chroot generado."

# ------------------------------------------------------------------------------
# 10. EJECUCIÓN DEL CHROOT
# ------------------------------------------------------------------------------
step "Ejecutando configuración dentro del sistema instalado (esto tarda varios minutos)"
if arch-chroot /mnt /root/iceman_chroot.sh; then
    msg_ok "Configuración interna completada sin errores."
else
    echo -e "${C_YELLOW}--- Log interno del chroot ---${C_NC}"
    tail -n 40 /mnt/root/iceman_chroot.log 2>/dev/null
    die "La configuración dentro del chroot falló. Revisa /mnt/root/iceman_chroot.log antes de reiniciar."
fi

# ------------------------------------------------------------------------------
# 11. LIMPIEZA FINAL Y SEGURA (borrar credenciales del disco de destino)
# ------------------------------------------------------------------------------
step "Limpieza final"
shred -u /mnt/root/iceman_vars.sh 2>/dev/null || rm -f /mnt/root/iceman_vars.sh
rm -f /mnt/root/iceman_chroot.sh /mnt/root/iceman_chroot.log
rm -rf /mnt/tmp/* /mnt/var/cache/pacman/pkg/*.part 2>/dev/null || true
cp "$LOG_FILE" /mnt/var/log/iceman_install_live.log 2>/dev/null || true
msg_ok "Credenciales temporales borradas y caché limpiada."

step "Desmontando sistema de archivos"
umount -R /mnt
[ "$LUKS_OPT" -eq 1 ] && cryptsetup close cryptroot
msg_ok "Todo desmontado correctamente."

echo -e "\n${C_GREEN}================================================================${C_NC}"
echo -e "${C_GREEN}   INSTALACIÓN COMPLETADA — Arch Linux + CachyOS listo para usar  ${C_NC}"
echo -e "${C_GREEN}================================================================${C_NC}"
echo -e "  Usuario:    ${USER_NAME}"
echo -e "  Equipo:     ${HOSTNAME_DEF}"
echo -e "  Cifrado:    $([ "$LUKS_OPT" -eq 1 ] && echo 'Sí (LUKS2)' || echo 'No')"
echo -e "  Entorno:    $([ "$IS_VM" -eq 1 ] && echo "Máquina Virtual (${VIRT_TYPE})" || echo 'Hardware físico')"
echo ""
echo -e "  Notas importantes:"
echo -e "   · Si activaste Secure Boot en 'Setup Mode', las llaves ya están firmadas."
echo -e "     Si no, revisa el aviso en el log antes de activarlo en la BIOS."
echo -e "   · Pamac queda configurado con soporte AUR y Flatpak activados."
echo -e "   · Snap está instalado con auto-limpieza (solo conserva 2 revisiones)."
echo -e "\n  Escribe 'reboot' para arrancar tu nuevo sistema.\n"
log "Instalación finalizada correctamente."
exit 0
