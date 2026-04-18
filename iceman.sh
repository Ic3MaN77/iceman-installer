#!/bin/bash
# ==============================================================================
# ICEMAN OS ARCHITECT - TITANIUM ULTRA (v7.0 - THE TRUE UNABRIDGED EDITION)
# Hardware: AMD Ryzen 9 5950X | AMD Radeon RX 7600 XT
# Contenido: 100% Gold 2.0 (LUKS, P10k, GSchema, 32-bit Libs) + Motor v6
# ==============================================================================

# ── 0. PREPARACIÓN INICIAL (SIN STRICT MODE AÚN) ──────────────────────────────
set +e 

C_CYAN='\033[1;36m'
C_GREEN='\033[1;32m'
C_RED='\033[1;31m'
C_YELLOW='\033[1;33m'
C_DEF='\033[0m'

LOG_FILE="/tmp/iceman-install.log"
ERR_LOG="/tmp/iceman-errors.log"
INSTALL_START=$SECONDS

> "$LOG_FILE"
> "$ERR_LOG"

clear
echo -e "${C_CYAN}======================================================${C_DEF}"
echo -e "${C_GREEN}   ICEMAN OS ARCHITECT - TITANIUM ULTRA (v7.0)        ${C_DEF}"
echo -e "${C_CYAN}======================================================${C_DEF}\n"

# Verificaciones de Seguridad (Gold 2.0)
if [[ ! -d /sys/firmware/efi/efivars ]]; then
    echo -e "${C_RED}[✗] Sistema no arrancado en UEFI. Abortando.${C_DEF}"; exit 1
fi
if ! ping -c 1 archlinux.org >/dev/null 2>&1; then
    echo -e "${C_RED}[✗] Sin conexión a Internet. Abortando.${C_DEF}"; exit 1
fi

echo -e "${C_YELLOW}[!] Limpiando rastros de repositorios antiguos en entorno Live...${C_DEF}"
if grep -q "cachyos" /etc/pacman.conf 2>/dev/null; then
    sed -i '/\[cachyos\]/,+2d' /etc/pacman.conf 2>/dev/null || true
    sed -i '/cachyos-mirrorlist/d' /etc/pacman.conf 2>/dev/null || true
fi
timedatectl set-ntp true
sleep 1

# ── 1. RECOLECCIÓN DE DATOS E INTERFAZ ────────────────────────────────────────
echo -e "\n${C_CYAN}--- CONFIGURACIÓN INTERACTIVA ---${C_DEF}"

echo -e "\n  1) Full Gaming  (Steam, ProtonPlus, Flatpak Bottles, Mandos, OBS...)"
echo -e "  2) Desktop Limpio  (Solo GNOME y herramientas de productividad)"
read -p "➤ Perfil de instalación [1-2] (Por defecto: 1): " PROFILE_SEL
INSTALL_PROFILE=${PROFILE_SEL:-1}

echo -e "\n${C_CYAN}Discos disponibles:${C_DEF}"
lsblk -d -n -p -o NAME,SIZE,MODEL | grep -v "loop" | awk '{print NR ") " $0}'
echo ""
read -p "➤ Selecciona el número del disco: " D_SEL; D_SEL=${D_SEL:-1}
TARGET_DISK=$(lsblk -d -n -p -o NAME | grep -v "loop" | sed -n "${D_SEL}p")

if [[ -z "$TARGET_DISK" ]]; then echo -e "${C_RED}Disco no válido.${C_DEF}"; exit 1; fi

read -p "➤ ¿Cifrar disco completo con LUKS2? [s/N] (Por defecto: N): " LUKS_ANS
if [[ ${LUKS_ANS,,} =~ ^(s|y)$ ]]; then
    USE_LUKS="YES"
    while true; do
        read -s -p "  Contraseña LUKS: " LUKS_PASS1; echo ""
        read -s -p "  Confirma LUKS:   " LUKS_PASS2; echo ""
        [[ "$LUKS_PASS1" == "$LUKS_PASS2" && -n "$LUKS_PASS1" ]] && break || echo -e "${C_RED}[!] Las contraseñas no coinciden. Repite.${C_DEF}"
    done
else
    USE_LUKS="NO"
    LUKS_PASS1=""
fi

read -p "➤ Nombre de Usuario [iceman]: " USERNAME; USERNAME=${USERNAME:-iceman}
while true; do
    read -s -p "➤ Contraseña para $USERNAME (y root): " USER_PASS1; echo ""
    read -s -p "➤ Confirma la contraseña:              " USER_PASS2; echo ""
    [[ "$USER_PASS1" == "$USER_PASS2" && -n "$USER_PASS1" ]] && break || echo -e "${C_RED}[!] Las contraseñas no coinciden. Repite.${C_DEF}"
done

read -p "➤ Nombre del Equipo [iceman-pc]: " HOSTNAME_PC; HOSTNAME_PC=${HOSTNAME_PC:-iceman-pc}

# Detección de VM y Resolución (Gold 2.0)
IS_VM=$(systemd-detect-virt 2>/dev/null || echo "none")
RAW_RES=$(cat /sys/class/drm/*/modes 2>/dev/null | grep -v '^i' | sort -t'x' -k2 -n | tail -1 || echo "1920x1080")
case "$RAW_RES" in
    3840x2160*) GRUB_SCREEN="4k"; GRUB_GFXMODE="3840x2160x32" ;;
    2560x1440*) GRUB_SCREEN="2k"; GRUB_GFXMODE="2560x1440x32" ;;
    *)          GRUB_SCREEN="1080p"; GRUB_GFXMODE="1920x1080x32" ;;
esac

echo -e "\n${C_RED}[!] ADVERTENCIA: Se destruirán TODOS los datos en ${TARGET_DISK}${C_DEF}"
read -p "➤ Escribe 'CONFIRMAR' para continuar (o aborta): " CONFIRM_INPUT
[[ "$CONFIRM_INPUT" != "CONFIRMAR" ]] && { echo -e "${C_YELLOW}Instalación abortada por el usuario.${C_DEF}"; exit 0; }

# ── 2. MOTOR VISUAL (SPINNER) Y PROTECCIÓN ────────────────────────────────────
set -e

cleanup_on_fail() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        echo -e "\n${C_RED}[!] ERROR CRÍTICO DETECTADO. Iniciando protocolo de emergencia...${C_DEF}"
        umount -R /mnt 2>/dev/null || true
        cryptsetup close cryptroot 2>/dev/null || true
        echo -e "${C_YELLOW}[!] Volúmenes desmontados. Log en $LOG_FILE${C_DEF}"
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
    echo -ne "${C_YELLOW}[*] ${msg}...${C_DEF}"
    eval "$cmd" >> "$LOG_FILE" 2>> "$ERR_LOG" &
    local pid=$!
    spinner $pid
    wait $pid
    local status=$?
    if [ $status -eq 0 ]; then
        echo -e "\r${C_GREEN}[✓] ${msg} completado.${C_DEF}"
    else
        echo -e "\r${C_RED}[✗] Error en: ${msg}. Revisa $ERR_LOG${C_DEF}"
        exit 1
    fi
}

echo -e "\n${C_CYAN}--- INICIANDO INSTALACIÓN GOLD 2.0 ---${C_DEF}"

# ── 3. PARTICIONADO Y BTRFS (INCLUYE LUKS) ────────────────────────────────────
prepare_storage() {
    umount -A -R /mnt 2>/dev/null || true
    cryptsetup close cryptroot 2>/dev/null || true
    wipefs -a "$TARGET_DISK"
    sgdisk -Z "$TARGET_DISK"
    sgdisk -n 1:0:+1024M -t 1:ef00 -c 1:EFI "$TARGET_DISK"
    sgdisk -n 2:0:0      -t 2:8300 -c 2:ROOT "$TARGET_DISK"
    partprobe "$TARGET_DISK" && sleep 2
    
    [[ "$TARGET_DISK" == *"nvme"* || "$TARGET_DISK" == *"mmcblk"* ]] && { P1="${TARGET_DISK}p1"; P2="${TARGET_DISK}p2"; } || { P1="${TARGET_DISK}1"; P2="${TARGET_DISK}2"; }
    
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
    if [[ "$IS_VM" != "none" ]]; then B_OPTS="rw,noatime,compress=zstd:1,ssd,space_cache=v2"; fi

    mount -o "${B_OPTS},subvol=@" "$T_ROOT" /mnt
    mkdir -p /mnt/{boot/efi,home,var/log,var/cache/pacman/pkg,var/cache,.snapshots}
    mount -o "${B_OPTS},subvol=@home" "$T_ROOT" /mnt/home
    mount -o "${B_OPTS},subvol=@var_log" "$T_ROOT" /mnt/var/log
    mount -o "${B_OPTS},subvol=@pkg" "$T_ROOT" /mnt/var/cache/pacman/pkg
    mount -o "${B_OPTS},subvol=@cache" "$T_ROOT" /mnt/var/cache
    mount -o "${B_OPTS},subvol=@snapshots" "$T_ROOT" /mnt/.snapshots
    mount "$P1" /mnt/boot/efi
}
run_task "Estructurando disco y cifrado (si aplica)" "prepare_storage"

# ── 4. INSTALACIÓN BASE ARCH PURO (RESTORED GOLD PACKAGES) ────────────────────
install_arch_base() {
    mkdir -p /mnt/etc
    echo 'KEYMAP=es' > /mnt/etc/vconsole.conf
    echo 'LANG=es_ES.UTF-8' > /mnt/etc/locale.conf

    BASE_PKGS="base base-devel linux-firmware sof-firmware amd-ucode btrfs-progs btrfsmaintenance nano vim git networkmanager grub efibootmgr os-prober plymouth ufw apparmor pacman-contrib sudo zram-generator cups avahi nss-mdns sane wget curl p7zip unzip ntfs-3g exfatprogs sbctl snapper snap-pac grub-btrfs inotify-tools"
    [[ "$USE_LUKS" == "YES" ]] && BASE_PKGS+=" cryptsetup"

    pacstrap -K /mnt $BASE_PKGS
    
    genfstab -U /mnt >> /mnt/etc/fstab
    sed -i 's/subvolid=[0-9]*,//g' /mnt/etc/fstab
    [[ "$USE_LUKS" == "YES" ]] && echo "cryptroot UUID=$(blkid -s UUID -o value "$P2") none luks,discard" > /mnt/etc/crypttab || true
}
run_task "Instalando sistema base de Arch Linux" "install_arch_base"

# ── 5. MATRIZ DE INYECCIÓN CHROOT (100% CÓDIGO GOLD) ──────────────────────────
cat << EOF > /mnt/root/vars.sh
USERNAME="$USERNAME"
USER_PASS1="$USER_PASS1"
HOSTNAME_PC="$HOSTNAME_PC"
INSTALL_PROFILE="$INSTALL_PROFILE"
GRUB_GFXMODE="$GRUB_GFXMODE"
GRUB_SCREEN="$GRUB_SCREEN"
USE_LUKS="$USE_LUKS"
EOF

cat << 'CHROOT_EOF' > /mnt/root/internal.sh
#!/bin/bash
set -e
source /root/vars.sh

# A. Identidad y Polkit Core (Fix Gold)
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

# B. Reflector, Pacman Candy y CachyOS Inyectado
pacman-key --init && pacman-key --populate archlinux
reflector --country Spain,France,Germany --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist

sed -i '/^#\[multilib\]/{s/^#//;n;s/^#//}' /etc/pacman.conf
sed -i 's/^#ParallelDownloads.*/ParallelDownloads = 15/' /etc/pacman.conf
sed -i 's/^#Color/Color/' /etc/pacman.conf
grep -qx 'ILoveCandy' /etc/pacman.conf || sed -i '/^Color/a ILoveCandy' /etc/pacman.conf

pacman-key --recv-keys F3B607488DB35A47 --keyserver hkps://keyserver.ubuntu.com
pacman-key --lsign-key F3B607488DB35A47
echo -e "\n[cachyos]\nServer = https://mirror.cachyos.org/repo/x86_64/cachyos\n" >> /etc/pacman.conf
pacman -Sy --noconfirm cachyos-keyring cachyos-mirrorlist
sed -i '/\[cachyos\]/,+2d' /etc/pacman.conf
echo -e "\n[cachyos]\nInclude = /etc/pacman.d/cachyos-mirrorlist\n" >> /etc/pacman.conf
pacman -Syu --noconfirm linux-cachyos linux-cachyos-headers

# C. YAY Compilador
sed -i "s/^#MAKEFLAGS=\"-j2\"/MAKEFLAGS=\"-j$(nproc)\"/" /etc/makepkg.conf
sudo -u "$USERNAME" bash -c 'cd /tmp && git clone https://aur.archlinux.org/yay-bin.git && cd yay-bin && makepkg -si --noconfirm'

# D. Hardware, Sysctl y Servicios (Restaurado Gold 2.0 list)
pacman -S --needed --noconfirm mesa lib32-mesa vulkan-radeon lib32-vulkan-radeon vulkan-mesa-layers lib32-vulkan-mesa-layers xf86-video-amdgpu bluez bluez-utils pipewire pipewire-audio pipewire-alsa pipewire-pulse pipewire-jack wireplumber realtime-privileges corectrl mangohud lib32-mangohud ananicy-cpp file-roller gst-plugins-good gst-plugins-bad gst-plugins-ugly libavcodec tumbler ffmpegthumbnailer webp-pixbuf-loader poppler-glib freerdp

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

# E. GNOME Ecosistema
pacman -S --needed --noconfirm gnome gnome-tweaks gdm xdg-desktop-portal-gnome flatpak power-profiles-daemon ttf-ubuntu-font-family ttf-dejavu ttf-liberation ttf-roboto noto-fonts sushi nautilus-image-converter python-nautilus gnome-browser-connector gnome-software gnome-software-packagekit-plugin systemd-oomd
systemctl enable gdm NetworkManager apparmor power-profiles-daemon systemd-oomd
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true

# F. Gaming Stack y Librerías de 32-bit (Si es perfil 1)
if [[ "$INSTALL_PROFILE" == "1" ]]; then
    pacman -S --needed --noconfirm giflib lib32-giflib libpng lib32-libpng libldap lib32-libldap gnutls lib32-gnutls mpg123 lib32-mpg123 openal lib32-openal v4l-utils lib32-v4l-utils libpulse lib32-libpulse alsa-plugins lib32-alsa-plugins alsa-lib lib32-alsa-lib sqlite lib32-sqlite libxcomposite lib32-libxcomposite ocl-icd lib32-ocl-icd libva lib32-libva gtk3 lib32-gtk3 gst-plugins-base-libs lib32-gst-plugins-base-libs vulkan-icd-loader lib32-vulkan-icd-loader vkd3d
    pacman -S --needed --noconfirm steam steam-native-runtime wine-staging winetricks lutris gamemode lib32-gamemode gamescope game-devices-udev discord obs-studio
    sudo -u "$USERNAME" yay -S --needed --noconfirm xpadneo-dkms ds4drv protonplus
    flatpak install -y flathub com.usebottles.bottles || true
fi

# G. Productividad & AUR Extra
AUR_APPS=(pamac-aur libpamac-flatpak-plugin onlyoffice-bin extension-manager btrfs-assistant mission-center stacer-bin ttf-ms-fonts)
[[ "$INSTALL_PROFILE" == "1" ]] && AUR_APPS+=(goverlay-bin input-remapper-git noisetorch-bin)
sudo -u "$USERNAME" yay -S --needed --noconfirm "${AUR_APPS[@]}"
pacman -S --needed --noconfirm firefox thunderbird qbittorrent filezilla
[[ "$INSTALL_PROFILE" == "1" ]] && systemctl enable input-remapper || true

# H. Estética, GSchema Override y Wallpapers (El método nativo tuyo)
pacman -S --needed --noconfirm papirus-icon-theme yaru-icon-theme
sudo -u "$USERNAME" yay -S --needed --noconfirm adw-gtk3 papirus-folders-git breezex-cursor-theme gnome-shell-extension-dash-to-dock gnome-shell-extension-blur-my-shell gnome-shell-extension-vitals gnome-shell-extension-appindicator gnome-shell-extension-caffeine gnome-shell-extension-clipboard-indicator gnome-shell-extension-gsconnect gnome-shell-extension-just-perfection gnome-shell-extension-gamemode gnome-shell-extension-sound-output-device-chooser gnome-shell-extension-tilingshell gnome-shell-extension-noannoyance
papirus-folders -C yaru --theme Papirus-Dark || true

git clone --quiet https://github.com/Ic3MaN77/iceman-installer.git /tmp/iceman-repo || true
mkdir -p /usr/share/backgrounds/iceman /usr/share/gnome-background-properties
cp /tmp/iceman-repo/wallpapers/*.webp /usr/share/backgrounds/iceman/ 2>/dev/null || true
cp /usr/share/backgrounds/iceman/Cyberpunk_City.webp /usr/share/backgrounds/iceman/default.webp 2>/dev/null || cp /usr/share/backgrounds/iceman/*.webp /usr/share/backgrounds/iceman/default.webp 2>/dev/null || true

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
SCHEMA
glib-compile-schemas /usr/share/glib-2.0/schemas/

# I. ZSH & Powerlevel10k
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

# J. Mkinitcpio, Particle Circle y Secure Boot
sed -i 's/^MODULES=()/MODULES=(btrfs amdgpu)/' /etc/mkinitcpio.conf
if [[ "$USE_LUKS" == "YES" ]]; then
    sed -i 's/^HOOKS=(.*/HOOKS=(base udev plymouth autodetect modconf kms keyboard keymap consolefont block encrypt filesystems fsck btrfs)/' /etc/mkinitcpio.conf
else
    sed -i 's/^HOOKS=(.*/HOOKS=(base udev plymouth autodetect modconf kms keyboard keymap consolefont block filesystems fsck btrfs)/' /etc/mkinitcpio.conf
fi
plymouth-set-default-theme -R bgrt || true
mkinitcpio -P

git clone --quiet https://github.com/yeyushengfan258/Particle-circle-grub-theme.git /tmp/particle || true
cd /tmp/particle && chmod +x install.sh && ./install.sh -t window -s "${GRUB_SCREEN}" || true

echo "LANG=es_ES.UTF-8" >> /etc/default/grub
sed -i 's|^GRUB_THEME=.*|GRUB_THEME="/usr/share/grub/themes/Particle-circle-window/theme.txt"|' /etc/default/grub || echo 'GRUB_THEME="/usr/share/grub/themes/Particle-circle-window/theme.txt"' >> /etc/default/grub
sed -i "s|^GRUB_GFXMODE=.*|GRUB_GFXMODE=${GRUB_GFXMODE}|" /etc/default/grub || echo "GRUB_GFXMODE=${GRUB_GFXMODE}" >> /etc/default/grub
grep -q '^GRUB_GFXPAYLOAD_LINUX=' /etc/default/grub || echo 'GRUB_GFXPAYLOAD_LINUX=keep' >> /etc/default/grub

CMD_LINE="quiet splash loglevel=3 amdgpu.ppfeaturemask=0xffffffff apparmor=1 lsm=landlock,lockdown,yama,integrity,apparmor,bpf"
sed -i "s|GRUB_CMDLINE_LINUX_DEFAULT=\".*\"|GRUB_CMDLINE_LINUX_DEFAULT=\"${CMD_LINE}\"|" /etc/default/grub

grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ICEMAN_OS
grub-mkconfig -o /boot/grub/grub.cfg

sbctl create-keys || true
sbctl sign -s /boot/efi/EFI/ICEMAN_OS/grubx64.efi || true
sbctl sign -s /boot/vmlinuz-linux-cachyos || true

# K. Mantenimiento Automático (ZRAM, Snapper, Limpieza)
printf '[zram0]\nzram-size = ram / 2\ncompression-algorithm = zstd\nswap-priority = 100\nfs-type = swap\n' > /etc/systemd/zram-generator.conf
systemctl enable ufw.service paccache.timer fstrim.timer
sed -i 's/^#SystemMaxUse=.*/SystemMaxUse=50M/' /etc/systemd/journald.conf

rm -rf /.snapshots && snapper --no-dbus -c root create-config / || true
chmod 750 /.snapshots
systemctl enable snapper-timeline.timer snapper-cleanup.timer grub-btrfsd.service || true

sudo -u "$USERNAME" yay -Yc --noconfirm || true
sudo -u "$USERNAME" yay -Sc --noconfirm || true
paccache -r || true

rm -f /etc/sudoers.d/99-iceman-install
chown -R "${USERNAME}:${USERNAME}" "/home/${USERNAME}"
chmod 700 "/home/${USERNAME}"

CHROOT_EOF

chmod +x /mnt/root/internal.sh
run_task "Inyectando Core Gold 2.0 (Gaming, Theming y Optimizaciones)" "arch-chroot /mnt /root/internal.sh"

# ── 6. SELLADO FINAL ──────────────────────────────────────────────────────────
post_install() {
    trap - EXIT
    rm -f /mnt/root/vars.sh /mnt/root/internal.sh
    mkdir -p /mnt/var/log/
    cp "$LOG_FILE" /mnt/var/log/iceman-install.log 2>/dev/null || true
    cp "$ERR_LOG" /mnt/var/log/iceman-errors.log 2>/dev/null || true
    umount -R /mnt 2>/dev/null || true
}
run_task "Sellando instalación y guardando logs" "post_install"

ELAPSED=$(( SECONDS - INSTALL_START ))
echo -e "\n${C_GREEN}╔══════════════════════════════════════════╗${C_DEF}"
echo -e "${C_GREEN}║  TITANIUM GNOME EDITION (GOLD 2.0)       ║${C_DEF}"
echo -e "${C_GREEN}╠══════════════════════════════════════════╣${C_DEF}"
printf "${C_GREEN}║${C_DEF}  %-14s: ${C_YELLOW}%s${C_DEF}\n" "Hostname"     "$HOSTNAME_PC"
printf "${C_GREEN}║${C_DEF}  %-14s: ${C_YELLOW}%s${C_DEF}\n" "Usuario"      "$USERNAME"
printf "${C_GREEN}║${C_DEF}  %-14s: ${C_YELLOW}%s${C_DEF}\n" "GRUB"         "Particle Circle @ ${GRUB_SCREEN}"
printf "${C_GREEN}║${C_DEF}  %-14s: ${C_YELLOW}%s${C_DEF}\n" "Perfil"       "$([ "$INSTALL_PROFILE" == "1" ] && echo 'Full Gaming' || echo 'Desktop Limpio')"
printf "${C_GREEN}║${C_DEF}  %-14s: ${C_YELLOW}%d min %d seg${C_DEF}\n" "Tiempo total" "$(( ELAPSED / 60 ))" "$(( ELAPSED % 60 ))"
echo -e "${C_GREEN}╚══════════════════════════════════════════╝${C_DEF}"

echo -e "\n${C_YELLOW}🚀 PASO FINAL: ACTIVAR SECURE BOOT${C_DEF}"
echo -e "Tu sistema ha sido firmado digitalmente, pero tu placa base aún necesita reconocerlo."
echo -e "Sigue estos 3 pasos antes de jugar:"
echo -e "  ${C_CYAN}1.${C_DEF} Escribe 'reboot' y entra en la BIOS de tu equipo."
echo -e "  ${C_CYAN}2.${C_DEF} Ve a Secure Boot y elige ${C_YELLOW}'Erase Keys'${C_DEF} o ${C_YELLOW}'Reset to Setup Mode'${C_DEF}."
echo -e "  ${C_CYAN}3.${C_DEF} Inicia tu nuevo Iceman OS, abre una terminal y escribe este comando:"
echo -e "     ${C_GREEN}sudo sbctl enroll-keys -m${C_DEF}"
echo -e "\n¡Listo! Tu máquina de forja Titanium te espera. Escribe ${C_YELLOW}reboot${C_DEF} para arrancar."
