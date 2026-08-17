#!/usr/bin/env bash
# ==============================================================================
# iceman-gaming-postinstall.sh
# CachyOS + KDE Plasma - Gaming Post-Install
# Target: AMD/Intel/NVIDIA, optimized primarily for AMD/RADV
# Safe to re-run: packages use --needed and config is managed idempotently.
# ============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="iceman-gaming-postinstall"
LOG_FILE="${HOME}/.${SCRIPT_NAME}.log"
CONFIG_DIR="${HOME}/.config/environment.d"
GAMING_ENV="${CONFIG_DIR}/gaming.conf"

# ------------------------------- Helpers -----------------------------------
info()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
ok()    { printf '\033[1;32m[ OK ]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*"; }
error() { printf '\033[1;31m[ERR ]\033[0m %s\n' "$*" >&2; }

exec > >(tee -a "$LOG_FILE") 2>&1

cleanup() { :; }
trap cleanup EXIT

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        error "Falta el comando requerido: $1"
        exit 1
    }
}

pkg_installed() {
    pacman -Qq "$1" >/dev/null 2>&1
}

install_pkgs() {
    local -a pkgs=("$@")
    local -a missing=()
    local pkg

    for pkg in "${pkgs[@]}"; do
        if ! pkg_installed "$pkg"; then
            missing+=("$pkg")
        fi
    done

    if ((${#missing[@]} == 0)); then
        ok "Paquetes ya instalados: ${#pkgs[@]}"
        return 0
    fi

    info "Instalando ${#missing[@]} paquetes: ${missing[*]}"
    sudo pacman -S --needed --noconfirm "${missing[@]}"
}

# ----------------------------- Preconditions -------------------------------
if [[ ${EUID} -eq 0 ]]; then
    error "Ejecuta este script como tu usuario normal, no como root."
    exit 1
fi

need_cmd sudo
need_cmd pacman

if [[ ! -r /etc/os-release ]]; then
    error "No puedo detectar el sistema operativo."
    exit 1
fi

# shellcheck disable=SC1091
source /etc/os-release

if [[ "${ID:-}" != "cachyos" && "${ID_LIKE:-}" != *cachyos* ]]; then
    error "Este script está diseñado para CachyOS. Detectado: ${PRETTY_NAME:-desconocido}"
    exit 1
fi

if [[ "${XDG_CURRENT_DESKTOP:-}" != *KDE* && "${DESKTOP_SESSION:-}" != *plasma* ]]; then
    warn "No parece que KDE Plasma sea el escritorio activo. Continuaré, pero este script está pensado para KDE Plasma."
fi

printf '\n'
printf '==============================================================\n'
printf '  %s\n' "$SCRIPT_NAME"
printf '  CachyOS + KDE Plasma / Gaming Setup\n'
printf '==============================================================\n\n'

# ----------------------------- Hardware ------------------------------------
info "Detectando hardware..."
CPU_MODEL="$(lscpu 2>/dev/null | awk -F: '/Model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' || true)"
GPU_INFO="$(lspci 2>/dev/null | grep -Ei 'VGA compatible controller|3D controller|Display controller' || true)"
RAM_GB="$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo)"

printf 'CPU : %s\n' "${CPU_MODEL:-desconocida}"
printf 'RAM : %s GB\n' "${RAM_GB:-?}"
printf 'GPU : %s\n\n' "${GPU_INFO:-desconocida}"

GPU_VENDOR="unknown"
if grep -qiE 'AMD|ATI' <<<"$GPU_INFO"; then
    GPU_VENDOR="amd"
elif grep -qiE 'NVIDIA' <<<"$GPU_INFO"; then
    GPU_VENDOR="nvidia"
elif grep -qiE 'Intel' <<<"$GPU_INFO"; then
    GPU_VENDOR="intel"
fi

ok "GPU detectada: $GPU_VENDOR"

# -------------------------- System update ----------------------------------
info "Actualizando el sistema antes del post-instalador..."
sudo pacman -Syu --noconfirm
ok "Sistema actualizado."

# -------------------------- Multilib check ----------------------------------
info "Comprobando repositorio multilib..."
if awk '\n    /^\[multilib\]$/ {in_multilib=1; next}\n    /^\[/ {in_multilib=0}\n    in_multilib && $0 !~ /^[[:space:]]*#/ && NF {found=1}\n    END {exit(found ? 0 : 1)}\n' /etc/pacman.conf; then
    ok "multilib está habilitado."
else
    warn "multilib no parece estar habilitado. Es necesario para muchas librerías de juegos de 32 bits."
    PACMAN_BACKUP="/etc/pacman.conf.iceman-backup-$(date +%Y%m%d-%H%M%S)"
    sudo cp -a /etc/pacman.conf "$PACMAN_BACKUP"

    if grep -qE '^#[[:space:]]*\[multilib\][[:space:]]*$' /etc/pacman.conf; then
        sudo sed -i '/^#[[:space:]]*\[multilib\][[:space:]]*$/,/^#[[:space:]]*Include[[:space:]]*=/ s/^#//' /etc/pacman.conf
    else
        printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' | sudo tee -a /etc/pacman.conf >/dev/null
    fi

    sudo pacman -Sy --noconfirm
    ok "multilib habilitado. Copia de seguridad: $PACMAN_BACKUP"
fi

# ------------------------- CachyOS gaming core -----------------------------
info "Instalando los metapaquetes gaming oficiales de CachyOS..."
install_pkgs cachyos-gaming-meta cachyos-gaming-applications
ok "Gaming base de CachyOS instalado."

# -------------------------- Extra essentials -------------------------------
# These complement the CachyOS gaming meta-package without replacing it.
EXTRA_PKGS=(
    mesa
    lib32-mesa
    vulkan-radeon
    lib32-vulkan-radeon
    mesa-utils
    vulkan-tools
    libva
    libva-mesa-driver
    lib32-libva-mesa-driver
    corectrl
    lm_sensors
    radeontop
    nvtop
    p7zip
    unzip
    unrar
    git
    curl
    wget
    bluez
    bluez-utils
    pipewire
    pipewire-alsa
    pipewire-pulse
    wireplumber
)

if [[ "$GPU_VENDOR" == "amd" ]]; then
    install_pkgs "${EXTRA_PKGS[@]}"
else
    # Keep only vendor-neutral essentials when the machine is not AMD.
    install_pkgs mesa lib32-mesa mesa-utils vulkan-tools libva bluez bluez-utils \
        pipewire pipewire-alsa pipewire-pulse wireplumber p7zip unzip unrar git curl wget \
        lm_sensors nvtop
fi

# -------------------------- AMD gaming tuning ------------------------------
mkdir -p "$CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

if [[ "$GPU_VENDOR" == "amd" ]]; then
    info "Configurando RADV y caché de shaders AMD (12 GB)..."
    cat > "$GAMING_ENV" <<'ENV'
# Managed by iceman-gaming-postinstall.sh
# CachyOS Gaming / AMD Radeon

# Use Mesa's RADV Vulkan driver.
AMD_VULKAN_ICD=RADV

# Keep a larger global Mesa shader cache for large games.
MESA_SHADER_CACHE_MAX_SIZE=12G
ENV
    chmod 600 "$GAMING_ENV"
    ok "Configuración AMD creada en $GAMING_ENV"
else
    info "GPU no AMD: no se aplicará configuración RADV."
fi

# ---------------------------- Services -------------------------------------
info "Configurando servicios útiles para gaming..."

if systemctl list-unit-files bluetooth.service >/dev/null 2>&1; then
    sudo systemctl enable --now bluetooth.service || warn "No se pudo activar Bluetooth."
fi

# PipeWire/WirePlumber are normally already enabled by CachyOS/KDE.
systemctl --user enable --now wireplumber.service 2>/dev/null || true
systemctl --user enable --now pipewire.service 2>/dev/null || true
systemctl --user enable --now pipewire-pulse.service 2>/dev/null || true
ok "Servicios de Bluetooth/Audio comprobados."

# ------------------------- Display / gaming tools --------------------------
info "Comprobando herramientas gaming principales..."
for cmd in steam gamescope mangohud goverlay lutris heroic; do
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd disponible."
    else
        warn "$cmd no aparece en PATH; revisar instalación."
    fi
done

# game-performance is supplied by CachyOS Settings on current CachyOS.
if command -v game-performance >/dev/null 2>&1; then
    ok "game-performance disponible."
else
    warn "game-performance no está disponible en PATH. CachyOS lo incluye en sus herramientas de gaming, pero se revisará manualmente si falta."
fi

# ------------------------- Anti-conflict check ------------------------------
if pacman -Q ananicy-cpp >/dev/null 2>&1 && pacman -Q gamemode >/dev/null 2>&1; then
    warn "Tanto ananicy-cpp como gamemode están instalados. CachyOS recomienda no combinarlos."
    warn "No desinstalo nada automáticamente; revisa qué servicio/herramienta quieres conservar."
elif pacman -Q ananicy-cpp >/dev/null 2>&1; then
    ok "ananicy-cpp detectado; no se instala gamemode."
fi

# -------------------------- Proton verification ----------------------------
info "Verificando compatibilidad Proton/CachyOS..."
for pkg in proton-cachyos proton-cachyos-slr umu-launcher wine-cachyos-opt winetricks protontricks; do
    if pacman -Q "$pkg" >/dev/null 2>&1; then
        ok "$pkg instalado."
    else
        warn "$pkg no está instalado."
    fi
done

# -------------------------- Vulkan verification ----------------------------
printf '\n'
info "Prueba rápida de Vulkan..."
if command -v vulkaninfo >/dev/null 2>&1; then
    VULKAN_SUMMARY="$(vulkaninfo --summary 2>&1 || true)"
    if grep -qiE 'AMD|RADV|Radeon' <<<"$VULKAN_SUMMARY"; then
        ok "Vulkan detecta la GPU AMD/RADV."
    elif [[ -n "$VULKAN_SUMMARY" ]]; then
        warn "Vulkan responde, pero no se pudo confirmar RADV automáticamente."
    else
        warn "vulkaninfo no devolvió información útil."
    fi
else
    warn "vulkaninfo no está disponible."
fi

if command -v glxinfo >/dev/null 2>&1; then
    glxinfo -B 2>/dev/null | sed -n '/OpenGL vendor string/p;/OpenGL renderer string/p;/OpenGL version string/p' || true
fi

# -------------------------- Final report -----------------------------------
printf '\n'
printf '==============================================================\n'
printf '  POST-INSTALACIÓN COMPLETADA\n'
printf '==============================================================\n'

printf '\nConfiguración aplicada:\n'
printf '  • CachyOS gaming meta + aplicaciones\n'
printf '  • Steam / Heroic / Lutris / Gamescope / MangoHud / GOverlay\n'
printf '  • Proton-CachyOS / Proton-CachyOS-SLR / umu-launcher\n'
printf '  • Wine-CachyOS / Winetricks / Protontricks\n'
printf '  • Vulkan + librerías 32-bit\n'
printf '  • PipeWire / WirePlumber / Bluetooth\n'

if [[ "$GPU_VENDOR" == "amd" ]]; then
    printf '  • RADV forzado\n'
    printf '  • Caché de shaders Mesa: 12 GB\n'
    printf '  • Herramientas AMD: CoreCtrl / RadeonTop\n'
fi

printf '\nLog: %s\n' "$LOG_FILE"
printf '\nRECOMENDACIÓN: reinicia la sesión o el equipo para que environment.d y la configuración de shaders queden cargadas.\n'
printf 'Después podrás usar "game-performance %%command%%" en Steam para que CachyOS cambie temporalmente al perfil Performance mientras juegas.\n\n'

ok "iceman-gaming-postinstall.sh terminado."
