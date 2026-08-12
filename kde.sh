# Instalador monolítico Arch Linux + KDE Plasma + Btrfs + AMD + Gaming

```bash
#!/usr/bin/env bash
#
# ARCH KDE AMD BTRFS INSTALLER
# Target:
#   AMD Ryzen 9 5950X
#   AMD Radeon RX 7600 XT
#   B550
#   32 GiB RAM
#
# UEFI / GPT / Btrfs / systemd-boot / NO ENCRYPTION
# Spain / Europe/Madrid / es_ES.UTF-8
#
# IMPORTANT:
#   This script DESTROYS the selected disk.
#   It performs extensive checks before doing so.
#
# Run from the official Arch Linux ISO as root.
#
# Expected initial invocation:
#   curl -fsSL https://raw.githubusercontent.com/YOUR_USER/YOUR_REPO/main/arch-install.sh | bash
#

set -Eeuo pipefail
umask 022

export LC_ALL=C
export LANG=C

SCRIPT_NAME="arch-install"
LOG_FILE="/tmp/${SCRIPT_NAME}-$(date +%Y%m%d-%H%M%S).log"

MNT="/mnt"
EFI_MNT="${MNT}/efi"
BTOP="${MNT}/.btrfs-top"

TARGET_DISK=""
EFI_PART=""
ROOT_PART=""

USERNAME=""
USER_PASSWORD=""

TARGET_UUID=""
EFI_UUID=""

TARGET_TOUCHED=0
INSTALL_STARTED=0
CHROOT_STARTED=0
CLEANUP_DONE=0

# ------------------------------------------------------------
# LOGGING
# ------------------------------------------------------------

exec > >(tee -a "$LOG_FILE") 2>&1

timestamp() {
    date '+%H:%M:%S'
}

info() {
    printf '\n[%s] [INFO] %s\n' "$(timestamp)" "$*"
}

warn() {
    printf '\n[%s] [WARN] %s\n' "$(timestamp)" "$*" >&2
}

die() {
    printf '\n[%s] [ERROR] %s\n' "$(timestamp)" "$*" >&2
    exit 1
}

ok() {
    printf '[%s] [ OK ] %s\n' "$(timestamp)" "$*"
}

section() {
    printf '\n============================================================\n'
    printf ' %s\n' "$*"
    printf '============================================================\n'
}

# ------------------------------------------------------------
# CLEANUP
# ------------------------------------------------------------

cleanup_mounts() {
    set +e

    sync

    # Stop any chroot processes which may still be holding files.
    if [[ -d "$MNT" ]] && mountpoint -q "$MNT"; then
        fuser -km "$MNT" >/dev/null 2>&1 || true
    fi

    # Recursive unmount. This is intentionally done from the live ISO.
    if [[ -d "$MNT" ]] && mountpoint -q "$MNT"; then
        umount -R "$MNT" >/dev/null 2>&1 || true
    fi

    # Explicit fallbacks.
    mountpoint -q "$EFI_MNT" && umount "$EFI_MNT" >/dev/null 2>&1 || true
    mountpoint -q "$BTOP" && umount "$BTOP" >/dev/null 2>&1 || true
    mountpoint -q "$MNT" && umount "$MNT" >/dev/null 2>&1 || true

    sync

    CLEANUP_DONE=1
    set -e
}

emergency_cleanup() {
    local rc="${1:-1}"

    if (( CLEANUP_DONE == 1 )); then
        return "$rc"
    fi

    printf '\n'
    printf '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n'
    printf ' INSTALLATION STOPPED WITH ERROR (exit code %s)\n' "$rc"
    printf '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n'

    warn "Beginning emergency cleanup."

    cleanup_mounts

    # Save the log in the live environment under a predictable name.
    cp -f "$LOG_FILE" "/root/arch-install-error.log" >/dev/null 2>&1 || true

    sync

    printf '\n'
    printf '------------------------------------------------------------\n'
    printf ' Emergency cleanup completed as far as safely possible.\n'
    printf ' Log: /root/arch-install-error.log\n'
    printf ' The machine will NOT reboot automatically.\n'
    printf '------------------------------------------------------------\n'
    printf '\n'

    return "$rc"
}

on_exit() {
    local rc=$?

    if (( rc != 0 )); then
        emergency_cleanup "$rc"
    else
        cleanup_mounts
        info "Installation cleanup completed."
    fi

    exit "$rc"
}

trap on_exit EXIT
trap 'exit 130' INT TERM

# ------------------------------------------------------------
# BASIC CHECKS
# ------------------------------------------------------------

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not available: $1"
}

preflight_basic() {
    section "PHASE 1 - BASIC PREFLIGHT"

    [[ "$EUID" -eq 0 ]] || die "The installer must be executed as root."

    [[ "$(uname -m)" == "x86_64" ]] || die "This installer requires x86_64."

    [[ -d /sys/firmware/efi/efivars ]] || \
        die "The system is NOT booted in UEFI mode. Reboot the ISO in UEFI mode."

    require_command pacman
    require_command pacstrap
    require_command arch-chroot
    require_command genfstab
    require_command lsblk
    require_command sgdisk
    require_command wipefs
    require_command mkfs.btrfs
    require_command mkfs.fat
    require_command mount
    require_command umount
    require_command curl
    require_command ip
    require_command findmnt
    require_command blkid
    require_command partprobe
    require_command systemctl

    ok "Root privileges."
    ok "x86_64 architecture."
    ok "UEFI mode."
    ok "Required installation tools."

    info "Hardware inventory:"
    printf '\n--- CPU ---\n'
    lscpu | grep -E 'Model name|CPU\(s\)|Architecture' || true

    printf '\n--- MEMORY ---\n'
    free -h

    printf '\n--- PCI ---\n'
    lspci -nnk 2>/dev/null || true

    printf '\n--- USB ---\n'
    lsusb 2>/dev/null || true

    printf '\n--- NETWORK ---\n'
    ip -br link || true

    printf '\n--- BLOCK DEVICES ---\n'
    lsblk -e7 -o NAME,PATH,SIZE,TYPE,FSTYPE,LABEL,MODEL,TRAN,RM,MOUNTPOINTS
}

# ------------------------------------------------------------
# PACMAN / LIVE ENVIRONMENT
# ------------------------------------------------------------

enable_multilib_live() {
    if ! grep -Eq '^[[:space:]]*\[multilib\]' /etc/pacman.conf; then
        cat >> /etc/pacman.conf <<'EOF'

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF
    fi
}

refresh_live_keyring() {
    section "PHASE 2 - LIVE ENVIRONMENT / KEYRING"

    enable_multilib_live

    info "Synchronizing and updating the Arch ISO environment."
    pacman -Syyu --noconfirm

    pacman -S --needed --noconfirm \
        archlinux-keyring \
        linux-firmware \
        iwd \
        networkmanager \
        curl \
        git \
        base-devel

    pacman-key --init
    pacman-key --populate archlinux

    ok "Live environment and Arch keyring ready."
}

# ------------------------------------------------------------
# NETWORK
# ------------------------------------------------------------

internet_ok() {
    curl -4fsS --connect-timeout 5 --max-time 10 \
        https://archlinux.org >/dev/null 2>&1
}

get_wifi_interfaces() {
    iw dev 2>/dev/null |
        awk '$1=="Interface"{print $2}' |
        sort -u
}

connect_wifi_if_needed() {
    section "PHASE 3 - NETWORK PREFLIGHT"

    if internet_ok; then
        ok "Internet connection already working."
        return 0
    fi

    warn "No working Internet connection detected."

    # Try NetworkManager automatically if available.
    if command -v nmcli >/dev/null 2>&1; then
        systemctl start NetworkManager >/dev/null 2>&1 || true
        sleep 2

        if nmcli networking connectivity check 2>/dev/null | grep -qiE 'full|limited'; then
            if internet_ok; then
                ok "NetworkManager connection is working."
                return 0
            fi
        fi
    fi

    mapfile -t WIFI_IFACES < <(get_wifi_interfaces)

    if (( ${#WIFI_IFACES[@]} == 0 )); then
        warn "No Wi-Fi interface was detected."
        warn "Ethernet and other network devices:"
        ip -br link || true
        die "There is no working network connection. Connect Ethernet or ensure the Wi-Fi adapter firmware is available, then rerun."
    fi

    printf '\nDetected Wi-Fi interfaces:\n'
    local i
    for i in "${!WIFI_IFACES[@]}"; do
        printf '  %d) %s\n' "$((i+1))" "${WIFI_IFACES[$i]}"
    done

    local selected
    if (( ${#WIFI_IFACES[@]} == 1 )); then
        selected="${WIFI_IFACES[0]}"
    else
        read -rp "Select Wi-Fi interface [1-${#WIFI_IFACES[@]}]: " selected
        [[ "$selected" =~ ^[0-9]+$ ]] ||
            die "Invalid Wi-Fi interface selection."
        (( selected >= 1 && selected <= ${#WIFI_IFACES[@]} )) ||
            die "Invalid Wi-Fi interface selection."
        selected="${WIFI_IFACES[$((selected-1))]}"
    fi

    info "Using Wi-Fi interface: $selected"

    systemctl start iwd >/dev/null 2>&1 || true
    sleep 2

    iwctl station "$selected" scan || true
    sleep 2

    printf '\nAvailable Wi-Fi networks:\n'
    iwctl station "$selected" get-networks || true
    printf '\n'

    local ssid
    local wifi_password

    read -rp "Wi-Fi network (SSID): " ssid
    [[ -n "$ssid" ]] || die "SSID cannot be empty."

    read -rsp "Wi-Fi password: " wifi_password
    printf '\n'

    iwctl station "$selected" connect "$ssid" <<< "$wifi_password"

    unset wifi_password

    info "Waiting for Wi-Fi connection..."
    sleep 5

    if ! internet_ok; then
        die "Wi-Fi connection was established but Internet access could not be verified."
    fi

    ok "Wi-Fi and Internet working."
}

# ------------------------------------------------------------
# MIRRORS
# ------------------------------------------------------------

prepare_mirrors() {
    section "PHASE 4 - MIRROR PREFLIGHT"

    [[ -s /etc/pacman.d/mirrorlist ]] ||
        die "Arch mirrorlist is missing."

    if ! grep -qE '^[[:space:]]*Server[[:space:]]*=' /etc/pacman.d/mirrorlist; then
        die "No active Arch mirror was found."
    fi

    # Test package database access without installing anything.
    pacman -Sy --noconfirm

    pacman -Si base >/dev/null ||
        die "Arch repositories are not reachable."

    ok "Arch repositories reachable."
}

# ------------------------------------------------------------
# PACKAGE PREFLIGHT
# ------------------------------------------------------------

OFFICIAL_PACKAGES=(
    # Core
    base
    base-devel
    linux
    linux-headers
    linux-firmware
    amd-ucode
    btrfs-progs
    dosfstools
    e2fsprogs
    efibootmgr

    # Basic system
    sudo
    git
    curl
    wget
    nano
    vim
    bash-completion
    man-db
    man-pages
    less
    unzip
    p7zip
    rsync
    htop
    fastfetch
    pciutils
    usbutils
    dmidecode
    smartmontools

    # Locale / fonts
    tzdata
    glibc
    xkeyboard-config
    noto-fonts
    noto-fonts-emoji
    ttf-dejavu

    # Network
    networkmanager
    iwd
    bluez
    bluez-utils
    avahi

    # Audio
    pipewire
    pipewire-alsa
    pipewire-pulse
    pipewire-jack
    wireplumber
    rtkit
    alsa-utils
    alsa-ucm-conf
    pavucontrol

    # Firmware management
    fwupd

    # KDE
    plasma-meta
    sddm
    kde-gtk-config
    dolphin
    ark
    konsole
    kate
    okular
    gwenview
    spectacle
    filelight
    kdeconnect
    kdegraphics-thumbnailers
    ffmpegthumbs
    kio-extras
    xdg-desktop-portal
    xdg-desktop-portal-kde
    xdg-user-dirs
    xdg-utils
    breeze-gtk

    # Graphics / AMD
    mesa
    vulkan-radeon
    vulkan-icd-loader
    vulkan-tools
    libva-mesa-driver
    mesa-vdpau
    libdrm
    libglvnd
    egl-wayland
    lib32-mesa
    lib32-vulkan-radeon
    lib32-vulkan-icd-loader
    lib32-libva
    lib32-libpulse
    lib32-pipewire
    lib32-openal
    lib32-alsa-lib
    lib32-alsa-plugins

    # Multimedia / codecs
    ffmpeg
    gst-libav
    gst-plugins-good
    gst-plugins-bad
    gst-plugins-ugly
    gst-plugin-pipewire
    vlc

    # Power / memory
    power-profiles-daemon
    zram-generator

    # Btrfs / snapshots
    snapper
    btrfs-assistant

    # Security
    firewalld
    plasma-firewall
    polkit

    # Gaming
    steam
    steam-devices
    gamemode
    lib32-gamemode
    mangohud
    lib32-mangohud
    gamescope
    wine
    winetricks
    lutris

    # Emulation
    retroarch
    dolphin-emu
)

package_exists_repo() {
    pacman -Si "$1" >/dev/null 2>&1
}

validate_official_packages() {
    section "PHASE 5 - PACKAGE PREFLIGHT"

    local pkg
    local missing=()

    info "Checking every package before disk modification."

    for pkg in "${OFFICIAL_PACKAGES[@]}"; do
        if package_exists_repo "$pkg"; then
            printf '  [ OK ] %s\n' "$pkg"
        else
            printf '  [MISSING] %s\n' "$pkg"
            missing+=("$pkg")
        fi
    done

    if (( ${#missing[@]} > 0 )); then
        printf '\nPackages not available:\n'
        printf '  %s\n' "${missing[@]}"
        die "Official package preflight failed. No disk has been modified."
    fi

    ok "All official packages are currently resolvable."
}

# ------------------------------------------------------------
# HARDWARE DETECTION
# ------------------------------------------------------------

detect_hardware() {
    section "PHASE 6 - HARDWARE DETECTION"

    local cpu gpu wifi audio

    cpu="$(lscpu | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    gpu="$(lspci -nn | grep -Ei 'VGA compatible controller|3D controller|Display controller' || true)"
    wifi="$(lspci -nn | grep -Ei 'Network controller|Wireless' || true)"
    audio="$(lspci -nn | grep -Ei 'Audio device|Audio controller' || true)"

    printf '\nCPU:\n%s\n' "${cpu:-Unknown}"
    printf '\nGPU:\n%s\n' "${gpu:-None detected}"
    printf '\nWi-Fi/Network:\n%s\n' "${wifi:-None detected}"
    printf '\nAudio:\n%s\n' "${audio:-None detected}"

    if ! grep -qi 'AMD' <<< "$cpu"; then
        warn "Detected CPU does not appear to be AMD."
        read -rp "Continue anyway? [yes/NO]: " answer
        [[ "$answer" == "yes" ]] || die "Installation cancelled."
    fi

    if ! grep -Eqi 'AMD|ATI.*Radeon' <<< "$gpu"; then
        warn "Expected AMD/ATI GPU was not detected."
        read -rp "Continue anyway? [yes/NO]: " answer
        [[ "$answer" == "yes" ]] || die "Installation cancelled."
    fi

    ok "Hardware detection completed."
}

# ------------------------------------------------------------
# DISK SELECTION
# ------------------------------------------------------------

disk_is_live_system() {
    local disk="$1"
    local root_source

    root_source="$(findmnt -no SOURCE / 2>/dev/null || true)"

    [[ -n "$root_source" ]] || return 1

    if [[ "$root_source" == "$disk" ]]; then
        return 0
    fi

    if lsblk -nrpo NAME "$disk" 2>/dev/null |
        grep -Fxq "$root_source"; then
        return 0
    fi

    return 1
}

show_disks() {
    printf '\nAvailable installation disks:\n\n'
    printf '%-5s %-18s %-10s %-8s %-10s %-24s\n' \
        "ID" "DEVICE" "SIZE" "TYPE" "TRAN" "MODEL"

    local n=1
    while read -r path size type tran rm model; do
        [[ "$type" == "disk" ]] || continue

        # Never offer obvious virtual/ISO devices.
        [[ "$path" == /dev/loop* ]] && continue
        [[ "$path" == /dev/zram* ]] && continue
        [[ "$path" == /dev/md* ]] && continue

        printf '%-5s %-18s %-10s %-8s %-10s %-24s\n' \
            "$n" "$path" "$size" "$type" "${tran:-?}" "${model:-?}"

        DISK_PATHS[$n]="$path"
        ((n++))
    done < <(
        lsblk -dnro PATH,SIZE,TYPE,TRAN,RM,MODEL |
        sed 's/  */ /g'
    )

    (( n > 1 )) || die "No suitable installation disk detected."
}

select_disk() {
    section "PHASE 7 - DESTINATION DISK"

    declare -g -a DISK_PATHS=()

    show_disks

    local choice
    read -rp $'\nSelect the disk to ERASE completely: ' choice

    [[ "$choice" =~ ^[0-9]+$ ]] ||
        die "Invalid disk selection."

    [[ -n "${DISK_PATHS[$choice]:-}" ]] ||
        die "Invalid disk selection."

    TARGET_DISK="${DISK_PATHS[$choice]}"

    # Never install to the booted ISO device.
    if disk_is_live_system "$TARGET_DISK"; then
        die "The selected disk contains the currently running live system."
    fi

    # Extra safety: identify whether it is removable.
    local removable
    removable="$(lsblk -dnro RM "$TARGET_DISK")"

    printf '\nSelected disk:\n'
    lsblk -d -o NAME,PATH,SIZE,MODEL,TRAN,RM "$TARGET_DISK"

    if [[ "$removable" == "1" ]]; then
        warn "The selected device is reported as removable."
        read -rp "Type ERASE-USB to explicitly allow this device: " confirm
        [[ "$confirm" == "ERASE-USB" ]] ||
            die "Installation cancelled."
    fi

    printf '\n'
    warn "EVERYTHING on $TARGET_DISK will be destroyed."
    read -rp "Type ERASE to confirm: " confirm
    [[ "$confirm" == "ERASE" ]] ||
        die "Installation cancelled."

    ok "Destination disk confirmed: $TARGET_DISK"
}

# ------------------------------------------------------------
# USER
# ------------------------------------------------------------

ask_user() {
    section "PHASE 8 - USER ACCOUNT"

    while true; do
        read -rp "Username: " USERNAME

        [[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]*[$]?$ ]] ||
            { warn "Invalid Linux username."; continue; }

        [[ "$USERNAME" != "root" ]] ||
            { warn "root cannot be used."; continue; }

        break
    done

    while true; do
        read -rsp "Password: " USER_PASSWORD
        printf '\n'

        read -rsp "Repeat password: " password2
        printf '\n'

        [[ "$USER_PASSWORD" == "$password2" ]] ||
            { warn "Passwords do not match."; unset password2; continue; }

        [[ -n "$USER_PASSWORD" ]] ||
            { warn "Password cannot be empty."; unset password2; continue; }

        unset password2
        break
    done

    ok "User account information collected."
}

# ------------------------------------------------------------
# DISK PARTITIONING
# ------------------------------------------------------------

partition_disk() {
    section "PHASE 9 - DISK PARTITIONING"

    INSTALL_STARTED=1
    TARGET_TOUCHED=1

    # Ensure nothing from the target disk is mounted.
    while read -r part; do
        [[ -n "$part" ]] || continue
        umount "$part" >/dev/null 2>&1 || true
    done < <(lsblk -nrpo NAME "$TARGET_DISK" | tail -n +2)

    swapoff -a >/dev/null 2>&1 || true

    sync

    info "Erasing partition table and filesystem signatures."
    sgdisk --zap-all "$TARGET_DISK"
    wipefs -a "$TARGET_DISK"

    info "Creating GPT + 1 GiB EFI + Btrfs root partition."

    sgdisk \
        -n 1:1MiB:+1GiB \
        -t 1:ef00 \
        -c 1:EFI \
        -n 2:0:0 \
        -t 2:8300 \
        -c 2:ARCH-BTRFS \
        "$TARGET_DISK"

    partprobe "$TARGET_DISK"
    sleep 2

    # Determine partition names generically.
    mapfile -t PARTS < <(
        lsblk -nrpo NAME,TYPE "$TARGET_DISK" |
        awk '$2=="part"{print $1}'
    )

    (( ${#PARTS[@]} == 2 )) ||
        die "Partitioning did not produce exactly two partitions."

    EFI_PART="${PARTS[0]}"
    ROOT_PART="${PARTS[1]}"

    # Ensure the 1 GiB partition is EFI.
    local efi_size
    efi_size="$(lsblk -bno SIZE "$EFI_PART")"

    if (( efi_size < 900000000 || efi_size > 1200000000 )); then
        # Sort by size if kernel enumerated unexpectedly.
        if (( $(lsblk -bno SIZE "${PARTS[1]}") < $(lsblk -bno SIZE "${PARTS[0]}") )); then
            EFI_PART="${PARTS[1]}"
            ROOT_PART="${PARTS[0]}"
        fi
    fi

    printf '\n'
    lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,PARTTYPE,MOUNTPOINTS "$TARGET_DISK"

    ok "GPT partition table created."
}

# ------------------------------------------------------------
# FILESYSTEM
# ------------------------------------------------------------

create_filesystems() {
    section "PHASE 10 - FILESYSTEMS / BTRFS"

    info "Formatting EFI partition as FAT32."
    mkfs.fat -F32 -n EFI "$EFI_PART"

    info "Formatting Linux partition as Btrfs."
    mkfs.btrfs -f -L ARCH "$ROOT_PART"

    info "Creating Btrfs subvolumes."

    mkdir -p "$BTOP"
    mount "$ROOT_PART" "$BTOP"

    btrfs subvolume create "$BTOP/@"
    btrfs subvolume create "$BTOP/@home"
    btrfs subvolume create "$BTOP/@snapshots"

    sync

    umount "$BTOP"

    # Root.
    mount \
        -o subvol=@,compress=zstd:3,noatime,ssd,discard=async \
        "$ROOT_PART" "$MNT"

    mkdir -p "$MNT/home"
    mkdir -p "$MNT/.snapshots"

    # Home.
    mount \
        -o subvol=@home,compress=zstd:3,noatime,ssd,discard=async \
        "$ROOT_PART" "$MNT/home"

    # Snapshots.
    mount \
        -o subvol=@snapshots,compress=zstd:3,noatime,ssd,discard=async \
        "$ROOT_PART" "$MNT/.snapshots"

    # EFI.
    mkdir -p "$EFI_MNT"
    mount "$EFI_PART" "$EFI_MNT"

    TARGET_UUID="$(blkid -s UUID -o value "$ROOT_PART")"
    EFI_UUID="$(blkid -s UUID -o value "$EFI_PART")"

    [[ -n "$TARGET_UUID" ]] || die "Could not obtain Btrfs UUID."
    [[ -n "$EFI_UUID" ]] || die "Could not obtain EFI UUID."

    ok "Btrfs root subvolume @."
    ok "Btrfs home subvolume @home."
    ok "Btrfs snapshot subvolume @snapshots."
    ok "EFI mounted."
}

# ------------------------------------------------------------
# PACSTRAP
# ------------------------------------------------------------

install_base_system() {
    section "PHASE 11 - INSTALLING ARCH"

    info "Installing the complete base system."

    pacstrap -K "$MNT" "${OFFICIAL_PACKAGES[@]}"

    ok "Official Arch system installed."
}

# ------------------------------------------------------------
# CONFIGURATION FILES
# ------------------------------------------------------------

write_fstab() {
    section "PHASE 12 - FSTAB"

    cat > "$MNT/etc/fstab" <<EOF
# Arch Linux generated by automated installer

UUID=${TARGET_UUID}  /            btrfs  subvol=@,compress=zstd:3,noatime,ssd,discard=async  0 0
UUID=${TARGET_UUID}  /home        btrfs  subvol=@home,compress=zstd:3,noatime,ssd,discard=async  0 0
UUID=${TARGET_UUID}  /.snapshots  btrfs  subvol=@snapshots,compress=zstd:3,noatime,ssd,discard=async  0 0
UUID=${EFI_UUID}     /efi         vfat   umask=0077,shortname=winnt  0 2
EOF

    mount -a -T "$MNT/etc/fstab"

    ok "fstab written and tested."
}

write_locale() {
    info "Configuring Spain / Spanish locale."

    sed -i 's/^#\(es_ES.UTF-8 UTF-8\)/\1/' "$MNT/etc/locale.gen"

    # Ensure locale exists even if the file layout changes.
    grep -q '^es_ES.UTF-8 UTF-8' "$MNT/etc/locale.gen" ||
        echo 'es_ES.UTF-8 UTF-8' >> "$MNT/etc/locale.gen"

    arch-chroot "$MNT" locale-gen

    cat > "$MNT/etc/locale.conf" <<'EOF'
LANG=es_ES.UTF-8
LC_ADDRESS=es_ES.UTF-8
LC_IDENTIFICATION=es_ES.UTF-8
LC_MEASUREMENT=es_ES.UTF-8
LC_MONETARY=es_ES.UTF-8
LC_NAME=es_ES.UTF-8
LC_NUMERIC=es_ES.UTF-8
LC_PAPER=es_ES.UTF-8
LC_TELEPHONE=es_ES.UTF-8
LC_TIME=es_ES.UTF-8
EOF

    cat > "$MNT/etc/vconsole.conf" <<'EOF'
KEYMAP=es
FONT=
EOF

    ok "Spanish (Spain) locale configured."
}

write_timezone() {
    info "Configuring Europe/Madrid."

    ln -sf /usr/share/zoneinfo/Europe/Madrid "$MNT/etc/localtime"
    arch-chroot "$MNT" hwclock --systohc

    ok "Europe/Madrid configured."
}

write_hostname() {
    cat > "$MNT/etc/hostname" <<'EOF'
arch-amd
EOF

    cat > "$MNT/etc/hosts" <<'EOF'
127.0.0.1   localhost
::1         localhost
127.0.1.1   arch-amd.localdomain arch-amd
EOF
}

configure_pacman() {
    section "PHASE 13 - PACMAN / REPOSITORIES"

    # Ensure official repositories and multilib are enabled.
    cat > "$MNT/etc/pacman.conf" <<'EOF'
[options]
HoldPkg     = pacman glibc
Architecture = auto
CheckSpace
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional
Color
ParallelDownloads = 5

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist

[multilib]
Include = /etc/pacman.d/mirrorlist
EOF

    # Verify target mirrorlist exists.
    [[ -s "$MNT/etc/pacman.d/mirrorlist" ]] ||
        die "Target mirrorlist was not installed."

    ok "core enabled."
    ok "extra enabled."
    ok "multilib enabled."
}

configure_network() {
    section "PHASE 14 - NETWORK"

    arch-chroot "$MNT" systemctl enable NetworkManager
    arch-chroot "$MNT" systemctl enable bluetooth

    # NetworkManager can use iwd; wpa_supplicant remains available through NM
    # where required. We deliberately do not force an experimental backend.
    mkdir -p "$MNT/etc/NetworkManager/conf.d"

    cat > "$MNT/etc/NetworkManager/conf.d/10-wifi-powersave.conf" <<'EOF'
[connection]
wifi.powersave = 3
EOF

    # DNS is handled by NetworkManager/systemd-resolved integration as available.
    ok "NetworkManager configured."
}

configure_audio() {
    section "PHASE 15 - AUDIO"

    # PipeWire user services are socket/user-session activated.
    mkdir -p "$MNT/etc/pipewire"

    ok "PipeWire / WirePlumber stack installed."
}

configure_power() {
    section "PHASE 16 - POWER / GAMING PERFORMANCE"

    arch-chroot "$MNT" systemctl enable power-profiles-daemon

    cat > "$MNT/etc/gamemode.ini" <<'EOF'
[general]
renice=10
inhibit_screensaver=1
softrealtime=auto

[cpu]
park_cores=no

[gpu]
apply_gpu_optimisations=accept-responsibility
gpu_device=0
amd_performance_level=auto

[custom]
EOF

    cat > "$MNT/etc/systemd/zram-generator.conf" <<'EOF'
[zram0]
zram-size = min(ram / 4, 8192)
compression-algorithm = zstd
swap-priority = 100
EOF

    ok "Power profiles and ZRAM configured."
}

configure_firewall() {
    section "PHASE 17 - FIREWALL"

    arch-chroot "$MNT" systemctl enable firewalld

    # Firewalld default zone is public; no inbound services are opened.
    arch-chroot "$MNT" firewall-offline-cmd --set-default-zone=public >/dev/null 2>&1 || true

    ok "Firewalld configured."
}

# ------------------------------------------------------------
# USERS
# ------------------------------------------------------------

configure_user() {
    section "PHASE 18 - USER ACCOUNT"

    arch-chroot "$MNT" useradd \
        --create-home \
        --shell /bin/bash \
        --groups wheel,audio,video,storage,optical \
        "$USERNAME"

    printf '%s:%s\n' "$USERNAME" "$USER_PASSWORD" |
        arch-chroot "$MNT" chpasswd

    # Do not retain password in shell variables after this point.
    unset USER_PASSWORD

    # Sudo for wheel group.
    cat > "$MNT/etc/sudoers.d/10-wheel" <<'EOF'
%wheel ALL=(ALL:ALL) ALL
EOF

    chmod 0440 "$MNT/etc/sudoers.d/10-wheel"

    # Root login remains disabled via locked password.
    arch-chroot "$MNT" passwd -l root

    ok "Normal user created."
    ok "Root password locked."
}

# ------------------------------------------------------------
# BOOT
# ------------------------------------------------------------

configure_boot() {
    section "PHASE 19 - SYSTEMD-BOOT"

    mkdir -p "$EFI_MNT/loader/entries"

    # bootctl must run with the ESP available.
    arch-chroot "$MNT" bootctl --esp-path=/efi install

    cat > "$MNT/efi/loader/loader.conf" <<'EOF'
default arch.conf
timeout 4
editor no
console-mode auto
EOF

    cat > "$MNT/efi/loader/entries/arch.conf" <<EOF
title   Arch Linux
linux   /vmlinuz-linux
initrd  /amd-ucode.img
initrd  /initramfs-linux.img
options root=UUID=${TARGET_UUID} rootflags=subvol=@ rw
EOF

    cat > "$MNT/efi/loader/entries/arch-fallback.conf" <<EOF
title   Arch Linux (fallback)
linux   /vmlinuz-linux
initrd  /amd-ucode.img
initrd  /initramfs-linux-fallback.img
options root=UUID=${TARGET_UUID} rootflags=subvol=@ rw
EOF

    arch-chroot "$MNT" bootctl --esp-path=/efi status

    ok "systemd-boot installed."
}

# ------------------------------------------------------------
# INITRAMFS
# ------------------------------------------------------------

configure_initramfs() {
    section "PHASE 20 - INITRAMFS"

    # Btrfs is already supported by the normal Arch initramfs.
    # Rebuild anyway so the final image is generated after all packages/config.
    arch-chroot "$MNT" mkinitcpio -P

    [[ -s "$MNT/boot/vmlinuz-linux" ]] ||
        die "Linux kernel image missing."

    [[ -s "$MNT/boot/initramfs-linux.img" ]] ||
        die "Linux initramfs missing."

    [[ -s "$MNT/boot/amd-ucode.img" ]] ||
        die "AMD microcode image missing."

    ok "Kernel, initramfs and AMD microcode verified."
}

# ------------------------------------------------------------
# SNAPSHOTS
# ------------------------------------------------------------

configure_snapper() {
    section "PHASE 21 - BTRFS SNAPSHOTS"

    # Create the Snapper configuration on root.
    if ! arch-chroot "$MNT" snapper -c root list-configs |
        awk '{print $1}' | grep -qx root; then

        arch-chroot "$MNT" snapper -c root create-config /
    fi

    # Snapper normally creates /.snapshots itself. Our dedicated @snapshots
    # subvolume is already mounted there, so ensure ownership/permissions.
    mkdir -p "$MNT/.snapshots"
    chmod 750 "$MNT/.snapshots"

    ok "Snapper root configuration prepared."
}

# ------------------------------------------------------------
# GRAPHICS / AMD
# ------------------------------------------------------------

verify_amd_graphics() {
    section "PHASE 22 - AMD GRAPHICS"

    # Verify expected stack exists.
    arch-chroot "$MNT" pacman -Q \
        linux-firmware \
        amd-ucode \
        mesa \
        vulkan-radeon \
        libva-mesa-driver \
        mesa-vdpau \
        lib32-vulkan-radeon \
        lib32-mesa >/dev/null

    # Explicit amdgpu kernel module configuration is NOT forced.
    # The kernel/udev stack should select it automatically.

    ok "AMD graphics stack installed."
}

# ------------------------------------------------------------
# KDE / DISPLAY MANAGER
# ------------------------------------------------------------

configure_kde() {
    section "PHASE 23 - KDE PLASMA"

    arch-chroot "$MNT" systemctl enable sddm

    # Force the first graphical session offered by SDDM to Plasma Wayland.
    mkdir -p "$MNT/etc/sddm.conf.d"

    cat > "$MNT/etc/sddm.conf.d/10-plasma.conf" <<'EOF'
[General]
DisplayServer=wayland

[Autologin]
Relogin=false
EOF

    # Ensure user directories exist.
    arch-chroot "$MNT" sudo -u "$USERNAME" xdg-user-dirs-update || true

    ok "KDE Plasma and SDDM configured."
}

# ------------------------------------------------------------
# AUR
# ------------------------------------------------------------

install_aur_helpers() {
    section "PHASE 24 - AUR / YAY / PAMAC"

    info "Building yay as the normal user."
    info "No AUR package is built as root."

    mkdir -p "$MNT/home/$USERNAME/aur-builds"
    chown -R "$USERNAME:$USERNAME" "$MNT/home/$USERNAME/aur-builds"

    local yay_repo="https://aur.archlinux.org/yay.git"
    local pamac_repo="https://aur.archlinux.org/pamac-aur.git"
    local game_repo="https://aur.archlinux.org/game-devices-udev.git"

    # Validate AUR repositories before building.
    arch-chroot "$MNT" runuser -u "$USERNAME" -- \
        git ls-remote "$yay_repo" HEAD >/dev/null

    arch-chroot "$MNT" runuser -u "$USERNAME" -- \
        git ls-remote "$pamac_repo" HEAD >/dev/null

    arch-chroot "$MNT" runuser -u "$USERNAME" -- \
        git ls-remote "$game_repo" HEAD >/dev/null

    arch-chroot "$MNT" runuser -u "$USERNAME" -- bash -c '
        set -Eeuo pipefail
        cd "$HOME/aur-builds"
        rm -rf yay
        git clone --depth=1 https://aur.archlinux.org/yay.git
        cd yay
        makepkg -si --noconfirm
    '

    arch-chroot "$MNT" runuser -u "$USERNAME" -- \
        yay --version

    # Pamac is explicitly requested by the user.
    # Current pamac-aur is built from AUR.
    arch-chroot "$MNT" runuser -u "$USERNAME" -- bash -c '
        set -Eeuo pipefail
        cd "$HOME/aur-builds"
        rm -rf pamac-aur
        git clone --depth=1 https://aur.archlinux.org/pamac-aur.git
        cd pamac-aur
        makepkg -si --noconfirm
    '

    # Controller udev rules. This supplements Steam Input; it does not replace it.
    arch-chroot "$MNT" runuser -u "$USERNAME" -- bash -c '
        set -Eeuo pipefail
        cd "$HOME/aur-builds"
        rm -rf game-devices-udev
        git clone --depth=1 https://aur.archlinux.org/game-devices-udev.git
        cd game-devices-udev
        makepkg -si --noconfirm
    '

    ok "yay installed."
    ok "pamac installed."
    ok "Additional controller udev rules installed."
}

# ------------------------------------------------------------
# GAME / CONTROLLER VERIFICATION
# ------------------------------------------------------------

verify_gaming() {
    section "PHASE 25 - GAMING / CONTROLLERS"

    arch-chroot "$MNT" pacman -Q \
        steam \
        steam-devices \
        gamemode \
        lib32-gamemode \
        mangohud \
        lib32-mangohud \
        gamescope \
        wine \
        winetricks \
        lutris \
        retroarch \
        dolphin-emu >/dev/null

    arch-chroot "$MNT" gamemoded -t >/dev/null 2>&1 || true

    # Refresh udev rules.
    arch-chroot "$MNT" udevadm control --reload
    arch-chroot "$MNT" udevadm trigger

    ok "Steam."
    ok "Steam device permissions."
    ok "GameMode."
    ok "MangoHud."
    ok "Gamescope."
    ok "Wine/Winetricks/Lutris."
    ok "RetroArch."
    ok "Dolphin."
}

# ------------------------------------------------------------
# FINAL SYSTEM CONFIGURATION
# ------------------------------------------------------------

final_system_configuration() {
    section "PHASE 26 - FINAL SYSTEM CONFIGURATION"

    # Enable systemd services that must exist from first boot.
    arch-chroot "$MNT" systemctl enable NetworkManager
    arch-chroot "$MNT" systemctl enable bluetooth
    arch-chroot "$MNT" systemctl enable sddm
    arch-chroot "$MNT" systemctl enable firewalld
    arch-chroot "$MNT" systemctl enable power-profiles-daemon

    # Ensure kernel module is available.
    [[ -e "$MNT/usr/lib/modules" ]] ||
        die "Kernel modules directory is missing."

    # Remove accidental machine-id from chroot if present so systemd generates it.
    rm -f "$MNT/etc/machine-id"
    arch-chroot "$MNT" systemd-machine-id-setup

    # Make sure all filesystems are cleanly synchronized.
    sync

    ok "System services configured."
}

# ------------------------------------------------------------
# PRE-REBOOT VALIDATION
# ------------------------------------------------------------

validate_installation() {
    section "PHASE 27 - FINAL VALIDATION"

    local failures=0

    check() {
        local description="$1"
        shift

        if "$@"; then
            ok "$description"
        else
            warn "FAILED: $description"
            failures=$((failures+1))
        fi
    }

    check "Root filesystem is Btrfs" \
        bash -c "findmnt -no FSTYPE '$MNT' | grep -qx btrfs"

    check "Root subvolume is @" \
        bash -c "findmnt -no OPTIONS '$MNT' | grep -q 'subvol=@'"

    check "Home is separate Btrfs subvolume" \
        bash -c "findmnt -no OPTIONS '$MNT/home' | grep -q 'subvol=@home'"

    check "EFI mounted" \
        mountpoint -q "$EFI_MNT"

    check "fstab exists" \
        test -s "$MNT/etc/fstab"

    check "Spanish locale configured" \
        grep -q '^LANG=es_ES.UTF-8$' "$MNT/etc/locale.conf"

    check "Madrid timezone configured" \
        test "$(readlink "$MNT/etc/localtime")" = "/usr/share/zoneinfo/Europe/Madrid"

    check "User exists" \
        arch-chroot "$MNT" id "$USERNAME"

    check "sudoers valid" \
        arch-chroot "$MNT" visudo -cf /etc/sudoers

    check "multilib enabled" \
        grep -q '^\[multilib\]' "$MNT/etc/pacman.conf"

    check "NetworkManager enabled" \
        arch-chroot "$MNT" systemctl is-enabled NetworkManager

    check "Bluetooth enabled" \
        arch-chroot "$MNT" systemctl is-enabled bluetooth

    check "SDDM enabled" \
        arch-chroot "$MNT" systemctl is-enabled sddm

    check "Firewalld enabled" \
        arch-chroot "$MNT" systemctl is-enabled firewalld

    check "Power profiles enabled" \
        arch-chroot "$MNT" systemctl is-enabled power-profiles-daemon

    check "Kernel exists" \
        test -s "$MNT/boot/vmlinuz-linux"

    check "AMD microcode exists" \
        test -s "$MNT/boot/amd-ucode.img"

    check "Initramfs exists" \
        test -s "$MNT/boot/initramfs-linux.img"

    check "systemd-boot entry exists" \
        test -s "$MNT/efi/loader/entries/arch.conf"

    check "yay installed" \
        arch-chroot "$MNT" runuser -u "$USERNAME" -- yay --version

    check "pamac installed" \
        arch-chroot "$MNT" pacman -Q pamac-aur

    check "Steam installed" \
        arch-chroot "$MNT" pacman -Q steam

    check "AMD Vulkan installed" \
        arch-chroot "$MNT" pacman -Q vulkan-radeon lib32-vulkan-radeon

    check "Btrfs tools installed" \
        arch-chroot "$MNT" pacman -Q btrfs-progs snapper btrfs-assistant

    check "KDE Plasma installed" \
        arch-chroot "$MNT" pacman -Q plasma-meta sddm

    printf '\n'
    if (( failures > 0 )); then
        die "$failures final validation checks failed."
    fi

    ok "ALL FINAL VALIDATION CHECKS PASSED."
}

# ------------------------------------------------------------
# CLEAN EXIT
# ------------------------------------------------------------

successful_finish() {
    section "PHASE 28 - CLEAN FINISH"

    # Write final diagnostic file while the target is still mounted.
    {
        echo "ARCH INSTALL FINAL REPORT"
        echo
        echo "Date: $(date -Is)"
        echo
        echo "Disk:"
        lsblk "$TARGET_DISK"
        echo
        echo "Btrfs:"
        btrfs subvolume list "$MNT" || true
        echo
        echo "Boot:"
        arch-chroot "$MNT" bootctl --esp-path=/efi status || true
        echo
        echo "Packages:"
        arch-chroot "$MNT" pacman -Q plasma-meta steam vulkan-radeon btrfs-progs snapper yay pamac-aur || true
    } > "$MNT/root/arch-install-final-report.txt"

    sync

    info "Final report saved inside the installed system at:"
    info "/root/arch-install-final-report.txt"

    # Prevent accidental modification after validation.
    INSTALL_STARTED=0

    ok "Installation completed successfully."
}

# ------------------------------------------------------------
# MAIN
# ------------------------------------------------------------

main() {
    clear || true

    printf '\n'
    printf '============================================================\n'
    printf '       ARCH LINUX AUTOMATED KDE AMD INSTALLER\n'
    printf '============================================================\n'
    printf '\n'
    printf 'This installer will create:\n'
    printf '  UEFI + GPT\n'
    printf '  FAT32 EFI (1 GiB)\n'
    printf '  Btrfs root + @home + @snapshots\n'
    printf '  systemd-boot\n'
    printf '  KDE Plasma / SDDM / Wayland\n'
    printf '  AMDGPU / Mesa / RADV\n'
    printf '  Steam / Wine / Lutris / RetroArch / Dolphin\n'
    printf '  yay / Pamac\n'
    printf '  Spanish Spain / Europe-Madrid\n'
    printf '\n'
    printf 'NO encryption is used.\n'
    printf '\n'

    preflight_basic
    refresh_live_keyring
    connect_wifi_if_needed
    prepare_mirrors
    detect_hardware
    validate_official_packages
    select_disk
    ask_user

    partition_disk
    create_filesystems
    install_base_system

    write_fstab
    write_locale
    write_timezone
    write_hostname
    configure_pacman
    configure_network
    configure_audio
    configure_power
    configure_firewall
    configure_user
    configure_boot
    configure_initramfs
    configure_snapper
    verify_amd_graphics
    configure_kde
    final_system_configuration
    validate_installation
    install_aur_helpers
    verify_gaming

    # AUR installation may have modified packages; validate everything again.
    validate_installation

    successful_finish

    printf '\n'
    printf '============================================================\n'
    printf '                 INSTALLATION READY\n'
    printf '============================================================\n'
    printf '\n'
    printf 'The NVMe is now configured.\n'
    printf 'The installer will unmount everything automatically.\n'
    printf '\n'
    printf 'Remove the Arch USB only after this script returns.\n'
    printf 'Then reboot from the installed NVMe.\n'
    printf '\n'

    # Do not reboot automatically.
    read -rp "Press ENTER to unmount and return to the Arch ISO: "

    exit 0
}

main "$@"
```
