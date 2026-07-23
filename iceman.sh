#!/bin/bash
# ==============================================================================
# ICEMAN INSTALLER V3.1 — ENTERPRISE MASTER DEPLOYMENT
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

# Constantes Globales
readonly ICEMAN_VERSION="3.1-Enterprise"
readonly LOG_FILE="/var/log/iceman_install.log"
readonly JSON_LOG="/var/log/iceman_install.json"
readonly TIMEZONE="Europe/Madrid"
readonly LOCALE_NAME="es_ES.UTF-8"
readonly KEYMAP="es"

# Colores y UI (Centralizados)
readonly C_BLU="\033[1;34m"
readonly C_CYA="\033[1;36m"
readonly C_GRE="\033[1;32m"
readonly C_RED="\033[1;31m"
readonly C_YEL="\033[1;33m"
readonly C_NC="\033[0m"

# Variables de Estado (Estrictamente inicializadas)
INSTALL_SUCCESS=0
START_TIME=$SECONDS
STEP_COUNT=0
readonly TOTAL_STEPS=12
declare -A BLOCK_TIMES

HOSTNAME_DEF=""
USER_NAME=""
PASSWORD=""
DESKTOP=""
DISK=""
LUKS_OPT=0
LUKS_PASS=""
ROOT_UUID=""

CPU_VENDOR="UNKNOWN"
GPU_VENDOR="UNKNOWN"
IS_SSD=0
HAS_BLUETOOTH=0
VIRT_TYPE="none"
SECURE_BOOT_STATE="Disabled"
HAS_INTERNET_AUR=0

# ------------------------------------------------------------------------------
# 2. FUNCIONES BASE (UI, LOGS, RETRY, MOUNT)
# ------------------------------------------------------------------------------
log_info() { echo -e "  ${C_BLU}ℹ INFO:${C_NC} $1"; echo "[$(date '+%H:%M:%S')] [INFO] $*" >> "$LOG_FILE"; }
log_warn() { echo -e "  ${C_YEL}⚠ WARN:${C_NC} $1"; echo "[$(date '+%H:%M:%S')] [WARN] $*" >> "$LOG_FILE"; }
log_error() { echo -e "  ${C_RED}✘ ERROR:${C_NC} $1"; echo "[$(date '+%H:%M:%S')] [ERROR] $*" >> "$LOG_FILE"; }
log_success() { echo -e "  ${C_GRE}✔ OK:${C_NC} $1"; echo "[$(date '+%H:%M:%S')] [SUCCESS] $*" >> "$LOG_FILE"; }

die() { 
    echo -e "\n${C_RED}[FATAL ERROR] $1${C_NC}\n"
    log_error "FATAL: $1"
    exit 1
}

safe_mount() {
    mount "$@" || die "Fallo al montar: $*"
}

draw_progress() {
    local step=$1 total=$2 title=$3
    local pc=$(( (step * 100) / total ))
    local fil=$(( pc / 5 ))
    local emp=$(( 20 - fil ))
    local bar=$(printf "%${fil}s" | tr ' ' '█')
    local e_bar=$(printf "%${emp}s" | tr ' ' '░')
    
    echo -e "\n${C_BLU}====================================================${C_NC}"
    echo -e "${C_BLU}[${step}/${total}]${C_NC} [${C_CYA}${bar}${C_NC}${e_bar}] ${pc}%"
    echo -e "${C_CYA}➜ ${title}${C_NC}"
    echo -e "${C_BLU}====================================================${C_NC}"
    log_info "FASE: ${title}"
}

retry_cmd() {
    local cmd="$1" max=3 delay=2 n=1
    while true; do
        if eval "$cmd" >/dev/null 2>&1; then return 0; else
            if [[ $n -lt $max ]]; then ((n++)); sleep $delay
            else return 1; fi
        fi
    done
}

get_password() {
    local prm=$1 p1="" p2=""
    while true; do
        read -rsp "$prm: " p1 < /dev/tty; echo
        read -rsp "Confirmar $prm: " p2 < /dev/tty; echo
        if [ "$p1" == "$p2" ] && [ -n "$p1" ]; then echo "$p1"; break
        else echo -e "${C_YEL}⚠ No coinciden. Reintenta.${C_NC}" >&2; fi
    done
}

# ------------------------------------------------------------------------------
# 3. TRAP GLOBAL (LIMPIEZA SEGURA E IDEMPOTENTE)
# ------------------------------------------------------------------------------
cleanup() {
    local rc=$?
    if [ "$INSTALL_SUCCESS" -ne 1 ]; then
        echo -e "\n${C_RED}Abortando. Limpiando entorno...${C_NC}"
        umount -q /mnt/boot/efi 2>/dev/null || true
        umount -q /mnt/.snapshots 2>/dev/null || true
        umount -q /mnt/var/cache/pacman/pkg 2>/dev/null || true
        umount -q /mnt/var/log 2>/dev/null || true
        umount -q /mnt/home 2>/dev/null || true
        umount -q /mnt/tmp 2>/dev/null || true
        umount -q -R /mnt 2>/dev/null || true
        [ -e /dev/mapper/cryptroot ] && cryptsetup close cryptroot 2>/dev/null || true
    fi
    LUKS_PASS=""; PASSWORD=""
    rm -f /tmp/iceman* 2>/dev/null || true
    exit "$rc"
}
trap cleanup ERR INT TERM EXIT

# ------------------------------------------------------------------------------
# 4. FASE 5: INTERACCIÓN CON EL USUARIO
# ------------------------------------------------------------------------------
user_input() {
    ((STEP_COUNT++)); draw_progress $STEP_COUNT $TOTAL_STEPS "Datos del Sistema"
    
    echo -e "Entorno de escritorio:\n 1) GNOME\n 2) KDE Plasma\n 3) Mínimo (Sin GUI)"
    while true; do
        read -rp "Opción (1-3): " opt < /dev/tty
        case $opt in
            1) DESKTOP="GNOME"; break ;;
            2) DESKTOP="KDE"; break ;;
            3) DESKTOP="NONE"; break ;;
            *) echo "Inválido." ;;
        esac
    done

    read -rp "Hostname [Arch-Rig]: " h_in < /dev/tty
    HOSTNAME_DEF=${h_in:-Arch-Rig}
    
    while true; do
        read -rp "Usuario (minúsculas): " USER_NAME < /dev/tty
        [[ "$USER_NAME" =~ ^[a-z_][a-z0-9_-]*$ ]] && break
        echo "Formato inválido."
    done

    PASSWORD=$(get_password "Contraseña Root/User")

    lsblk -d -p -n -o NAME,SIZE,MODEL,TRAN | grep -v -E 'loop|sr0'
    while true; do
        read -rp "Disco (ej. /dev/nvme0n1): " DISK < /dev/tty
        [ -b "$DISK" ] && break || echo "Disco no encontrado."
    done

    read -rp "¿Cifrar con LUKS2? (s/N): " l_ans < /dev/tty
    if [[ "$l_ans" =~ ^[Ss]$ ]]; then
        LUKS_OPT=1
        LUKS_PASS=$(get_password "Contraseña LUKS2")
    fi
}

# ------------------------------------------------------------------------------
# 5. FASE 2: DETECCIÓN AUTOMÁTICA DE HARDWARE
# ------------------------------------------------------------------------------
detect_hardware() {
    ((STEP_COUNT++)); draw_progress $STEP_COUNT $TOTAL_STEPS "Auditoría de Hardware"
    
    [ -d /sys/firmware/efi/efivars ] || die "Falta UEFI."
    VIRT_TYPE=$(systemd-detect-virt 2>/dev/null || echo "none")
    
    grep -qi "vendor_id.*amd" /proc/cpuinfo && CPU_VENDOR="AMD"
    grep -qi "vendor_id.*intel" /proc/cpuinfo && CPU_VENDOR="INTEL"
    
    if lspci | grep -i vga | grep -qi "nvidia"; then GPU_VENDOR="NVIDIA";
    elif lspci | grep -i vga | grep -qi "amd\|radeon"; then GPU_VENDOR="AMD";
    elif lspci | grep -i vga | grep -qi "intel"; then GPU_VENDOR="INTEL"; fi
    
    local d_gran=$(cat "/sys/block/$(basename "$DISK")/queue/discard_granularity" 2>/dev/null || echo "0")
    [ "$d_gran" != "0" ] && IS_SSD=1 || IS_SSD=0
    
    lsusb | grep -qi "bluetooth" && HAS_BLUETOOTH=1 || HAS_BLUETOOTH=0
    
    curl -I -s --connect-timeout 4 "https://archlinux.org" >/dev/null || die "Sin Internet."
    curl -I -s --connect-timeout 4 "https://github.com" >/dev/null && HAS_INTERNET_AUR=1 || true

    log_success "$CPU_VENDOR | $GPU_VENDOR | SSD:$IS_SSD | VIRT:$VIRT_TYPE"
}

# ------------------------------------------------------------------------------
# 6. FASE 3: PACMAN Y REPOSITORIOS
# ------------------------------------------------------------------------------
configure_pacman() {
    local t0=$SECONDS
    ((STEP_COUNT++)); draw_progress $STEP_COUNT $TOTAL_STEPS "Afinando Pacman"

    sed -i -e '/^#Color/s/^#//' -e '/^#VerbosePkgLists/s/^#//' \
           -e '/^#ParallelDownloads/s/^#//' -e '/\[multilib\]/,/Include/s/^#//' /etc/pacman.conf
    grep -q "^ILoveCandy" /etc/pacman.conf || sed -i '/^Color/a ILoveCandy' /etc/pacman.conf
    sed -i "s/^#\?\s*ParallelDownloads\s*=.*/ParallelDownloads=10/" /etc/pacman.conf

    log_info "Reflector actualizando espejos..."
    retry_cmd "reflector --latest 10 --sort rate --save /etc/pacman.d/mirrorlist --protocol https"

    pacman-key --recv-keys F3B607488DB35A47 --keyserver keyserver.ubuntu.com >/dev/null 2>&1 || die "Fallo llave Cachy"
    pacman-key --lsign-key F3B607488DB35A47 >/dev/null 2>&1
    
    echo -e "[cachyos]\nServer = https://mirror.cachyos.org/repo/\$arch/\$repo" > /tmp/cachy_tmp.conf
    cat /tmp/cachy_tmp.conf >> /etc/pacman.conf
    pacman -Sy --noconfirm cachyos-keyring cachyos-mirrorlist >/dev/null 2>&1 || die "Fallo Keyring Cachy"
    
    sed -i '/\[cachyos\]/,+1d' /etc/pacman.conf
    echo -e "\n[cachyos]\nSigLevel = Required DatabaseOptional\nInclude = /etc/pacman.d/cachyos-mirrorlist" >> /etc/pacman.conf
    
    pacman -Syy >/dev/null 2>&1
    BLOCK_TIMES["Pacman"]=$((SECONDS - t0))
}

# ------------------------------------------------------------------------------
# 7. FASE 4 & 1: PARTICIONADO, LUKS Y BTRFS
# ------------------------------------------------------------------------------
prepare_disk() {
    local t0=$SECONDS
    ((STEP_COUNT++)); draw_progress $STEP_COUNT $TOTAL_STEPS "Discos y Criptografía"

    sgdisk -Z "$DISK" >/dev/null
    sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI" "$DISK" >/dev/null
    sgdisk -n 2:0:0 -t 2:8300 -c 2:"ROOT" "$DISK" >/dev/null
    udevadm settle; sleep 2

    local pfx=""; [[ "$DISK" =~ [0-9]$ ]] && pfx="p"
    local part_efi="${DISK}${pfx}1"; local part_root="${DISK}${pfx}2"

    mkfs.fat -F32 -n EFI "$part_efi" >/dev/null

    local mapper_dev="$part_root"
    if [ "$LUKS_OPT" -eq 1 ]; then
        log_info "Configurando LUKS2..."
        printf '%s' "$LUKS_PASS" | cryptsetup -q luksFormat --type luks2 "$part_root" -
        printf '%s' "$LUKS_PASS" | cryptsetup open "$part_root" cryptroot - || die "Fallo LUKS open."
        cryptsetup luksDump "$part_root" >/dev/null || die "Cabecera LUKS corrupta."
        mapper_dev="/dev/mapper/cryptroot"
        ROOT_UUID=$(blkid -s UUID -o value "$part_root")
    fi

    mkfs.btrfs -f -L ArchCachy "$mapper_dev" >/dev/null
    safe_mount "$mapper_dev" /mnt
    
    for sv in @ @home @log @pkg @snapshots; do btrfs subvolume create "/mnt/${sv}" >/dev/null; done
    umount /mnt

    local opts="noatime,compress=zstd:1,space_cache=v2"
    [ "$IS_SSD" -eq 1 ] && opts="${opts},discard=async"

    safe_mount -o "${opts},subvol=@" "$mapper_dev" /mnt
    mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,boot/efi,tmp}
    
    safe_mount -o "${opts},subvol=@home" "$mapper_dev" /mnt/home
    safe_mount -o "${opts},subvol=@log" "$mapper_dev" /mnt/var/log
    safe_mount -o "${opts},subvol=@pkg" "$mapper_dev" /mnt/var/cache/pacman/pkg
    safe_mount -o "${opts},subvol=@snapshots" "$mapper_dev" /mnt/.snapshots
    safe_mount "$part_efi" /mnt/boot/efi

    BLOCK_TIMES["Discos"]=$((SECONDS - t0))
}

# ------------------------------------------------------------------------------
# 8. FASE 2 & 3: PACSTRAP
# ------------------------------------------------------------------------------
install_base() {
    local t0=$SECONDS
    ((STEP_COUNT++)); draw_progress $STEP_COUNT $TOTAL_STEPS "Pacstrap"

    local pkgs=(base base-devel linux-cachyos linux-cachyos-headers linux-firmware 
                cachyos-keyring cachyos-hooks cachyos-settings btrfs-progs grub efibootmgr 
                networkmanager sudo git curl sbctl snapper snap-pac grub-btrfs btrfs-assistant)

    # Microcode estricto excluyente
    if [ "$CPU_VENDOR" == "AMD" ]; then pkgs+=(amd-ucode);
    elif [ "$CPU_VENDOR" == "INTEL" ]; then pkgs+=(intel-ucode); fi

    [ "$GPU_VENDOR" == "AMD" ] && pkgs+=(mesa xf86-video-amdgpu vulkan-radeon corectrl)
    [ "$GPU_VENDOR" == "INTEL" ] && pkgs+=(mesa intel-media-driver vulkan-intel)
    [ "$GPU_VENDOR" == "NVIDIA" ] && pkgs+=(nvidia-dkms nvidia-utils)

    [ "$HAS_BLUETOOTH" -eq 1 ] && pkgs+=(bluez bluez-utils)
    [ "$VIRT_TYPE" == "kvm" ] && pkgs+=(qemu-guest-agent)

    if [ "$DESKTOP" == "GNOME" ]; then pkgs+=(gnome gnome-tweaks gdm xdg-desktop-portal-gnome)
    elif [ "$DESKTOP" == "KDE" ]; then pkgs+=(plasma-meta dolphin sddm xdg-desktop-portal-kde); fi

    retry_cmd "pacstrap -K /mnt ${pkgs[*]}" || die "Pacstrap falló."
    genfstab -U /mnt | grep -v 'tmpfs' > /mnt/etc/fstab

    BLOCK_TIMES["Pacstrap"]=$((SECONDS - t0))
}

# ------------------------------------------------------------------------------
# 9. FASE 1 & 4: CONFIGURACIÓN CHROOT
# ------------------------------------------------------------------------------
configure_chroot() {
    local t0=$SECONDS
    ((STEP_COUNT++)); draw_progress $STEP_COUNT $TOTAL_STEPS "Chroot y Configuración"

    local dm_srv=""; [ "$DESKTOP" == "GNOME" ] && dm_srv="gdm"; [ "$DESKTOP" == "KDE" ] && dm_srv="sddm"

    cat > /mnt/tmp/vars.sh <<EOF
export TIMEZONE="${TIMEZONE}" LOCALE_NAME="${LOCALE_NAME}" KEYMAP="${KEYMAP}"
export HOSTNAME_DEF="${HOSTNAME_DEF}" USER_NAME="${USER_NAME}" PASSWORD="${PASSWORD}"
export LUKS_OPT=${LUKS_OPT} ROOT_UUID="${ROOT_UUID}" HAS_INTERNET_AUR=${HAS_INTERNET_AUR}
export IS_SSD=${IS_SSD} HAS_BLUETOOTH=${HAS_BLUETOOTH} VIRT_TYPE="${VIRT_TYPE}" DM_SERVICE="${dm_srv}"
EOF

    cat > /mnt/tmp/chroot.sh <<'EOF'
#!/bin/bash
set -Eeuo pipefail
source /tmp/vars.sh

ln -sf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime; hwclock --systohc
sed -i "s/^#\?\(${LOCALE_NAME}\)/\1/" /etc/locale.gen; locale-gen >/dev/null
echo "LANG=${LOCALE_NAME}" > /etc/locale.conf; echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
echo "${HOSTNAME_DEF}" > /etc/hostname

# Idempotencia usuario
id "${USER_NAME}" >/dev/null 2>&1 || useradd -m -G wheel,video,audio,storage,kvm -s /bin/bash "${USER_NAME}"
echo "root:${PASSWORD}" | chpasswd; echo "${USER_NAME}:${PASSWORD}" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /tmp/10-wheel
visudo -cf /tmp/10-wheel && install -m440 /tmp/10-wheel /etc/sudoers.d/10-wheel

# Hook encrypt (Busybox-based default)
HOOKS="base udev autodetect microcode modconf kms keyboard keymap consolefont block"
[ "${LUKS_OPT}" -eq 1 ] && HOOKS="${HOOKS} encrypt"
HOOKS="${HOOKS} filesystems fsck"
sed -i "s/^HOOKS=.*/HOOKS=(${HOOKS})/" /etc/mkinitcpio.conf
mkinitcpio -P >/dev/null || exit 1

sed -i 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=4/' /etc/default/grub
cmdline="quiet splash loglevel=3 rd.udev.log_priority=3"
if [ "${LUKS_OPT}" -eq 1 ]; then
    cmdline="${cmdline} cryptdevice=UUID=${ROOT_UUID}:cryptroot root=/dev/mapper/cryptroot"
    sed -i 's/^#GRUB_ENABLE_CRYPTODISK=y/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub
fi
sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=.*|GRUB_CMDLINE_LINUX_DEFAULT=\"${cmdline}\"|" /etc/default/grub
grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ArchCachy --recheck >/dev/null
grub-mkconfig -o /boot/grub/grub.cfg >/dev/null 2>&1

if sbctl status 2>/dev/null | grep -qi "Setup Mode:.*Enabled"; then
    sbctl create-keys >/dev/null && sbctl enroll-keys --microsoft >/dev/null
    for bin in /boot/vmlinuz-linux-cachyos /boot/efi/EFI/ArchCachy/grubx64.efi; do
        [ -f "$bin" ] && sbctl sign -s "$bin" >/dev/null
    done
fi

# Snapper Limpio (Sin umounts)
cp /etc/snapper/config-templates/default /etc/snapper/configs/root
sed -i 's/^SNAPPER_CONFIGS=.*/SNAPPER_CONFIGS="root"/' /etc/conf.d/snapper
sed -i -e 's/^TIMELINE_MIN_AGE=.*/TIMELINE_MIN_AGE="1800"/' \
       -e 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/' \
       -e 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="7"/' /etc/snapper/configs/root

systemctl enable NetworkManager grub-btrfsd snapper-cleanup.timer snapper-timeline.timer >/dev/null 2>&1
[ -n "${DM_SERVICE}" ] && systemctl enable "${DM_SERVICE}" >/dev/null 2>&1
[ "${IS_SSD}" -eq 1 ] && systemctl enable fstrim.timer >/dev/null 2>&1
[ "${HAS_BLUETOOTH}" -eq 1 ] && systemctl enable bluetooth >/dev/null 2>&1
[ "${VIRT_TYPE}" == "kvm" ] && systemctl enable qemu-guest-agent >/dev/null 2>&1
EOF

    arch-chroot /mnt bash /tmp/chroot.sh || die "Fallo en Chroot."
    BLOCK_TIMES["Chroot"]=$((SECONDS - t0))
}

# ------------------------------------------------------------------------------
# 10. FASE 6: VALIDACIÓN ESTRICTA
# ------------------------------------------------------------------------------
validate_install() {
    ((STEP_COUNT++)); draw_progress $STEP_COUNT $TOTAL_STEPS "Validación"
    local c="/mnt" err=0
    
    check() { [ -s "$1" ] || { log_error "Fallo validación: $2"; err=1; }; }
    
    check "$c/boot/vmlinuz-linux-cachyos" "Kernel"
    check "$c/boot/efi/EFI/ArchCachy/grubx64.efi" "GRUB EFI"
    check "$c/etc/fstab" "fstab vacío"
    
    [ -x "$c/usr/bin/bash" ] || { log_error "Bash roto"; err=1; }
    arch-chroot $c lsinitcpio /boot/initramfs-linux-cachyos.img >/dev/null 2>&1 || { log_error "Initramfs corrupto"; err=1; }
    grep -q "menuentry" $c/boot/grub/grub.cfg || { log_error "GRUB cfg sin entradas"; err=1; }
    
    if [ "$LUKS_OPT" -eq 1 ]; then
        [ -e /dev/mapper/cryptroot ] || { log_error "Mapper LUKS caído"; err=1; }
        grep -q "cryptdevice" $c/etc/default/grub || { log_error "GRUB sin LUKS config"; err=1; }
    fi

    arch-chroot $c sbctl status 2>/dev/null | grep -qi "Setup Mode:.*Enabled" && SECURE_BOOT_STATE="Enrolled"
    [ $err -eq 0 ] || die "El sistema no pasó la validación de integridad."
}

# ------------------------------------------------------------------------------
# 11. FASE 7: REPORTES Y LIMPIEZA
# ------------------------------------------------------------------------------
generate_report() {
    ((STEP_COUNT++)); draw_progress $STEP_COUNT $TOTAL_STEPS "Finalizando"
    
    cat > "/mnt$JSON_LOG" <<EOF
{
    "version": "${ICEMAN_VERSION}", "time_seconds": $((SECONDS - START_TIME)),
    "hardware": { "cpu": "${CPU_VENDOR}", "gpu": "${GPU_VENDOR}", "is_ssd": $([ "$IS_SSD" -eq 1 ] && echo true || echo false) },
    "config": { "desktop": "${DESKTOP}", "luks_enabled": $([ "$LUKS_OPT" -eq 1 ] && echo true || echo false) }
}
EOF
    cp "$LOG_FILE" /mnt/var/log/iceman_install.log 2>/dev/null || true
    PASSWORD=""; LUKS_PASS=""; rm -f /mnt/tmp/vars.sh /mnt/tmp/chroot.sh 2>/dev/null || true
    INSTALL_SUCCESS=1
}

main() {
    clear; echo -e "${C_BLU}== ICEMAN INSTALLER V3.1 ENTERPRISE ==${C_NC}"
    user_input; detect_hardware; configure_pacman
    prepare_disk; install_base; configure_chroot
    validate_install; generate_report

    echo -e "\n${C_GRE}✔ INSTALACIÓN COMPLETADA${C_NC}\n Tiempos por Bloque:"
    for k in "${!BLOCK_TIMES[@]}"; do printf "  - %-10s : %02dm %02ds\n" "$k" $((BLOCK_TIMES[$k]%3600/60)) $((BLOCK_TIMES[$k]%60)); done
    printf "  - %-10s : %02dm %02ds\n\n" "TOTAL" $(((SECONDS-START_TIME)%3600/60)) $(((SECONDS-START_TIME)%60))
}
main "$@"
