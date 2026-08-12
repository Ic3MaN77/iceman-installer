#!/usr/bin/env bash
#
# Iceman Installer - Arch Linux + CachyOS repositories + KDE Plasma + AMD Gaming
# TARGET HARDWARE:
#   Gigabyte B550 AORUS ELITE V2
#   AMD Ryzen 9 5950X
#   32 GiB RAM
#   AMD Radeon RX 7600 XT 16 GiB
#   UEFI / GPT / NVMe / Btrfs / systemd-boot
#
# Run from the official Arch Linux ISO as root.
# Supported invocation:
#   curl -fsSL https://raw.githubusercontent.com/Ic3MaN77/iceman-installer/main/kde.sh | bash
#
# WARNING: this installer ERASES the selected disk.
#
set -Eeuo pipefail
umask 022
export LC_ALL=C
export LANG=C

readonly MNT=/mnt
readonly EFI_MNT=/mnt/boot
readonly LOG_FILE="/tmp/iceman-kde-$(date +%Y%m%d-%H%M%S).log"
readonly CACHY_KEY="F3B607488DB35A47"
readonly CACHY_BASE_URL="https://mirror.cachyos.org/repo/x86_64/cachyos"
readonly CACHY_KEYRING_URL="${CACHY_BASE_URL}/cachyos-keyring-20240331-1-any.pkg.tar.zst"
readonly CACHY_MIRRORLIST_URL="${CACHY_BASE_URL}/cachyos-mirrorlist-27-1-any.pkg.tar.zst"
readonly CACHY_V3_MIRRORLIST_URL="${CACHY_BASE_URL}/cachyos-v3-mirrorlist-27-1-any.pkg.tar.zst"

TARGET_DISK=""
EFI_PART=""
ROOT_PART=""
ROOT_UUID=""
EFI_UUID=""
USERNAME=""
USER_PASSWORD=""
STARTED=0
CLEANED=0

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

cleanup() {
    local rc=$?
    set +e
    if (( CLEANED == 0 )); then
        sync
        if [[ -d "$MNT" ]]; then
            umount -R "$MNT" >/dev/null 2>&1 || true
        fi
        CLEANED=1
    fi
    if (( rc != 0 )); then
        cp -f "$LOG_FILE" /root/iceman-kde-error.log >/dev/null 2>&1 || true
        printf '\nLa instalación terminó con ERROR (código %s).\n' "$rc"
        printf 'Log: /root/iceman-kde-error.log\n'
        printf 'NO reinicio automáticamente.\n'
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

tty_read() {
    local prompt="$1"
    local __var="$2"
    local value
    if [[ -r /dev/tty ]]; then
        IFS= read -r -p "$prompt" value < /dev/tty || return 1
    else
        IFS= read -r -p "$prompt" value || return 1
    fi
    printf -v "$__var" '%s' "$value"
}
tty_secret() {
    local prompt="$1"
    local __var="$2"
    local value
    if [[ -r /dev/tty ]]; then
        IFS= read -r -s -p "$prompt" value < /dev/tty || return 1
    else
        IFS= read -r -s -p "$prompt" value || return 1
    fi
    printf '\n'
    printf -v "$__var" '%s' "$value"
}

hardware_preflight() {
    section "1/14 - COMPROBACIÓN DEL EQUIPO"

    [[ $EUID -eq 0 ]] || die "Debes ejecutar el instalador como root."
    [[ $(uname -m) == x86_64 ]] || die "Este instalador requiere x86_64."
    [[ -d /sys/firmware/efi/efivars ]] || die "El ISO no está arrancado en UEFI."
    systemd-detect-virt --quiet 2>/dev/null && die "Se ha detectado una máquina virtual. Este instalador está diseñado para METAL."
    for c in pacman pacstrap arch-chroot genfstab lsblk sgdisk wipefs mkfs.btrfs mkfs.fat mount umount partprobe blkid lscpu lspci dmidecode; do need "$c"; done

    local cpu board gpu ram
    cpu="$(lscpu | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    board="$(dmidecode -s baseboard-product-name 2>/dev/null || true)"
    gpu="$(lspci -nn | grep -Ei 'VGA compatible controller|3D controller|Display controller' | grep -Ei 'AMD|ATI|Radeon' | head -n1 || true)"
    ram="$(awk '/MemTotal/{printf "%.0f", $2/1024/1024}' /proc/meminfo)"

    printf 'CPU:         %s\n' "$cpu"
    printf 'Placa:       %s\n' "$board"
    printf 'GPU:         %s\n' "${gpu:-NO DETECTADA}"
    printf 'RAM:         %s GiB\n' "$ram"

    grep -qi 'Ryzen 9 5950X' <<<"$cpu" || die "CPU incorrecta. Este instalador está bloqueado para Ryzen 9 5950X."
    grep -qi 'B550 AORUS ELITE V2' <<<"$board" || die "Placa base incorrecta. Se esperaba Gigabyte B550 AORUS ELITE V2."
    grep -qi 'RX 7600 XT' <<<"$gpu" || die "GPU incorrecta. Se esperaba Radeon RX 7600 XT."
    (( ram >= 30 )) || die "Se esperaban aproximadamente 32 GiB de RAM."

    ok "Hardware objetivo confirmado."
}

network_preflight() {
    section "2/14 - INTERNET"

    local test_url="https://archlinux.org"
    if curl -4fsS --connect-timeout 5 --max-time 15 "$test_url" >/dev/null; then
        ok "Internet funcionando."
        return
    fi

    warn "No hay Internet. Voy a intentar levantar iwd para Wi-Fi."
    if command -v iwctl >/dev/null 2>&1; then
        systemctl start iwd >/dev/null 2>&1 || true
        sleep 2
        local ifaces
        mapfile -t ifaces < <(iw dev 2>/dev/null | awk '$1=="Interface"{print $2}')
        if (( ${#ifaces[@]} > 0 )); then
            local iface="${ifaces[0]}" ssid password
            iwctl station "$iface" scan >/dev/null 2>&1 || true
            iwctl station "$iface" get-networks || true
            tty_read "SSID Wi-Fi: " ssid || die "No se pudo leer el SSID."
            [[ -n "$ssid" ]] || die "SSID vacío."
            tty_secret "Contraseña Wi-Fi: " password || die "No se pudo leer la contraseña."
            iwctl station "$iface" connect "$ssid" <<<"$password" || die "No se pudo conectar al Wi-Fi."
            unset password
            sleep 5
        fi
    fi

    curl -4fsS --connect-timeout 5 --max-time 15 "$test_url" >/dev/null ||
        die "No hay Internet. Conecta Ethernet o Wi-Fi y vuelve a ejecutar el instalador."
    ok "Internet funcionando."
}

live_update() {
    section "3/14 - ENTORNO LIVE Y LLAVES ARCH"

    # Arch does not support partial upgrades. The live environment is fully updated
    # before packages are queried/installed.
    pacman -Syu --noconfirm
    pacman -S --needed --noconfirm \
        archlinux-keyring \
        curl \
        git \
        dosfstools \
        btrfs-progs \
        gptfdisk \
        e2fsprogs \
        networkmanager \
        iwd
    ok "Entorno live actualizado y herramientas disponibles."
}


preflight_packages() {
    section "4/14 - COMPROBACIÓN DE PAQUETES"

    local packages=(
        base linux-firmware amd-ucode btrfs-progs dosfstools e2fsprogs
        sudo networkmanager git curl wget nano pciutils usbutils dmidecode smartmontools
        tzdata glibc efibootmgr systemd mkinitcpio dbus
        plasma-meta sddm dolphin konsole kate ark spectacle gwenview okular
        kdeconnect kde-gtk-config kio-extras kdegraphics-thumbnailers ffmpegthumbs
        xdg-user-dirs xdg-utils xdg-desktop-portal xdg-desktop-portal-kde breeze-gtk
        mesa vulkan-radeon vulkan-icd-loader lib32-mesa lib32-vulkan-radeon
        lib32-vulkan-icd-loader libva-mesa-driver mesa-vdpau vulkan-tools
        pipewire pipewire-alsa pipewire-pulse pipewire-jack wireplumber
        alsa-utils alsa-ucm-conf rtkit pavucontrol lib32-pipewire lib32-libpulse
        bluez bluez-utils fwupd power-profiles-daemon zram-generator
        snapper btrfs-assistant snap-pac firewalld plasma-firewall
        steam steam-devices gamemode lib32-gamemode mangohud lib32-mangohud
        gamescope wine wine-gecko wine-mono winetricks lutris
        retroarch dolphin-emu fastfetch htop noto-fonts noto-fonts-emoji
    )

    local pkg missing=()
    for pkg in "${packages[@]}"; do
        if pacman -Si "$pkg" >/dev/null 2>&1; then
            printf '  [ OK ] %s\n' "$pkg"
        else
            printf '  [FALTA] %s\n' "$pkg"
            missing+=("$pkg")
        fi
    done

    (( ${#missing[@]} == 0 )) ||
        die "Hay paquetes oficiales que no están disponibles: ${missing[*]}"

    ok "Todos los paquetes Arch requeridos están disponibles."
}

cachyos_preflight() {
    section "5/14 - COMPROBACIÓN CACHYOS"

    pacman-key --init >/dev/null 2>&1 || true
    pacman-key --recv-keys "$CACHY_KEY" --keyserver keyserver.ubuntu.com
    pacman-key --lsign-key "$CACHY_KEY"

    local url
    for url in "$CACHY_KEYRING_URL" "$CACHY_MIRRORLIST_URL" "$CACHY_V3_MIRRORLIST_URL"; do
        curl -4fsSL --connect-timeout 10 --max-time 30 -o /dev/null "$url" ||
            die "No se puede descargar el componente CachyOS: $url"
    done

    ok "Clave CachyOS y componentes v3 accesibles."
}

show_disks() {
    printf '\nDiscos detectados:\n'
    lsblk -e7 -d -o NAME,PATH,SIZE,MODEL,TRAN,RM,TYPE
    printf '\nParticiones y montajes:\n'
    lsblk -e7 -o NAME,PATH,SIZE,FSTYPE,LABEL,MODEL,MOUNTPOINTS
}

select_disk() {
    section "6/14 - SELECCIÓN DEL NVMe"

    show_disks
    tty_read $'\nEscribe el disco COMPLETO que quieres borrar (ej. /dev/nvme0n1): ' TARGET_DISK || die "No se pudo leer el disco."
    [[ "$TARGET_DISK" =~ ^/dev/(nvme[0-9]+n[0-9]+|sd[a-z]+|vd[a-z]+)$ ]] ||
        die "Ruta de disco no válida: $TARGET_DISK"
    [[ -b "$TARGET_DISK" ]] || die "El dispositivo no existe: $TARGET_DISK"

    local live_root
    live_root="$(findmnt -no SOURCE / 2>/dev/null || true)"
    if [[ -n "$live_root" ]] && lsblk -nrpo NAME "$TARGET_DISK" | grep -Fxq "$live_root"; then
        die "El disco seleccionado contiene el sistema live. NO se puede borrar."
    fi

    printf '\nHas seleccionado: %s\n' "$TARGET_DISK"
    lsblk -d -o NAME,PATH,SIZE,MODEL,TRAN "$TARGET_DISK"
    printf '\nATENCIÓN: TODO EL CONTENIDO DE ESTE DISCO SERÁ BORRADO.\n'
    local confirm
    tty_read "Escribe exactamente BORRAR para continuar: " confirm || die "Cancelado."
    [[ "$confirm" == "BORRAR" ]] || die "No se ha escrito BORRAR. No se ha tocado ningún disco."
}

user_preflight() {
    section "7/14 - USUARIO"

    while :; do
        tty_read "Nombre de usuario Linux: " USERNAME || die "No se pudo leer el usuario."
        [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || { warn "Nombre no válido."; continue; }
        [[ "$USERNAME" != root ]] || { warn "No uses root."; continue; }
        break
    done

    while :; do
        local p2
        tty_secret "Contraseña: " USER_PASSWORD || die "No se pudo leer la contraseña."
        tty_secret "Repite la contraseña: " p2 || die "No se pudo leer la contraseña."
        [[ -n "$USER_PASSWORD" ]] || { warn "La contraseña no puede estar vacía."; continue; }
        [[ "$USER_PASSWORD" == "$p2" ]] || { warn "Las contraseñas no coinciden."; unset p2; continue; }
        unset p2
        break
    done
}

partition_and_format() {
    section "8/14 - PARTICIONADO Y BTRFS"

    STARTED=1
    swapoff -a >/dev/null 2>&1 || true
    umount -R "$MNT" >/dev/null 2>&1 || true

    sgdisk --zap-all "$TARGET_DISK"
    wipefs -a "$TARGET_DISK"
    sgdisk \
        -n 1:1MiB:+1GiB -t 1:ef00 -c 1:EFI \
        -n 2:0:0 -t 2:8300 -c 2:ARCH-BTRFS \
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
    mkdir -p "$MNT/home" "$EFI_MNT"
    mount -o subvol=@home,noatime,compress=zstd:3,discard=async "$ROOT_PART" "$MNT/home"
    mkdir -p "$EFI_MNT"
    mount "$EFI_PART" "$EFI_MNT"

    ROOT_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
    EFI_UUID="$(blkid -s UUID -o value "$EFI_PART")"
    [[ -n "$ROOT_UUID" && -n "$EFI_UUID" ]] || die "No se pudieron obtener los UUID."

    ok "GPT, EFI y Btrfs preparados."
}

write_base_config() {
    section "9/14 - SISTEMA BASE"

    cat > "$MNT/etc/fstab" <<EOF
UUID=$ROOT_UUID / btrfs subvol=@,noatime,compress=zstd:3,discard=async 0 0
UUID=$ROOT_UUID /home btrfs subvol=@home,noatime,compress=zstd:3,discard=async 0 0
UUID=$EFI_UUID /boot vfat umask=0077 0 2
EOF

    arch-chroot "$MNT" ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime
    arch-chroot "$MNT" hwclock --systohc

    sed -i 's/^#\(es_ES.UTF-8 UTF-8\)/\1/' "$MNT/etc/locale.gen"
    sed -i 's/^#\(en_US.UTF-8 UTF-8\)/\1/' "$MNT/etc/locale.gen"
    arch-chroot "$MNT" locale-gen
    cat > "$MNT/etc/locale.conf" <<'EOF'
LANG=es_ES.UTF-8
LC_TIME=es_ES.UTF-8
EOF
    cat > "$MNT/etc/vconsole.conf" <<'EOF'
KEYMAP=es
EOF

    cat > "$MNT/etc/hostname" <<'EOF'
iceman-pc
EOF
    cat > "$MNT/etc/hosts" <<'EOF'
127.0.0.1 localhost
::1 localhost
127.0.1.1 iceman-pc.localdomain iceman-pc
EOF

    ok "fstab, zona horaria, locale y hostname configurados."
}

install_arch_base() {
    section "10/14 - PAQUETES BASE ARCH"

    local packages=(
        base
        linux-firmware amd-ucode
        btrfs-progs dosfstools e2fsprogs
        sudo networkmanager
        git curl wget nano
        pciutils usbutils dmidecode smartmontools
        tzdata glibc
        efibootmgr
        systemd
        mkinitcpio
        dbus
    )

    pacstrap -K "$MNT" "${packages[@]}"
    ok "Base Arch instalada."
}

install_cachyos_repositories() {
    section "11/14 - REPOSITORIOS CACHYOS x86-64-v3"

    # Ryzen 9 5950X = Zen 3. It is x86-64-v3 capable, not Zen4/znver4.
    # We deliberately do NOT install the CachyOS 'cachyos' repo because that
    # also replaces pacman with CachyOS's fork. The optimized v3 repositories
    # are sufficient for this machine and are explicitly documented by CachyOS.
    arch-chroot "$MNT" pacman-key --init
    arch-chroot "$MNT" pacman-key --recv-keys "$CACHY_KEY" --keyserver keyserver.ubuntu.com
    arch-chroot "$MNT" pacman-key --lsign-key "$CACHY_KEY"

    arch-chroot "$MNT" pacman -U --noconfirm \
        "$CACHY_KEYRING_URL" \
        "$CACHY_MIRRORLIST_URL" \
        "$CACHY_V3_MIRRORLIST_URL"

    cat > "$MNT/etc/pacman.conf" <<'EOF'
[options]
Architecture = auto
CheckSpace
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional
Color
ParallelDownloads = 5

[cachyos-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist

[cachyos-core-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist

[cachyos-extra-v3]
Include = /etc/pacman.d/cachyos-v3-mirrorlist

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF

    arch-chroot "$MNT" pacman -Syu --noconfirm
    arch-chroot "$MNT" pacman -S --needed --noconfirm linux-cachyos linux-cachyos-headers
    arch-chroot "$MNT" pacman -Rns --noconfirm linux linux-headers >/dev/null 2>&1 || true

    ok "Repositorios CachyOS v3 y kernel linux-cachyos instalados."
}

install_desktop_gaming() {
    section "12/14 - KDE, AMD, AUDIO Y GAMING"

    local packages=(
        # KDE Plasma
        plasma-meta sddm
        dolphin konsole kate ark
        spectacle gwenview okular
        kdeconnect kde-gtk-config
        kio-extras kdegraphics-thumbnailers ffmpegthumbs
        xdg-user-dirs xdg-utils
        xdg-desktop-portal xdg-desktop-portal-kde
        breeze-gtk

        # AMD / Mesa / Vulkan / video
        mesa vulkan-radeon vulkan-icd-loader
        lib32-mesa lib32-vulkan-radeon lib32-vulkan-icd-loader
        libva-mesa-driver mesa-vdpau
        vulkan-tools

        # Audio
        pipewire pipewire-alsa pipewire-pulse pipewire-jack
        wireplumber alsa-utils alsa-ucm-conf rtkit pavucontrol
        lib32-pipewire lib32-libpulse

        # Network / firmware
        bluez bluez-utils fwupd

        # Power / memory
        power-profiles-daemon zram-generator

        # Btrfs
        snapper btrfs-assistant snap-pac

        # Security
        firewalld plasma-firewall

        # Gaming
        steam steam-devices
        gamemode lib32-gamemode
        mangohud lib32-mangohud
        gamescope
        wine wine-gecko wine-mono
        winetricks lutris

        # Emulation
        retroarch dolphin-emu

        # Useful basic tools
        fastfetch htop
        noto-fonts noto-fonts-emoji
    )

    arch-chroot "$MNT" pacman -S --needed --noconfirm "${packages[@]}"
    ok "KDE, AMD/Mesa/RADV, PipeWire, gaming y emulación instalados."
}

configure_system() {
    section "13/14 - CONFIGURACIÓN FINAL"

    arch-chroot "$MNT" useradd --create-home --shell /bin/bash \
        --groups wheel,audio,video,gamemode "$USERNAME"
    printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD" | arch-chroot "$MNT" chpasswd
    unset USER_PASSWORD

    cat > "$MNT/etc/sudoers.d/10-wheel" <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF
    chmod 0440 "$MNT/etc/sudoers.d/10-wheel"
    arch-chroot "$MNT" visudo -cf /etc/sudoers

    cat > "$MNT/etc/systemd/zram-generator.conf" <<'EOF'
[zram0]
zram-size = min(ram / 4, 8192)
compression-algorithm = zstd
swap-priority = 100
EOF

    # Do not force an experimental Wi-Fi backend. NetworkManager manages Wi-Fi.
    # Snapper: create-config MUST create the .snapshots subvolume itself.
    # We intentionally do not pre-create/mount a separate @snapshots volume.
    arch-chroot "$MNT" snapper -c root create-config /
    chmod 750 "$MNT/.snapshots"
    arch-chroot "$MNT" systemctl enable snapper-timeline.timer snapper-cleanup.timer

    arch-chroot "$MNT" systemctl enable NetworkManager
    arch-chroot "$MNT" systemctl enable bluetooth
    arch-chroot "$MNT" systemctl enable sddm
    arch-chroot "$MNT" systemctl enable firewalld
    arch-chroot "$MNT" systemctl enable power-profiles-daemon
    arch-chroot "$MNT" systemctl enable fstrim.timer

    # Steam/GameMode/Wayland need a normal user session; no global daemon is required.
    # Generate user directories now so KDE has them on first login.
    arch-chroot "$MNT" runuser -u "$USERNAME" -- xdg-user-dirs-update || true

    # Disable root password login.
    arch-chroot "$MNT" passwd -l root >/dev/null 2>&1 || true

    ok "Usuario, servicios, zram, Snapper y ajustes de gaming configurados."
}

configure_boot() {
    section "14/14 - SYSTEMD-BOOT E INITRAMFS"

    arch-chroot "$MNT" bootctl --esp-path=/boot install

    # linux-cachyos uses these filenames, while AMD microcode is supplied separately.
    arch-chroot "$MNT" mkinitcpio -P

    [[ -s "$MNT/boot/vmlinuz-linux-cachyos" ]] ||
        die "No existe /boot/vmlinuz-linux-cachyos."
    [[ -s "$MNT/boot/initramfs-linux-cachyos.img" ]] ||
        die "No existe initramfs de linux-cachyos."
    [[ -s "$MNT/boot/initramfs-linux-cachyos-fallback.img" ]] ||
        die "No existe initramfs fallback de linux-cachyos."
    [[ -s "$MNT/boot/amd-ucode.img" ]] ||
        die "No existe el microcódigo AMD."

    mkdir -p "$EFI_MNT/loader/entries"
    cat > "$EFI_MNT/loader/loader.conf" <<'EOF'
default arch-cachyos.conf
timeout 4
editor no
console-mode auto
EOF

    cat > "$EFI_MNT/loader/entries/arch-cachyos.conf" <<EOF
title   Iceman Arch + CachyOS KDE
linux   /vmlinuz-linux-cachyos
initrd  /amd-ucode.img
initrd  /initramfs-linux-cachyos.img
options root=UUID=$ROOT_UUID rootflags=subvol=@ rw
EOF

    cat > "$EFI_MNT/loader/entries/arch-cachyos-fallback.conf" <<EOF
title   Iceman Arch + CachyOS KDE (fallback)
linux   /vmlinuz-linux-cachyos
initrd  /amd-ucode.img
initrd  /initramfs-linux-cachyos-fallback.img
options root=UUID=$ROOT_UUID rootflags=subvol=@ rw
EOF

    arch-chroot "$MNT" bootctl --esp-path=/boot update
    arch-chroot "$MNT" bootctl --esp-path=/boot status

    ok "systemd-boot, kernel CachyOS e initramfs preparados."
}

final_validation() {
    section "15/16 - VALIDACIÓN ANTES DE REINICIAR"

    local fail=0
    check() {
        local name="$1"; shift
        if "$@"; then
            ok "$name"
        else
            warn "FALLO: $name"
            fail=$((fail+1))
        fi
    }

    check "Root Btrfs" bash -c "findmnt -no FSTYPE \"$MNT\" | grep -qx btrfs"
    check "Root subvol @ " bash -c "findmnt -no OPTIONS '$MNT' | grep -q 'subvol=@'"
    check "Home subvol @home" bash -c "findmnt -no OPTIONS '$MNT/home' | grep -q 'subvol=@home'"
    check "EFI montada" mountpoint -q "$EFI_MNT"
    check "fstab" test -s "$MNT/etc/fstab"
    check "Usuario" arch-chroot "$MNT" id "$USERNAME"
    check "sudoers" arch-chroot "$MNT" visudo -cf /etc/sudoers
    check "KDE" arch-chroot "$MNT" pacman -Q plasma-meta sddm
    check "AMD Vulkan 64/32" arch-chroot "$MNT" pacman -Q vulkan-radeon lib32-vulkan-radeon
    check "PipeWire" arch-chroot "$MNT" pacman -Q pipewire wireplumber
    check "Steam" arch-chroot "$MNT" pacman -Q steam
    check "Wine/Lutris" arch-chroot "$MNT" pacman -Q wine lutris
    check "GameMode" arch-chroot "$MNT" pacman -Q gamemode lib32-gamemode
    check "Snapper" arch-chroot "$MNT" snapper -c root list-configs
    check "Kernel CachyOS" test -s "$MNT/boot/vmlinuz-linux-cachyos"
    check "Initramfs CachyOS" test -s "$MNT/boot/initramfs-linux-cachyos.img"
    check "Initramfs fallback CachyOS" test -s "$MNT/boot/initramfs-linux-cachyos-fallback.img"
    check "AMD microcode" test -s "$MNT/boot/amd-ucode.img"
    check "systemd-boot entry" test -s "$EFI_MNT/loader/entries/arch-cachyos.conf"

    # Verify the installed system's package databases and repositories.
    check "Repositorios CachyOS accesibles" arch-chroot "$MNT" pacman -Si linux-cachyos
    check "Kernel package installed" arch-chroot "$MNT" pacman -Q linux-cachyos linux-cachyos-headers

    if (( fail > 0 )); then
        die "$fail comprobaciones fallaron. NO se reiniciará."
    fi

    {
        echo "ICEMAN INSTALL FINAL REPORT"
        echo "Date: $(date -Is)"
        echo
        echo "Hardware:"
        lscpu | grep -E 'Model name|CPU\(s\)' || true
        dmidecode -s baseboard-product-name || true
        lspci -nn | grep -Ei 'VGA|3D|Display' || true
        echo
        echo "Disk:"
        lsblk "$TARGET_DISK"
        echo
        echo "Btrfs:"
        btrfs subvolume list "$MNT"
        echo
        echo "Boot:"
        arch-chroot "$MNT" bootctl --esp-path=/boot status
        echo
        echo "Kernel:"
        arch-chroot "$MNT" pacman -Q linux-cachyos linux-cachyos-headers
        echo
        echo "Desktop/Gaming:"
        arch-chroot "$MNT" pacman -Q plasma-meta sddm steam gamemode wine lutris retroarch dolphin-emu
    } > "$MNT/root/iceman-final-report.txt"

    sync
    ok "TODAS las comprobaciones han pasado."
}

finish() {
    section "16/16 - INSTALACIÓN TERMINADA"

    printf '\nEl sistema está instalado en %s\n' "$TARGET_DISK"
    printf 'Usuario: %s\n' "$USERNAME"
    printf 'KDE Plasma + SDDM + Wayland disponible\n'
    printf 'Kernel: linux-cachyos\n'
    printf 'AMD: Mesa + RADV + firmware + microcódigo\n'
    printf 'Gaming: Steam + GameMode + MangoHud + Gamescope + Wine + Lutris\n'
    printf 'Emulación: RetroArch + Dolphin\n'
    printf 'Btrfs + Snapper\n'
    printf '\nLog: %s\n' "$LOG_FILE"
    printf 'Informe: /root/iceman-final-report.txt dentro del sistema instalado\n'
    printf '\nRetira el USB y pulsa ENTER para desmontar.\n'
    local dummy
    tty_read "" dummy || true
}

main() {
    clear || true
    printf '============================================================\n'
    printf '       ICEMAN ARCH + CACHYOS KDE GAMING INSTALLER\n'
    printf '============================================================\n'
    printf 'Hardware objetivo: Ryzen 9 5950X + RX 7600 XT + B550 Aorus Elite V2\n'
    printf 'El disco seleccionado SERÁ BORRADO.\n\n'

    hardware_preflight
    network_preflight
    live_update
    preflight_packages
    cachyos_preflight
    select_disk
    user_preflight
    partition_and_format
    write_base_config
    install_arch_base
    install_cachyos_repositories
    install_desktop_gaming
    configure_system
    configure_boot
    final_validation
    finish
}
main "$@"
