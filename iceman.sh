#!/bin/bash
# ==============================================================================
# ICEMAN INSTALLER V7 — Arch Linux + Kernel CachyOS
# Adaptativo: Bare Metal / VM (QEMU, VirtualBox, VMware) — Objetivo: Gaming/Uso diario
# Idioma del sistema resultante: es_ES.UTF-8 · Zona horaria: Europe/Madrid
# ==============================================================================
# LANZAMIENTO (elige una opción, ejecutar como root en el ISO live de Arch):
#
#   Opción A (recomendada — descarga y revisa antes de ejecutar):
#     curl -fsSL https://raw.githubusercontent.com/Ic3MaN77/iceman-installer/refs/heads/main/iceman.sh -o iceman.sh
#     less iceman.sh          # opcional: revisar el contenido
#     bash iceman.sh
#
#   Opción B (una sola línea, con sustitución de proceso — el stdin del script
#             sigue siendo tu terminal, así que los prompts interactivos funcionan):
#     bash <(curl -fsSL https://raw.githubusercontent.com/Ic3MaN77/iceman-installer/refs/heads/main/iceman.sh)
#
#   Evita "curl ... | bash" a secas: con una tubería normal el stdin del script
#   pasa a ser la propia tubería, no tu teclado, y los `read` podrían fallar.
#   Este script ya usa `< /dev/tty` como salvaguarda por si aun así lo lanzas así.
# ==============================================================================

set -uo pipefail
IFS=$'\n\t'

# ------------------------------------------------------------------------------
# 0. VARIABLES GLOBALES
# ------------------------------------------------------------------------------
SCRIPT_VERSION="7.0"
LOG_FILE="/var/log/iceman_install.log"
: > "$LOG_FILE" 2>/dev/null || LOG_FILE="/tmp/iceman_install.log"; : > "$LOG_FILE"

C_BLUE="\033[1;34m"; C_CYAN="\033[1;36m"; C_GREEN="\033[1;32m"
C_RED="\033[1;31m";  C_YELLOW="\033[1;33m"; C_MAGENTA="\033[1;35m"; C_NC="\033[0m"

TIMEZONE="Europe/Madrid"
LOCALE_NAME="es_ES.UTF-8"
KEYMAP="es"
XKB_LAYOUT="es"
PARALLEL_DL=15

WORK_DIR="$(mktemp -d /tmp/iceman.XXXXXX)"
STEP_COUNT=0
TOTAL_STEPS=15  # incluye el paso condicional de LUKS (solo aparece si se activa el cifrado)

# ------------------------------------------------------------------------------
# 1. UTILIDADES DE SALIDA / LOG / ERRORES / PROGRESO VISUAL
# ------------------------------------------------------------------------------
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

# run_spin: comandos "opacos" (mkfs, sgdisk, sed, useradd...). Spinner + tiempo + última línea del log.
run_spin() {
    local desc="$1"; shift
    log "CMD(spin): $*"
    ( "$@" ) >> "$LOG_FILE" 2>&1 &
    local pid=$!
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0 start=$SECONDS last=""
    while kill -0 "$pid" 2>/dev/null; do
        last="$(tail -n 1 "$LOG_FILE" 2>/dev/null | cut -c1-55)"
        printf "\r  ${C_CYAN}%s${C_NC} %s ${C_YELLOW}(%ds)${C_NC} %s\033[K" \
            "${spin:i++%${#spin}:1}" "$desc" "$((SECONDS-start))" "$last"
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
# run_spin_soft: como run_spin pero NO aborta si falla (optimizaciones opcionales, ej. reflector).
run_spin_soft() {
    local desc="$1"; shift
    log "CMD(spin-soft): $*"
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
        printf "\r  ${C_GREEN}✔${C_NC} %s\033[K\n" "$desc"
    else
        printf "\r  ${C_YELLOW}⚠${C_NC} %s (opcional, se continúa)\033[K\n" "$desc"
    fi
}
# run_visible: comandos con progreso nativo útil (pacman, pacstrap, curl, git, yay, mkinitcpio).
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
    umount -q /mnt/tmp 2>/dev/null || true
    umount -R /mnt 2>/dev/null || true
    [ -e /dev/mapper/cryptroot ] && cryptsetup close cryptroot 2>/dev/null || true
    rm -rf "$WORK_DIR" 2>/dev/null || true
}
trap cleanup_on_exit EXIT

clear
echo -e "${C_BLUE}================================================================${C_NC}"
echo -e "${C_BLUE}   ICEMAN INSTALLER v${SCRIPT_VERSION} — Arch Linux + CachyOS Kernel   ${C_NC}"
echo -e "${C_BLUE}================================================================${C_NC}"
echo "Log completo en: $LOG_FILE"
log "Iniciando Iceman Installer v${SCRIPT_VERSION}"

# ------------------------------------------------------------------------------
# 2. PRE-VUELO
# ------------------------------------------------------------------------------
step "Comprobaciones previas del entorno"
[ "$EUID" -eq 0 ] || die "Este script debe ejecutarse como root (en el live ISO ya lo eres)."
[ -d /sys/firmware/efi/efivars ] || die "No se ha arrancado en modo UEFI. Este script requiere UEFI."
command -v curl >/dev/null || die "curl no está disponible en el entorno live."
command -v pacstrap >/dev/null || die "Esto no parece la ISO de Arch Linux (falta pacstrap)."
ping -c 2 -W 3 archlinux.org >/dev/null 2>&1 || die "Sin conexión a Internet. Conéctate (iwctl / nmcli / cable) y reinténtalo."
msg_ok "UEFI y conexión a Internet verificados."
run_spin "Sincronizando reloj (NTP)" timedatectl set-ntp true

step "Detección de hardware (Metal / VM) y memoria disponible"
VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || echo none)"
if [ "$VIRT_TYPE" = "none" ]; then
    IS_VM=0; msg_ok "Hardware físico (Metal) detectado."
else
    IS_VM=1; msg_warn "Entorno virtualizado detectado: ${VIRT_TYPE}. Se instalarán guest-tools y se omitirán drivers de GPU física."
fi

CPU_VENDOR="$(grep -m1 -oP 'vendor_id\s*:\s*\K.*' /proc/cpuinfo)"
case "$CPU_VENDOR" in
    *AMD*)   MICROCODE_PKG="amd-ucode" ;;
    *Intel*) MICROCODE_PKG="intel-ucode" ;;
    *)       MICROCODE_PKG="amd-ucode intel-ucode"; msg_warn "CPU no identificada, se instalan ambos microcodes." ;;
esac
msg_ok "Microcódigo: ${MICROCODE_PKG}"

GPU_VENDOR="generic"
if [ "$IS_VM" -eq 0 ]; then
    GPU_INFO="$(lspci -nn 2>/dev/null | grep -Ei 'vga|3d|display' || true)"
    if echo "$GPU_INFO" | grep -qi 'amd\|ati\|radeon'; then
        GPU_VENDOR="amd"; msg_ok "GPU AMD/Radeon detectada."
    elif echo "$GPU_INFO" | grep -qi 'nvidia'; then
        GPU_VENDOR="nvidia"; msg_warn "GPU NVIDIA detectada (mesa genérica; sin drivers propietarios)."
    fi
    log "GPU detectada: $GPU_INFO"
fi

# RAM: se usa para dimensionar (de forma segura y con degradación gradual) un tmpfs
# donde compilar paquetes AUR — NUNCA para la caché de paquetes de pacman, que debe
# quedar en disco real (subvolumen @pkg) para persistir entre reinicios.
TOTAL_RAM_MB=$(free -m | awk '/^Mem:/{print $2}')
if   [ "$TOTAL_RAM_MB" -ge 24000 ]; then BUILD_TMPFS_MB=16384; USE_TMPFS_BUILD=1
elif [ "$TOTAL_RAM_MB" -ge 12000 ]; then BUILD_TMPFS_MB=8192;  USE_TMPFS_BUILD=1
elif [ "$TOTAL_RAM_MB" -ge 6000 ];  then BUILD_TMPFS_MB=3072;  USE_TMPFS_BUILD=1
else BUILD_TMPFS_MB=0; USE_TMPFS_BUILD=0
fi
if [ "$USE_TMPFS_BUILD" -eq 1 ]; then
    msg_ok "RAM detectada: ${TOTAL_RAM_MB}MB → compilación AUR se hará en RAM (tmpfs ${BUILD_TMPFS_MB}MB)."
else
    msg_warn "RAM detectada: ${TOTAL_RAM_MB}MB (< 6GB) → compilación AUR se hará en disco (más lento, pero seguro)."
fi

# ------------------------------------------------------------------------------
# 3. RECOLECCIÓN DE DATOS DEL USUARIO
# ------------------------------------------------------------------------------
step "Selección de disco de instalación"
lsblk -d -p -n -o NAME,SIZE,MODEL,TRAN | grep -v -E 'loop|sr0'
read -rp "$(echo -e ${C_CYAN}'Introduce la ruta del disco a usar (ej. /dev/sda, /dev/nvme0n1): '${C_NC})" DISK < /dev/tty
[ -b "$DISK" ] || die "‘$DISK’ no es un dispositivo de bloque válido."

DISK_SIZE_BYTES=$(blockdev --getsize64 "$DISK" 2>/dev/null || echo 0)
DISK_SIZE_GB=$((DISK_SIZE_BYTES / 1024 / 1024 / 1024))
[ "$DISK_SIZE_GB" -ge 40 ] || die "El disco (${DISK_SIZE_GB}GB) es demasiado pequeño. Se recomiendan 40GB+ para el stack completo (GNOME + gaming + AUR)."

DISK_MODEL="$(lsblk -dn -o MODEL "$DISK" 2>/dev/null || echo desconocido)"
echo -e "${C_RED}\n¡ATENCIÓN! Vas a BORRAR POR COMPLETO:${C_NC}  ${DISK}  (${DISK_MODEL}, ${DISK_SIZE_GB}GB)"
read -rp "$(echo -e ${C_RED}'Escribe exactamente BORRAR para confirmar: '${C_NC})" CONFIRM1 < /dev/tty
[ "$CONFIRM1" = "BORRAR" ] || die "Confirmación no coincide. Abortado por seguridad."
read -rp "$(echo -e ${C_RED}"Segunda confirmación: escribe la ruta del disco (${DISK}): "${C_NC})" CONFIRM2 < /dev/tty
[ "$CONFIRM2" = "$DISK" ] || die "La segunda confirmación no coincide. Abortado por seguridad."
msg_ok "Disco confirmado: $DISK"

DISK_BASE="$(basename "$DISK")"
ROTA=$(cat "/sys/block/${DISK_BASE}/queue/rotational" 2>/dev/null || echo 1)
if [ "$ROTA" = "0" ]; then IS_SSD=1; msg_ok "SSD/NVMe detectado: se activa discard/TRIM."
else IS_SSD=0; msg_warn "Disco mecánico (HDD): se omite discard=async."
fi

step "Datos de usuario y sistema"
read -rp "Nombre de usuario [Iceman]: " USER_NAME < /dev/tty; USER_NAME="${USER_NAME:-Iceman}"
read -rp "Nombre del equipo [Arch-Gaming-Rig]: " HOSTNAME_DEF < /dev/tty; HOSTNAME_DEF="${HOSTNAME_DEF:-Arch-Gaming-Rig}"

while true; do
    read -rsp "Contraseña para ${USER_NAME} y root: " PASSWORD < /dev/tty; echo
    read -rsp "Repite la contraseña: " PASSWORD2 < /dev/tty; echo
    if [ -z "$PASSWORD" ]; then msg_warn "La contraseña no puede estar vacía."
    elif [ "$PASSWORD" != "$PASSWORD2" ]; then msg_warn "Las contraseñas no coinciden."
    else break
    fi
done
msg_ok "Contraseña establecida."

LUKS_OPT=0
read -rp "¿Cifrar la partición raíz con LUKS2? (s/N): " LUKS_ANS < /dev/tty
if [[ "$LUKS_ANS" =~ ^[Ss]$ ]]; then
    LUKS_OPT=1
    while true; do
        read -rsp "Contraseña de cifrado LUKS: " LUKS_PASS < /dev/tty; echo
        read -rsp "Repite la contraseña LUKS: " LUKS_PASS2 < /dev/tty; echo
        [ -n "$LUKS_PASS" ] && [ "$LUKS_PASS" = "$LUKS_PASS2" ] && break
        msg_warn "Las contraseñas LUKS no coinciden o están vacías."
    done
    msg_ok "Cifrado LUKS2 activado (PBKDF2, compatible con GRUB)."
else
    msg_info "Instalación sin cifrado (por defecto)."
fi
echo -e "\n${C_GREEN}✔ Configuración fijada. Iniciando automatización...${C_NC}"; sleep 1

# ------------------------------------------------------------------------------
# 4. OPTIMIZACIÓN DEL ENTORNO LIVE (pacman.conf, mirrors, espacio en RAM)
# ------------------------------------------------------------------------------
step "Optimizando pacman.conf, mirrors y espacio del live"
# Expande el overlay del ISO live para evitar el clásico error "/ too full" al
# descargar muchos paquetes (algunos archiso traen el cowspace muy justo).
mount -o remount,size=75% /run/archiso/cowspace 2>/dev/null || true

sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i "s/^#ParallelDownloads.*/ParallelDownloads = ${PARALLEL_DL}/" /etc/pacman.conf
grep -q "^ILoveCandy" /etc/pacman.conf || sed -i '/^\[options\]/a ILoveCandy' /etc/pacman.conf
sed -i '/^#\[multilib\]/,/^#Include/{s/^#//}' /etc/pacman.conf

if command -v reflector >/dev/null 2>&1; then
    run_spin_soft "Ordenando mirrors por velocidad (reflector)" \
        timeout 60 reflector --country Spain,Portugal,France,Germany --age 12 --protocol https --sort rate --save /etc/pacman.d/mirrorlist
else
    msg_info "reflector no disponible; se usa el mirrorlist por defecto del ISO."
fi
run_visible "Sincronizando pacman (multilib + mirrors nuevos)" pacman -Sy

# ------------------------------------------------------------------------------
# 5. REPOSITORIOS CACHYOS (método oficial, con localización dinámica del script)
# ------------------------------------------------------------------------------
step "Instalando repositorios CachyOS (detección dinámica de CPU y estructura)"
cd "$WORK_DIR"
echo -e "  ${C_CYAN}▶ Descargando cachyos-repo.tar.xz...${C_NC}"
curl -# -fL "https://mirror.cachyos.org/cachyos-repo.tar.xz" -o cachyos-repo.tar.xz 2> >(tee -a "$LOG_FILE" >&2)
[ -s cachyos-repo.tar.xz ] || die "La descarga del tarball de CachyOS falló o está vacía."

run_spin "Extrayendo tarball" tar -xf cachyos-repo.tar.xz
# Localizamos cachyos-repo.sh dinámicamente en vez de asumir una ruta fija:
# si CachyOS cambia la estructura interna del tarball, esto se sigue adaptando.
REPO_SCRIPT_PATH="$(find "$WORK_DIR" -maxdepth 3 -name 'cachyos-repo.sh' 2>/dev/null | head -n1)"
[ -n "$REPO_SCRIPT_PATH" ] || die "No se encontró cachyos-repo.sh tras extraer el tarball (¿cambió la estructura del paquete?)."
cd "$(dirname "$REPO_SCRIPT_PATH")"
chmod +x cachyos-repo.sh
run_visible "Ejecutando cachyos-repo.sh --install" bash -c "yes | ./cachyos-repo.sh --install"
cd "$WORK_DIR"
run_visible "Sincronizando pacman (Arch + CachyOS)" pacman -Syy

# Libera la caché de paquetes del entorno LIVE (keyring/mirrorlist ya instalados);
# esto NO afecta a la caché persistente del sistema final (@pkg), que aún no existe.
run_spin "Liberando caché de paquetes del live" pacman -Scc --noconfirm

msg_ok "Kernel seleccionado: linux-cachyos (+ linux-cachyos-lts como respaldo)."

# ------------------------------------------------------------------------------
# 6. PARTICIONADO, LUKS Y BTRFS
# ------------------------------------------------------------------------------
step "Particionando $DISK (GPT: EFI 1GiB + ROOT resto)"
umount -R /mnt 2>/dev/null || true
swapoff -a 2>/dev/null || true
cryptsetup close cryptroot 2>/dev/null || true

run_spin "Borrando tabla de particiones" sgdisk -Z "$DISK"
run_spin "Creando partición EFI" sgdisk -n 1:0:+1G -t 1:ef00 -c 1:"EFI" "$DISK"
run_spin "Creando partición ROOT" sgdisk -n 2:0:0 -t 2:8300 -c 2:"ROOT" "$DISK"
partprobe "$DISK" >> "$LOG_FILE" 2>&1 || true
sleep 2

if [[ "$DISK" == *"nvme"* ]] || [[ "$DISK" == *"mmcblk"* ]]; then
    PART_EFI="${DISK}p1"; PART_ROOT="${DISK}p2"
else
    PART_EFI="${DISK}1";  PART_ROOT="${DISK}2"
fi
[ -b "$PART_EFI" ] && [ -b "$PART_ROOT" ] || die "No se detectaron las particiones tras particionar (${PART_EFI} / ${PART_ROOT})."
msg_ok "Particiones: EFI=${PART_EFI}  ROOT=${PART_ROOT}"

run_spin "Formateando EFI (FAT32)" mkfs.fat -F32 -n EFI "$PART_EFI"

if [ "$LUKS_OPT" -eq 1 ]; then
    step "Configurando cifrado LUKS2 sobre $PART_ROOT"
    # --pbkdf pbkdf2 es OBLIGATORIO: GRUB no soporta Argon2 (default de cryptsetup),
    # solo PBKDF2 (confirmado en el manual de GRUB y ArchWiki). Sin esto, el sistema
    # no arrancaría: GRUB no podría desbloquear la partición para leer /boot.
    printf '%s' "$LUKS_PASS" | cryptsetup -q luksFormat --type luks2 --pbkdf pbkdf2 "$PART_ROOT" - >> "$LOG_FILE" 2>&1 \
        || die "Fallo en luksFormat"
    printf '%s' "$LUKS_PASS" | cryptsetup open "$PART_ROOT" cryptroot - >> "$LOG_FILE" 2>&1 \
        || die "No se pudo abrir el contenedor LUKS."
    MAPPER_ROOT="/dev/mapper/cryptroot"
    ROOT_UUID="$(blkid -s UUID -o value "$PART_ROOT")"
    msg_ok "LUKS2 configurado y abierto."
else
    MAPPER_ROOT="$PART_ROOT"
    ROOT_UUID=""
fi

step "Formateando BTRFS y creando subvolúmenes"
run_spin "Formateando BTRFS" mkfs.btrfs -f -L ArchCachy "$MAPPER_ROOT"
mount "$MAPPER_ROOT" /mnt
for sv in @ @home @log @pkg @snapshots; do
    run_spin "Creando subvolumen $sv" btrfs subvolume create "/mnt/${sv}"
done
umount /mnt
msg_ok "Subvolúmenes creados: @ @home @log @pkg @snapshots"

step "Montando estructura BTRFS definitiva"
if [ "$IS_SSD" -eq 1 ]; then MOUNT_OPTS="noatime,compress=zstd:1,space_cache=v2,discard=async"
else MOUNT_OPTS="noatime,compress=zstd:1,space_cache=v2"
fi
mount -o "${MOUNT_OPTS},subvol=@" "$MAPPER_ROOT" /mnt
mkdir -p /mnt/{home,var/log,var/cache/pacman/pkg,.snapshots,boot/efi}
mount -o "${MOUNT_OPTS},subvol=@home"      "$MAPPER_ROOT" /mnt/home
mount -o "${MOUNT_OPTS},subvol=@log"       "$MAPPER_ROOT" /mnt/var/log
mount -o "${MOUNT_OPTS},subvol=@pkg"       "$MAPPER_ROOT" /mnt/var/cache/pacman/pkg
mount -o "${MOUNT_OPTS},subvol=@snapshots" "$MAPPER_ROOT" /mnt/.snapshots
mount "$PART_EFI" /mnt/boot/efi
msg_ok "Sistema de archivos montado en /mnt (${MOUNT_OPTS}). @pkg queda en disco real y persistente."

# ------------------------------------------------------------------------------
# 7. INSTALACIÓN BASE (pacstrap) — progreso en vivo
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
    ntfs-3g exfatprogs dosfstools xdg-user-dirs
)
# pacstrap ya es no-interactivo por defecto (--noconfirm implícito salvo -i);
# NO se le añade --noconfirm manualmente para evitar que se interprete como paquete.
run_visible "pacstrap (varios minutos, verás la descarga real en pantalla)" pacstrap -K /mnt "${BASE_PKGS[@]}"

step "Generando fstab"
genfstab -U /mnt >> /mnt/etc/fstab
[ "$LUKS_OPT" -eq 0 ] || echo "# root cifrada, desbloqueada vía cryptdevice en kernel cmdline (GRUB)" >> /mnt/etc/fstab
msg_ok "fstab generado (solo con montajes reales; el tmpfs de compilación se monta DESPUÉS, no queda grabado)."

run_spin "Copiando pacman.conf al nuevo sistema" cp /etc/pacman.conf /mnt/etc/pacman.conf
run_spin "Copiando mirrorlists CachyOS" bash -c 'cp -a /etc/pacman.d/cachyos*-mirrorlist /mnt/etc/pacman.d/ 2>/dev/null || true'

# Ahora sí, DESPUÉS de genfstab: tmpfs solo para compilar AUR en RAM. Al no estar
# en fstab, tras el reinicio /tmp vuelve a ser un directorio normal en disco.
if [ "$USE_TMPFS_BUILD" -eq 1 ]; then
    mkdir -p /mnt/tmp
    run_spin "Habilitando tmpfs de compilación (${BUILD_TMPFS_MB}MB en RAM)" \
        mount -t tmpfs -o "size=${BUILD_TMPFS_MB}M,mode=1777" tmpfs /mnt/tmp
fi

# ------------------------------------------------------------------------------
# 8. VARIABLES SEGURAS PARA EL CHROOT (evita inyección de shell con contraseñas)
# ------------------------------------------------------------------------------
step "Preparando configuración segura para chroot"
install -d -m 700 /mnt/root
{
    printf 'USER_NAME=%q\n'         "$USER_NAME"
    printf 'HOSTNAME_DEF=%q\n'      "$HOSTNAME_DEF"
    printf 'PASSWORD=%q\n'          "$PASSWORD"
    printf 'TIMEZONE=%q\n'          "$TIMEZONE"
    printf 'LOCALE_NAME=%q\n'       "$LOCALE_NAME"
    printf 'KEYMAP=%q\n'            "$KEYMAP"
    printf 'XKB_LAYOUT=%q\n'        "$XKB_LAYOUT"
    printf 'LUKS_OPT=%q\n'          "$LUKS_OPT"
    printf 'ROOT_UUID=%q\n'         "$ROOT_UUID"
    printf 'IS_VM=%q\n'             "$IS_VM"
    printf 'VIRT_TYPE=%q\n'         "$VIRT_TYPE"
    printf 'GPU_VENDOR=%q\n'        "$GPU_VENDOR"
    printf 'USE_TMPFS_BUILD=%q\n'   "$USE_TMPFS_BUILD"
} > /mnt/root/iceman_vars.sh
chmod 600 /mnt/root/iceman_vars.sh
msg_ok "Variables trasladadas de forma segura."

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
C_CYAN="\033[1;36m"; C_GREEN="\033[1;32m"; C_RED="\033[1;31m"; C_YELLOW="\033[1;33m"; C_NC="\033[0m"
log(){ echo "[$(date '+%H:%M:%S')] $*" >> "$LOG"; }

run_spin() {
    local desc="$1"; shift
    log "CMD(spin): $*"
    ( "$@" ) >> "$LOG" 2>&1 &
    local pid=$!
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0 start=$SECONDS last=""
    while kill -0 "$pid" 2>/dev/null; do
        last="$(tail -n 1 "$LOG" 2>/dev/null | cut -c1-55)"
        printf "\r  ${C_CYAN}%s${C_NC} %s ${C_YELLOW}(%ds)${C_NC} %s\033[K" "${spin:i++%${#spin}:1}" "$desc" "$((SECONDS-start))" "$last"
        sleep 0.15
    done
    wait "$pid"; local rc=$?
    if [ "$rc" -eq 0 ]; then
        printf "\r  ${C_GREEN}✔${C_NC} %s\033[K\n" "$desc"; log "OK: $desc"
    else
        printf "\r  ${C_RED}✘${C_NC} %s\033[K\n" "$desc"
        echo "FALLO: $desc" >&2; tail -n 30 "$LOG" >&2; exit 1
    fi
}
run_visible() {
    local desc="$1"; shift
    log "CMD(visible): $*"
    echo -e "  ${C_CYAN}▶ ${desc}...${C_NC}"
    "$@" 2>&1 | tee -a "$LOG"
    local rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ]; then
        echo -e "  ${C_RED}✘${C_NC} ${desc}" >&2; tail -n 30 "$LOG" >&2; exit 1
    fi
    echo -e "  ${C_GREEN}✔${C_NC} ${desc}"
}
run_visible_soft() {
    local desc="$1"; shift
    log "CMD(visible-soft): $*"
    echo -e "  ${C_CYAN}▶ ${desc}...${C_NC}"
    "$@" 2>&1 | tee -a "$LOG"
    local rc=${PIPESTATUS[0]}
    if [ "$rc" -ne 0 ]; then
        echo -e "  ${C_YELLOW}⚠${C_NC} ${desc} (falló, se continúa)"; log "AVISO: $desc falló"; return 1
    fi
    echo -e "  ${C_GREEN}✔${C_NC} ${desc}"
}

echo -e "${C_CYAN}==> [chroot] Regionalización${C_NC}"
run_spin "Zona horaria y reloj" bash -c "ln -sf /usr/share/zoneinfo/${TIMEZONE} /etc/localtime && hwclock --systohc"
echo "${LOCALE_NAME} UTF-8" > /etc/locale.gen
echo "en_US.UTF-8 UTF-8" >> /etc/locale.gen
run_spin "Generando locales" locale-gen
echo "LANG=${LOCALE_NAME}" > /etc/locale.conf
echo "KEYMAP=${KEYMAP}" > /etc/vconsole.conf
echo "FONT=lat9w-16" >> /etc/vconsole.conf
echo "${HOSTNAME_DEF}" > /etc/hostname
cat > /etc/hosts <<EOF
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME_DEF}.localdomain ${HOSTNAME_DEF}
EOF
mkdir -p /etc/X11/xorg.conf.d
cat > /etc/X11/xorg.conf.d/00-keyboard.conf <<EOF
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "${XKB_LAYOUT}"
EndSection
EOF

echo -e "${C_CYAN}==> [chroot] pacman.conf del sistema instalado${C_NC}"
sed -i 's/^#Color/Color/' /etc/pacman.conf
sed -i "s/^#ParallelDownloads.*/ParallelDownloads = 15/" /etc/pacman.conf
grep -q "^ILoveCandy" /etc/pacman.conf || sed -i '/^\[options\]/a ILoveCandy' /etc/pacman.conf
sed -i '/^#\[multilib\]/,/^#Include/{s/^#//}' /etc/pacman.conf
run_spin "pacman-key --init" pacman-key --init
run_spin "pacman-key --populate" pacman-key --populate archlinux cachyos
run_visible "Sincronizando pacman" pacman -Syy

echo -e "${C_CYAN}==> [chroot] Usuarios y permisos${C_NC}"
echo "root:${PASSWORD}" | chpasswd
run_spin "Creando usuario ${USER_NAME}" useradd -m -G wheel,input,video,audio,storage,optical -s /bin/bash "${USER_NAME}"
echo "${USER_NAME}:${PASSWORD}" | chpasswd
echo "%wheel ALL=(ALL:ALL) ALL" > /etc/sudoers.d/10-wheel
chmod 440 /etc/sudoers.d/10-wheel
# NOPASSWD TEMPORAL, solo para que makepkg/yay puedan hacer 'sudo pacman -U' sin
# TTY durante la instalación. Se revierte sin falta al final de este script.
echo "${USER_NAME} ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/90-temp-installer
chmod 440 /etc/sudoers.d/90-temp-installer
su - "${USER_NAME}" -c 'xdg-user-dirs-update' >> "$LOG" 2>&1 || true

echo -e "${C_CYAN}==> [chroot] Optimización de compilación (makepkg)${C_NC}"
sed -i 's/^CFLAGS=.*/CFLAGS="-march=native -O2 -pipe -fno-plt -fexceptions -Wp,-D_FORTIFY_SOURCE=2 -Wformat -Werror=format-security -fstack-clash-protection -fcf-protection"/' /etc/makepkg.conf
sed -i 's/^CXXFLAGS=.*/CXXFLAGS="\$CFLAGS"/' /etc/makepkg.conf
sed -i 's/^#\?MAKEFLAGS=.*/MAKEFLAGS="-j\$(nproc)"/' /etc/makepkg.conf
sed -i 's/^COMPRESSZST=.*/COMPRESSZST=(zstd -c -T0 --ultra -20 -)/' /etc/makepkg.conf
if [ "${USE_TMPFS_BUILD}" -eq 1 ]; then
    # /tmp ya es tmpfs (montado por el script externo, DESPUÉS de genfstab, así que
    # no queda persistido). Todas las compilaciones de AUR usarán RAM.
    sed -i 's|^#\?BUILDDIR=.*|BUILDDIR=/tmp/makepkg|' /etc/makepkg.conf
    grep -q '^BUILDDIR=' /etc/makepkg.conf || echo 'BUILDDIR=/tmp/makepkg' >> /etc/makepkg.conf
    echo "OK: BUILDDIR apuntando a tmpfs (compilación en RAM)." >> "$LOG"
else
    echo "INFO: RAM insuficiente para tmpfs de build; se compila en disco." >> "$LOG"
fi

echo -e "${C_CYAN}==> [chroot] ZRAM${C_NC}"
mkdir -p /etc/systemd
cat > /etc/systemd/zram-generator.conf <<EOF
[zram0]
zram-size = min(ram / 2, 8192)
compression-algorithm = zstd
swap-priority = 100
fs-type = swap
EOF

echo -e "${C_CYAN}==> [chroot] Drivers gráficos, multimedia y codecs${C_NC}"
COMMON_MEDIA_PKGS=(gst-plugins-good gst-plugins-bad gst-plugins-ugly gst-libav ffmpeg a52dec faac faad2 x264 x265 xvidcore libdvdcss)
if [ "$IS_VM" -eq 0 ] && [ "$GPU_VENDOR" = "amd" ]; then
    run_visible "Instalando drivers AMD + codecs" pacman -S --noconfirm --needed mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon \
        libva-mesa-driver lib32-libva-mesa-driver mesa-vdpau lib32-mesa-vdpau corectrl "${COMMON_MEDIA_PKGS[@]}"
elif [ "$IS_VM" -eq 1 ]; then
    run_visible "Instalando drivers genéricos + codecs (VM)" pacman -S --noconfirm --needed mesa lib32-mesa "${COMMON_MEDIA_PKGS[@]}"
    case "$VIRT_TYPE" in
        qemu|kvm)   run_visible_soft "Guest tools QEMU/KVM" pacman -S --noconfirm --needed qemu-guest-agent spice-vdagent
                    systemctl enable qemu-guest-agent >> "$LOG" 2>&1 ;;
        vmware)     run_visible_soft "Guest tools VMware" pacman -S --noconfirm --needed open-vm-tools
                    systemctl enable vmtoolsd >> "$LOG" 2>&1 ;;
        oracle)     run_visible_soft "Guest tools VirtualBox" pacman -S --noconfirm --needed virtualbox-guest-utils
                    systemctl enable vboxservice >> "$LOG" 2>&1 ;;
        *) log "Hipervisor '${VIRT_TYPE}' sin guest-tools específicas conocidas." ;;
    esac
else
    run_visible "Instalando drivers genéricos + codecs" pacman -S --noconfirm --needed mesa lib32-mesa "${COMMON_MEDIA_PKGS[@]}"
fi

echo -e "${C_CYAN}==> [chroot] Escritorio GNOME + GDM${C_NC}"
run_visible "Instalando GNOME + GDM" pacman -S --noconfirm --needed gnome gnome-tweaks gdm xdg-desktop-portal-gnome
run_spin "Habilitando NetworkManager" systemctl enable NetworkManager
run_spin "Habilitando GDM" systemctl enable gdm
run_spin "Habilitando fstrim.timer" systemctl enable fstrim.timer

echo -e "${C_CYAN}==> [chroot] Bluetooth, red y firewall${C_NC}"
run_visible "Instalando bluez" pacman -S --noconfirm --needed bluez bluez-utils
run_spin "Habilitando bluetooth" systemctl enable bluetooth
run_visible "Instalando ufw/gufw" pacman -S --noconfirm --needed ufw gufw
run_spin "Configurando reglas de firewall" bash -c "ufw default deny incoming && ufw default allow outgoing && ufw allow from 192.168.0.0/16"
run_spin "Habilitando ufw (systemd)" systemctl enable ufw
run_spin "Activando ufw (firewall real)" ufw --force enable

echo -e "${C_CYAN}==> [chroot] mkinitcpio (hooks + Plymouth)${C_NC}"
if [ "${LUKS_OPT}" -eq 1 ]; then
    HOOKS_LINE="HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block plymouth encrypt btrfs filesystems fsck)"
else
    HOOKS_LINE="HOOKS=(base udev autodetect microcode modconf kms keyboard keymap consolefont block plymouth btrfs filesystems fsck)"
fi
sed -i "s|^HOOKS=(.*|${HOOKS_LINE}|" /etc/mkinitcpio.conf
plymouth-set-default-theme -R bgrt >> "$LOG" 2>&1 || true
run_visible "Generando initramfs (mkinitcpio)" mkinitcpio -P

echo -e "${C_CYAN}==> [chroot] GRUB${C_NC}"
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
run_visible "Instalando os-prober (detección de otros SO)" pacman -S --noconfirm --needed os-prober
run_spin "grub-install" grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ArchCachy --recheck
run_visible "Generando grub.cfg" grub-mkconfig -o /boot/grub/grub.cfg

echo -e "${C_CYAN}==> [chroot] Snapper (snapshots BTRFS) + grub-btrfs${C_NC}"
run_visible "Instalando snapper" pacman -S --noconfirm --needed snapper snap-pac btrfs-assistant
umount /.snapshots 2>/dev/null || true
rm -rf /.snapshots
run_spin "Creando configuración snapper" snapper --no-dbus -c root create-config /
mkdir -p /.snapshots
mount -a >> "$LOG" 2>&1 || true
sed -i 's/^TIMELINE_LIMIT_HOURLY=.*/TIMELINE_LIMIT_HOURLY="5"/'   /etc/snapper/configs/root 2>/dev/null || true
sed -i 's/^TIMELINE_LIMIT_DAILY=.*/TIMELINE_LIMIT_DAILY="5"/'     /etc/snapper/configs/root 2>/dev/null || true
sed -i 's/^TIMELINE_LIMIT_WEEKLY=.*/TIMELINE_LIMIT_WEEKLY="2"/'   /etc/snapper/configs/root 2>/dev/null || true
sed -i 's/^TIMELINE_LIMIT_MONTHLY=.*/TIMELINE_LIMIT_MONTHLY="1"/' /etc/snapper/configs/root 2>/dev/null || true
run_spin "Habilitando timers snapper/grub-btrfsd" systemctl enable snapper-timeline.timer snapper-cleanup.timer grub-btrfsd

echo -e "${C_CYAN}==> [chroot] Secure Boot (sbctl)${C_NC}"
if [ -d /sys/firmware/efi/efivars ] && sbctl status 2>/dev/null | grep -qi "Setup Mode:.*Enabled"; then
    run_spin "sbctl create-keys" sbctl create-keys
    run_spin "sbctl enroll-keys" sbctl enroll-keys --microsoft
    for f in /boot/vmlinuz-linux-cachyos /boot/vmlinuz-linux-cachyos-lts \
             /boot/EFI/ArchCachy/grubx64.efi /boot/grub/x86_64-efi/core.efi; do
        [ -f "$f" ] && sbctl sign -s "$f" >> "$LOG" 2>&1
    done
    echo -e "  ${C_GREEN}✔${C_NC} Secure Boot configurado y binarios firmados."
else
    echo -e "  ${C_YELLOW}⚠${C_NC} Firmware no está en 'Setup Mode'. Secure Boot NO configurado (instrucciones en el log)."
    { echo "Para activar Secure Boot tras el primer arranque:"
      echo "  1. Pon Secure Boot en 'Setup Mode' desde la BIOS/UEFI."
      echo "  2. Como root: sbctl create-keys && sbctl enroll-keys --microsoft"
      echo "  3. sbctl sign -s <cada binario .efi de /boot>"; } >> "$LOG"
fi

echo -e "${C_CYAN}==> [chroot] Software base, ofimática y gaming${C_NC}"
run_visible "Instalando software base + gaming" pacman -S --noconfirm --needed \
    firefox thunderbird qbittorrent \
    steam lutris mangohud lib32-mangohud goverlay gamemode lib32-gamemode gamescope \
    wine-staging winetricks \
    flatpak grub-btrfs waypaper swww power-profiles-daemon

run_spin "Firefox como navegador por defecto" bash -c "xdg-settings set default-web-browser firefox.desktop || true"
run_spin "Habilitando power-profiles-daemon" systemctl enable power-profiles-daemon

echo -e "${C_CYAN}==> [chroot] Flathub${C_NC}"
run_spin "Añadiendo remoto Flathub (root)" flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
run_spin "Añadiendo remoto Flathub (usuario)" su - "${USER_NAME}" -c "flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo"

echo -e "${C_CYAN}==> [chroot] yay (AUR helper)${C_NC}"
run_visible_soft "Compilando e instalando yay-bin" su - "${USER_NAME}" -c '
    set -e
    cd /tmp && rm -rf yay-bin
    git clone --depth 1 https://aur.archlinux.org/yay-bin.git
    cd yay-bin
    makepkg -si --noconfirm
'

echo -e "${C_CYAN}==> [chroot] Paquetes AUR: Pamac, ofimática, gaming extra, Plymouth, tema GRUB${C_NC}"
if su - "${USER_NAME}" -c 'command -v yay' >/dev/null 2>&1; then
    run_visible_soft "Instalando paquetes AUR" su - "${USER_NAME}" -c '
        yay -S --noconfirm --needed --answerclean All --answerdiff None --answeredit None \
            pamac-all \
            onlyoffice-desktopeditors \
            heroic-games-launcher-bin \
            protonup-qt \
            plymouth-theme-arch-elegant \
            game-devices-udev \
            snapd
    '
else
    echo -e "  ${C_YELLOW}⚠${C_NC} yay no disponible, se omite la fase de paquetes AUR."
    log "AVISO: yay no disponible, se omite fase AUR."
fi

if [ -d /usr/share/plymouth/themes/arch-elegant ]; then
    run_spin "Aplicando tema Plymouth arch-elegant" bash -c "plymouth-set-default-theme -R arch-elegant && mkinitcpio -P"
fi
if command -v snap >/dev/null 2>&1 || pacman -Qq snapd >/dev/null 2>&1; then
    ln -sf /var/lib/snapd/snap /snap 2>/dev/null || true
    run_spin "Habilitando snapd" systemctl enable --now snapd.socket
    systemctl enable --now snapd.apparmor >> "$LOG" 2>&1 || true
    snap set system refresh.retain=2 >> "$LOG" 2>&1 || true
fi
if [ -f /etc/pamac.conf ]; then
    sed -i 's/^#EnableAUR/EnableAUR/'                     /etc/pamac.conf
    sed -i 's/^#CheckAURUpdates/CheckAURUpdates/'          /etc/pamac.conf
    sed -i 's/^#EnableFlatpak/EnableFlatpak/'              /etc/pamac.conf
    sed -i 's/^#CheckFlatpakUpdates/CheckFlatpakUpdates/'  /etc/pamac.conf
    sed -i 's/^#RemoveUnrequiredDeps/RemoveUnrequiredDeps/' /etc/pamac.conf
    echo -e "  ${C_GREEN}✔${C_NC} pamac.conf configurado (AUR + Flatpak + auto-limpieza)."
fi
pacman -Rns --noconfirm gnome-software >> "$LOG" 2>&1 || true

echo -e "${C_CYAN}==> [chroot] Tema de GRUB (Particle-circle)${C_NC}"
cd /tmp
if run_visible_soft "Clonando tema de GRUB" git clone --depth 1 https://github.com/yeyushengfan258/Particle-circle-grub-theme.git; then
    cd Particle-circle-grub-theme
    chmod +x install.sh
    run_visible_soft "Instalando imagemagick" pacman -S --noconfirm --needed imagemagick
    if run_visible_soft "Instalando tema GRUB (2K)" ./install.sh -t window -s 2k -b; then
        run_spin "Regenerando grub.cfg con el tema" grub-mkconfig -o /boot/grub/grub.cfg
    fi
fi

echo -e "${C_CYAN}==> [chroot] Revirtiendo sudo sin contraseña (seguridad final)${C_NC}"
rm -f /etc/sudoers.d/90-temp-installer
echo -e "  ${C_GREEN}✔${C_NC} sudo vuelve a requerir contraseña para ${USER_NAME}."

echo -e "${C_CYAN}==> [chroot] Limpieza de huérfanos (la caché @pkg se conserva a propósito)${C_NC}"
orphans="$(pacman -Qtdq 2>/dev/null || true)"
[ -n "$orphans" ] && run_spin "Eliminando paquetes huérfanos" pacman -Rns --noconfirm $orphans
run_spin "Limpiando solo versiones antiguas de caché (pacman -Sc)" pacman -Sc --noconfirm

echo -e "${C_GREEN}==> [chroot] Configuración interna FINALIZADA con éxito.${C_NC}"
log "Configuración interna finalizada con éxito."
exit 0
CHROOT_EOF
chmod 700 /mnt/root/iceman_chroot.sh
msg_ok "Script de chroot generado."

# ------------------------------------------------------------------------------
# 10. EJECUCIÓN DEL CHROOT (salida en vivo, hereda la terminal)
# ------------------------------------------------------------------------------
step "Ejecutando configuración dentro del sistema instalado (verás cada sub-paso en vivo)"
if arch-chroot /mnt /root/iceman_chroot.sh; then
    msg_ok "Configuración interna completada sin errores."
else
    echo -e "${C_YELLOW}--- Log interno del chroot ---${C_NC}"
    tail -n 40 /mnt/root/iceman_chroot.log 2>/dev/null
    die "La configuración dentro del chroot falló. Revisa /mnt/root/iceman_chroot.log antes de reiniciar."
fi

# ------------------------------------------------------------------------------
# 11. LIMPIEZA FINAL
# ------------------------------------------------------------------------------
step "Limpieza final y desmontaje"
shred -u /mnt/root/iceman_vars.sh 2>/dev/null || rm -f /mnt/root/iceman_vars.sh
rm -f /mnt/root/iceman_chroot.sh /mnt/root/iceman_chroot.log
cp "$LOG_FILE" /mnt/var/log/iceman_install_live.log 2>/dev/null || true
umount -q /mnt/tmp 2>/dev/null || true   # tmpfs de compilación: no estaba en fstab, se descarta sin más
umount -R /mnt
[ "$LUKS_OPT" -eq 1 ] && cryptsetup close cryptroot
msg_ok "Todo desmontado correctamente."

echo -e "\n${C_GREEN}================================================================${C_NC}"
echo -e "${C_GREEN}   INSTALACIÓN COMPLETADA — Arch Linux + CachyOS listo para usar  ${C_NC}"
echo -e "${C_GREEN}================================================================${C_NC}"
echo -e "  Usuario:    ${USER_NAME}"
echo -e "  Equipo:     ${HOSTNAME_DEF}"
echo -e "  Cifrado:    $([ "$LUKS_OPT" -eq 1 ] && echo 'Sí (LUKS2, PBKDF2)' || echo 'No')"
echo -e "  Entorno:    $([ "$IS_VM" -eq 1 ] && echo "Máquina Virtual (${VIRT_TYPE})" || echo 'Hardware físico')"
echo -e "  Build AUR:  $([ "$USE_TMPFS_BUILD" -eq 1 ] && echo "RAM (tmpfs ${BUILD_TMPFS_MB}MB)" || echo 'Disco')"
echo ""
echo -e "  Notas importantes:"
echo -e "   · Secure Boot: automático solo si activaste 'Setup Mode' antes de instalar."
echo -e "   · Pamac queda con AUR y Flatpak activados; Snap con auto-limpieza (2 revisiones)."
echo -e "   · La caché de paquetes (@pkg) es persistente a propósito: no se borra tras reiniciar."
echo -e "\n  Escribe 'reboot' para arrancar tu nuevo sistema.\n"
log "Instalación finalizada correctamente."
exit 0
