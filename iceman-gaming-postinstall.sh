#!/usr/bin/env bash
# ==============================================================================
# iceman-gaming-postinstall.sh
# CachyOS + KDE Plasma - Gaming Post-Install
# Refactored release: 2.0.0
# Target: AMD / Intel / NVIDIA
#
# Designed for a safe re-run on CachyOS. It does not remove packages, does not
# overwrite unmanaged configuration without creating a timestamped backup, and
# uses the official CachyOS gaming meta-packages as the primary source of gaming
# components.
# ==============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="iceman-gaming-postinstall"
SCRIPT_VERSION="2.0.0"
LOG_FILE="${HOME}/.${SCRIPT_NAME}.log"
CONFIG_DIR="${HOME}/.config/environment.d"
GAMING_ENV="${CONFIG_DIR}/gaming.conf"

# ------------------------------- Output --------------------------------------
BLUE='\033[1;34m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
RESET='\033[0m'

info()  { printf '%b[INFO]%b %s\n' "$BLUE" "$RESET" "$*"; }
ok()    { printf '%b[ OK ]%b %s\n' "$GREEN" "$RESET" "$*"; }
warn()  { printf '%b[WARN]%b %s\n' "$YELLOW" "$RESET" "$*"; }
error() { printf '%b[ERR ]%b %s\n' "$RED" "$RESET" "$*" >&2; }

mkdir -p "$(dirname "$LOG_FILE")"
exec > >(tee -a "$LOG_FILE") 2>&1

# Keep the script intentionally quiet on normal EXIT.
cleanup() { :; }
trap cleanup EXIT

# ------------------------------- Helpers -------------------------------------
need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        error "Falta el comando requerido: $1"
        exit 1
    }
}

pkg_installed() {
    pacman -Qq "$1" >/dev/null 2>&1
}

pkg_available() {
    pacman -Si "$1" >/dev/null 2>&1
}

install_pkgs() {
    local -a requested=("$@")
    local -a missing=()
    local -a unavailable=()
    local pkg

    for pkg in "${requested[@]}"; do
        if pkg_installed "$pkg"; then
            continue
        fi
        if pkg_available "$pkg"; then
            missing+=("$pkg")
        else
            unavailable+=("$pkg")
        fi
    done

    if ((${#unavailable[@]})); then
        error "Paquetes no disponibles en los repositorios activos: ${unavailable[*]}"
        return 1
    fi

    if ((${#missing[@]} == 0)); then
        ok "Paquetes comprobados; no había nada nuevo que instalar."
        return 0
    fi

    info "Instalando ${#missing[@]} paquetes: ${missing[*]}"
    sudo pacman -S --needed --noconfirm "${missing[@]}"
}

backup_file() {
    local file="$1"
    local backup

    [[ -e "$file" ]] || return 0
    backup="${file}.iceman-backup-$(date +%Y%m%d-%H%M%S)"

    if [[ "$file" == /etc/* ]]; then
        sudo cp -a -- "$file" "$backup"
    else
        cp -a -- "$file" "$backup"
    fi

    printf '%s\n' "$backup"
}

is_multilib_enabled() {
    awk '
        /^[[:space:]]*\[multilib\][[:space:]]*$/ {
            in_multilib=1
            next
        }
        /^[[:space:]]*\[/ {
            in_multilib=0
        }
        in_multilib && $0 !~ /^[[:space:]]*#/ && NF {
            enabled=1
        }
        END {
            exit(enabled ? 0 : 1)
        }
    ' /etc/pacman.conf
}

enable_multilib() {
    local backup

    info "Comprobando el repositorio multilib..."
    if is_multilib_enabled; then
        ok "multilib ya está habilitado."
        return 0
    fi

    warn "multilib no está habilitado; es necesario para muchas librerías/juegos de 32 bits."
    backup="$(backup_file /etc/pacman.conf)"

    if grep -qE '^[[:space:]]*#[[:space:]]*\[multilib\][[:space:]]*$' /etc/pacman.conf; then
        sudo sed -i '/^[[:space:]]*#[[:space:]]*\[multilib\][[:space:]]*$/,/^[[:space:]]*#[[:space:]]*Include[[:space:]]*=.*mirrorlist/ s/^[[:space:]]*#//' /etc/pacman.conf
    else
        printf '\n[multilib]\nInclude = /etc/pacman.d/mirrorlist\n' | sudo tee -a /etc/pacman.conf >/dev/null
    fi

    if ! is_multilib_enabled; then
        error "No se pudo habilitar multilib correctamente. Se conserva la copia: $backup"
        return 1
    fi

    ok "multilib habilitado. Copia de seguridad: $backup"
}

gpu_vendor_from_info() {
    local info="$1"

    if grep -qiE 'NVIDIA' <<<"$info"; then
        printf 'nvidia\n'
    elif grep -qiE 'AMD|ATI' <<<"$info"; then
        printf 'amd\n'
    elif grep -qiE 'Intel' <<<"$info"; then
        printf 'intel\n'
    else
        printf 'unknown\n'
    fi
}

write_managed_env() {
    local content="$1"
    local temp
    local backup=""

    mkdir -p "$CONFIG_DIR"
    chmod 700 "$CONFIG_DIR"
    temp="$(mktemp)"
    printf '%s\n' "$content" > "$temp"
    chmod 600 "$temp"

    if [[ -f "$GAMING_ENV" ]] && cmp -s "$temp" "$GAMING_ENV"; then
        rm -f "$temp"
        ok "Configuración de entorno gaming ya estaba al día."
        return 0
    fi

    if [[ -e "$GAMING_ENV" ]]; then
        backup="$(backup_file "$GAMING_ENV")"
        info "Configuración anterior respaldada en: $backup"
    fi

    mv -f -- "$temp" "$GAMING_ENV"
    chmod 600 "$GAMING_ENV"
    ok "Configuración guardada en $GAMING_ENV"
}

# ----------------------------- Preconditions ---------------------------------
if [[ ${EUID} -eq 0 ]]; then
    error "Ejecuta este script como tu usuario normal, no como root."
    exit 1
fi

need_cmd sudo
need_cmd pacman
need_cmd awk
need_cmd grep
need_cmd sed
need_cmd tee
need_cmd systemctl

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

if [[ "$(uname -m)" != "x86_64" ]]; then
    error "Este perfil está preparado para sistemas x86_64. Arquitectura detectada: $(uname -m)"
    exit 1
fi

if [[ "${XDG_CURRENT_DESKTOP:-}" != *KDE* && "${DESKTOP_SESSION:-}" != *plasma* ]]; then
    warn "No parece que KDE Plasma sea el escritorio activo. Continuaré, pero el script está pensado para KDE Plasma."
fi

printf '\n'
printf '====================================================================\n'
printf '  %s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
printf '  CachyOS + KDE Plasma / Gaming Setup\n'
printf '====================================================================\n\n'

# ----------------------------- Hardware --------------------------------------
info "Detectando hardware..."
CPU_MODEL="$(lscpu 2>/dev/null | awk -F: '/Model name/ {gsub(/^[ \t]+/, "", $2); print $2; exit}' || true)"
RAM_GB="$(awk '/MemTotal/ {printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || true)"
GPU_INFO=""
if command -v lspci >/dev/null 2>&1; then
    GPU_INFO="$(lspci 2>/dev/null | grep -Ei 'VGA compatible controller|3D controller|Display controller' || true)"
fi
GPU_VENDOR="$(gpu_vendor_from_info "$GPU_INFO")"

printf 'CPU : %s\n' "${CPU_MODEL:-desconocida}"
printf 'RAM : %s GB\n' "${RAM_GB:-?}"
printf 'GPU : %s\n' "${GPU_INFO:-desconocida}"
printf 'VENDOR : %s\n\n' "$GPU_VENDOR"
ok "Hardware detectado."

# --------------------------- Multilib first ----------------------------------
# Enable the repository before the full upgrade so there is no standalone -Sy
# operation later in the script.
enable_multilib

# -------------------------- System update ------------------------------------
info "Actualizando el sistema..."
sudo pacman -Syu --noconfirm
ok "Sistema actualizado."

# ---------------------- CachyOS gaming foundation ----------------------------
info "Instalando la base oficial de gaming de CachyOS..."
install_pkgs cachyos-gaming-meta cachyos-gaming-applications cachyos-settings
ok "Base gaming de CachyOS comprobada."

# --------------------------- Core utilities -----------------------------------
CORE_PKGS=(
    mesa-utils
    vulkan-tools
    libva
    lm_sensors
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
install_pkgs "${CORE_PKGS[@]}"

# ------------------------- GPU-specific setup --------------------------------
case "$GPU_VENDOR" in
    amd)
        info "Configurando componentes gráficos para AMD/RADV..."
        install_pkgs mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon libva-mesa-driver lib32-libva-mesa-driver corectrl radeontop
        write_managed_env '# Managed by iceman-gaming-postinstall.sh
# CachyOS Gaming / AMD Radeon

# Fuerza la implementación RADV para Vulkan.
AMD_VULKAN_ICD=RADV

# Aumenta el tamaño máximo de la caché de shaders de Mesa.
MESA_SHADER_CACHE_MAX_SIZE=12G'
        ;;
    intel)
        info "Configurando componentes gráficos para Intel..."
        install_pkgs mesa lib32-mesa vulkan-intel lib32-vulkan-intel mesa-utils vulkan-tools
        write_managed_env '# Managed by iceman-gaming-postinstall.sh
# CachyOS Gaming / Intel

# Mesa/Vulkan seleccionará el controlador Intel instalado.
'
        ;;
    nvidia)
        info "Comprobando componentes gráficos para NVIDIA sin sustituir el controlador instalado por CachyOS..."
        install_pkgs mesa lib32-mesa mesa-utils vulkan-tools
        write_managed_env '# Managed by iceman-gaming-postinstall.sh
# CachyOS Gaming / NVIDIA

# Aumenta la caché de shaders del controlador NVIDIA.
__GL_SHADER_DISK_CACHE_SIZE=12000000000'
        ;;
    *)
        warn "No pude identificar el fabricante de la GPU; no instalaré un controlador específico."
        write_managed_env '# Managed by iceman-gaming-postinstall.sh
# CachyOS Gaming / Generic
'
        ;;
esac

# --------------------- Power profile / game-performance ----------------------
# CachyOS recommends game-performance for on-demand performance mode. It uses
# power-profiles-daemon and is not the same mechanism as gamemode.
info "Comprobando game-performance..."

if pkg_installed tlp; then
    warn "TLP está instalado; no forzaré power-profiles-daemon para evitar conflictos."
else
    install_pkgs power-profiles-daemon || warn "No se pudo instalar power-profiles-daemon; game-performance puede no estar disponible."
fi

if command -v game-performance >/dev/null 2>&1; then
    ok "game-performance disponible."
else
    warn "game-performance no está en PATH. CachyOS debería proporcionarlo mediante cachyos-settings."
fi

# -------------------------- Audio / Bluetooth ---------------------------------
info "Comprobando servicios de audio y Bluetooth..."

if systemctl list-unit-files bluetooth.service >/dev/null 2>&1; then
    sudo systemctl enable --now bluetooth.service || warn "No se pudo activar Bluetooth."
else
    warn "bluetooth.service no está disponible."
fi

for unit in pipewire.service pipewire-pulse.service wireplumber.service; do
    if systemctl --user list-unit-files "$unit" >/dev/null 2>&1; then
        systemctl --user enable --now "$unit" || warn "No se pudo activar $unit."
    fi
done
ok "Servicios de audio/Bluetooth comprobados."

# --------------------- ananicy / gamemode policy ------------------------------
# CachyOS explicitly advises against combining gamemode and ananicy-cpp because
# both may alter process niceness. This script intentionally does not install
# or enable gamemode automatically; it uses Cachy's game-performance wrapper.
if pkg_installed ananicy-cpp; then
    ok "ananicy-cpp detectado; se conserva y no se instala/activa gamemode."
elif pkg_installed gamemode; then
    warn "gamemode detectado sin ananicy-cpp. Se conserva tal cual; no se modifica."
else
    ok "No se ha instalado ningún gestor adicional de prioridades de procesos."
fi

# ----------------------- Optional monitor availability -----------------------
info "Comprobando herramientas gaming principales..."
for cmd in steam gamescope mangohud goverlay lutris heroic faugus-launcher; do
    if command -v "$cmd" >/dev/null 2>&1; then
        ok "$cmd disponible."
    else
        warn "$cmd no aparece en PATH; revisa la instalación del metapaquete gaming."
    fi
done

# -------------------------- Proton verification -----------------------------
info "Verificando componentes Proton/Wine de CachyOS..."
for pkg in proton-cachyos-slr umu-launcher wine-cachyos-opt winetricks protontricks; do
    if pkg_installed "$pkg"; then
        ok "$pkg instalado."
    else
        warn "$pkg no está instalado."
    fi
done

# -------------------------- Vulkan verification -----------------------------
printf '\n'
info "Prueba rápida de Vulkan..."
if command -v vulkaninfo >/dev/null 2>&1; then
    VULKAN_SUMMARY="$(vulkaninfo --summary 2>&1 || true)"
    if [[ -n "$VULKAN_SUMMARY" ]]; then
        if grep -qiE 'RADV|AMD|Radeon' <<<"$VULKAN_SUMMARY" && [[ "$GPU_VENDOR" == "amd" ]]; then
            ok "Vulkan detecta AMD/RADV."
        elif grep -qiE 'NVIDIA' <<<"$VULKAN_SUMMARY" && [[ "$GPU_VENDOR" == "nvidia" ]]; then
            ok "Vulkan detecta NVIDIA."
        elif grep -qiE 'Intel' <<<"$VULKAN_SUMMARY" && [[ "$GPU_VENDOR" == "intel" ]]; then
            ok "Vulkan detecta Intel."
        else
            warn "Vulkan responde, pero el proveedor mostrado no coincide claramente con la detección inicial."
        fi
    else
        warn "vulkaninfo no devolvió información útil."
    fi
else
    warn "vulkaninfo no está disponible."
fi

if command -v glxinfo >/dev/null 2>&1; then
    glxinfo -B 2>/dev/null | sed -n '/OpenGL vendor string/p;/OpenGL renderer string/p;/OpenGL version string/p' || true
fi

# -------------------------- Final report -------------------------------------
printf '\n'
printf '====================================================================\n'
printf '  POST-INSTALACIÓN COMPLETADA — %s v%s\n' "$SCRIPT_NAME" "$SCRIPT_VERSION"
printf '====================================================================\n\n'

printf 'Configuración aplicada/comprobada:\n'
printf '  • CachyOS gaming meta + aplicaciones oficiales\n'
printf '  • CachyOS Settings / game-performance\n'
printf '  • Steam / Heroic / Lutris / Gamescope / MangoHud / GOverlay\n'
printf '  • Proton-CachyOS-SLR / umu-launcher / Wine-CachyOS / Winetricks / Protontricks\n'
printf '  • Vulkan + librerías 32-bit mediante multilib\n'
printf '  • PipeWire / WirePlumber / Bluetooth\n'
printf '  • Configuración de caché de shaders según fabricante\n'

case "$GPU_VENDOR" in
    amd)
        printf '  • AMD: RADV forzado + caché Mesa de 12 GB + CoreCtrl/RadeonTop\n'
        ;;
    nvidia)
        printf '  • NVIDIA: caché de shaders de 12 GB sin sustituir el driver del sistema\n'
        ;;
    intel)
        printf '  • Intel: Vulkan Intel 64/32-bit comprobado\n'
        ;;
esac

printf '\nLog: %s\n' "$LOG_FILE"
printf '\nRECOMENDACIÓN:\n'
printf '  Reinicia la sesión (o el equipo) para que environment.d quede cargado.\n'
printf '  En Steam puedes usar: game-performance %%command%%\n'
printf '  Esto activa temporalmente el perfil de rendimiento durante el juego.\n\n'

ok "$SCRIPT_NAME v$SCRIPT_VERSION terminado correctamente."
