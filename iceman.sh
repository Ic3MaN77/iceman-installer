#!/bin/bash
# ==============================================================================
# ICEMAN OS ARCHITECT - TITANIUM GNOME EDITION (GOLD 3.1 - TTY FIX)
# Hardware: AMD Ryzen 9 5950X | AMD Radeon RX 7600 XT
# Contenido: Monolítico, Curl-Safe, CachyOS Nativo, Fix Bucle TTY
# ==============================================================================

# Encapsulamiento de seguridad para ejecución via curl
{
set +e 

# ── Colores ────────────────────────────────────────────────────────────────────
C_CYAN='\033[1;36m'
C_GREEN='\033[1;32m'
C_RED='\033[1;31m'
C_YELLOW='\033[1;33m'
C_DEF='\033[0m'

# ── Logs (Memoria RAM Segura) ──────────────────────────────────────────────────
LOG_FILE="/tmp/iceman-install.log"
ERR_LOG="/tmp/iceman-errors.log"
INSTALL_START=$SECONDS

> "$LOG_FILE"
> "$ERR_LOG"

clear
echo -e "${C_CYAN}======================================================${C_DEF}"
echo -e "${C_GREEN}   ICEMAN OS ARCHITECT - TITANIUM GNOME (GOLD 3.1)    ${C_DEF}"
echo -e "${C_CYAN}======================================================${C_DEF}\n"

echo -e "${C_YELLOW}[!] Inicializando matriz GNOME nativa, por favor espere...${C_DEF}\n"

# ── Saneamiento y Seguridad ────────────────────────────────────────────────────
if [[ ! -d /sys/firmware/efi/efivars ]]; then
    echo -e "${C_RED}[✗] Sistema no arrancado en UEFI. Abortando.${C_DEF}"; exit 1
fi
if ! ping -c 1 archlinux.org >/dev/null 2>&1; then
    echo -e "${C_RED}[✗] Sin conexión a Internet. Abortando.${C_DEF}"; exit 1
fi

timedatectl set-ntp true

# Inyección temprana de CachyOS en el LiveUSB (Evita doble instalación de kernel)
if ! grep -q "cachyos" /etc/pacman.conf 2>/dev/null; then
    echo -e "${C_CYAN}[+] Preparando entorno Live para CachyOS...${C_DEF}"
    pacman-key --recv-keys F3B607488DB35A47 --keyserver hkps://keyserver.ubuntu.com >/dev/null 2>&1
    pacman-key --lsign-key F3B607488DB35A47 >/dev/null 2>&1
    pacman -U 'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-keyring-20240331-1-any.pkg.tar.zst' 'https://mirror.cachyos.org/repo/x86_64/cachyos/cachyos-mirrorlist-18-1-any.pkg.tar.zst' --noconfirm >/dev/null 2>&1
    echo -e "\n[cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n" >> /etc/pacman.conf
fi

# ── Configuración Interactiva (Redirigido a /dev/tty para evitar bucles) ──────
echo -e "${C_CYAN}--- PERFIL Y TOPOLOGÍA DE ALMACENAMIENTO ---${C_DEF}\n"

echo -e "  1) Full Gaming  (Steam, ProtonPlus, Flatpak Bottles, Mandos, OBS...)"
echo -e "  2) Desktop Limpio  (Solo GNOME y herramientas de productividad)"
read -p "➤ Perfil de instalación [1-2] (Por defecto: 1): " PROFILE_SEL < /dev/tty
INSTALL_PROFILE=${PROFILE_SEL:-1}

echo -e "\n${C_CYAN}Discos disponibles:${C_DEF}"
lsblk -d -n -p -o NAME,SIZE,MODEL | grep -v "loop" | awk '{print NR ") " $0}'
echo ""
read -p "➤ Selecciona el número del disco de destino: " D_SEL < /dev/tty
D_SEL=${D_SEL:-1}
TARGET_DISK=$(lsblk -d -n -p -o NAME | grep -v "loop" | sed -n "${D_SEL}p")

if [[ -z "$TARGET_DISK" ]]; then echo -e "${C_RED}[!] Disco inválido.${C_DEF}"; exit 1; fi

read -p "➤ ¿Cifrar disco completo con LUKS2? [s/N] (Por defecto: N): " LUKS_ANS < /dev/tty
if [[ ${LUKS_ANS,,} =~ ^(s|y)$ ]]; then
    USE_LUKS="YES"
    while true; do
        read -s -p "  Contraseña LUKS: " LUKS_PASS1 < /dev/tty; echo ""
        read -s -p "  Confirma LUKS:   " LUKS_PASS2 < /dev/tty; echo ""
        [[ "$LUKS_PASS1" == "$LUKS_PASS2" && -n "$LUKS_PASS1" ]] && break || echo -e "${C_RED}[!] Las contraseñas no coinciden. Repite.${C_DEF}"
    done
else
    USE_LUKS="NO"
    LUKS_PASS1=""
fi

read -p "➤ Nombre de usuario administrador [Por defecto: iceman]: " USERNAME < /dev/tty
USERNAME=${USERNAME:-iceman}
while true; do
    read -s -p "➤ Contraseña para $USERNAME (y root): " USER_PASS1 < /dev/tty; echo ""
    read -s -p "➤ Confirma la contraseña:              " USER_PASS2 < /dev/tty; echo ""
    [[ "$USER_PASS1" == "$USER_PASS2" && -n "$USER_PASS1" ]] && break || echo -e "${C_RED}[!] Las contraseñas no coinciden. Repite.${C_DEF}"
done

read -p "➤ Nombre del equipo [Por defecto: iceman-pc]: " HOSTNAME_PC < /dev/tty
HOSTNAME_PC=${HOSTNAME_PC:-iceman-pc}

# Detección de resolución dinámica
RAW_RES=$(cat /sys/class/drm/*/modes 2>/dev/null | grep -v '^i' | sort -t'x' -k2 -n | tail -1 || echo "1920x1080")
case "$RAW_RES" in
    3840x2160*) GRUB_SCREEN="4k"; GRUB_GFXMODE="3840x2160x32" ;;
    2560x1440*) GRUB_SCREEN="2k"; GRUB_GFXMODE="2560x1440x32" ;;
    *)          GRUB_SCREEN="1080p"; GRUB_GFXMODE="1920x1080x32" ;;
esac

echo -e "\n${C_RED}[!] ADVERTENCIA: Se destruirán TODOS los datos en ${TARGET_DISK}${C_DEF}"
read -p "➤ Escribe 'CONFIRMAR' para continuar (o aborta): " CONFIRM_INPUT < /dev/tty
[[ "$CONFIRM_INPUT" != "CONFIRMAR" ]] && { echo -e "${C_YELLOW}Instalación abortada por el usuario.${C_DEF}"; exit 0; }

# ── Motor de Spinners y Tareas ────────────────────────────────────────────────
set -e 

cleanup_on_fail() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo -e "\n${C_RED}[!] ERROR CRÍTICO DETECTADO. Iniciando protocolo de emergencia...${C_DEF}"
        rm -f /mnt/iceman_chroot.sh /mnt/iceman.conf 2>/dev/null || true
        umount -R /mnt 2>/dev/null || true
        cryptsetup close cryptroot 2>/dev/null || true
        echo -e "${C_YELLOW}[!] Volúmenes desmontados y cifrado sellado por seguridad. Log en $LOG_FILE${C_DEF}"
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

echo -e "\n${C_CYAN}--- INICIANDO INSTALACIÓN DEL SISTEMA ---${C_DEF}"

# ── Cirugía de Disco y BTRFS ──────────────────────────────────────────────────
disk_setup() {
    umount -A -R /mnt 2>/dev/null || true
    cryptsetup close cryptroot 2>/dev/null || true
    wipefs -a ${TARGET_DISK}
    sgdisk -Z ${TARGET_DISK}
    sgdisk -n 1:0:+1G -t 1:ef00 -c 1:EFI  ${TARGET_DISK}
    sgdisk -n 2:0:0   -t 2:8300 -c 2:ROOT ${TARGET_DISK}
    partprobe ${TARGET_DISK}
    sleep 2

    if [[ "$TARGET_DISK" == *"nvme"* ]] || [[ "$TARGET_DISK" == *"mmcblk"* ]]; then
        P1="${TARGET_DISK}p1"; P2="${TARGET_DISK}p2"
    else
        P1="${TARGET_DISK}1"; P2="${TARGET_DISK}2"
    fi

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
    mount -o "${B_OPTS},subvol=@"          "$T_ROOT" /mnt
    mkdir -p /mnt/{boot/efi,home,var/log,var/cache/pacman/pkg,var/cache,.snapshots}
    mount -o "${B_OPTS},subvol=@home"      "$T_ROOT" /mnt/home
    mount -o "${B_OPTS},subvol=@var_log"   "$T_ROOT" /mnt/var/log
    mount -o "${B_OPTS},subvol=@pkg"       "$T_ROOT" /mnt/var/cache/pacman/pkg
    mount -o "${B_OPTS},subvol=@cache"     "$T_ROOT" /mnt/var/cache
    mount -o "${B_OPTS},subvol=@snapshots" "$T_ROOT" /mnt/.snapshots
    mount "$P1" /mnt/boot/efi
}
run_task "Purgando Sectores y Particionando GPT" "disk_setup"

# ── Pacstrap Base (Instalación Nativa CachyOS) ────────────────────────────────
pacstrap_base() {
    mkdir -p /mnt/etc
    echo 'KEYMAP=es' > /mnt/etc/vconsole.conf
    echo 'LANG=es_ES.UTF-8' > /mnt/etc/locale.conf

    # Instalamos directamente linux-cachyos gracias a la inyección previa
    BASE_PKGS="base base-devel linux-cachyos linux-cachyos-headers linux-firmware sof-firmware amd-ucode btrfs-progs btrfsmaintenance nano vim git networkmanager grub efibootmgr os-prober plymouth ufw apparmor pacman-contrib sudo zram-generator cups avahi nss-mdns sane wget curl p7zip unzip ntfs-3g exfatprogs sbctl"
    [[ "$USE_LUKS" == "YES" ]] && BASE_PKGS+=" cryptsetup"

    pacstrap -K /mnt ${BASE_PKGS}
    
    genfstab -U /mnt >> /mnt/etc/fstab
    sed -i 's/subvolid=[0-9]*,//g' /mnt/etc/fstab
    [[ "$USE_LUKS" == "YES" ]] && echo "cryptroot UUID=$(blkid -s UUID -o value "$P2") none luks,discard" > /mnt/etc/crypttab || true
}
run_task "Inyectando Sistema Base optimizado" "pacstrap_base"

# ── Configuración de Chroot (Core Titanium) ───────────────────────────────────
cat > /mnt/iceman.conf << CONFIG
USERNAME="${USERNAME}"
USER_PASS1="${USER_PASS1}"
USE_LUKS="${USE_LUKS}"
HOSTNAME_PC="${HOSTNAME_PC}"
INSTALL_PROFILE="${INSTALL_PROFILE}"
GRUB_GFXMODE="${GRUB_GFXMODE}"
GRUB_SCREEN="${GRUB_SCREEN}"
CONFIG
chmod 600 /mnt/iceman.conf

# Escribiendo el motor en el disco
cat << 'EOF' > /mnt/iceman_chroot.sh
#!/bin/bash
source /iceman.conf
E_LOG="/var/log/iceman-errors.log"

install_pacman() { for pkg in "$@"; do pacman -S --needed --noconfirm "$pkg" || echo "[$(date +%T)] [PACMAN] Falló: $pkg" >> "$E_LOG"; done; }
install_aur() { for pkg in "$@"; do sudo -u "$USERNAME" yay -S --needed --noconfirm "$pkg" || echo "[$(date +%T)] [AUR] Falló: $pkg" >> "$E_LOG"; done; }

task_1() {
    # Identidad, locale y POLKIT ABSOLUTO
    ln -sf /usr/share/zoneinfo/Europe/Madrid /etc/localtime && hwclock --systohc
    sed -i 's/^#es_ES.UTF-8 UTF-8/es_ES.UTF-8 UTF-8/' /etc/locale.gen && locale-gen
    echo 'LANG=es_ES.UTF-8' > /etc/locale.conf
    echo 'KEYMAP=es' > /etc/vconsole.conf
    echo "$HOSTNAME_PC" > /etc/hostname
    printf "127.0.0.1\tlocalhost\n::1\t\tlocalhost\n127.0.1.1\t%s.localdomain %s\n" "$HOSTNAME_PC" "$HOSTNAME_PC" > /etc/hosts

    echo "root:$(openssl passwd -6 "$USER_PASS1")" | chpasswd -e
    useradd -m -G wheel,video,audio,storage,optical,network,lp,scanner -s /bin/bash "$USERNAME"
    echo "$USERNAME:$(openssl passwd -6 "$USER_PASS1")" | chpasswd -e

    echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-iceman-install
    chmod 440 /etc/sudoers.d/99-iceman-install
    
    mkdir -p /etc/polkit-1/rules.d/
    cat << 'POLKIT1' > /etc/polkit-1/rules.d/49-nopasswd-wheel.rules
polkit.addAdminRule(function(action, subject) { return ["unix-group:wheel"]; });
polkit.addRule(function(action, subject) {
    if (subject.isInGroup("wheel")) {
        if (action.id.indexOf("org.freedesktop.color-manager.") == 0 || action.id.indexOf("org.freedesktop.packagekit.") == 0 || action.id.indexOf("org.freedesktop.NetworkManager.") == 0 || action.id.indexOf("org.freedesktop.login1.") == 0 || action.id.indexOf("org.gnome.settings-daemon.plugins.power.") == 0) {
            return polkit.Result.YES;
        }
    }
});
POLKIT1
    cat << 'POLKIT2' > /etc/polkit-1/rules.d/90-corectrl.rules
polkit.addRule(function(action, subject) {
    if ((action.id == "org.corectrl.helper.init" || action.id == "org.corectrl.helperkiller.init") && subject.local == true && subject.active == true && subject.isInGroup("corectrl")) {
            return polkit.Result.YES;
    }
});
POLKIT2
}

task_2() {
    # Pacman Candy, Reflector y consolidación CachyOS
    pacman-key --init && pacman-key --populate archlinux
    reflector --country Spain,France,Germany --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist || true

    sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' /etc/pacman.conf
    sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 15/' /etc/pacman.conf
    sed -i 's/^#Color/Color/' /etc/pacman.conf
    grep -qx 'ILoveCandy' /etc/pacman.conf || sed -i '/^Color/a ILoveCandy' /etc/pacman.conf

    if ! grep -q "cachyos" /etc/pacman.conf; then
        echo -e "\n[cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n" >> /etc/pacman.conf
        pacman -Sy --noconfirm cachyos-keyring cachyos-mirrorlist
    fi
}

task_3() {
    # Yay
    sed -i "s/^#MAKEFLAGS=\"-j2\"/MAKEFLAGS=\"-j$(nproc)\"/" /etc/makepkg.conf
    sudo -u "$USERNAME" bash -c 'cd /tmp && git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm'
}

task_4() {
    # Drivers AMD, PipeWire y Sysctl Gaming Optimizations
    PKGS_HW=(mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon vulkan-mesa-layers lib32-vulkan-mesa-layers xf86-video-amdgpu bluez bluez-utils pipewire pipewire-audio pipewire-alsa pipewire-pulse pipewire-jack wireplumber realtime-privileges corectrl mangohud lib32-mangohud ananicy-cpp file-roller gst-plugins-good gst-plugins-bad gst-plugins-ugly libavcodec tumbler ffmpegthumbnailer webp-pixbuf-loader poppler-glib freerdp)
    install_pacman "${PKGS_HW[@]}"

    cat > /etc/sysctl.d/99-gaming.conf << 'SYSCTL'
vm.max_map_count=2147483642
vm.swappiness=10
net.core.default_qdisc=fq_pie
net.ipv4.tcp_congestion_control=bbr
SYSCTL

    usermod -aG realtime,corectrl "$USERNAME"
    mkdir -p "/home/${USERNAME}/.config/autostart"
    cat > "/home/${USERNAME}/.config/autostart/corectrl.desktop" << 'CORECTRL'
[Desktop Entry]
Type=Application
Exec=corectrl --minimize-systray
Hidden=false
X-GNOME-Autostart-enabled=true
Name=CoreCtrl
CORECTRL
    systemctl enable bluetooth ananicy-cpp avahi-daemon cups btrfsmaintenance-refresh.service
}

task_5() {
    # Ecosistema GNOME Nativo
    PKGS_GNOME=(gnome gnome-tweaks gdm xdg-desktop-portal-gnome flatpak power-profiles-daemon ttf-ubuntu-font-family ttf-dejavu ttf-liberation ttf-roboto noto-fonts sushi nautilus-image-converter python-nautilus gnome-browser-connector gnome-software gnome-software-packagekit-plugin systemd-oomd)
    install_pacman "${PKGS_GNOME[@]}"
    systemctl enable gdm NetworkManager apparmor power-profiles-daemon systemd-oomd
    flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true
}

task_6() {
    # Gaming Stack, Controladores y Flatpak (Perfil Dinámico)
    [[ "$INSTALL_PROFILE" != "1" ]] && return 0

    PKGS_LIBS_32=(giflib lib32-giflib libpng lib32-libpng libldap lib32-libldap gnutls lib32-gnutls mpg123 lib32-mpg123 openal lib32-openal v4l-utils lib32-v4l-utils libpulse lib32-libpulse alsa-plugins lib32-alsa-plugins alsa-lib lib32-alsa-lib sqlite lib32-sqlite libxcomposite lib32-libxcomposite ocl-icd lib32-ocl-icd libva lib32-libva gtk3 lib32-gtk3 gst-plugins-base-libs lib32-gst-plugins-base-libs vulkan-icd-loader lib32-vulkan-icd-loader vkd3d)
    install_pacman "${PKGS_LIBS_32[@]}"

    PKGS_GAMING=(steam steam-native-runtime wine-staging winetricks lutris gamemode lib32-gamemode gamescope game-devices-udev discord obs-studio)
    install_pacman "${PKGS_GAMING[@]}"
    
    install_aur xpadneo-dkms ds4drv protonplus
    flatpak install -y flathub com.usebottles.bottles || echo "[FLATPAK] Falló Bottles" >> "$E_LOG"
}

task_7() {
    # Productividad y Gestión AUR
    AUR_APPS=(pamac-aur libpamac-flatpak-plugin onlyoffice-bin extension-manager btrfs-assistant mission-center stacer-bin ttf-ms-fonts)
    if [[ "$INSTALL_PROFILE" == "1" ]]; then
        AUR_APPS+=(goverlay-bin input-remapper-git noisetorch-bin)
    fi
    install_aur "${AUR_APPS[@]}"
    install_pacman firefox thunderbird qbittorrent filezilla
    [[ "$INSTALL_PROFILE" == "1" ]] && systemctl enable input-remapper || true
}

task_8() {
    # Estética GNOME, Wallpapers Default y GSchema Blindado
    install_pacman papirus-icon-theme yaru-icon-theme
    AUR_EST=(adw-gtk3 papirus-folders-git breezex-cursor-theme gnome-shell-extension-dash-to-dock gnome-shell-extension-blur-my-shell gnome-shell-extension-vitals gnome-shell-extension-appindicator gnome-shell-extension-caffeine gnome-shell-extension-clipboard-indicator gnome-shell-extension-gsconnect gnome-shell-extension-just-perfection gnome-shell-extension-gamemode gnome-shell-extension-sound-output-device-chooser gnome-shell-extension-tilingshell gnome-shell-extension-noannoyance)
    install_aur "${AUR_EST[@]}"
    papirus-folders -C yaru --theme Papirus-Dark || true

    git clone --quiet https://github.com/Ic3MaN77/iceman-installer.git /tmp/iceman-repo
    mkdir -p /usr/share/backgrounds/iceman /usr/share/gnome-background-properties
    cp /tmp/iceman-repo/wallpapers/*.webp /usr/share/backgrounds/iceman/ 2>/dev/null || true

    FIRST_WP=$(ls -1 /usr/share/backgrounds/iceman/*.webp 2>/dev/null | head -n 1)
    if [[ -n "$FIRST_WP" ]]; then
        ln -sf "$FIRST_WP" /usr/share/backgrounds/iceman/default.webp
    fi

    {
        echo '<?xml version="1.0" encoding="UTF-8"?><wallpapers>'
        for wp in /usr/share/backgrounds/iceman/*.webp; do
            name=$(basename "$wp" .webp)
            printf '<wallpaper deleted="false"><name>%s</name><filename>%s</filename><options>zoom</options><pcolor>#000</pcolor><scolor>#000</scolor></wallpaper>\n' "$name" "$wp"
        done
        echo '</wallpapers>'
    } > /usr/share/gnome-background-properties/iceman.xml

    mkdir -p /usr/share/glib-2.0/schemas/
    cat > /usr/share/glib-2.0/schemas/99-iceman.gschema.override << 'SCHEMA'
[org.gnome.desktop.interface]
color-scheme='prefer-dark'
gtk-theme='adw-gtk3-dark'
icon-theme='Papirus-Dark'
cursor-theme='BreezeX-Dark'

[org.gnome.desktop.background]
picture-uri='file:///usr/share/backgrounds/iceman/default.webp'
picture-uri-dark='file:///usr/share/backgrounds/iceman/default.webp'

[org.gnome.desktop.screensaver]
picture-uri='file:///usr/share/backgrounds/iceman/default.webp'
SCHEMA
    glib-compile-schemas /usr/share/glib-2.0/schemas/
}

task_9() {
    # Shell ZSH y Powerlevel10k
    pacman -S --noconfirm zsh fastfetch zsh-autosuggestions zsh-syntax-highlighting
    sudo -u "$USERNAME" git clone --depth=1 https://github.com/ohmyzsh/ohmyzsh.git "/home/${USERNAME}/.oh-my-zsh" || true
    sudo -u "$USERNAME" git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "/home/${USERNAME}/.oh-my-zsh/custom/themes/powerlevel10k" || true

    sudo -u "$USERNAME" bash -c "cat > /home/${USERNAME}/.zshrc" << 'ZSHRC'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh 2>/dev/null || true
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh 2>/dev/null || true
source "$ZSH/oh-my-zsh.sh" 2>/dev/null || true
fastfetch -l cachyos
ZSHRC
    chsh -s /usr/bin/zsh "$USERNAME"
}

task_10() {
    # mkinitcpio, GRUB PARTICLE-CIRCLE Manual y SECURE BOOT
    sed -i 's/^MODULES=()/MODULES=(btrfs amdgpu)/' /etc/mkinitcpio.conf
    if [[ "$USE_LUKS" == "YES" ]]; then
        sed -i 's/^HOOKS=(.*/HOOKS=(base udev plymouth autodetect modconf kms keyboard keymap consolefont block encrypt filesystems fsck btrfs)/' /etc/mkinitcpio.conf
    else
        sed -i 's/^HOOKS=(.*/HOOKS=(base udev plymouth autodetect modconf kms keyboard keymap consolefont block filesystems fsck btrfs)/' /etc/mkinitcpio.conf
    fi
    plymouth-set-default-theme -R bgrt || true
    mkinitcpio -P

    pacman -S --noconfirm snapper snap-pac grub-btrfs
    umount /.snapshots 2>/dev/null || true
    rm -rf /.snapshots
    snapper --no-dbus -c root create-config / || true
    mount -a
    chmod 750 /.snapshots
    systemctl enable snapper-timeline.timer snapper-cleanup.timer grub-btrfsd.service || true

    git clone --quiet https://github.com/yeyushengfan258/Particle-circle-grub-theme.git /tmp/particle
    mkdir -p /usr/share/grub/themes/Particle-circle-window
    cp -r /tmp/particle/Particle-circle-window/* /usr/share/grub/themes/Particle-circle-window/ 2>/dev/null || true
    
    echo "LANG=es_ES.UTF-8" >> /etc/default/grub
    if grep -q '^GRUB_THEME=' /etc/default/grub; then
        sed -i 's|^GRUB_THEME=.*|GRUB_THEME="/usr/share/grub/themes/Particle-circle-window/theme.txt"|' /etc/default/grub
    else
        echo 'GRUB_THEME="/usr/share/grub/themes/Particle-circle-window/theme.txt"' >> /etc/default/grub
    fi

    if grep -q '^GRUB_GFXMODE=' /etc/default/grub; then
        sed -i "s|^GRUB_GFXMODE=.*|GRUB_GFXMODE=${GRUB_GFXMODE}|" /etc/default/grub
    else
        echo "GRUB_GFXMODE=${GRUB_GFXMODE}" >> /etc/default/grub
    fi
    grep -q '^GRUB_GFXPAYLOAD_LINUX=' /etc/default/grub || echo 'GRUB_GFXPAYLOAD_LINUX=keep' >> /etc/default/grub

    CMD_LINE="quiet splash loglevel=3 amdgpu.ppfeaturemask=0xffffffff apparmor=1 lsm=landlock,lockdown,yama,integrity,apparmor,bpf"
    sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\".*\"|GRUB_CMDLINE_LINUX_DEFAULT=\"${CMD_LINE}\"|" /etc/default/grub

    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ICEMAN_OS
    grub-mkconfig -o /boot/grub/grub.cfg
    
    sbctl create-keys || true
    sbctl sign -s /boot/efi/EFI/ICEMAN_OS/grubx64.efi || true
    sbctl sign -s /boot/vmlinuz-linux-cachyos || true
    
    snapper --no-dbus -c root create --description "baseline-titanium-$(date +%F)" || true
}

task_11() {
    # Mantenimiento Automático y Sello Final
    printf '[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd\nswap-priority = 100\nfs-type = swap\n' > /etc/systemd/zram-generator.conf
    systemctl enable ufw.service paccache.timer fstrim.timer
    sed -i 's/^#SystemMaxUse=.*/SystemMaxUse=50M/' /etc/systemd/journald.conf

    sudo -u "$USERNAME" yay -Yc --noconfirm || true
    sudo -u "$USERNAME" yay -Sc --noconfirm || true
    paccache -r || true

    rm -f /etc/sudoers.d/99-iceman-install
    chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}"
    chmod 700 "/home/${USERNAME}"
}
EOF
chmod +x /mnt/iceman_chroot.sh

# ── Ejecución de Tareas en Bucle (Visual Spinner) ─────────────────────────────
TASK_LABELS=(
    "Forjando Identidad y Fix Polkit CoreCtrl"
    "Configurando Gestor Pacman y Repos CachyOS"
    "Desplegando Motor AUR (Yay)"
    "Instalando Drivers, Sysctl Gaming y Miniaturas"
    "Construyendo Ecosistema GNOME Nativo"
    "Inyectando Gaming Stack (Mandos, ProtonPlus, Flatpak)"
    "Desplegando Productividad y Gestión"
    "Inyectando Theming GSchema y Extensiones"
    "Configurando Shell ZSH (Powerlevel10k)"
    "Sellando Particle-Circle, Secure Boot y Snapper"
    "Optimizando y Purgando Sistema"
)

for i in "${!TASK_LABELS[@]}"; do
    N=$((i + 1))
    run_task "[${N}/11] ${TASK_LABELS[$i]}" "arch-chroot /mnt bash -c 'source /iceman_chroot.sh && task_${N}'"
done

# ── Cierre y Resumen ──────────────────────────────────────────────────────────
trap - EXIT
mkdir -p /mnt/var/log/
cp "$LOG_FILE" /mnt/var/log/iceman-install.log 2>/dev/null || true
cp "$ERR_LOG" /mnt/var/log/iceman-errors.log 2>/dev/null || true

rm -f /mnt/iceman_chroot.sh /mnt/iceman.conf 2>/dev/null || true
umount -R /mnt 2>/dev/null || true

ELAPSED=$(( SECONDS - INSTALL_START ))
echo -e "\n${C_GREEN}╔══════════════════════════════════════════╗${C_DEF}"
echo -e "${C_GREEN}║  TITANIUM GNOME EDITION (GOLD 3.1)       ║${C_DEF}"
echo -e "${C_GREEN}╠══════════════════════════════════════════╣${C_DEF}"
printf "${C_GREEN}║${C_DEF}  %-14s: ${C_YELLOW}%s${C_DEF}\n" "Hostname"     "$HOSTNAME_PC"
printf "${C_GREEN}║${C_DEF}  %-14s: ${C_YELLOW}%s${C_DEF}\n" "Usuario"      "$USERNAME"
printf "${C_GREEN}║${C_DEF}  %-14s: ${C_YELLOW}%s${C_DEF}\n" "GRUB"         "Particle Circle @ ${GRUB_SCREEN}"
printf "${C_GREEN}║${C_DEF}  %-14s: ${C_YELLOW}%s${C_DEF}\n" "Perfil"       "$([ "$INSTALL_PROFILE" == "1" ] && echo 'Full Gaming' || echo 'Desktop Limpio')"
printf "${C_GREEN}║${C_DEF}  %-14s: ${C_YELLOW}%d min %d seg${C_DEF}\n" "Tiempo total" "$(( ELAPSED / 60 ))" "$(( ELAPSED % 60 ))"
echo -e "${C_GREEN}╚══════════════════════════════════════════╝${C_DEF}"

echo -e "\n${C_YELLOW}🚀 PASO FINAL: ACTIVAR SECURE BOOT${C_DEF}"
echo -e "Sigue estos 3 pasos antes de jugar:"
echo -e "  ${C_CYAN}1.${C_DEF} Escribe 'reboot' y entra en la BIOS de tu equipo."
echo -e "  ${C_CYAN}2.${C_DEF} Ve a Secure Boot y elige ${C_YELLOW}'Erase Keys'${C_DEF} o ${C_YELLOW}'Reset to Setup Mode'${C_DEF}."
echo -e "  ${C_CYAN}3.${C_DEF} Inicia tu nuevo Iceman OS, abre terminal y escribe:"
echo -e "     ${C_GREEN}sudo sbctl enroll-keys -m${C_DEF}"
echo -e "\n¡Listo! Escribe ${C_YELLOW}reboot${C_DEF} para arrancar."

# Cierre del encapsulamiento de seguridad curl
}
