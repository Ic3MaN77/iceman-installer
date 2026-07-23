#!/bin/bash
# ==============================================================================
# ICEMAN INSTALLER — Arch Linux + Kernel CachyOS (Modo 100% Desatendido)
# Adaptativo: Bare Metal / VM (QEMU, VirtualBox, VMware)
# Optimización Dinámica: RAM (tmpfs) escalable según capacidad real detectada.
# ==============================================================================

set -uo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------------------
# 0. VARIABLES Y ENTORNO NO INTERACTIVO
# ------------------------------------------------------------------------------
LOG_FILE="/var/log/iceman_install.log"
: > "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/iceman_install.log"; : > "$LOG_FILE"

C_BLUE="\033[1;34m"; C_CYAN="\033[1;36m"; C_GREEN="\033[1;32m"
C_RED="\033[1;31m";  C_YELLOW="\033[1;33m"; C_NC="\033[0m"

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
die() {
    echo -e "\n${C_RED}✘ FALLO CRÍTICO:${C_NC} ${1}" >&2
    tail -n 15 "$LOG_FILE" >&2 2>/dev/null
    echo -e "${C_RED}Instalación abortada.${C_NC}" >&2
    cleanup_on_exit
    exit 1
}

run_spin() {
    local desc="$1"; shift
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
        die "$desc (Comando: $*)"
    fi
}

run_visible() {
    local desc="$1"; shift
    echo -e "  ${C_CYAN}▶ ${desc}...${C_NC}"
    "$@" 2>&1 | tee -a "$LOG_FILE" || die "$desc"
    msg_ok "$desc completado."
}

cleanup_on_exit() {
    umount -q /mnt/tmp 2>/dev/null || true
    umount -q /mnt/var/cache/pacman/pkg 2>/dev/null || true
    umount -q -R /mnt 2>/dev/null || true
    [ -e /dev/mapper/cryptroot ] && cryptsetup close cryptroot 2>/dev/null || true
    rm -rf "$WORK_DIR" 2>/dev/null || true
}
trap cleanup_on_exit EXIT

clear
echo -e "${C_BLUE}================================================================${C_NC}"
echo -e "${C_BLUE}       ICEMAN INSTALLER — ARCH LINUX + CACHYOS (ADAPTATIVO)     ${C_NC}"
echo -e "${C_BLUE}================================================================${C_NC}"

# ------------------------------------------------------------------------------
# FASE 0: VALIDACIONES DEL ENTORNO
# ------------------------------------------------------------------------------
step "Auditoría de Entorno (Pre-vuelo)"
[ "$EUID" -eq 0 ] || die "Este script exige privilegios de root."
[ -d /sys/firmware/efi/efivars ] || die "Requiere arranque en modo UEFI nativo."
ping -c 2 -W 3 archlinux.org >/dev/null 2>&1 || die "Sin conexión a Internet."

# Detección de Virtualización vs Metal
VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || echo none)"
if [ "$VIRT_TYPE" != "none" ]; then
    IS_VM=1
    msg_warn "Entorno Virtual detectado ($VIRT_TYPE). Se instalarán Guest Tools y se omitirán drivers GPU pesados."
else
    IS_VM=0
    msg_ok "Entorno Bare Metal detectado."
fi

# Análisis dinámico de RAM para tmpfs seguro
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
if [ "$TOTAL_RAM_MB" -ge 30000 ]; then
    TMP_SIZE="16G"; PKG_SIZE="8G"
elif [ "$TOTAL_RAM_MB" -ge 15000 ]; then
    TMP_SIZE="8G"; PKG_SIZE="4G"
elif [ "$TOTAL_RAM_MB" -ge 7000 ]; then
    TMP_SIZE="3G"; PKG_SIZE="2G"
else
    die "ICEMAN requiere mínimo 8GB de RAM (física o asignada a la VM). Detectado: ${TOTAL_RAM_MB}MB."
fi
msg_ok "Memoria disponible: ${TOTAL_RAM_MB}MB. Aceleración configurada en: TMP=${TMP_SIZE}, PKG=${PKG_SIZE}."

# ------------------------------------------------------------------------------
# FASE 1: RECOPILACIÓN DE DATOS (Única intervención)
# ------------------------------------------------------------------------------
step "Configuración Estratégica"
lsblk -d -p -n -o NAME,SIZE,MODEL,TRAN | grep -v -E 'loop|sr0'
read -rp "$(echo -e ${C_CYAN}'Ruta exacta del disco destino (ej. /dev/sda o /dev/nvme0n1): '${C_NC})" DISK < /dev/tty
[ -b "$DISK" ] || die "El dispositivo ‘$DISK’ no existe."

# Validación del tamaño mínimo del disco (Ecosistema Gaming + Base)
DISK_SIZE_BYTES=$(blockdev --getsize64 "$DISK" 2>/dev/null || echo 0)
DISK_SIZE_GB=$((DISK_SIZE_BYTES / 1024 / 1024 / 1024))
if [ "$DISK_SIZE_GB" -lt 35 ]; then
    die "El disco $DISK es demasiado pequeño (${DISK_SIZE_GB}GB). Se recomiendan mínimo 40GB para el ecosistema completo."
fi

echo -e "${C_RED}\n¡ADVERTENCIA! Vas a BORRAR POR COMPLETO el disco ${DISK}${C_NC}"
read -rp "$(echo -e ${C_RED}'Escribe "BORRAR" en mayúsculas para confirmar: '${C_NC})" CONFIRM < /dev/tty
[ "$CONFIRM" = "BORRAR" ] || die "Abortado por el usuario."

read -rp "Nombre de usuario [Iceman]: " USER_NAME < /dev/tty; USER_NAME="${USER_NAME:-Iceman}"
read -rp "Nombre del equipo [Arch-Gaming-Rig]: " HOSTNAME_DEF < /dev/tty; HOSTNAME_DEF="${HOSTNAME_DEF:-Arch-Gaming-Rig}"

while true; do
    read -rsp "Contraseña principal (Usuario y Root): " PASSWORD < /dev/tty; echo
    read -rsp "Repite la contraseña: " PASSWORD2 < /dev/tty; echo
    [ -n "$PASSWORD" ] && [ "$PASSWORD" = "$PASSWORD2" ] && break
    msg_warn "Las contraseñas no coinciden. Inténtalo de nuevo."
done

LUKS_OPT=0
read -rp "¿Cifrar partición raíz con LUKS2? (s/N): " LUKS_ANS < /dev/tty
if [[ "$LUKS_ANS" =~ ^[Ss]$ ]]; then
    LUKS_OPT=1
    while true; do
        read -rsp "Contraseña LUKS: " LUKS_PASS < /dev/tty; echo
        read -rsp "Repite contraseña LUKS: " LUKS_PASS2 < /dev/tty; echo
        [ -n "$LUKS_PASS" ] && [ "$LUKS_PASS" = "$LUKS_PASS2" ] && break
        msg_warn "Las contraseñas LUKS no coinciden."
    done
fi

echo -e "\n${C_GREEN}✔ Configuración fijada. Iniciando automatización pura...${C_NC}\n"; sleep 2

# ------------------------------------------------------------------------------
# FASE 2: PREPARACIÓN DE HARDWARE
# ------------------------------------------------------------------------------
step "Identificación de Hardware Interno"
run_spin "Sincronizando reloj (NTP)" timedatectl set-ntp true
CPU_VENDOR="$(grep -m1 -oP 'vendor_id\s*:\s*\K.*' /proc/cpuinfo)"
[[ "$CPU_VENDOR" == *"AMD"* ]] && MICROCODE_PKG="amd-ucode" || MICROCODE_PKG="intel-ucode"

GPU_VENDOR="generic"
if [ "$IS_VM" -eq 0 ]; then
    GPU_INFO="$(lspci -nn 2>/dev/null | grep -Ei 'vga|3d|display' || true)"
    [[ "$GPU_INFO" =~ (amd|ati) ]] && GPU_VENDOR="amd"
    [[ "$GPU_INFO" =~ nvidia ]] && GPU_VENDOR="nvidia"
fi

DISK_BASE="$(basename "$DISK")"
ROTA=$(cat "/sys/block/${DISK_BASE}/queue/rotational" 2>/dev/null || echo 1)
[ "$ROTA" = "0" ] && IS_SSD=1 || IS_SSD=0

# ------------------------------------------------------------------------------
# FASE 3: PROTECCIÓN CONTRA OVERFLOW DEL ENTORNO LIVE E INYECCIÓN DE REPOSITORIOS
# ------------------------------------------------------------------------------
step "Inyección Segura de Repositorios CachyOS"
# Expande el espacio raíz del USB Live dinámicamente para evitar el error "Partition / too full"
mount -o remount,size=75% /run/archiso/cowspace 2>/dev/null || true

sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 15/' /etc/pacman.conf
sed -i '/^#\[multilib\]/,/^#Include/{s/^#//}' /etc/pacman.conf
run_spin "Actualizando pacman base" pacman -Sy --noconfirm

cd "$WORK_DIR"
run_spin "Descargando ecosistema CachyOS" curl -sSL "https://mirror.cachyos.org/cachyos-repo.tar.xz" -o cachyos-repo.tar.xz
mkdir cachyos-repo && tar -xf cachyos-repo.tar.xz -C cachyos-repo --strip-components=1
cd cachyos-repo
run_spin "Inyectando repositorios CachyOS" bash -c "yes | ./cachyos-repo.sh --install"

# PURGA CRÍTICA: Eliminar la caché descargada de CachyOS en el entorno Live para liberar RAM.
run_spin "Purgando memoria volátil (Evita colapso de RAM)" pacman -Scc --noconfirm
run_spin "Sincronizando llaves finales" pacman -Syy --noconfirm

# ------------------------------------------------------------------------------
# FASE 4: ARQUITECTURA DE DISCO (BTRFS)
# ------------------------------------------------------------------------------
step "Geometría y Particionado de $DISK"
umount -q -R /mnt 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true

run_spin "Generando mapa GPT y particiones" bash -c "sgdisk -Z \"$DISK\" && sgdisk -n 1:0:+1G -t 1:ef00 -c 1:\"EFI\" \"$DISK\" && sgdisk -n 2:0:0 -t 2:8300 -c 2:\"ROOT\" \"$DISK\""
partprobe "$DISK" >/dev/null 2>&1 || true; sleep 2

[[ "$DISK" == *"nvme"* || "$DISK" == *"mmcblk"* ]] && PART_EFI="${DISK}p1" || PART_EFI="${DISK}1"
[[ "$DISK" == *"nvme"* || "$DISK" == *"mmcblk"* ]] && PART_ROOT="${DISK}p2" || PART_ROOT="${DISK}2"

run_spin "Dando formato EFI (FAT32)" mkfs.fat -F32 -n EFI "$PART_EFI"

if [ "$LUKS_OPT" -eq 1 ]; then
    run_spin "Aplicando LUKS2 (Cifrado)" bash -c "printf '%s' \"$LUKS_PASS\" | cryptsetup -q luksFormat --type luks2 \"$PART_ROOT\" -"
    run_spin "Apertura de Volumen LUKS" bash -c "printf '%s' \"$LUKS_PASS\" | cryptsetup open \"$PART_ROOT\" cryptroot -"
    MAPPER_ROOT="/dev/mapper/cryptroot"
    ROOT_UUID="$(blkid -s UUID -o value "$PART_ROOT")"
else
    MAPPER_ROOT="$PART_ROOT"
    ROOT_UUID=""
fi

run_spin "Creando BTRFS Raíz" mkfs.btrfs -f -L ArchCachy "$MAPPER_ROOT"
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
# FASE 5: DESPLIEGUE DEL SISTEMA BASE Y ACELERADORES RAM
# ------------------------------------------------------------------------------
step "Montaje en RAM dinámico y Despliegue Pacstrap"
mount -t tmpfs -o size=${TMP_SIZE},mode=1777 tmpfs /mnt/tmp
mount -t tmpfs -o size=${PKG_SIZE} tmpfs /mnt/var/cache/pacman/pkg

BASE_PKGS=(
    base base-devel linux-cachyos linux-cachyos-headers linux-cachyos-lts
    linux-firmware ${MICROCODE_PKG} cachyos-keyring cachyos-hooks cachyos-settings
    btrfs-progs grub grub-btrfs efibootmgr networkmanager nano vim git curl rsync
    zram-generator sbctl plymouth ntfs-3g xdg-user-dirs
)
run_visible "Inyectando Base System y Kernel" pacstrap -K /mnt "${BASE_PKGS[@]}" --noconfirm

run_spin "Fijando estructura (FSTAB)" genfstab -U /mnt >> /mnt/etc/fstab
[ "$LUKS_OPT" -eq 1 ] && echo "# Cryptdevice UUID=$ROOT_UUID reserved for GRUB" >> /mnt/etc/fstab
cp /etc/pacman.conf /mnt/etc/pacman.conf
cp -a /etc/pacman.d/cachyos*-mirrorlist /mnt/etc/pacman.d/ 2>/dev/null || true

# ------------------------------------------------------------------------------
# FASE 6: INYECCIÓN DEL SCRIPT CHROOT
# ------------------------------------------------------------------------------
step "Preparando Controlador Interno"
install -d -m 700 /mnt/root
cat > /mnt/root/iceman_vars.sh <<VARS_EOF
USER_NAME="${USER_NAME}"
HOSTNAME_DEF="${HOSTNAME_DEF}"
PASSWORD="${PASSWORD}"
TIMEZONE="${TIMEZONE}"
LOCALE_NAME="${LOCALE_NAME}"
KEYMAP="${KEYMAP}"
IS_VM=${IS_VM}
VIRT_TYPE="${VIRT_TYPE}"
GPU_VENDOR="${GPU_VENDOR}"
LUKS_OPT=${LUKS_OPT}
ROOT_UUID="${ROOT_UUID}"
VARS_EOF

cat > /mnt/root/iceman_chroot.sh <<'CHROOT_EOF'
#!/bin/bash
set -uo pipefail
source /root/iceman_vars.sh
LOG=/root/iceman_chroot.log; : > "$LOG"
C_CYAN="\033[1;36m"; C_GREEN="\033[1;32m"; C_RED="\033[1;31m"; C_NC="\033[0m"

run_spin() {
    local desc="$1"; shift
    ( "$@" ) >> "$LOG" 2>&1 &
    local pid=$!
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'; local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r  ${C_CYAN}%s${C_NC} %s \033[K" "${spin:i++%${#spin}:1}" "$desc"; sleep 0.15
    done
    wait "$pid"; local rc=$?
    [ "$rc" -eq 0 ] && printf "\r  ${C_GREEN}✔${C_NC} %s\033[K\n" "$desc" || { printf "\r  ${C_RED}✘${C_NC} %s\033[K\n" "$desc"; exit 1; }
}
run_visible() { echo -e "  ${C_CYAN}▶ ${1}...${C_NC}"; shift; "$@" 2>&1 | tee -a "$LOG" || exit 1; }

echo -e "${C_CYAN}==> Regionalización${C_NC}"
ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime && hwclock --systohc
echo "${LOCALE_NAME} UTF-8" > /etc/locale.gen && locale-gen >> "$LOG" 2>&1
echo "LANG=${LOCALE_NAME}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
echo "${HOSTNAME_DEF}" > /etc/hostname

echo -e "${C_CYAN}==> Estructura de Usuarios${C_NC}"
echo "root:${PASSWORD}" | chpasswd
useradd -m -G wheel,input,video,audio,storage,optical -s /bin/bash "${USER_NAME}"
echo "${USER_NAME}:${PASSWORD}" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
su - "${USER_NAME}" -c 'xdg-user-dirs-update' >> "$LOG" 2>&1 || true

echo -e "${C_CYAN}==> Optimización ZRAM / Compilación${C_NC}"
sed -i 's/^MAKEFLAGS=.*/MAKEFLAGS="-j$(nproc)"/' /etc/makepkg.conf
echo "BUILDDIR=/tmp/makepkg" >> /etc/makepkg.conf
cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
EOF

echo -e "${C_CYAN}==> Drivers Gráficos y Pila Multimedia${C_NC}"
COMMON_MEDIA=(gst-plugins-good gst-plugins-bad gst-plugins-ugly ffmpeg x264 x265)
if [ "$IS_VM" -eq 0 ]; then
    if [ "$GPU_VENDOR" = "amd" ]; then
        run_visible "Drivers AMD Nativo" pacman -S --noconfirm --needed mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon corectrl "${COMMON_MEDIA[@]}"
    else
        run_visible "Drivers Genéricos" pacman -S --noconfirm --needed mesa lib32-mesa "${COMMON_MEDIA[@]}"
    fi
else
    # Módulo de adaptación dinámica a Entornos Virtuales
    run_visible "Controladores base VM" pacman -S --noconfirm --needed mesa "${COMMON_MEDIA[@]}"
    if [[ "$VIRT_TYPE" == *"kvm"* ]] || [[ "$VIRT_TYPE" == *"qemu"* ]]; then
        run_spin "Guest Agent QEMU" pacman -S --noconfirm qemu-guest-agent spice-vdagent
        systemctl enable qemu-guest-agent
    elif [[ "$VIRT_TYPE" == *"oracle"* ]]; then
        run_spin "Guest Utils VirtualBox" pacman -S --noconfirm virtualbox-guest-utils
        systemctl enable vboxservice
    elif [[ "$VIRT_TYPE" == *"vmware"* ]]; then
        run_spin "Open VM Tools VMware" pacman -S --noconfirm open-vm-tools
        systemctl enable vmtoolsd
    fi
fi

run_visible "Instalando Entorno Gráfico (GNOME)" pacman -S --noconfirm --needed gnome gnome-tweaks gdm xdg-desktop-portal-gnome bluez bluez-utils ufw
systemctl enable NetworkManager gdm fstrim.timer bluetooth ufw >> "$LOG" 2>&1

echo -e "${C_CYAN}==> Kernel e Initramfs${C_NC}"
[ "${LUKS_OPT}" -eq 1 ] && HOOKS="base udev autodetect microcode modconf kms keyboard keymap consolefont block plymouth encrypt btrfs filesystems fsck" || HOOKS="base udev autodetect microcode modconf kms keyboard keymap consolefont block plymouth btrfs filesystems fsck"
sed -i "s|^HOOKS=(.*|HOOKS=(${HOOKS})|" /etc/mkinitcpio.conf
run_visible "Generando Initramfs" mkinitcpio -P

echo -e "${C_CYAN}==> Bootloader (GRUB)${C_NC}"
sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=4/' /etc/default/grub
sed -i 's/^#\?GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
if [ "${LUKS_OPT}" -eq 1 ]; then
    sed -i "s|^GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX=\"cryptdevice=UUID=${ROOT_UUID}:cryptroot root=/dev/mapper/cryptroot\"|" /etc/default/grub
    echo "GRUB_ENABLE_CRYPTODISK=y" >> /etc/default/grub
fi
run_spin "Instalando GRUB" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ArchCachy --recheck
run_spin "Configurando GRUB" grub-mkconfig -o /boot/grub/grub.cfg

echo -e "${C_CYAN}==> Ecosistema Gaming y Herramientas${C_NC}"
run_visible "Instalando dependencias pesadas" pacman -S --noconfirm --needed firefox qbittorrent steam lutris mangohud wine-staging flatpak
run_spin "Activando Flatpak" flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo

echo -e "${C_CYAN}==> Repositorio AUR (YAY)${C_NC}"
su - "${USER_NAME}" -c 'git clone --depth 1 https://aur.archlinux.org/yay-bin.git /tmp/yay-bin && cd /tmp/yay-bin && makepkg -si --noconfirm' >> "$LOG" 2>&1 || true
if su - "${USER_NAME}" -c 'command -v yay' >/dev/null 2>&1; then
    run_visible "Compilando AUR de forma segura" su - "${USER_NAME}" -c 'yay -S --noconfirm --needed --answerclean All --answerdiff None --answeredit None protonup-qt game-devices-udev'
fi

run_spin "Limpieza final de chroot" pacman -Scc --noconfirm
exit 0
CHROOT_EOF
chmod 700 /mnt/root/iceman_chroot.sh

# ------------------------------------------------------------------------------
# FASE 7: EJECUCIÓN AUTÓNOMA DEL ENTORNO CHROOT Y FINALIZACIÓN
# ------------------------------------------------------------------------------
step "Iniciando despliegue de software mediante Chroot"
arch-chroot /mnt /root/iceman_chroot.sh || die "Fallo crítico al ejecutar secuencias de chroot. Revisa los logs internos."

step "Saneamiento y desmontaje"
rm -f /mnt/root/iceman_vars.sh /mnt/root/iceman_chroot.sh
cp "$LOG_FILE" /mnt/var/log/iceman_install.log 2>/dev/null || true

umount -q /mnt/tmp 2>/dev/null || true
umount -q /mnt/var/cache/pacman/pkg 2>/dev/null || true
umount -q -R /mnt
[ "$LUKS_OPT" -eq 1 ] && cryptsetup close cryptroot

echo -e "\n${C_GREEN}================================================================${C_NC}"
echo -e "${C_GREEN} ¡ICEMAN DESPLEGADO CON ÉXITO!                                  ${C_NC}"
echo -e "${C_GREEN}================================================================${C_NC}"
echo -e "  Usuario principal: ${USER_NAME} | Equipo: ${HOSTNAME_DEF}"
echo -e "\n  Escribe 'reboot' para salir del entorno Live.\n"
exit 0
