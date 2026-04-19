#!/bin/bash
# ==============================================================================
# ICEMAN OS ARCHITECT - TITANIUM HYPRLAND + CAELESTIA SHELL EDITION (v9.0)
# Target: AMD Ryzen 9 5950X | AMD Radeon RX 7600 XT | Entornos VM (KVM/VBox)
# Contenido: BTRFS, LUKS2, CachyOS, Hyprland, AGS, SDDM Dark, Dotfiles Injection
# ==============================================================================
set +e 

# ── Colores ────────────────────────────────────────────────────────────────────
C_CYAN='\033[1;36m'
C_GREEN='\033[1;32m'
C_RED='\033[1;31m'
C_YELLOW='\033[1;33m'
C_PURPLE='\033[1;35m'
C_DEF='\033[0m'

# ── Logs (Memoria RAM Segura) ──────────────────────────────────────────────────
LOG_FILE="/tmp/iceman-install.log"
ERR_LOG="/tmp/iceman-errors.log"
INSTALL_START=$SECONDS

> "$LOG_FILE"
> "$ERR_LOG"

clear
echo -e "${C_PURPLE}======================================================${C_DEF}"
echo -e "${C_GREEN}  ICEMAN OS ARCHITECT - TITANIUM HYPRLAND (CAELESTIA) ${C_DEF}"
echo -e "${C_PURPLE}======================================================${C_DEF}\n"

# ── Detección de Entorno (El Cerebro) ──────────────────────────────────────────
IS_VM=$(systemd-detect-virt || echo "none")
if [[ "$IS_VM" != "none" ]]; then
    echo -e "${C_YELLOW}[!] Entorno de Virtualización Detectado: $IS_VM${C_DEF}"
    echo -e "${C_YELLOW}[!] Se activarán protocolos de compatibilidad Wayland (Software Cursors).${C_DEF}\n"
else
    echo -e "${C_CYAN}[!] Entorno Bare Metal Detectado. Activando máxima aceleración AMD.${C_DEF}\n"
fi

# ── Saneamiento y Seguridad ────────────────────────────────────────────────────
if [[ ! -d /sys/firmware/efi/efivars ]]; then
    echo -e "${C_RED}[✗] Sistema no arrancado en UEFI. Abortando.${C_DEF}"; exit 1
fi
if ! ping -c 1 archlinux.org >/dev/null 2>&1; then
    echo -e "${C_RED}[✗] Sin conexión a Internet. Abortando.${C_DEF}"; exit 1
fi

if grep -q "cachyos" /etc/pacman.conf 2>/dev/null; then
    sed -i '/\[cachyos\]/,+2d' /etc/pacman.conf 2>/dev/null || true
    sed -i '/cachyos-mirrorlist/d' /etc/pacman.conf 2>/dev/null || true
fi
timedatectl set-ntp true

# ── Configuración Interactiva ──────────────────────────────────────────────────
echo -e "${C_PURPLE}--- PERFIL Y TOPOLOGÍA DE ALMACENAMIENTO ---${C_DEF}\n"

echo -e "\n${C_CYAN}Discos disponibles:${C_DEF}"
lsblk -d -n -p -o NAME,SIZE,MODEL | grep -v "loop" | awk '{print NR ") " $0}'
echo ""
read -p "➤ Selecciona el número del disco de destino: " D_SEL; D_SEL=${D_SEL:-1}
TARGET_DISK=$(lsblk -d -n -p -o NAME | grep -v "loop" | sed -n "${D_SEL}p")

if [[ -z "$TARGET_DISK" ]]; then echo -e "${C_RED}[!] Disco inválido.${C_DEF}"; exit 1; fi

read -p "➤ ¿Cifrar disco completo con LUKS2? [s/N]: " LUKS_ANS
if [[ ${LUKS_ANS,,} =~ ^(s|y)$ ]]; then
    USE_LUKS="YES"
    while true; do
        read -s -p "  Contraseña LUKS: " LUKS_PASS1; echo ""
        read -s -p "  Confirma LUKS:   " LUKS_PASS2; echo ""
        [[ "$LUKS_PASS1" == "$LUKS_PASS2" && -n "$LUKS_PASS1" ]] && break || echo -e "${C_RED}[!] Las contraseñas no coinciden.${C_DEF}"
    done
else
    USE_LUKS="NO"
    LUKS_PASS1=""
fi

read -p "➤ Nombre de usuario administrador [Por defecto: iceman]: " USERNAME
USERNAME=${USERNAME:-iceman}
while true; do
    read -s -p "➤ Contraseña para $USERNAME (y root): " USER_PASS1; echo ""
    read -s -p "➤ Confirma la contraseña:              " USER_PASS2; echo ""
    [[ "$USER_PASS1" == "$USER_PASS2" && -n "$USER_PASS1" ]] && break || echo -e "${C_RED}[!] Las contraseñas no coinciden.${C_DEF}"
done

HOSTNAME_PC="iceman-titan"

# Detección de resolución para GRUB y SDDM
RAW_RES=$(cat /sys/class/drm/*/modes 2>/dev/null | grep -v '^i' | sort -t'x' -k2 -n | tail -1 || echo "1920x1080")
case "$RAW_RES" in
    3840x2160*) GRUB_SCREEN="4k"; GRUB_GFXMODE="3840x2160x32" ;;
    2560x1440*) GRUB_SCREEN="2k"; GRUB_GFXMODE="2560x1440x32" ;;
    *)          GRUB_SCREEN="1080p"; GRUB_GFXMODE="1920x1080x32" ;;
esac

echo -e "\n${C_RED}[!] ADVERTENCIA: Se destruirán TODOS los datos en ${TARGET_DISK}${C_DEF}"
read -p "➤ Escribe 'CONFIRMAR' para continuar: " CONFIRM_INPUT
[[ "$CONFIRM_INPUT" != "CONFIRMAR" ]] && exit 0

# ── Motor de Spinners y Tareas ────────────────────────────────────────────────
set -e 

cleanup_on_fail() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo -e "\n${C_RED}[!] ERROR CRÍTICO. Protocolo de emergencia...${C_DEF}"
        rm -f /mnt/iceman_chroot.sh /mnt/iceman.conf 2>/dev/null || true
        umount -R /mnt 2>/dev/null || true
        cryptsetup close cryptroot 2>/dev/null || true
    fi
    exit $exit_code
}
trap cleanup_on_fail EXIT

spinner() {
    local pid=$1
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    while [ "$(ps a | awk '{print $1}' | grep $pid)" ]; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    printf "    \b\b\b\b"
}

run_task() {
    local msg="$1"
    local cmd="$2"
    echo -ne "${C_YELLOW}[→]${C_DEF} ${C_CYAN}${msg}${C_DEF}..."
    eval "$cmd" >> "$LOG_FILE" 2>> "$ERR_LOG" &
    local pid=$!
    spinner $pid
    wait $pid
    local status=$?
    if [ $status -eq 0 ]; then
        echo -e "\r${C_GREEN}[✓] ${msg}... Completado!${C_DEF}\033[K"
    else
        echo -e "\r${C_RED}[✗] ${msg}... FALLÓ (revisa $ERR_LOG)${C_DEF}\033[K"
        exit 1
    fi
}

# ── TAREA 1: Cirugía de Disco (BTRFS + LUKS) ──────────────────────────────────
disk_setup() {
    umount -A -R /mnt 2>/dev/null || true
    cryptsetup close cryptroot 2>/dev/null || true
    wipefs -a ${TARGET_DISK}
    sgdisk -Z ${TARGET_DISK}
    sgdisk -n 1:0:+1G -t 1:ef00 -c 1:EFI  ${TARGET_DISK}
    sgdisk -n 2:0:0   -t 2:8300 -c 2:ROOT ${TARGET_DISK}
    partprobe ${TARGET_DISK}
    sleep 2

    [[ "$TARGET_DISK" == *"nvme"* || "$TARGET_DISK" == *"mmcblk"* ]] && P1="${TARGET_DISK}p1" P2="${TARGET_DISK}p2" || P1="${TARGET_DISK}1" P2="${TARGET_DISK}2"

    mkfs.fat -F32 -n EFI "$P1"

    if [[ "$USE_LUKS" == "YES" ]]; then
        echo -n "$LUKS_PASS1" | cryptsetup luksFormat --type luks2 "$P2" -
        echo -n "$LUKS_PASS1" | cryptsetup open "$P2" cryptroot -
        T_ROOT="/dev/mapper/cryptroot"
    else
        T_ROOT="$P2"
    fi

    mkfs.btrfs -f -L ICEMAN_OS "$T_ROOT"
    mount "$T_ROOT" /mnt
    for sv in @ @home @var_log @pkg @cache @snapshots; do btrfs subvolume create /mnt/$sv; done
    umount /mnt

    B_OPTS="rw,noatime,compress=zstd:3,ssd,discard=async,space_cache=v2"
    mount -o "${B_OPTS},subvol=@" "$T_ROOT" /mnt
    mkdir -p /mnt/{boot/efi,home,var/log,var/cache/pacman/pkg,var/cache,.snapshots}
    mount -o "${B_OPTS},subvol=@home" "$T_ROOT" /mnt/home
    mount -o "${B_OPTS},subvol=@var_log" "$T_ROOT" /mnt/var/log
    mount -o "${B_OPTS},subvol=@pkg" "$T_ROOT" /mnt/var/cache/pacman/pkg
    mount -o "${B_OPTS},subvol=@cache" "$T_ROOT" /mnt/var/cache
    mount -o "${B_OPTS},subvol=@snapshots" "$T_ROOT" /mnt/.snapshots
    mount "$P1" /mnt/boot/efi
}
run_task "Purgando Sectores y Particionando (BTRFS)" "disk_setup"

# ── TAREA 2: Pacstrap Base ────────────────────────────────────────────────────
pacstrap_base() {
    mkdir -p /mnt/etc
    echo 'KEYMAP=es' > /mnt/etc/vconsole.conf
    echo 'LANG=es_ES.UTF-8' > /mnt/etc/locale.conf

    BASE_PKGS="base base-devel linux linux-headers linux-firmware amd-ucode btrfs-progs nano vim git networkmanager grub efibootmgr os-prober ufw sudo zram-generator wget curl unzip jq"
    [[ "$USE_LUKS" == "YES" ]] && BASE_PKGS+=" cryptsetup"

    pacstrap -K /mnt ${BASE_PKGS}
    genfstab -U /mnt >> /mnt/etc/fstab
    sed -i 's/subvolid=[0-9]*,//g' /mnt/etc/fstab
    [[ "$USE_LUKS" == "YES" ]] && echo "cryptroot UUID=$(blkid -s UUID -o value "$P2") none luks,discard" > /mnt/etc/crypttab || true
}
run_task "Inyectando Sistema Base Arch" "pacstrap_base"

# ── Configuración de Chroot (El Motor Interno) ──────────────────────────────
cat > /mnt/iceman.conf << CONFIG
USERNAME="${USERNAME}"
USER_PASS1="${USER_PASS1}"
USE_LUKS="${USE_LUKS}"
HOSTNAME_PC="${HOSTNAME_PC}"
IS_VM="${IS_VM}"
GRUB_GFXMODE="${GRUB_GFXMODE}"
GRUB_SCREEN="${GRUB_SCREEN}"
CONFIG
chmod 600 /mnt/iceman.conf

cat << 'EOF' > /mnt/iceman_chroot.sh
#!/bin/bash
source /iceman.conf
E_LOG="/var/log/iceman-errors.log"

install_pacman() { for pkg in "$@"; do pacman -S --needed --noconfirm "$pkg" || echo "[PACMAN] Falló: $pkg" >> "$E_LOG"; done; }
install_aur() { for pkg in "$@"; do sudo -u "$USERNAME" yay -S --needed --noconfirm "$pkg" || echo "[AUR] Falló: $pkg" >> "$E_LOG"; done; }

task_1() {
    ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime && hwclock --systohc
    sed -i 's/^#es_ES.UTF-8 UTF-8/es_ES.UTF-8 UTF-8/' /etc/locale.gen && locale-gen
    echo 'LANG=es_ES.UTF-8' > /etc/locale.conf
    echo 'KEYMAP=es' > /etc/vconsole.conf
    echo "$HOSTNAME_PC" > /etc/hostname
    
    useradd -m -G wheel,video,audio,storage,network,input -s /bin/bash "$USERNAME"
    echo "root:$(openssl passwd -6 "$USER_PASS1")" | chpasswd -e
    echo "$USERNAME:$(openssl passwd -6 "$USER_PASS1")" | chpasswd -e
    echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-iceman
}

task_2() {
    pacman-key --init && pacman-key --populate archlinux
    sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' /etc/pacman.conf
    sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 15/' /etc/pacman.conf
    sed -i 's/^#Color/Color\nILoveCandy/' /etc/pacman.conf

    # Repositorios CachyOS
    pacman-key --recv-keys F3B607488DB35A47 --keyserver hkps://keyserver.ubuntu.com
    pacman-key --lsign-key F3B607488DB35A47
    echo -e "\n[cachyos]\nServer = https://mirror.cachyos.org/repo/x86_64/cachyos\n" >> /etc/pacman.conf
    pacman -Sy --noconfirm cachyos-keyring cachyos-mirrorlist
    sed -i '/\[cachyos\]/,+2d' /etc/pacman.conf
    sed -i '/^\[core\]/i [cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n' /etc/pacman.conf
    
    pacman -Syyu --noconfirm linux-cachyos linux-cachyos-headers
}

task_3() {
    sudo -u "$USERNAME" bash -c 'cd /tmp && git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm'
}

task_4() {
    # Drivers Inteligentes (VM vs Bare Metal)
    if [[ "$IS_VM" != "none" ]]; then
        install_pacman xf86-video-vmware xf86-video-qxl qemu-guest-agent mesa
        echo -e "WLR_NO_HARDWARE_CURSORS=1\nWLR_RENDERER_ALLOW_SOFTWARE=1\nLIBGL_ALWAYS_SOFTWARE=1" > /etc/environment
        systemctl enable qemu-guest-agent || true
    else
        install_pacman mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon xf86-video-amdgpu
        echo -e "vm.max_map_count=2147483642\nnet.ipv4.tcp_congestion_control=bbr\nnet.core.default_qdisc=fq_pie" > /etc/sysctl.d/99-gaming.conf
    fi

    # Display Server Wayland Nativo
    install_pacman hyprland xdg-desktop-portal-hyprland xdg-desktop-portal-gtk polkit-gnome qt5-wayland qt6-wayland
}

task_5() {
    # Caelestia Shell Core (AGS) y Dependencias Visuales
    install_pacman npm nodejs dart-sass fd ripgrep fzf hyprpicker slurp grim wl-clipboard brightnessctl pamixer pavucontrol ttf-jetbrains-mono-nerd ttf-nerd-fonts-symbols noto-fonts-emoji
    install_aur aylurs-gtk-shell swww matugen-bin hyprshot
}

task_6() {
    # SDDM Pure Dark & Gestor de Sesión
    install_pacman sddm qt5-graphicaleffects qt5-svg qt5-quickcontrols2
    systemctl enable sddm
    
    install_aur sddm-theme-catppuccin
    mkdir -p /etc/sddm.conf.d/
    cat > /etc/sddm.conf.d/theme.conf << 'SDDM'
[Theme]
Current=catppuccin-mocha
CursorTheme=Breeze_Snow

[Wayland]
EnableHiDPI=true
SDDM

    mkdir -p /usr/share/wayland-sessions
    cat > /usr/share/wayland-sessions/hyprland.desktop << 'HYPR'
[Desktop Entry]
Name=Hyprland
Comment=An intelligent dynamic tiling Wayland compositor
Exec=Hyprland
Type=Application
HYPR
}

task_7() {
    # Dotfiles Infiltration: Preparando el terreno para Caelestia
    mkdir -p /home/${USERNAME}/.config/{hypr,ags}
    
    # Auto-generamos un Hyprland Master Config seguro y estilizado
    cat > /home/${USERNAME}/.config/hypr/hyprland.conf << 'HYPRCONF'
monitor=,preferred,auto,1

exec-once = /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1
exec-once = swww-daemon --format xrgb
exec-once = ags

env = XCURSOR_SIZE,24
env = QT_QPA_PLATFORMTHEME,qt5ct

general {
    gaps_in = 5
    gaps_out = 10
    border_size = 2
    col.active_border = rgba(33ccffee) rgba(00ff99ee) 45deg
    col.inactive_border = rgba(595959aa)
    layout = dwindle
}

decoration {
    rounding = 10
    blur {
        enabled = true
        size = 3
        passes = 1
    }
    drop_shadow = yes
    shadow_range = 4
    shadow_render_power = 3
    col.shadow = rgba(1a1a1aee)
}

animations {
    enabled = yes
    bezier = myBezier, 0.05, 0.9, 0.1, 1.05
    animation = windows, 1, 7, myBezier
    animation = windowsOut, 1, 7, default, popin 80%
    animation = border, 1, 10, default
    animation = workspaces, 1, 6, default
}

dwindle {
    pseudotile = yes
    preserve_split = yes
}

# Keybindings
$mainMod = SUPER
bind = $mainMod, Return, exec, kitty
bind = $mainMod, Q, killactive, 
bind = $mainMod, M, exit, 
bind = $mainMod, E, exec, nautilus
bind = $mainMod, V, togglefloating, 
bind = $mainMod, Space, exec, ags -t applauncher
bind = $mainMod, left, movefocus, l
bind = $mainMod, right, movefocus, r
bind = $mainMod, up, movefocus, u
bind = $mainMod, down, movefocus, d
HYPRCONF

    install_pacman kitty nautilus firefox
    chown -R ${USERNAME}:${USERNAME} /home/${USERNAME}/.config
}

task_8() {
    # Audio, Red y Utilidades Core
    install_pacman pipewire pipewire-audio pipewire-pulse pipewire-alsa pipewire-jack wireplumber bluez bluez-utils
    systemctl enable bluetooth NetworkManager
}

task_9() {
    # ZSH Titanium
    pacman -S --noconfirm zsh fastfetch
    sudo -u "$USERNAME" sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended || true
    sudo -u "$USERNAME" git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "/home/${USERNAME}/.oh-my-zsh/custom/themes/powerlevel10k" || true
    sudo -u "$USERNAME" bash -c "echo 'ZSH_THEME=\"powerlevel10k/powerlevel10k\"\nsource \$HOME/.oh-my-zsh/oh-my-zsh.sh\nfastfetch' > /home/${USERNAME}/.zshrc"
    chsh -s /usr/bin/zsh "$USERNAME"
}

task_10() {
    # mkinitcpio y GRUB Particle Secure
    if [[ "$IS_VM" != "none" ]]; then
        sed -i 's/^MODULES=()/MODULES=(btrfs qxl virtio_gpu)/' /etc/mkinitcpio.conf
    else
        sed -i 's/^MODULES=()/MODULES=(btrfs amdgpu)/' /etc/mkinitcpio.conf
    fi

    if [[ "$USE_LUKS" == "YES" ]]; then
        sed -i 's/^HOOKS=(.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt filesystems fsck btrfs)/' /etc/mkinitcpio.conf
    else
        sed -i 's/^HOOKS=(.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems fsck btrfs)/' /etc/mkinitcpio.conf
    fi
    mkinitcpio -P

    git clone --quiet https://github.com/yeyushengfan258/Particle-circle-grub-theme.git /tmp/particle
    cd /tmp/particle && chmod +x install.sh && ./install.sh -t window -s "${GRUB_SCREEN}" || true
    
    echo 'GRUB_THEME="/usr/share/grub/themes/Particle-circle-window/theme.txt"' >> /etc/default/grub
    
    CMD_LINE="quiet loglevel=3 apparmor=1"
    [[ "$IS_VM" == "none" ]] && CMD_LINE="${CMD_LINE} amdgpu.ppfeaturemask=0xffffffff"
    sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\".*\"|GRUB_CMDLINE_LINUX_DEFAULT=\"${CMD_LINE}\"|" /etc/default/grub

    pacman -S --noconfirm sbctl grub-btrfs
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ICEMAN_OS
    grub-mkconfig -o /boot/grub/grub.cfg
    
    sbctl create-keys || true
}

task_11() {
    # Mantenimiento y Sello Final
    printf '[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd\n' > /etc/systemd/zram-generator.conf
    systemctl enable ufw.service fstrim.timer
    sudo -u "$USERNAME" yay -Sc --noconfirm || true
    rm -f /etc/sudoers.d/99-iceman
}
EOF
chmod +x /mnt/iceman_chroot.sh

# ── Ejecución ─────────────────────────────────────────────────────────────────
TASK_LABELS=(
    "Forjando Identidad de Usuario"
    "Configurando CachyOS Core"
    "Desplegando Motor AUR (Yay)"
    "Instalando Drivers y Wayland / Hyprland"
    "Inyectando Ecosistema AGS (Caelestia Core)"
    "Instalando SDDM Pure Dark Theme"
    "Infiltrando Dotfiles y Configuración Maestra"
    "Activando Pipewire y Servicios"
    "Configurando Shell ZSH (Powerlevel10k)"
    "Sellando GRUB Particle y mkinitcpio"
    "Purgando y Optimizando"
)

for i in "${!TASK_LABELS[@]}"; do
    N=$((i + 1))
    run_task "[${N}/11] ${TASK_LABELS[$i]}" "arch-chroot /mnt bash -c 'source /iceman_chroot.sh && task_${N}'"
done

# ── Cierre ────────────────────────────────────────────────────────────────────
trap - EXIT
rm -f /mnt/iceman_chroot.sh /mnt/iceman.conf 2>/dev/null || true
umount -R /mnt 2>/dev/null || true

echo -e "\n${C_PURPLE}╔══════════════════════════════════════════╗${C_DEF}"
echo -e "${C_PURPLE}║  TITANIUM HYPRLAND EDITION (v9.0)        ║${C_DEF}"
echo -e "${C_PURPLE}╠══════════════════════════════════════════╣${C_DEF}"
printf "${C_PURPLE}║${C_DEF}  %-14s: ${C_YELLOW}%s${C_DEF}\n" "Entorno"      "$([ "$IS_VM" != "none" ] && echo 'Virtual Machine' || echo 'Bare Metal AMD')"
printf "${C_PURPLE}║${C_DEF}  %-14s: ${C_YELLOW}%s${C_DEF}\n" "Compositor"   "Hyprland (CachyOS Git)"
printf "${C_PURPLE}║${C_DEF}  %-14s: ${C_YELLOW}%s${C_DEF}\n" "Shell"        "AGS (Caelestia Engine)"
printf "${C_PURPLE}║${C_DEF}  %-14s: ${C_YELLOW}%s${C_DEF}\n" "Display"      "SDDM Dark + Wayland"
echo -e "${C_PURPLE}╚══════════════════════════════════════════╝${C_DEF}"

echo -e "\n${C_GREEN}¡Instalación completada! Escribe 'reboot' para entrar al nuevo mundo.${C_DEF}"
