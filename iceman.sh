#!/usr/bin/env bash
#
# Iceman Installer — Arch Linux + CachyOS v3 + KDE Plasma + AMD Gaming
# Designed for bare metal on the user's AMD gaming PC, but hardware names
# are detected from firmware/PCI capabilities rather than exact marketing names.
#
# REQUIREMENTS:
#   - Official Arch Linux ISO, booted in UEFI mode
#   - Internet connection
#   - x86_64 CPU with x86-64-v3 support
#   - AMD Radeon GPU (AMDGPU/Mesa/RADV stack)
#
# IMPORTANT: the selected disk is ERASED completely.
# Supports: curl -fsSL <raw-url> | bash
#
set -Eeuo pipefail
umask 022
export LC_ALL=C
export LANG=C

readonly MNT=/mnt
readonly ESP_MNT=/mnt/boot
readonly LOG_FILE="/tmp/iceman-kde-$(date +%Y%m%d-%H%M%S).log"
readonly CACHY_BASE_URL="https://mirror.cachyos.org/repo/x86_64/cachyos"
readonly CACHY_KEY="F3B607488DB35A47"
readonly CACHY_KEYSERVER="keyserver.ubuntu.com"

TARGET_DISK=""
EFI_PART=""
ROOT_PART=""
ROOT_UUID=""
EFI_UUID=""
USERNAME=""
USER_PASSWORD=""
CPU_VENDOR=""
CPU_MODEL=""
GPU_LINE=""
GPU_PCI_ID=""
GPU_DRIVER=""
RAM_GIB=""
CACHY_FLAVOR=""
CACHY_KEYRING_URL=""
CACHY_MIRRORLIST_URL=""
CACHY_OPT_MIRRORLIST_URL=""
CLEANED=0
DISK_TOUCHED=0

exec > >(tee -a "$LOG_FILE") 2>&1

timestamp() { date '+%H:%M:%S'; }
info() { printf '\n[%s] [INFO] %s\n' "$(timestamp)" "$*"; }
warn() { printf '\n[%s] [WARN] %s\n' "$(timestamp)" "$*" >&2; }
ok() { printf '[%s] [ OK ] %s\n' "$(timestamp)" "$*"; }
die() { printf '\n[%s] [ERROR] %s\n' "$(timestamp)" "$*" >&2; exit 1; }
section() {
    printf '\n============================================================\n'
    printf ' %s\n' "$*"
    printf '============================================================\n'
}

need() { command -v "$1" >/dev/null 2>&1 || die "Falta el comando requerido: $1"; }

read_tty() {
    local prompt="$1" var="$2" value
    if [[ -r /dev/tty ]]; then
        IFS= read -r -p "$prompt" value < /dev/tty || return 1
    else
        IFS= read -r -p "$prompt" value || return 1
    fi
    printf -v "$var" '%s' "$value"
}

read_secret() {
    local prompt="$1" var="$2" value
    if [[ -r /dev/tty ]]; then
        IFS= read -r -s -p "$prompt" value < /dev/tty || return 1
    else
        IFS= read -r -s -p "$prompt" value || return 1
    fi
    printf '\n'
    printf -v "$var" '%s' "$value"
}

cleanup() {
    local rc=$?
    set +e
    sync
    if [[ -d "$MNT" ]]; then
        umount -R "$MNT" >/dev/null 2>&1 || true
    fi
    CLEANED=1
    if (( rc != 0 )); then
        cp -f "$LOG_FILE" /root/iceman-kde-error.log >/dev/null 2>&1 || true
        printf '\nLa instalación terminó con ERROR (código %s).\n' "$rc"
        printf 'Log: /root/iceman-kde-error.log\n'
        if (( DISK_TOUCHED == 1 )); then
            printf 'ATENCIÓN: el disco seleccionado ya fue modificado/borrado. NO reinicio automáticamente.\n'
        fi
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

hardware_detect() {
    section "1/13 — DETECCIÓN REAL DEL HARDWARE"
    [[ $EUID -eq 0 ]] || die "Debes ejecutar el instalador como root."
    [[ "$(uname -m)" == "x86_64" ]] || die "Este instalador requiere x86_64."
    [[ -d /sys/firmware/efi/efivars ]] || die "El ISO no está arrancado en UEFI. Reinicia y arranca el USB en modo UEFI."
    if systemd-detect-virt --quiet 2>/dev/null; then
        die "Se ha detectado una máquina virtual. Este instalador está destinado a METAL."
    fi

    for c in pacman pacstrap arch-chroot genfstab lsblk sgdisk wipefs mkfs.btrfs mkfs.fat mount umount partprobe blkid lscpu lspci; do
        need "$c"
    done

    CPU_VENDOR="$(lscpu -s 1 -J 2>/dev/null | awk -F'"' '/Vendor ID/{getline; print $4; exit}')"
    [[ -n "$CPU_VENDOR" ]] || CPU_VENDOR="$(lscpu | awk -F: '/Vendor ID/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    CPU_MODEL="$(lscpu | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    RAM_GIB="$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo)"

    GPU_LINE="$(lspci -nnk | awk '/VGA compatible controller|3D controller|Display controller/{print; getline; print; getline; print; exit}')"
    GPU_PCI_ID="$(printf '%s\n' "$GPU_LINE" | sed -n 's/.*\[\([0-9A-Fa-f]\{4\}:[0-9A-Fa-f]\{4\}\)\].*/\1/p' | head -n1)"
    GPU_DRIVER="$(printf '%s\n' "$GPU_LINE" | sed -n 's/.*Kernel driver in use: \([^[:space:]]*\).*/\1/p' | head -n1)"

    local board
    board="$(cat /sys/devices/virtual/dmi/id/board_name 2>/dev/null || true)"

    printf 'CPU vendor:  %s\n' "${CPU_VENDOR:-desconocido}"
    printf 'CPU modelo:  %s\n' "${CPU_MODEL:-desconocido}"
    printf 'Placa:       %s\n' "${board:-desconocida}"
    printf 'RAM:         %s GiB\n' "$RAM_GIB"
    printf 'GPU:         %s\n' "${GPU_LINE:-NO DETECTADA}"
    printf 'GPU PCI ID:  %s\n' "${GPU_PCI_ID:-desconocido}"
    printf 'GPU driver:  %s\n' "${GPU_DRIVER:-no cargado}"

    [[ "$CPU_VENDOR" == "AuthenticAMD" ]] || die "La CPU detectada no es AMD. Este instalador está optimizado para la plataforma AMD objetivo."
    (( RAM_GIB >= 16 )) || die "La memoria detectada es inferior a 16 GiB; no coincide con el perfil de este instalador."
    [[ "$GPU_PCI_ID" == 1002:* ]] || die "No se ha detectado una GPU AMD Radeon por PCI. El stack gráfico de este instalador es AMDGPU/Mesa/RADV."

    local ld_help gcc_arch
    ld_help="$(/lib/ld-linux-x86-64.so.2 --help 2>/dev/null || true)"
    if ! grep -q 'x86-64-v3 (supported, searched)' <<<"$ld_help"; then
        die "La CPU no reporta soporte x86-64-v3. Los repositorios optimizados de CachyOS usados por esta instalación requieren v3."
    fi

    gcc_arch=""
    if command -v gcc >/dev/null 2>&1; then
        gcc_arch="$(gcc -march=native -Q --help=target 2>/dev/null | awk '/^[[:space:]]+-march=/{print $2; exit}')"
    fi

    # Conservative policy for the current AMD platform:
    # - Zen4/Zen5 -> znver4 repository (shared v4 mirrorlist)
    # - Otherwise -> x86-64-v3 repository
    if [[ "$gcc_arch" == "znver4" || "$gcc_arch" == "znver5" ]]; then
        CACHY_FLAVOR="znver4"
    else
        CACHY_FLAVOR="v3"
    fi

    printf 'CachyOS repo: %s\n' "$CACHY_FLAVOR"
    ok "Hardware detectado por capacidades/vendor, no por el nombre comercial de la GPU."
}

network_check() {
    section "2/13 — RED"
    need curl
    if curl -fsS --connect-timeout 5 --max-time 15 https://archlinux.org >/dev/null; then
        ok "Internet funcionando."
        return
    fi

    warn "No hay conexión funcional. El ISO oficial de Arch normalmente ya trae iwctl/iwd para Wi-Fi."
    if command -v iwctl >/dev/null 2>&1 && command -v iw >/dev/null 2>&1; then
        systemctl start iwd >/dev/null 2>&1 || true
        mapfile -t ifaces < <(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}')
        if (( ${#ifaces[@]} > 0 )); then
            local iface="${ifaces[0]}" ssid password
            iwctl station "$iface" scan >/dev/null 2>&1 || true
            iwctl station "$iface" get-networks || true
            read_tty "SSID Wi-Fi: " ssid || die "No se pudo leer el SSID."
            read_secret "Contraseña Wi-Fi: " password || die "No se pudo leer la contraseña."
            iwctl station "$iface" connect "$ssid" <<<"$password" || die "No se pudo conectar al Wi-Fi."
            unset password
            sleep 3
        fi
    fi

    curl -fsS --connect-timeout 5 --max-time 15 https://archlinux.org >/dev/null ||
        die "No hay Internet. Conecta Ethernet o Wi-Fi y vuelve a ejecutar el instalador."
    ok "Internet funcionando."
}

preflight_tools() {
    section "3/13 — HERRAMIENTAS Y REPOSITORIOS"
    local tools=(pacman pacstrap arch-chroot genfstab lsblk sgdisk wipefs mkfs.btrfs mkfs.fat mount umount partprobe blkid findmnt lscpu lspci)
    local t
    for t in "${tools[@]}"; do need "$t"; done

    # The official Arch ISO is intended to be used as-is. We do not perform a
    # live-system full upgrade, avoiding a partial-upgrade trap in the installer.
    pacman -S --needed --noconfirm archlinux-keyring >/dev/null
    pacman-key --init >/dev/null 2>&1 || true
    pacman-key --populate archlinux >/dev/null 2>&1 || true
    pacman -Syy --noconfirm >/dev/null

    local package_check=(base linux-firmware btrfs-progs dosfstools sudo networkmanager plasma-meta sddm mesa vulkan-radeon lib32-mesa lib32-vulkan-radeon pipewire wireplumber steam gamemode mangohud gamescope wine lutris snapper btrfs-assistant snap-pac)
    local missing=() pkg
    for pkg in "${package_check[@]}"; do
        if ! pacman -Si "$pkg" >/dev/null 2>&1; then
            missing+=("$pkg")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        die "Faltan paquetes en los repositorios disponibles del ISO: ${missing[*]}"
    fi
    ok "Herramientas Arch y paquetes base disponibles."
}

latest_cachyos_pkg() {
    local prefix="$1" listing file
    listing="$(curl -fsSL --connect-timeout 10 --max-time 30 "$CACHY_BASE_URL/")" ||
        die "No se puede consultar el directorio oficial de paquetes de CachyOS."

    file="$(printf '%s\n' "$listing" | sed -n 's/.*href="\([^"/]*\.pkg\.tar\.zst\)".*/\1/p' | grep -E "^${prefix}[-_].*\.pkg\.tar\.zst$" | sort -V | tail -n1)"
    [[ -n "$file" ]] || die "No se encontró el paquete CachyOS dinámicamente: $prefix"
    printf '%s/%s' "$CACHY_BASE_URL" "$file"
}

install_cachyos_repos() {
    section "4/13 — CACHYOS"
    CACHY_KEYRING_URL="$(latest_cachyos_pkg cachyos-keyring)"
    CACHY_MIRRORLIST_URL="$(latest_cachyos_pkg cachyos-mirrorlist)"
    if [[ "$CACHY_FLAVOR" == "znver4" ]]; then
        CACHY_OPT_MIRRORLIST_URL="$(latest_cachyos_pkg cachyos-v4-mirrorlist)"
    else
        CACHY_OPT_MIRRORLIST_URL="$(latest_cachyos_pkg cachyos-v3-mirrorlist)"
    fi

    info "Importando clave CachyOS oficial."
    pacman-key --recv-keys "$CACHY_KEY" --keyserver "$CACHY_KEYSERVER"
    pacman-key --lsign-key "$CACHY_KEY"

    info "Instalando keyring y mirrorlists desde el mirror oficial."
    pacman -U --noconfirm "$CACHY_KEYRING_URL" "$CACHY_MIRRORLIST_URL" "$CACHY_OPT_MIRRORLIST_URL"
    ok "Keyring y mirrorlist CachyOS instalados."

    mkdir -p "$MNT"
    # The target pacman.conf is kept intact; only CachyOS optimized repositories
    # are inserted above Arch's core repository. The [cachyos] repo is intentionally
    # omitted to keep Arch's pacman instead of installing CachyOS's pacman fork.
    if [[ "$CACHY_FLAVOR" == "znver4" ]]; then
        cat > /tmp/iceman-cachy-repos.conf <<'EOF_REPOS'
[cachyos-znver4]
Include = /etc/pacman.d/cachyos-v4-mirrorlist

[cachyos-core-znver4]
Include = /etc/pacman.d/cachyos-v4-mirrorlist

[cachyos-extra-znver4]
Include = /etc/pacman.d/cachyos-v4-mirrorlist
EOF_REPOS
    else
        cat > /tmp/iceman-cachy-repos.conf <<'EOF_REPOS'
[cachyos-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist

[cachyos-core-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist

[cachyos-extra-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist
EOF_REPOS
    fi
    ok "CachyOS preparado para $CACHY_FLAVOR."
}

show_disks() {
    printf '\nDiscos completos:\n'
    lsblk -e7 -d -o PATH,SIZE,MODEL,TRAN,RM,RO,TYPE
    printf '\nParticiones y montajes:\n'
    lsblk -e7 -o PATH,SIZE,FSTYPE,LABEL,MODEL,TRAN,RM,MOUNTPOINTS
}

select_disk() {
    section "5/13 — DISCO DESTINO"
    show_disks
    read_tty $'\nEscribe el disco COMPLETO que quieres borrar (ej. /dev/nvme0n1): ' TARGET_DISK || die "No se pudo leer el disco."
    [[ -b "$TARGET_DISK" ]] || die "El dispositivo no existe: $TARGET_DISK"
    [[ "$TARGET_DISK" =~ ^/dev/(nvme[0-9]+n[0-9]+|sd[a-z]+|vd[a-z]+|mmcblk[0-9]+)$ ]] || die "Ruta de disco no válida: $TARGET_DISK"

    local live_source
    live_source="$(findmnt -no SOURCE / 2>/dev/null || true)"
    if [[ -n "$live_source" ]] && lsblk -nrpo NAME "$TARGET_DISK" | grep -Fxq "$live_source"; then
        die "Has seleccionado el disco que contiene el sistema live. No se puede borrar."
    fi

    printf '\nDISCO SELECCIONADO:\n'
    lsblk -d -o PATH,SIZE,MODEL,TRAN,RM "$TARGET_DISK"
    printf '\nTODO el contenido de este disco será destruido.\n'
    local confirm
    read_tty "Escribe exactamente BORRAR para continuar: " confirm || die "Cancelado."
    [[ "$confirm" == "BORRAR" ]] || die "No se escribió BORRAR. No se ha tocado el disco."
}

user_setup_input() {
    section "6/13 — USUARIO"
    while :; do
        read_tty "Nombre de usuario Linux: " USERNAME || die "No se pudo leer el usuario."
        [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || { warn "Nombre no válido."; continue; }
        [[ "$USERNAME" != root ]] || { warn "No uses root."; continue; }
        break
    done
    while :; do
        local p2
        read_secret "Contraseña: " USER_PASSWORD || die "No se pudo leer la contraseña."
        read_secret "Repite la contraseña: " p2 || die "No se pudo leer la contraseña."
        [[ -n "$USER_PASSWORD" ]] || { warn "La contraseña no puede estar vacía."; continue; }
        [[ "$USER_PASSWORD" == "$p2" ]] || { warn "Las contraseñas no coinciden."; unset p2; continue; }
        unset p2
        break
    done
}

partition_disk() {
    section "7/13 — PARTICIONADO + BTRFS"
    DISK_TOUCHED=1
    swapoff -a >/dev/null 2>&1 || true
    umount -R "$MNT" >/dev/null 2>&1 || true

    sgdisk --zap-all "$TARGET_DISK"
    wipefs -a "$TARGET_DISK"
    sgdisk \
        -n 1:1MiB:+1GiB -t 1:ef00 -c 1:EFI \
        -n 2:0:0       -t 2:8300 -c 2:ARCH-BTRFS \
        "$TARGET_DISK"
    partprobe "$TARGET_DISK"
    sleep 2

    if [[ "$TARGET_DISK" == /dev/nvme* || "$TARGET_DISK" == /dev/mmcblk* ]]; then
        EFI_PART="${TARGET_DISK}p1"
        ROOT_PART="${TARGET_DISK}p2"
    else
        EFI_PART="${TARGET_DISK}1"
        ROOT_PART="${TARGET_DISK}2"
    fi

    [[ -b "$EFI_PART" && -b "$ROOT_PART" ]] || die "No se pudieron localizar las particiones creadas."

    mkfs.fat -F32 -n EFI "$EFI_PART"
    mkfs.btrfs -f -L ARCH "$ROOT_PART"

    mkdir -p "$MNT"
    mount -o noatime,compress=zstd:3,discard=async "$ROOT_PART" "$MNT"
    btrfs subvolume create "$MNT/@"
    btrfs subvolume create "$MNT/@home"
    umount "$MNT"

    mount -o subvol=@,noatime,compress=zstd:3,discard=async "$ROOT_PART" "$MNT"
    mkdir -p "$MNT/home" "$ESP_MNT"
    mount -o subvol=@home,noatime,compress=zstd:3,discard=async "$ROOT_PART" "$MNT/home"
    mount "$EFI_PART" "$ESP_MNT"

    ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
    EFI_UUID="$(blkid -s UUID -o value "$EFI_PART")"
    [[ -n "$ROOT_UUID" && -n "$EFI_UUID" ]] || die "No se pudieron obtener los UUID de las particiones."
    ok "GPT + ESP + Btrfs preparados."
}

install_base() {
    section "8/13 — ARCH BASE"
    local microcode=""
    if [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
        microcode=amd-ucode
    else
        microcode=intel-ucode
    fi

    pacstrap -K "$MNT" \
        base linux-firmware "$microcode" \
        btrfs-progs dosfstools sudo networkmanager \
        curl git nano \
        tzdata glibc dbus

    # Insert Cachy repositories into the target pacman configuration.
    arch-chroot "$MNT" pacman-key --init
    arch-chroot "$MNT" pacman-key --recv-keys "$CACHY_KEY" --keyserver "$CACHY_KEYSERVER"
    arch-chroot "$MNT" pacman-key --lsign-key "$CACHY_KEY"
    arch-chroot "$MNT" pacman -U --noconfirm "$CACHY_KEYRING_URL" "$CACHY_MIRRORLIST_URL" "$CACHY_OPT_MIRRORLIST_URL"

    cp -a "$MNT/etc/pacman.conf" "$MNT/etc/pacman.conf.iceman-backup"
    awk -v repo_file=/tmp/iceman-cachy-repos.conf '
        BEGIN { inserted=0 }
        /^\[core\]$/ && !inserted {
            while ((getline line < repo_file) > 0) print line
            close(repo_file)
            print ""
            inserted=1
        }
        { print }
    ' "$MNT/etc/pacman.conf" > /tmp/iceman-pacman.conf
    mv /tmp/iceman-pacman.conf "$MNT/etc/pacman.conf"

    # The repo list is now present in the target; sync the full system.
    arch-chroot "$MNT" pacman -Syyu --noconfirm

    ok "Base Arch + CachyOS preparados."
}

install_kernel() {
    section "9/13 — KERNEL CACHYOS"
    arch-chroot "$MNT" pacman -S --needed --noconfirm linux-cachyos
    arch-chroot "$MNT" pacman -Rns --noconfirm linux linux-headers >/dev/null 2>&1 || true
    ok "linux-cachyos instalado."
}

install_desktop_and_gaming() {
    section "10/13 — KDE + AMD + AUDIO + GAMING"
    local packages=(
        plasma-meta sddm
        dolphin konsole kate ark spectacle gwenview okular
        kdeconnect kde-gtk-config kio-extras kdegraphics-thumbnailers ffmpegthumbs
        xdg-user-dirs xdg-utils xdg-desktop-portal xdg-desktop-portal-kde breeze-gtk

        mesa vulkan-radeon vulkan-icd-loader
        lib32-mesa lib32-vulkan-radeon lib32-vulkan-icd-loader
        libva-mesa-driver mesa-vdpau vulkan-tools

        pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber
        alsa-utils alsa-ucm-conf pavucontrol lib32-pipewire lib32-libpulse

        bluez bluez-utils fwupd power-profiles-daemon zram-generator
        snapper btrfs-assistant snap-pac
        firewalld plasma-firewall

        steam steam-devices
        gamemode lib32-gamemode
        mangohud lib32-mangohud
        gamescope
        wine wine-gecko wine-mono winetricks lutris

        retroarch dolphin-emu
        noto-fonts noto-fonts-emoji
    )

    arch-chroot "$MNT" pacman -S --needed --noconfirm "${packages[@]}"
    ok "KDE Plasma, Mesa/RADV, PipeWire, Steam, Wine/Lutris, emulación y utilidades instalados."
}

configure_system() {
    section "11/13 — CONFIGURACIÓN"
    local target_user="$USERNAME"

    arch-chroot "$MNT" useradd --create-home --shell /bin/bash --groups wheel "$target_user"
    printf '%s:%s\n' "$target_user" "$USER_PASSWORD" | arch-chroot "$MNT" chpasswd
    unset USER_PASSWORD

    cat > "$MNT/etc/sudoers.d/10-wheel" <<'EOF_SUDO'
%wheel ALL=(ALL:ALL) ALL
EOF_SUDO
    chmod 0440 "$MNT/etc/sudoers.d/10-wheel"
    arch-chroot "$MNT" visudo -cf /etc/sudoers

    arch-chroot "$MNT" ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
    arch-chroot "$MNT" hwclock --systohc
    sed -i 's/^#\(es_ES.UTF-8 UTF-8\)/\1/' "$MNT/etc/locale.gen"
    sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' "$MNT/etc/locale.gen"
    arch-chroot "$MNT" locale-gen

    cat > "$MNT/etc/locale.conf" <<'EOF_LOCALE'
LANG=es_ES.UTF-8
LC_TIME=es_ES.UTF-8
EOF_LOCALE
    cat > "$MNT/etc/vconsole.conf" <<'EOF_VC'
KEYMAP=es
EOF_VC
    cat > "$MNT/etc/hostname" <<'EOF_HOST'
iceman-pc
EOF_HOST
    cat > "$MNT/etc/hosts" <<'EOF_HOSTS'
127.0.0.1 localhost
::1 localhost
127.0.1.1 iceman-pc.localdomain iceman-pc
EOF_HOSTS

    cat > "$MNT/etc/systemd/zram-generator.conf" <<'EOF_ZRAM'
[zram0]
zram-size = min(ram / 4, 8192)
compression-algorithm = zstd
swap-priority = 100
EOF_ZRAM

    arch-chroot "$MNT" snapper -c root create-config /
    chmod 750 "$MNT/.snapshots"

    arch-chroot "$MNT" systemctl enable NetworkManager
    arch-chroot "$MNT" systemctl enable bluetooth
    arch-chroot "$MNT" systemctl enable sddm
    arch-chroot "$MNT" systemctl enable firewalld
    arch-chroot "$MNT" systemctl enable power-profiles-daemon
    arch-chroot "$MNT" systemctl enable fstrim.timer
    arch-chroot "$MNT" systemctl enable snapper-timeline.timer snapper-cleanup.timer
    arch-chroot "$MNT" systemctl set-default graphical.target

    arch-chroot "$MNT" runuser -u "$target_user" -- xdg-user-dirs-update || true
    arch-chroot "$MNT" passwd -l root >/dev/null 2>&1 || true

    # Let SDDM/KDE choose the usable Wayland session without forcing a display server
    # in a way that could make a future Plasma/SDDM transition unbootable.
    ok "Locale, usuario, zram, Snapper y servicios configurados."
}

write_fstab_and_boot() {
    section "12/13 — FSTAB + SYSTEMD-BOOT + INITRAMFS"

    genfstab -U "$MNT" > "$MNT/etc/fstab"
    grep -qE "^[^#]+[[:space:]]+/[[:space:]]+btrfs" "$MNT/etc/fstab" || die "fstab no contiene / como Btrfs."
    grep -qE "^[^#]+[[:space:]]+/home[[:space:]]+btrfs" "$MNT/etc/fstab" || die "fstab no contiene /home como Btrfs."
    grep -qE "^[^#]+[[:space:]]+/boot[[:space:]]+vfat" "$MNT/etc/fstab" || die "fstab no contiene /boot como ESP."

    # systemd-boot needs the kernel/initramfs on the ESP or XBOOTLDR. Here /boot IS the ESP.
    arch-chroot -S "$MNT" bootctl --esp-path=/boot install
    arch-chroot "$MNT" mkinitcpio -P

    [[ -s "$MNT/boot/vmlinuz-linux-cachyos" ]] || die "Falta /boot/vmlinuz-linux-cachyos."
    [[ -s "$MNT/boot/initramfs-linux-cachyos.img" ]] || die "Falta initramfs-linux-cachyos.img."
    [[ -s "$MNT/boot/initramfs-linux-cachyos-fallback.img" ]] || die "Falta initramfs fallback de CachyOS."
    [[ -s "$MNT/boot/amd-ucode.img" ]] || [[ "$CPU_VENDOR" != "AuthenticAMD" ]] || die "Falta amd-ucode.img."

    mkdir -p "$ESP_MNT/loader/entries"
    cat > "$ESP_MNT/loader/loader.conf" <<'EOF_LOADER'
default iceman-cachyos.conf
timeout 4
editor no
console-mode auto
EOF_LOADER

    cat > "$ESP_MNT/loader/entries/iceman-cachyos.conf" <<EOF_ENTRY
title   Iceman Arch + CachyOS KDE
linux   /vmlinuz-linux-cachyos
EOF_ENTRY
    if [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
        cat >> "$ESP_MNT/loader/entries/iceman-cachyos.conf" <<EOF_AMD
initrd  /amd-ucode.img
EOF_AMD
    else
        cat >> "$ESP_MNT/loader/entries/iceman-cachyos.conf" <<EOF_INTEL
initrd  /intel-ucode.img
EOF_INTEL
    fi
    cat >> "$ESP_MNT/loader/entries/iceman-cachyos.conf" <<EOF_ROOT
initrd  /initramfs-linux-cachyos.img
options root=UUID=$ROOT_UUID rootflags=subvol=@ rw
EOF_ROOT

    cat > "$ESP_MNT/loader/entries/iceman-cachyos-fallback.conf" <<EOF_FALL
title   Iceman Arch + CachyOS KDE (fallback)
linux   /vmlinuz-linux-cachyos
EOF_FALL
    if [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
        echo 'initrd  /amd-ucode.img' >> "$ESP_MNT/loader/entries/iceman-cachyos-fallback.conf"
    else
        echo 'initrd  /intel-ucode.img' >> "$ESP_MNT/loader/entries/iceman-cachyos-fallback.conf"
    fi
    cat >> "$ESP_MNT/loader/entries/iceman-cachyos-fallback.conf" <<EOF_FALLROOT
initrd  /initramfs-linux-cachyos-fallback.img
options root=UUID=$ROOT_UUID rootflags=subvol=@ rw
EOF_FALLROOT

    arch-chroot -S "$MNT" bootctl --esp-path=/boot update
    arch-chroot -S "$MNT" bootctl --esp-path=/boot status
    ok "fstab, systemd-boot, kernel e initramfs verificados."
}

final_validation() {
    section "13/13 — VALIDACIÓN FINAL, SIN REINICIO AUTOMÁTICO"
    local fail=0
    check() {
        local label="$1"; shift
        if "$@"; then ok "$label"; else warn "FALLO: $label"; fail=$((fail+1)); fi
    }

    check "raíz Btrfs" findmnt -no FSTYPE "$MNT"
    check "raíz subvol @" bash -c "findmnt -no OPTIONS '$MNT' | grep -q 'subvol=@'"
    check "home subvol @home" bash -c "findmnt -no OPTIONS '$MNT/home' | grep -q 'subvol=@home'"
    check "ESP en /boot" mountpoint -q "$ESP_MNT"
    check "fstab válido" test -s "$MNT/etc/fstab"
    check "usuario creado" arch-chroot "$MNT" id "$USERNAME"
    check "sudoers válido" arch-chroot "$MNT" visudo -cf /etc/sudoers
    check "KDE + SDDM" arch-chroot "$MNT" pacman -Q plasma-meta sddm
    check "AMD Vulkan 64/32" arch-chroot "$MNT" pacman -Q vulkan-radeon lib32-vulkan-radeon
    check "PipeWire" arch-chroot "$MNT" pacman -Q pipewire pipewire-pulse wireplumber
    check "Steam" arch-chroot "$MNT" pacman -Q steam
    check "Wine/Lutris" arch-chroot "$MNT" pacman -Q wine lutris
    check "GameMode/MangoHud" arch-chroot "$MNT" pacman -Q gamemode mangohud
    check "Snapper" arch-chroot "$MNT" snapper -c root list-configs
    check "Kernel CachyOS" test -s "$MNT/boot/vmlinuz-linux-cachyos"
    check "initramfs CachyOS" test -s "$MNT/boot/initramfs-linux-cachyos.img"
    check "initramfs fallback" test -s "$MNT/boot/initramfs-linux-cachyos-fallback.img"
    if [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
        check "microcódigo AMD" test -s "$MNT/boot/amd-ucode.img"
    fi
    check "entrada systemd-boot" test -s "$ESP_MNT/loader/entries/iceman-cachyos.conf"
    check "entrada fallback systemd-boot" test -s "$ESP_MNT/loader/entries/iceman-cachyos-fallback.conf"
    check "repo CachyOS" arch-chroot "$MNT" pacman -Si linux-cachyos

    if (( fail > 0 )); then
        die "$fail comprobaciones finales han fallado. NO se reiniciará."
    fi

    cat > "$MNT/root/iceman-final-report.txt" <<EOF_REPORT
ICEMAN INSTALL — INFORME FINAL
Fecha: $(date -Is)

Hardware detectado:
CPU: $CPU_MODEL
CPU vendor: $CPU_VENDOR
RAM: ${RAM_GIB} GiB
GPU PCI: ${GPU_PCI_ID:-desconocido}
GPU driver detectado en live: ${GPU_DRIVER:-no cargado}
CachyOS flavor: $CACHY_FLAVOR

Disco instalado:
$TARGET_DISK

Sistema:
Arch Linux + CachyOS optimized repositories + KDE Plasma
Btrfs: @ + @home
Boot: systemd-boot, ESP montada en /boot
Kernel: linux-cachyos
Microcode: ${microcode:-auto}

Gaming:
Steam, GameMode, MangoHud, Gamescope, Wine, Lutris
Emulación: RetroArch, Dolphin
EOF_REPORT
    sync
    ok "TODAS las comprobaciones finales han pasado."
}

finish() {
    printf '\n============================================================\n'
    printf ' INSTALACIÓN COMPLETADA\n'
    printf '============================================================\n'
    printf 'Sistema: Arch Linux + CachyOS + KDE Plasma\n'
    printf 'GPU: AMD detectada por PCI; stack Mesa/RADV instalado\n'
    printf 'Kernel: linux-cachyos (%s)\n' "$CACHY_FLAVOR"
    printf 'Disco: %s\n' "$TARGET_DISK"
    printf 'Usuario: %s\n' "$USERNAME"
    printf '\nNO se reinicia automáticamente. Retira el USB y pulsa ENTER.\n'
    printf 'Log live: %s\n' "$LOG_FILE"
    printf 'Informe instalado: /root/iceman-final-report.txt\n'
    local dummy
    read_tty "" dummy || true
}

main() {
    clear || true
    printf '============================================================\n'
    printf '       ICEMAN ARCH + CACHYOS KDE GAMING INSTALLER\n'
    printf '============================================================\n'
    printf 'Detección: capacidades CPU + vendor PCI, no nombre comercial.\n'
    printf 'El disco seleccionado SERÁ BORRADO.\n'

    hardware_detect
    network_check
    preflight_tools
    install_cachyos_repos
    select_disk
    user_setup_input
    partition_disk
    install_base
    install_kernel
    install_desktop_and_gaming
    configure_system
    write_fstab_and_boot
    final_validation
    finish
}

main "$@"
