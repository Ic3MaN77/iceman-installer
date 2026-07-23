#!/bin/bash
# ==============================================================================
# ICEMAN INSTALLER — Arch Linux + CachyOS [ULTIMATE EDITION]
# Target: Gigabyte B550 | Ryzen 9 5950X | Radeon RX 7600 XT | 32GB RAM | NVMe
# ==============================================================================

set -uo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------------------
# 0. MODO DEBUG Y VARIABLES GLOBALES
# ------------------------------------------------------------------------------
DEBUG=0
if [[ "${1:-}" == "--debug" ]]; then
    DEBUG=1
    set -x
    echo -e "\033[1;33m[!] MODO DEBUG ACTIVADO. Ejecución detallada.\033[0m"
    sleep 2
fi

LOG_FILE="/var/log/iceman_install.log"
: > "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/iceman_install.log"; : > "$LOG_FILE"

C_BLUE="\033[1;34m"; C_CYAN="\033[1;36m"; C_GREEN="\033[1;32m"
C_RED="\033[1;31m";  C_YELLOW="\033[1;33m"; C_NC="\033[0m"

TIMEZONE="Europe/Madrid"
LOCALE_NAME="es_ES.UTF-8"
KEYMAP="es"
WORK_DIR="$(mktemp -d /tmp/iceman.XXXXXX)"
STEP_COUNT=0
TOTAL_STEPS=12

# ------------------------------------------------------------------------------
# 1. FUNCIONES CORE Y ROBUSTEZ
# ------------------------------------------------------------------------------
log() { echo "[$(date '+%H:%M:%S')] $*" >> "$LOG_FILE"; }
step() { STEP_COUNT=$((STEP_COUNT+1)); echo -e "\n${C_BLUE}[Paso ${STEP_COUNT}/${TOTAL_STEPS}]${C_NC} ${C_CYAN}${1}${C_NC}"; log "PASO ${STEP_COUNT}: ${1}"; }
msg_ok() { echo -e "  ${C_GREEN}✔${C_NC} ${1}"; log "OK: ${1}"; }
msg_warn() { echo -e "  ${C_YELLOW}⚠${C_NC} ${1}"; log "WARN: ${1}"; }

die() {
    set +x
    echo -e "\n${C_RED}✘ FALLO CRÍTICO:${C_NC} ${1}" >&2
    tail -n 20 "$LOG_FILE" >&2 2>/dev/null
    echo -e "${C_RED}Instalación abortada de emergencia. Limpiando entorno...${C_NC}" >&2
    cleanup_on_exit
    exit 1
}

cleanup_on_exit() {
    umount -q /mnt/tmp 2>/dev/null || true
    umount -q /mnt/var/cache/pacman/pkg 2>/dev/null || true
    umount -q -R /mnt 2>/dev/null || true
    [ -e /dev/mapper/cryptroot ] && cryptsetup close cryptroot 2>/dev/null || true
    rm -rf "$WORK_DIR" 2>/dev/null || true
}
trap cleanup_on_exit EXIT

run_cmd() {
    local desc="$1"; shift
    if [ "$DEBUG" -eq 1 ]; then
        echo -e "  ${C_YELLOW}▶ [DEBUG]${C_NC} ${desc}..."
        "$@" 2>&1 | tee -a "$LOG_FILE" || die "${desc} (Fallo en comando)"
        msg_ok "${desc}"
    else
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
        else
            printf "\r  ${C_RED}✘${C_NC} %s\033[K\n" "$desc"
            die "$desc (Revisa el log: $LOG_FILE)"
        fi
    fi
}

clear
echo -e "${C_BLUE}================================================================${C_NC}"
echo -e "${C_BLUE}   ICEMAN INSTALLER — ARCH LINUX + CACHYOS [ULTIMATE EDITION]   ${C_NC}"
echo -e "${C_BLUE}================================================================${C_NC}"

# ------------------------------------------------------------------------------
# 2. AUDITORÍA DE SISTEMA Y OPTIMIZACIÓN DINÁMICA (VM vs FÍSICO)
# ------------------------------------------------------------------------------
step "Auditoría de Hardware y Entorno"
[ "$EUID" -eq 0 ] || die "Se requieren privilegios de root (EUID 0)."
[ -d /sys/firmware/efi/efivars ] || die "Falta soporte UEFI nativo. Verifica la BIOS/VM."

# Comprobación de conectividad mejorada (curl head en lugar de ping)
curl -I -s --connect-timeout 5 https://archlinux.org >/dev/null || die "Sin conexión a Internet (Fallo curl archlinux.org)."

TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
CPU_CORES=$(nproc)

if [ "$TOTAL_RAM_MB" -ge 30000 ]; then
    TMP_SIZE="16G"; PKG_SIZE="8G"; ZRAM_MAX="8192"
elif [ "$TOTAL_RAM_MB" -ge 15000 ]; then
    TMP_SIZE="8G"; PKG_SIZE="4G"; ZRAM_MAX="4096"
else
    TMP_SIZE="2G"; PKG_SIZE="2G"; ZRAM_MAX="2048"
fi
msg_ok "CPU: ${CPU_CORES} hilos detectados."
msg_ok "RAM: ${TOTAL_RAM_MB}MB. Perfil Aceleración: TMP=${TMP_SIZE}, PKG=${PKG_SIZE}, ZRAM=${ZRAM_MAX}MB."

CPU_VENDOR="$(grep -m1 -oP 'vendor_id\s*:\s*\K.*' /proc/cpuinfo)"
[[ "$CPU_VENDOR" == *"AMD"* ]] && MICROCODE="amd-ucode" || MICROCODE="intel-ucode"

# ------------------------------------------------------------------------------
# 3. INTERFAZ DE USUARIO Y VALIDACIÓN
# ------------------------------------------------------------------------------
step "Configuración y Bloqueo de Perfil"
lsblk -d -p -n -o NAME,SIZE,MODEL,TRAN | grep -v -E 'loop|sr0'
read -rp "$(echo -e ${C_CYAN}'Ruta del disco destino (ej. /dev/nvme0n1 o /dev/vda): '${C_NC})" DISK < /dev/tty
[ -b "$DISK" ] || die "Disco ‘$DISK’ inválido o inexistente."

DISK_SIZE_GB=$(($(blockdev --getsize64 "$DISK" 2>/dev/null || echo 0) / 1024 / 1024 / 1024))
[ "$DISK_SIZE_GB" -lt 40 ] && die "Almacenamiento insuficiente (${DISK_SIZE_GB}GB). Mínimo 40GB."

read -rp "$(echo -e ${C_RED}'Escribe "BORRAR" para formatear '$DISK' por completo: '${C_NC})" CONFIRM < /dev/tty
[ "$CONFIRM" = "BORRAR" ] || die "Abortado por seguridad."

USER_NAME="Iceman"
HOSTNAME_DEF="Arch-Gaming-Rig"

while true; do
    read -rsp "Contraseña de Sistema (Usuario/Root): " PASSWORD < /dev/tty; echo
    read -rsp "Repite la contraseña: " PASSWORD2 < /dev/tty; echo
    [ -n "$PASSWORD" ] && [ "$PASSWORD" = "$PASSWORD2" ] && break
    msg_warn "Contraseñas no coinciden."
done

LUKS_OPT=0
read -rp "¿Cifrar partición raíz LUKS2? (s/N): " LUKS_ANS < /dev/tty
if [[ "$LUKS_ANS" =~ ^[Ss]$ ]]; then
    LUKS_OPT=1
    while true; do
        read -rsp "Contraseña LUKS: " LUKS_PASS < /dev/tty; echo
        read -rsp "Repite LUKS: " LUKS_PASS2 < /dev/tty; echo
        [ -n "$LUKS_PASS" ] && [ "$LUKS_PASS" = "$LUKS_PASS2" ] && break
        msg_warn "Contraseñas LUKS no coinciden."
    done
fi

DISK_BASE="$(basename "$DISK")"
ROTA=$(cat "/sys/block/${DISK_BASE}/queue/rotational" 2>/dev/null || echo 1)
[ "$ROTA" = "0" ] && IS_SSD=1 || IS_SSD=0

# ------------------------------------------------------------------------------
# 4. REPOSITORIOS CACHYOS
# ------------------------------------------------------------------------------
step "Inyección Robusta de Repositorios CachyOS"
mount -o remount,size=75% /run/archiso/cowspace 2>/dev/null || true
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 15/' /etc/pacman.conf

run_cmd "Descargando instalador de CachyOS" curl -sSL "https://mirror.cachyos.org/cachyos-repo.tar.xz" -o "$WORK_DIR/cachyos-repo.tar.xz"
tar -xf "$WORK_DIR/cachyos-repo.tar.xz" -C "$WORK_DIR"
cd "$WORK_DIR/cachyos-repo" || die "No se pudo acceder al directorio del repo CachyOS."
run_cmd "Integrando llaves y repositorios CachyOS" bash -c "./cachyos-repo.sh --install --noconfirm"
run_cmd "Sincronización Pacman" pacman -Syy --noconfirm

# ------------------------------------------------------------------------------
# 5. ESTRUCTURA BTRFS Y LUKS
# ------------------------------------------------------------------------------
step "Particionado y Capa de Bloques (BTRFS)"
umount -q -R /mnt 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true

run_cmd "Esquema GPT y Particiones" bash -c "sgdisk -Z \"$DISK\" && sgdisk -n 1:0:+1G -t 1:ef00 -c 1:\"EFI\" \"$DISK\" && sgdisk -n 2:0:0 -t 2:8300 -c 2:\"ROOT\" \"$DISK\""
partprobe "$DISK" >/dev/null 2>&1 || true; udevadm settle; sleep 2

[[ "$DISK" == *"nvme"* || "$DISK" == *"vda"* || "$DISK" == *"mmcblk"* ]] && PFX="p" || PFX=""
[[ "$DISK" == *"vda"* ]] && PFX="" # KVM fix
PART_EFI="${DISK}${PFX}1"
PART_ROOT="${DISK}${PFX}2"
[ -b "$PART_EFI" ] && [ -b "$PART_ROOT" ] || die "Particiones no detectadas. EFI: $PART_EFI | ROOT: $PART_ROOT"

run_cmd "Formato EFI" mkfs.fat -F32 -n EFI "$PART_EFI"

if [ "$LUKS_OPT" -eq 1 ]; then
    run_cmd "Formato LUKS2 (pbkdf2)" bash -c "printf '%s' \"$LUKS_PASS\" | cryptsetup -q luksFormat --type luks2 --pbkdf pbkdf2 \"$PART_ROOT\" -"
    run_cmd "Apertura LUKS" bash -c "printf '%s' \"$LUKS_PASS\" | cryptsetup open \"$PART_ROOT\" cryptroot -"
    MAPPER_ROOT="/dev/mapper/cryptroot"
    ROOT_UUID="$(blkid -s UUID -o value "$PART_ROOT")"
else
    MAPPER_ROOT="$PART_ROOT"
    ROOT_UUID=""
fi

run_cmd "Formato BTRFS" mkfs.btrfs -f -L ArchCachy "$MAPPER_ROOT"
mount "$MAPPER_ROOT" /mnt

for sv in @ @home @log @pkg @snapshots; do 
    btrfs subvolume create "/mnt/${sv}" >/dev/null || die "Fallo al crear subvolumen ${sv}"
done
umount /mnt

[ "$IS_SSD" -eq 1 ] && OPTS="noatime,compress=zstd:1,space_cache=v2,discard=async" || OPTS="noatime,compress=zstd:1,space_cache=v2"
mount -o "${OPTS},subvol=@" "$MAPPER_ROOT" /mnt
mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,boot/efi,tmp}
mount -o "${OPTS},subvol=@home" "$MAPPER_ROOT" /mnt/home
mount -o "${OPTS},subvol=@log"  "$MAPPER_ROOT" /mnt/var/log
mount -o "${OPTS},subvol=@pkg"  "$MAPPER_ROOT" /mnt/var/cache/pacman/pkg
mount -o "${OPTS},subvol=@snapshots" "$MAPPER_ROOT" /mnt/.snapshots
mount "$PART_EFI" /mnt/boot/efi

# ------------------------------------------------------------------------------
# 6. PACSTRAP Y FSTAB (Orden Corregido)
# ------------------------------------------------------------------------------
step "Despliegue Core del Sistema Operativo"

# 1. Montamos TMPFS antes de pacstrap para acelerar la caché
mount -t tmpfs -o size=${TMP_SIZE},mode=1777 tmpfs /mnt/tmp
mount -t tmpfs -o size=${PKG_SIZE} tmpfs /mnt/var/cache/pacman/pkg

BASE_PKGS=(
    base base-devel linux-cachyos linux-cachyos-headers linux-firmware 
    ${MICROCODE} cachyos-keyring cachyos-hooks cachyos-settings
    btrfs-progs grub grub-btrfs efibootmgr networkmanager nano git curl
    zram-generator sbctl plymouth snapper snap-pac btrfs-assistant
    fwupd power-profiles-daemon
)

# 2. Instalación Base
run_cmd "Instalación Pacstrap" pacstrap -K /mnt "${BASE_PKGS[@]}" --noconfirm

# 3. Genfstab AHORA SÍ, después de tener el sistema de archivos base estructurado
run_cmd "Generando FSTAB (Filtrando temporales)" bash -c "genfstab -U /mnt | grep -v 'tmpfs' > /mnt/etc/fstab"
[ "$LUKS_OPT" -eq 1 ] && echo "# Cryptdevice UUID=$ROOT_UUID reservado" >> /mnt/etc/fstab

cp /etc/pacman.conf /mnt/etc/pacman.conf
cp -a /etc/pacman.d/cachyos*-mirrorlist /mnt/etc/pacman.d/ 2>/dev/null || true

# ------------------------------------------------------------------------------
# 7. INYECCIÓN DEL SCRIPT CHROOT
# ------------------------------------------------------------------------------
step "Construcción del Entorno Chroot"
cat > /mnt/root/iceman_vars.sh <<VARS_EOF
USER_NAME="${USER_NAME}"
HOSTNAME_DEF="${HOSTNAME_DEF}"
PASSWORD="${PASSWORD}"
TIMEZONE="${TIMEZONE}"
LOCALE_NAME="${LOCALE_NAME}"
KEYMAP="${KEYMAP}"
LUKS_OPT=${LUKS_OPT}
ROOT_UUID="${ROOT_UUID}"
ZRAM_MAX=${ZRAM_MAX}
CPU_CORES=${CPU_CORES}
IS_SSD=${IS_SSD}
VARS_EOF

cat > /mnt/root/iceman_chroot.sh <<'CHROOT_EOF'
#!/bin/bash
set -euo pipefail
source /root/iceman_vars.sh

LOG=/root/iceman_chroot.log; : > "$LOG"
run_cmd() {
    local desc="$1"; shift
    echo -e "  \033[1;36m▶\033[0m ${desc}..."
    "$@" 2>&1 | tee -a "$LOG" || { echo -e "  \033[1;31m✘ Fallo en: ${desc}\033[0m"; exit 1; }
}

# -- Configuración Base --
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime && hwclock --systohc
sed -i "s/^#${LOCALE_NAME}/${LOCALE_NAME}/" /etc/locale.gen
locale-gen >> "$LOG" 2>&1
echo "LANG=${LOCALE_NAME}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
echo "${HOSTNAME_DEF}" > /etc/hostname

echo "root:${PASSWORD}" | chpasswd
useradd -m -G wheel,input,video,audio,storage,optical,kvm,render -s /bin/bash "${USER_NAME}"
echo "${USER_NAME}:${PASSWORD}" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
echo "${USER_NAME} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/90-temp-installer
chmod 440 /etc/sudoers.d/*

# -- Optimizaciones de Compilación (Idempotente) --
sed -i "s/^#\?MAKEFLAGS=.*/MAKEFLAGS=\"-j${CPU_CORES}\"/" /etc/makepkg.conf
sed -i '/^BUILDDIR=/d' /etc/makepkg.conf
echo "BUILDDIR=/tmp/makepkg" >> /etc/makepkg.conf

cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = min(ram / 2, ${ZRAM_MAX})
compression-algorithm = zstd
EOF

# -- Hardware AMD Dedicado y GNOME --
run_cmd "Instalando Stack AMD/Gaming y GNOME" pacman -S --noconfirm --needed \
    mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon libva-mesa-driver mesa-vdpau \
    vulkan-tools corectrl lm_sensors gnome gnome-tweaks gdm xdg-desktop-portal-gnome \
    ufw bluez bluez-utils gst-plugins-good gst-plugins-bad gst-plugins-ugly ffmpeg

# -- Configuración Automática CoreCtrl (Polkit) --
mkdir -p /etc/polkit-1/rules.d/
cat > /etc/polkit-1/rules.d/90-corectrl.rules << 'EOF_POL'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.corectrl.helper.init" || action.id == "org.corectrl.helperkiller.init") &&
        subject.local == true && subject.active == true && subject.isInGroup("wheel")) {
            return polkit.Result.YES;
    }
});
EOF_POL

# -- Servicios Críticos --
systemctl enable NetworkManager systemd-resolved gdm bluetooth ufw power-profiles-daemon >> "$LOG" 2>&1
[ "$IS_SSD" -eq 1 ] && systemctl enable fstrim.timer >> "$LOG" 2>&1
ufw default deny >> "$LOG" 2>&1

# -- Snapper Blindado --
run_cmd "Configurando Snapper BTRFS de forma segura" bash -c '
    umount /.snapshots 2>/dev/null || true
    rm -rf /.snapshots 2>/dev/null || true
    snapper --no-dbus -c root create-config /
    btrfs subvolume delete /.snapshots
    mkdir -p /.snapshots
    mount -a
    chmod 750 /.snapshots
'
systemctl enable snapper-timeline.timer snapper-cleanup.timer grub-btrfsd >> "$LOG" 2>&1

# -- Initramfs --
[ "${LUKS_OPT}" -eq 1 ] && HOOKS="base udev autodetect microcode modconf kms keyboard keymap consolefont block plymouth encrypt btrfs filesystems fsck" || HOOKS="base udev autodetect microcode modconf kms keyboard keymap consolefont block plymouth btrfs filesystems fsck"
sed -i "s|^HOOKS=(.*|HOOKS=(${HOOKS})|" /etc/mkinitcpio.conf
plymouth-set-default-theme -R bgrt >> "$LOG" 2>&1 || true
run_cmd "Generando Initramfs" mkinitcpio -P

# -- GRUB (Resolución QHD y AMD PState) --
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=4/' /etc/default/grub
sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT=.*/GRUB_CMDLINE_LINUX_DEFAULT="quiet splash loglevel=3 rd.udev.log_priority=3 vt.global_cursor_default=0 amd_pstate=active"/' /etc/default/grub
sed -i 's/^#\?GRUB_GFXMODE=.*/GRUB_GFXMODE=2560x1440,auto/' /etc/default/grub
sed -i 's/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
if [ "${LUKS_OPT}" -eq 1 ]; then
    sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=${ROOT_UUID}:cryptroot root=/dev/mapper/cryptroot\"|" /etc/default/grub
    echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
fi
run_cmd "Instalando GRUB" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ArchCachy --recheck
run_cmd "Compilando GRUB CFG" grub-mkconfig -o /boot/grub/grub.cfg

# -- Secure Boot --
if sbctl status 2>/dev/null | grep -qi "Setup Mode:.*Enabled"; then
    run_cmd "Configurando Secure Boot" sbctl create-keys
    sbctl enroll-keys --microsoft >> "$LOG" 2>&1
    for f in /boot/vmlinuz-linux-cachyos /boot/efi/EFI/ArchCachy/grubx64.efi; do
        [ -f "$f" ] && sbctl sign -s "$f" >> "$LOG" 2>&1
    done
fi

# -- Ecosistema Gaming y AUR --
run_cmd "Instalando Software Base" pacman -S --noconfirm --needed steam lutris mangohud goverlay gamemode gamescope wine-staging winetricks mame retroarch flatpak firefox
su - "${USER_NAME}" -c 'git clone --depth 1 https://aur.archlinux.org/yay-bin.git /tmp/yay-bin && cd /tmp/yay-bin && makepkg -si --noconfirm' >> "$LOG" 2>&1 || true
if su - "${USER_NAME}" -c 'command -v yay' >/dev/null 2>&1; then
    run_cmd "Construyendo Paquetes AUR" su - "${USER_NAME}" -c 'yay -S --noconfirm --needed --answerclean All --answerdiff None --answeredit None pamac-all heroic-games-launcher-bin protonup-qt game-devices-udev'
fi

# -- Verificaciones Finales de Integridad --
run_cmd "Auditoría de Integridad del Sistema" bash -c '
    [ -f /boot/grub/grub.cfg ] || { echo "ERROR: Falta grub.cfg"; exit 1; }
    [ -d /.snapshots ] || { echo "ERROR: Falta el directorio de Snapper"; exit 1; }
    [ -f /boot/vmlinuz-linux-cachyos ] || { echo "ERROR: Kernel CachyOS no encontrado en /boot"; exit 1; }
    grep -q "@home" /etc/fstab || { echo "ERROR: Subvolumen @home ausente en fstab"; exit 1; }
    systemctl is-enabled NetworkManager >/dev/null || { echo "ERROR: NetworkManager no habilitado"; exit 1; }
'

snapper --no-dbus -c root create --description "Instalación limpia" || true
rm -f /etc/sudoers.d/90-temp-installer

# -- Informe Final --
echo -e "\n\033[1;34m================================================================\033[0m"
echo -e "\033[1;32m   INFORME FINAL DE SISTEMA\033[0m"
echo -e "\033[1;34m================================================================\033[0m"
echo -e " CPU: $(lscpu | grep 'Model name' | cut -d ':' -f2 | xargs)"
echo -e " GPU: $(lspci | grep -i vga | cut -d ':' -f3 | xargs)"
echo -e " RAM: $(free -m | awk '/^Mem:/{print $2}') MB"
echo -e " Kernel Target: linux-cachyos"
echo -e " BTRFS y Snapper: Operativos y Snapshot Cero Creado"
echo -e " Secure Boot: $(sbctl status 2>/dev/null | grep "Secure Boot:" | awk '{print $3}' || echo "No Activo/No Detectado")"
echo -e "\033[1;32m ✔ INSTALACIÓN VALIDADA CORRECTAMENTE\033[0m"
echo -e "\033[1;34m================================================================\033[0m\n"

exit 0
CHROOT_EOF
chmod 700 /mnt/root/iceman_chroot.sh

# ------------------------------------------------------------------------------
# 8. EJECUCIÓN CHROOT Y LIMPIEZA
# ------------------------------------------------------------------------------
step "Transfiriendo control al núcleo aislado (Chroot)"
arch-chroot /mnt /root/iceman_chroot.sh || die "Excepción no controlada en entorno chroot. Instalación fallida."

step "Saneamiento Final"
rm -f /mnt/root/iceman_vars.sh /mnt/root/iceman_chroot.sh

umount -q /mnt/tmp 2>/dev/null || true
umount -q /mnt/var/cache/pacman/pkg 2>/dev/null || true
cp "$LOG_FILE" /mnt/var/log/iceman_install.log 2>/dev/null || true

umount -q -R /mnt
[ "$LUKS_OPT" -eq 1 ] && cryptsetup close cryptroot

echo -e "\n${C_GREEN}================================================================${C_NC}"
echo -e "${C_GREEN} ¡ICEMAN DEPLOY FINALIZADO CON ÉXITO!                           ${C_NC}"
echo -e "${C_GREEN}================================================================${C_NC}"
echo -e "  Escribe 'reboot' para salir del LiveUSB y arrancar tu nuevo sistema."
echo -e "  ${C_CYAN}💡 Tip:${C_NC} Una vez reiniciado, ejecuta ${C_YELLOW}systemd-analyze${C_NC} para ver tu benchmark de arranque.\n"
exit 0
