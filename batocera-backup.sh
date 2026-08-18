#!/bin/bash
# ============================================================================
# Batocera Backup V2
# Universalidad controlada, incremental, auditable y verificable.
#
# Referencia validada: Batocera 43.
#
# Uso normal (flujo completo):
#   curl -fsSL URL | bash
#
# Modos avanzados:
#   curl -fsSL URL | bash -s -- audit
#   curl -fsSL URL | bash -s -- verify
#   curl -fsSL URL | bash -s -- backup
#
# Opciones:
#   --non-interactive         usa --destination y no pregunta
#   --destination PATH        destino del backup; por defecto se selecciona
#   --full-verify             verificación exhaustiva SHA-256 + rsync checksum
#   --allow-live-wine         permite backup con Wine/Proton/Bottles activos
#   --force-unsupported       permite seguir en versión desconocida/no validada
#
# Principios:
#   - NO sigue symlinks del origen: las ROMs externas no se copian.
#   - Conserva symlinks, ACL, xattrs, hardlinks, sparse files y ownership.
#   - El backup es incremental mediante rsync.
#   - Los archivos reemplazados/eliminados van a history/<run-id>, solo como
#     delta; no se crean copias completas repetidas.
#   - La verificación SHA-256 normal solo recalcula archivos nuevos/modificados.
#   - La verificación completa sigue disponible con --full-verify.
#   - El detalle masivo se guarda en logs; la terminal muestra progreso/resumen.
#   - El modo normal hace auditoría -> resumen -> confirmación -> backup -> verify.
# ============================================================================

set -u
set -o pipefail
IFS=$'\n\t'

SCRIPT_NAME="batocera-backup"
VERSION="3.0.0"
SUPPORTED_BATO_MAJOR="43"

USERDATA="${BATOCERA_USERDATA:-/userdata}"
BOOT_CONF="/boot/batocera-boot.conf"
BOOT_CONFIG="/boot/config.txt"

MODE="full"
NONINTERACTIVE=0
ALLOW_LIVE_WINE=0
FULL_VERIFY=0
FORCE_UNSUPPORTED=0
DESTINATION=""

RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_START_EPOCH="$(date +%s)"
TMP_ROOT="/tmp/${SCRIPT_NAME}-${RUN_ID}"
TMP_LOG="${TMP_ROOT}/run.log"
TMP_AUDIT="${TMP_ROOT}/audit-report.txt"
TMP_CHANGED="${TMP_ROOT}/changed-files.txt"
TMP_SOURCE_META="${TMP_ROOT}/source-meta.txt"
TMP_DEST_META="${TMP_ROOT}/dest-meta.txt"
TMP_CANDIDATES="${TMP_ROOT}/candidates.txt"

BATOCERA_VERSION="unknown"
BATOCERA_MAJOR="unknown"
DEST_FS=""
DEST_SOURCE=""
DEST_SIZE=0
DEST_AVAIL=0
HASHFILE=""
BACKUP_ROOT=""
BACKUP_CURRENT=""
BACKUP_DATA=""
BACKUP_META=""
BACKUP_AUDIT=""
BACKUP_MANIFEST=""
BACKUP_LOGS=""
BACKUP_HISTORY=""
LOCK_DIR=""
LOCK_ACQUIRED=0
ES_WAS_RUNNING=0
TMP_READY=0
RSYNC_BIN=""

mkdir -p "$TMP_ROOT" 2>/dev/null || {
    printf 'ERROR: no se pudo crear %s\n' "$TMP_ROOT" >&2
    exit 2
}
TMP_READY=1
: > "$TMP_LOG"

say() {
    printf '%s\n' "$*" | tee -a "$TMP_LOG"
}
log() {
    printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$TMP_LOG"
}
warn() {
    printf '[%s] WARNING: %s\n' "$(date '+%F %T')" "$*" | tee -a "$TMP_LOG" >&2
}
die() {
    local rc="${2:-2}"
    printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$1" | tee -a "$TMP_LOG" >&2
    exit "$rc"
}

cleanup() {
    local rc=$?
    if (( ES_WAS_RUNNING == 1 )); then
        restart_emulationstation || true
    fi
    if (( LOCK_ACQUIRED == 1 )) && [[ -n "$LOCK_DIR" ]]; then
        rm -f "${LOCK_DIR}/pid" 2>/dev/null || true
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
    if (( TMP_READY == 1 )); then
        if (( rc != 0 )); then
            cp -f "$TMP_LOG" "/tmp/${SCRIPT_NAME}-last-failed.log" 2>/dev/null || true
        else
            rm -rf "$TMP_ROOT" 2>/dev/null || true
        fi
    fi
    exit "$rc"
}
trap cleanup EXIT

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Falta el comando requerido: $1" 2
}

usage() {
    cat <<USAGE
Uso:
  $SCRIPT_NAME                       flujo completo (audit -> confirm -> backup -> verify)
  $SCRIPT_NAME backup                alias del flujo completo
  $SCRIPT_NAME audit                 solo auditoría
  $SCRIPT_NAME verify                solo verificación del backup seleccionado

Opciones:
  --destination PATH
  --non-interactive
  --full-verify
  --allow-live-wine
  --force-unsupported
  -h, --help

Ejemplo con curl:
  curl -fsSL https://raw.githubusercontent.com/Ic3MaN77/iceman-installer/refs/heads/main/batocera-backup.sh | bash
USAGE
}

parse_args() {
    local first="${1:-}"
    if [[ -n "$first" ]]; then
        case "$first" in
            full|backup|--backup)
                MODE="full"; shift ;;
            audit)
                MODE="audit"; shift ;;
            verify)
                MODE="verify"; shift ;;
            --help|-h)
                usage; exit 0 ;;
            --non-interactive|--destination|--full-verify|--allow-live-wine|--force-unsupported|--destination=*)
                MODE="full" ;;
            *)
                die "Argumento desconocido: $first. Usa --help." 2 ;;
        esac
    fi

    while (($#)); do
        case "$1" in
            --non-interactive)
                NONINTERACTIVE=1 ;;
            --destination)
                shift
                (($#)) || die "--destination requiere una ruta." 2
                DESTINATION="$1" ;;
            --destination=*)
                DESTINATION="${1#*=}" ;;
            --full-verify)
                FULL_VERIFY=1 ;;
            --allow-live-wine)
                ALLOW_LIVE_WINE=1 ;;
            --force-unsupported)
                FORCE_UNSUPPORTED=1 ;;
            --help|-h)
                usage; exit 0 ;;
            backup|full|audit|verify|--backup)
                # Ya procesado cuando era el primer argumento; se ignora solo
                # para tolerar llamadas redundantes.
                ;;
            *)
                die "Opción desconocida: $1. Usa --help." 2 ;;
        esac
        shift
    done
}

require_root() {
    [[ "${EUID:-999}" -eq 0 ]] || die "Este script debe ejecutarse como root. En Batocera normalmente ya eres root." 2
}

get_fstype() {
    findmnt -no FSTYPE --target "$1" 2>/dev/null | head -n1
}
get_source() {
    findmnt -no SOURCE --target "$1" 2>/dev/null | head -n1
}

read_batocera_version() {
    local v=""
    if [[ -r /usr/share/batocera/batocera.version ]]; then
        v="$(head -n1 /usr/share/batocera/batocera.version 2>/dev/null | tr -d '\r' || true)"
    fi
    if [[ -z "$v" ]] && command -v batocera-version >/dev/null 2>&1; then
        v="$(batocera-version 2>/dev/null | head -n1 | tr -d '\r' || true)"
    fi
    [[ -n "$v" ]] || v="unknown"
    BATOCERA_VERSION="$v"
    if [[ "$v" =~ ^([0-9]+) ]]; then
        BATOCERA_MAJOR="${BASH_REMATCH[1]}"
    else
        BATOCERA_MAJOR="unknown"
    fi
}

check_batocera() {
    [[ -d "$USERDATA" ]] || die "No existe $USERDATA. No parece una instalación Batocera activa." 2
    read_batocera_version

    if [[ "$BATOCERA_MAJOR" != "$SUPPORTED_BATO_MAJOR" ]]; then
        if [[ "$MODE" == "audit" ]]; then
            warn "Batocera detectado: $BATOCERA_VERSION. Esta versión no está validada; la auditoría continuará, pero el modo backup/verify requerirá --force-unsupported."
        elif (( FORCE_UNSUPPORTED == 0 )); then
            die "Batocera detectado: $BATOCERA_VERSION. Esta versión está validada para Batocera $SUPPORTED_BATO_MAJOR. Ejecuta una auditoría primero o usa --force-unsupported si sabes lo que haces." 8
        else
            warn "Versión no validada: $BATOCERA_VERSION. Se continúa con --force-unsupported."
        fi
    fi
}

check_userdata_mount() {
    local source fs target opts
    target="$(findmnt -no TARGET --target "$USERDATA" 2>/dev/null | head -n1)"
    source="$(get_source "$USERDATA")"
    fs="$(get_fstype "$USERDATA")"
    opts="$(findmnt -no OPTIONS --target "$USERDATA" 2>/dev/null | head -n1)"
    [[ "$target" == "$USERDATA" ]] || die "$USERDATA no parece ser un punto de montaje válido." 2
    [[ -n "$source" ]] || die "No se pudo determinar el dispositivo de $USERDATA." 2
    [[ -n "$fs" ]] || die "No se pudo determinar el filesystem de $USERDATA." 2
    [[ "$opts" != *,ro,* && "$opts" != ro,* ]] || die "$USERDATA está montado en solo lectura." 2

    log "/userdata: source=$source fs=$fs opts=$opts"
}

is_candidate_mount() {
    local target="$1" source="$2" fstype="$3"
    [[ -d "$target" ]] || return 1
    mountpoint -q "$target" 2>/dev/null || return 1
    [[ "$target" =~ ^/media/[^/]+(/.*)?$ || "$target" =~ ^/run/media/[^/]+/[^/]+(/.*)?$ ]] || return 1
    [[ "$target" == "$USERDATA" || "$target" == /boot || "$target" == / ]] && return 1
    [[ "$target" == "$USERDATA"/* ]] && return 1
    [[ -n "$source" ]] || return 1
    [[ "$source" == /dev/* || "$source" == UUID=* || "$source" == LABEL=* || "$source" == //* ]] || return 1
    [[ "$fstype" != tmpfs && "$fstype" != overlay && "$fstype" != proc && "$fstype" != sysfs && "$fstype" != devtmpfs ]] || return 1
    [[ -w "$target" ]] || return 1
    return 0
}

scan_destinations() {
    : > "$TMP_CANDIDATES"
    local line target source fstype size avail
    while IFS= read -r line; do
        target="$(awk '{print $1}' <<<"$line")"
        source="$(awk '{print $2}' <<<"$line")"
        fstype="$(awk '{print $3}' <<<"$line")"
        size="$(awk '{print $4}' <<<"$line")"
        avail="$(awk '{print $5}' <<<"$line")"
        is_candidate_mount "$target" "$source" "$fstype" || continue
        printf '%s\t%s\t%s\t%s\t%s\n' "$target" "$source" "$fstype" "$size" "$avail" >> "$TMP_CANDIDATES"
    done < <(findmnt -rn -o TARGET,SOURCE,FSTYPE,SIZE,AVAIL 2>/dev/null | sort -u)

    # Fallback específico para entornos donde findmnt no devuelve el punto
    # esperado con el formato anterior.
    if [[ ! -s "$TMP_CANDIDATES" ]]; then
        local p
        for p in /media/* /run/media/*/*; do
            [[ -d "$p" ]] || continue
            mountpoint -q "$p" 2>/dev/null || continue
            target="$p"
            source="$(get_source "$target")"
            fstype="$(get_fstype "$target")"
            size="$(df -P -k "$target" 2>/dev/null | awk 'NR==2 {print $2*1024}')"
            avail="$(df -P -k "$target" 2>/dev/null | awk 'NR==2 {print $4*1024}')"
            is_candidate_mount "$target" "$source" "$fstype" || continue
            printf '%s\t%s\t%s\t%s\t%s\n' "$target" "$source" "$fstype" "${size:-0}" "${avail:-0}" >> "$TMP_CANDIDATES"
        done
    fi
}

format_bytes() {
    local n="${1:-0}"
    if (( n < 1024 )); then printf '%s B' "$n"; return; fi
    awk -v n="$n" 'BEGIN {split("B KiB MiB GiB TiB PiB",u); i=1; while(n>=1024 && i<6){n/=1024;i++} printf "%.1f %s",n,u[i]}'
}

choose_destination() {
    scan_destinations
    [[ -s "$TMP_CANDIDATES" ]] || die "No se encontraron unidades montadas y escribibles bajo /media o /run/media." 3

    # Destino directo para automatización.
    if [[ -n "$DESTINATION" ]]; then
        [[ -d "$DESTINATION" ]] || die "El destino indicado no existe: $DESTINATION" 3
        mountpoint -q "$DESTINATION" 2>/dev/null || die "El destino indicado no es un punto de montaje: $DESTINATION" 3
    else
        if (( NONINTERACTIVE == 1 )); then
            die "En modo --non-interactive debes indicar --destination PATH." 3
        fi

        say ""
        say "============================================================"
        say " UNIDADES DISPONIBLES PARA EL BACKUP"
        say "============================================================"
        local i=0 target source fstype size avail
        while IFS=$'\t' read -r target source fstype size avail; do
            ((i+=1))
            printf ' %2d) %-32s %-8s total=%-10s libres=%-10s\n' \
                "$i" "$target" "$fstype" "$(format_bytes "$size")" "$(format_bytes "$avail")" | tee -a "$TMP_LOG"
        done < "$TMP_CANDIDATES"
        say ""
        printf 'Selecciona el destino [1-%d]: ' "$i"
        local choice
        read -r choice </dev/tty || choice=""
        [[ "$choice" =~ ^[0-9]+$ ]] || die "Selección de destino no válida." 3
        (( choice >= 1 && choice <= i )) || die "Selección fuera de rango." 3
        DESTINATION="$(sed -n "${choice}p" "$TMP_CANDIDATES" | cut -f1)"
    fi

    DESTINATION="${DESTINATION%/}"
    [[ -n "$DESTINATION" ]] || die "Destino vacío." 3
    [[ "$DESTINATION" != "$USERDATA" && "$DESTINATION" != "$USERDATA"/* ]] || die "El destino no puede estar dentro de /userdata." 3

    DEST_SOURCE="$(get_source "$DESTINATION")"
    DEST_FS="$(get_fstype "$DESTINATION")"
    [[ -n "$DEST_SOURCE" ]] || die "No se pudo determinar el origen del destino." 3
    [[ -n "$DEST_FS" ]] || die "No se pudo determinar el filesystem del destino." 3

    local userdata_source
    userdata_source="$(get_source "$USERDATA")"
    [[ "$DEST_SOURCE" != "$userdata_source" ]] || die "El destino usa el mismo filesystem que /userdata. Por seguridad se requiere otro filesystem." 3

    DEST_SIZE="$(df -P -B1 "$DESTINATION" | awk 'NR==2 {print $2}')"
    DEST_AVAIL="$(df -P -B1 "$DESTINATION" | awk 'NR==2 {print $4}')"
    [[ "$DEST_AVAIL" =~ ^[0-9]+$ ]] || die "No se pudo determinar el espacio libre del destino." 3

    BACKUP_ROOT="${DESTINATION}/.batocera_backup"
    BACKUP_CURRENT="${BACKUP_ROOT}/current"
    BACKUP_DATA="${BACKUP_CURRENT}/userdata"
    BACKUP_META="${BACKUP_ROOT}/metadata"
    BACKUP_AUDIT="${BACKUP_ROOT}/audit"
    BACKUP_MANIFEST="${BACKUP_ROOT}/manifests"
    BACKUP_LOGS="${BACKUP_ROOT}/logs"
    BACKUP_HISTORY="${BACKUP_ROOT}/history"
    LOCK_DIR="${BACKUP_ROOT}/.lock"

    log "Destino seleccionado: $DESTINATION (fs=$DEST_FS, source=$DEST_SOURCE)"
}

check_destination_space() {
    local userdata_bytes=0
    userdata_bytes="$(du -sx -B1 "$USERDATA" 2>/dev/null | awk '{print $1}' || echo 0)"
    [[ "$userdata_bytes" =~ ^[0-9]+$ ]] || userdata_bytes=0

    local minimum=$((512*1024*1024))
    local needed="$minimum"
    if [[ ! -d "$BACKUP_DATA" ]]; then
        # Primera copia: margen de 5% + 512 MiB.
        needed=$((userdata_bytes + userdata_bytes/20 + minimum))
    fi

    if (( DEST_AVAIL < needed )); then
        die "Espacio insuficiente en $DESTINATION. Libres=$(format_bytes "$DEST_AVAIL"), mínimo estimado=$(format_bytes "$needed")." 4
    fi

    say "Espacio libre destino : $(format_bytes "$DEST_AVAIL")"
    say "Tamaño estimado userdata: $(format_bytes "$userdata_bytes")"
}

ensure_backup_dirs() {
    mkdir -p "$BACKUP_CURRENT" "$BACKUP_META" "$BACKUP_AUDIT" "$BACKUP_MANIFEST" "$BACKUP_LOGS" "$BACKUP_HISTORY" ||
        die "No se pudo crear la estructura de backup." 4
    chmod 700 "$BACKUP_ROOT" 2>/dev/null || true
}

acquire_lock() {
    mkdir "$LOCK_DIR" 2>/dev/null || {
        local oldpid=""
        [[ -r "$LOCK_DIR/pid" ]] && oldpid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
        if [[ "$oldpid" =~ ^[0-9]+$ ]] && kill -0 "$oldpid" 2>/dev/null; then
            die "Ya hay otra ejecución activa (PID $oldpid)." 5
        fi
        rm -rf "$LOCK_DIR" 2>/dev/null || die "No se pudo recuperar el lock antiguo." 5
        mkdir "$LOCK_DIR" 2>/dev/null || die "No se pudo adquirir el lock." 5
    }
    printf '%s\n' "$$" > "$LOCK_DIR/pid" || die "No se pudo escribir el PID del lock." 5
    LOCK_ACQUIRED=1
}

write_metadata() {
    local out="${BACKUP_META}/run-${RUN_ID}.txt"
    {
        echo "script_version=$VERSION"
        echo "backup_id=$RUN_ID"
        echo "date=$(date --iso-8601=seconds 2>/dev/null || date)"
        echo "batocera_version=$BATOCERA_VERSION"
        echo "batocera_major=$BATOCERA_MAJOR"
        echo "kernel=$(uname -srmo 2>/dev/null || echo unknown)"
        echo "hostname=$(hostname 2>/dev/null || echo unknown)"
        echo "source_userdata=$USERDATA"
        echo "destination=$DESTINATION"
        echo "destination_source=$DEST_SOURCE"
        echo "destination_fs=$DEST_FS"
        echo
        echo "[userdata_mount]"
        findmnt --target "$USERDATA" 2>/dev/null || true
        echo
        echo "[destination_mount]"
        findmnt --target "$DESTINATION" 2>/dev/null || true
        echo
        echo "[disk_usage]"
        df -h "$USERDATA" "$DESTINATION"
        echo
        echo "[block_devices]"
        lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS 2>/dev/null || true
    } > "$out" || die "No se pudo escribir metadata." 4
}

copy_boot_configs() {
    local outdir="${BACKUP_META}/boot"
    mkdir -p "$outdir" || die "No se pudo crear metadata/boot." 4
    for f in "$BOOT_CONF" "$BOOT_CONFIG"; do
        if [[ -r "$f" ]]; then
            cp -a "$f" "$outdir/$(basename "$f")" || die "No se pudo copiar $f a metadata." 4
        fi
    done
}

record_user_config_paths() {
    local out="${BACKUP_META}/important-paths-${RUN_ID}.txt"
    {
        echo "[persistent]"
        for p in \
            "$USERDATA/system" \
            "$USERDATA/system/wine-bottles" \
            "$USERDATA/system/wine/custom" \
            "$USERDATA/bios" \
            "$USERDATA/saves" \
            "$USERDATA/themes" \
            "$USERDATA/music" \
            "$USERDATA/screenshots" \
            "$USERDATA/roms"
        do
            if [[ -e "$p" || -L "$p" ]]; then
                printf '%s\n' "$p"
            fi
        done
        echo
        echo "[boot-configs]"
        if [[ -r "$BOOT_CONF" ]]; then echo "$BOOT_CONF"; fi
        if [[ -r "$BOOT_CONFIG" ]]; then echo "$BOOT_CONFIG"; fi
    } > "$out" || die "No se pudo escribir important-paths." 4
}

audit_symlinks() {
    local out="${TMP_ROOT}/symlinks.txt"
    : > "$out"
    if [[ -d "$USERDATA" ]]; then
        find "$USERDATA" -xdev -type l -print0 2>/dev/null |
            while IFS= read -r -d '' link; do
                printf '%s -> %s\n' "$link" "$(readlink "$link" 2>/dev/null || true)" >> "$out"
            done
    fi
    local total
    total="$(wc -l < "$out" 2>/dev/null || echo 0)"
    printf 'Symlinks encontrados: %s\n' "$total"
    printf 'Detalle: %s\n' "$out"
    # Symlinks que salen de /userdata se registran; nunca se siguen.
    if [[ -s "$out" ]]; then
        printf '\n--- Enlaces externos ---\n'
        cat "$out"
    fi
}

audit_rom_storage() {
    local real_files=0 real_dirs=0 symlinks=0 out="${TMP_ROOT}/roms-audit.txt"
    : > "$out"
    if [[ -d "$USERDATA/roms" ]]; then
        symlinks="$(find "$USERDATA/roms" -xdev -type l 2>/dev/null | wc -l)"
        real_files="$(find "$USERDATA/roms" -xdev -type f 2>/dev/null | wc -l)"
        real_dirs="$(find "$USERDATA/roms" -xdev -mindepth 1 -type d 2>/dev/null | wc -l)"
        {
            echo "=== /userdata/roms ==="
            echo "symlinks=$symlinks"
            echo "real_files=$real_files"
            echo "real_dirs=$real_dirs"
            echo
            find "$USERDATA/roms" -xdev -maxdepth 2 -printf '%y %p\n' 2>/dev/null | sort
        } > "$out"
    fi
    printf 'ROMs reales dentro de /userdata/roms: %s archivos, %s directorios\n' "$real_files" "$real_dirs"
    printf 'Symlinks dentro de /userdata/roms: %s\n' "$symlinks"
    printf 'Detalle: %s\n' "$out"
}

audit_external_links() {
    local out="${TMP_ROOT}/external-links.txt"
    : > "$out"
    find "$USERDATA" -xdev -type l -print0 2>/dev/null |
        while IFS= read -r -d '' link; do
            local target
            target="$(readlink "$link" 2>/dev/null || true)"
            if [[ "$target" == /* && "$target" != "$USERDATA"/* ]]; then
                printf '%s -> %s\n' "$link" "$target" >> "$out"
            fi
        done
    printf 'Symlinks que apuntan fuera de /userdata: %s\n' "$(wc -l < "$out" 2>/dev/null || echo 0)"
    if [[ -s "$out" ]]; then cat "$out"; fi
}

audit_wine() {
    local out="${TMP_ROOT}/wine.txt"
    {
        echo "=== /userdata/system/wine-bottles ==="
        if [[ -d "$USERDATA/system/wine-bottles" ]]; then
            find "$USERDATA/system/wine-bottles" -xdev -maxdepth 6 -printf '%y %p\n' 2>/dev/null | sort
        else
            echo "(no existe)"
        fi
        echo
        echo "=== /userdata/system/wine/custom ==="
        if [[ -d "$USERDATA/system/wine/custom" ]]; then
            find "$USERDATA/system/wine/custom" -xdev -maxdepth 6 -printf '%y %p\n' 2>/dev/null | sort
        else
            echo "(no existe)"
        fi
        echo
        echo "=== firmas de prefixes ==="
        find "$USERDATA" -xdev \( -name drive_c -o -name dosdevices -o -name system.reg -o -name user.reg -o -name userdef.reg -o -name compatdata \) -print 2>/dev/null | sort | head -20000
    } > "$out"
    if [[ -d "$USERDATA/system/wine-bottles" ]]; then
        printf 'wine-bottles: %s, archivos=%s\n' \
            "$(du -sh "$USERDATA/system/wine-bottles" 2>/dev/null | awk '{print $1}' || echo '?')" \
            "$(find "$USERDATA/system/wine-bottles" -xdev -type f 2>/dev/null | wc -l)"
    else
        echo 'wine-bottles: no existe'
    fi
    printf 'Detalle Wine/Proton: %s\n' "$out"
}

audit_customizations() {
    local out="${TMP_ROOT}/customizations.txt"
    {
        echo "=== system top-level ==="
        find "$USERDATA/system" -mindepth 1 -maxdepth 2 -xdev -printf '%y %p\n' 2>/dev/null | sort
        echo
        echo "=== paths containing rgs ==="
        find "$USERDATA/system" -xdev -iname '*rgs*' -print 2>/dev/null | sort
        echo
        echo "=== executable custom scripts ==="
        find "$USERDATA/system" -xdev -type f -perm /111 -print 2>/dev/null | sort
    } > "$out"
    printf 'Personalizaciones/scripting: detalle=%s\n' "$out"
}

audit_sizes() {
    local out="${TMP_ROOT}/sizes.txt"
    {
        echo "=== Tamaños principales ==="
        for p in \
            "$USERDATA/system" \
            "$USERDATA/system/wine-bottles" \
            "$USERDATA/system/wine/custom" \
            "$USERDATA/bios" \
            "$USERDATA/saves" \
            "$USERDATA/themes" \
            "$USERDATA/music" \
            "$USERDATA/screenshots" \
            "$USERDATA/roms"
        do
            if [[ -e "$p" || -L "$p" ]]; then
                printf '%-45s %s\n' "$p" "$(du -sh "$p" 2>/dev/null | awk '{print $1}' || echo '?')"
            fi
        done
    } > "$out"
    cat "$out"
}

audit_processes() {
    local out="${TMP_ROOT}/processes.txt"
    {
        echo "=== Wine/Proton processes ==="
        pgrep -af '(^|/)(wine|wine64|wineserver|wineboot|proton|protontricks)([^/[:alnum:]_-]|$)' 2>/dev/null || true
        echo
        echo "=== Common launchers ==="
        pgrep -af '(bottles|lutris|boxtron|proton)' 2>/dev/null || true
    } > "$out"
    if grep -vE '^===|^[[:space:]]*$' "$out" | grep -q .; then
        printf 'ATENCION: hay procesos Wine/Proton/Bottles activos.\n'
        cat "$out"
    else
        echo 'Procesos Wine/Proton/Bottles: ninguno detectado.'
    fi
}

write_audit_report() {
    {
        echo "Batocera Backup V$VERSION"
        echo "Run: $RUN_ID"
        echo "Batocera: $BATOCERA_VERSION"
        echo "Destino: $DESTINATION"
        echo
        audit_sizes
        echo
        audit_rom_storage
        echo
        audit_symlinks
        echo
        audit_external_links
        echo
        audit_wine
        echo
        audit_customizations
        echo
        audit_processes
    } > "$TMP_AUDIT" 2>&1 || die "No se pudo generar la auditoría." 6

    cp -f "$TMP_AUDIT" "/tmp/${SCRIPT_NAME}-audit-latest.txt" 2>/dev/null || true
    cat "$TMP_AUDIT"
}

wine_processes_present() {
    pgrep -af '(^|/)(wine|wine64|wineserver|wineboot|proton|protontricks)([^/[:alnum:]_-]|$)' >/dev/null 2>&1
}

stop_emulationstation() {
    if pgrep -x emulationstation >/dev/null 2>&1; then
        ES_WAS_RUNNING=1
        if [[ -x /etc/init.d/S31emulationstation ]]; then
            log 'Deteniendo EmulationStation temporalmente...'
            /etc/init.d/S31emulationstation stop >/dev/null 2>&1 || warn 'No se pudo detener EmulationStation limpiamente; se continúa.'
        else
            warn 'EmulationStation activo pero no existe S31emulationstation; se continúa.'
        fi
    fi
}

restart_emulationstation() {
    if (( ES_WAS_RUNNING == 1 )); then
        if [[ -x /etc/init.d/S31emulationstation ]]; then
            /etc/init.d/S31emulationstation start >/dev/null 2>&1 || true
        fi
        ES_WAS_RUNNING=0
    fi
}

prepare_runtime() {
    need_cmd rsync
    need_cmd sha256sum
    need_cmd find
    need_cmd stat
    need_cmd findmnt
    RSYNC_BIN="$(command -v rsync)"
}

check_before_copy() {
    [[ -d "$USERDATA" ]] || die "/userdata ha desaparecido antes de copiar." 7
    [[ -d "$DESTINATION" ]] || die "El destino ha desaparecido antes de copiar." 7
    [[ "$(get_source "$USERDATA")" == "$(get_source "$USERDATA")" ]] || die 'Comprobación interna inválida.' 7
    [[ "$(get_source "$DESTINATION")" != "$(get_source "$USERDATA")" ]] || die 'El destino ya no es un filesystem distinto de /userdata.' 7
}

run_rsync() {
    local rsync_log="${BACKUP_LOGS}/rsync-${RUN_ID}.log"
    local error_log="${BACKUP_LOGS}/errors-${RUN_ID}.log"
    local history_run="${BACKUP_HISTORY}/${RUN_ID}"
    local source="$USERDATA/"
    local dest="$BACKUP_DATA/"

    mkdir -p "$history_run" || die 'No se pudo crear el histórico de esta ejecución.' 7
    : > "$rsync_log"
    : > "$error_log"

    log 'Iniciando copia incremental de /userdata...'
    say 'Progreso:'
    say '  (Los detalles por archivo se guardan en el log; aquí solo verás el progreso global.)'

    # --delete + --backup-dir hace que los cambios/eliminaciones del destino
    # anterior pasen al histórico como DELTA, no como copia completa.
    "$RSYNC_BIN" \
        -aHAX \
        --numeric-ids \
        --sparse \
        --one-file-system \
        --partial \
        --delay-updates \
        --delete \
        --delete-delay \
        --backup \
        --backup-dir="$history_run" \
        --info=progress2,stats1,name0 \
        "$source" "$dest" \
        > >(tee "$rsync_log") \
        2> >(tee "$error_log" >&2)
    local rc=$?

    case "$rc" in
        0)
            log 'rsync finalizó correctamente.'
            ;;
        24)
            die 'rsync terminó con exit 24: hubo archivos que cambiaron/desaparecieron durante la copia. El backup no se considera íntegro.' 10
            ;;
        *)
            [[ -s "$error_log" ]] && cat "$error_log" >&2
            die "rsync terminó con exit $rc. Revisa $error_log." 10
            ;;
    esac

    # El histórico se conserva solo si contiene algo.
    if [[ -d "$history_run" ]] && ! find "$history_run" -type f -print -quit 2>/dev/null | grep -q .; then
        rmdir "$history_run" 2>/dev/null || true
    fi
}

# Genera una lista de archivos del backup. La lista se usa para mantener un
# índice de SHA-256 incremental. Pathnames con TAB o salto de línea son raros;
# si aparecen, forzamos una verificación completa para no perder información.
check_unsafe_paths() {
    local bad=0 p
    while IFS= read -r -d '' p; do
        if [[ "$p" == *$'\t'* || "$p" == *$'\n'* ]]; then
            bad=1
            break
        fi
    done < <(find "$BACKUP_DATA" -xdev -type f -print0 2>/dev/null)
    return "$bad"
}

load_old_hash_index() {
    OLD_HASHES=()
    OLD_SIZE=()
    OLD_MTIME=()
    OLD_CTIME=()
    local index="$BACKUP_CURRENT/hash-index.tsv"
    [[ -s "$index" ]] || return 0
    while IFS=$'\t' read -r path size mtime ctime hash; do
        [[ -n "$path" && -n "$hash" ]] || continue
        OLD_HASHES["$path"]="$hash"
        OLD_SIZE["$path"]="$size"
        OLD_MTIME["$path"]="$mtime"
        OLD_CTIME["$path"]="$ctime"
    done < "$index"
}

# bash 4+ permite arrays asociativos. Se declaran fuera de la función para que
# el entorno sea simple y portable dentro del script.
declare -A OLD_HASHES OLD_SIZE OLD_MTIME OLD_CTIME

generate_hash_manifests() {
    local hashfile="${BACKUP_MANIFEST}/sha256-${RUN_ID}.txt"
    local indexfile="${BACKUP_CURRENT}/hash-index.tsv"
    HASHFILE="$hashfile"
    local newindex="${TMP_ROOT}/hash-index.new.tsv"
    local changed_manifest="${BACKUP_MANIFEST}/changed-sha256-${RUN_ID}.txt"
    local old_index="${BACKUP_CURRENT}/hash-index.tsv"
    local path rel size mtime ctime hash oldhash oldsize oldmtime oldctime need_hash
    local count=0 hashed=0 reused=0 changed=0
    local source_path src_hash dst_hash

    : > "$hashfile"
    : > "$newindex"
    : > "$changed_manifest"

    if ! check_unsafe_paths; then
        warn 'Se detectaron nombres de archivo con TAB/salto de línea; se ejecutará verificación SHA-256 completa para esta ejecución.'
        FULL_VERIFY=1
    fi

    load_old_hash_index

    while IFS= read -r -d '' path; do
        rel="${path#"$BACKUP_DATA/"}"
        size="$(stat -c %s "$path" 2>/dev/null || echo 0)"
        mtime="$(stat -c %Y "$path" 2>/dev/null || echo 0)"
        ctime="$(stat -c %Z "$path" 2>/dev/null || echo 0)"

        oldhash="${OLD_HASHES[$rel]:-}"
        oldsize="${OLD_SIZE[$rel]:-}"
        oldmtime="${OLD_MTIME[$rel]:-}"
        oldctime="${OLD_CTIME[$rel]:-}"
        need_hash=0

        if (( FULL_VERIFY == 1 )); then
            need_hash=1
        elif [[ -z "$oldhash" ]]; then
            need_hash=1
        elif [[ "$oldsize" != "$size" || "$oldmtime" != "$mtime" || "$oldctime" != "$ctime" ]]; then
            need_hash=1
        fi

        if (( need_hash == 1 )); then
            dst_hash="$(sha256sum "$path" | awk '{print $1}')" || die "No se pudo calcular SHA-256 de $rel." 11
            printf '%s\t%s\t%s\t%s\t%s\n' "$rel" "$size" "$mtime" "$ctime" "$dst_hash" >> "$newindex"
            printf '%s  ./%s\n' "$dst_hash" "$rel" >> "$hashfile"
            printf '%s\t%s\n' "$rel" "$dst_hash" >> "$changed_manifest"
            ((hashed+=1))

            # Para archivos nuevos/modificados, comprobamos también el origen.
            source_path="$USERDATA/$rel"
            if [[ -f "$source_path" && ! -L "$source_path" ]]; then
                src_hash="$(sha256sum "$source_path" | awk '{print $1}')" || die "No se pudo calcular SHA-256 del origen $rel." 11
                if [[ "$src_hash" != "$dst_hash" ]]; then
                    die "SHA-256 no coincide para: $rel" 11
                fi
            fi
            ((changed+=1))
        else
            hash="$oldhash"
            printf '%s\t%s\t%s\t%s\t%s\n' "$rel" "$size" "$mtime" "$ctime" "$hash" >> "$newindex"
            printf '%s  ./%s\n' "$hash" "$rel" >> "$hashfile"
            ((reused+=1))
        fi
        ((count+=1))
    done < <(find "$BACKUP_DATA" -xdev -type f -print0 2>/dev/null)

    mv -f "$newindex" "$indexfile" || die 'No se pudo actualizar hash-index.tsv.' 11

    # Mantén el resumen amigable y no vuelques miles de archivos a la terminal.
    say ''
    say 'Verificación incremental SHA-256:'
    say "  Archivos totales : $count"
    say "  Hash calculado   : $hashed"
    say "  Hash reutilizado : $reused"
    say "  Cambiados/nuevos : $changed"
    say "  Manifest         : $hashfile"

}

verify_hashes_full_manifest() {
    local hashfile="$1"
    [[ -f "$hashfile" ]] || die "No existe manifest SHA-256: $hashfile" 11
    ( cd "$BACKUP_DATA" && sha256sum -c "$hashfile" ) > "${BACKUP_LOGS}/sha256-check-${RUN_ID}.log" 2>&1 || {
        cat "${BACKUP_LOGS}/sha256-check-${RUN_ID}.log" >&2
        die 'La verificación SHA-256 completa ha fallado.' 11
    }
    log 'Verificación SHA-256 completa: OK.'
}

verify_sync_dry_run() {
    local out="${BACKUP_LOGS}/verify-rsync-${RUN_ID}.log"
    log 'Ejecutando verificación exhaustiva de divergencias con rsync --checksum --dry-run...'
    "$RSYNC_BIN" \
        -aHAXn \
        --numeric-ids \
        --one-file-system \
        --checksum \
        --delete \
        --itemize-changes \
        --out-format='%i|%n%L' \
        "$USERDATA/" "$BACKUP_DATA/" > "$out" 2>&1
    local rc=$?
    if (( rc != 0 )); then
        die "rsync --checksum --dry-run falló con rc=$rc. Detalle: $out" 12
    fi
    if grep -qE '^([><ch\.][^ ]*|\*deleting )' "$out"; then
        warn "Hay diferencias entre /userdata y current/userdata. Detalle: $out"
        return 4
    fi
    log 'Origen y backup coinciden según rsync --checksum --dry-run.'
    return 0
}

prune_old_logs_and_manifests() {
    # No eliminamos históricos de datos automáticamente: contienen deltas útiles
    # para recuperar archivos sobrescritos/borrados. Solo evitamos acumular logs
    # enormes de ejecuciones antiguas y manifests redundantes más allá de 12 runs.
    local f
    mapfile -t f < <(find "$BACKUP_LOGS" -maxdepth 1 -type f -name '*.log' -printf '%T@ %p\n' 2>/dev/null | sort -nr | tail -n +13 | cut -d' ' -f2-)
    ((${#f[@]})) && rm -f -- "${f[@]}" 2>/dev/null || true

    mapfile -t f < <(find "$BACKUP_MANIFEST" -maxdepth 1 -type f -name '*.txt' -printf '%T@ %p\n' 2>/dev/null | sort -nr | tail -n +37 | cut -d' ' -f2-)
    ((${#f[@]})) && rm -f -- "${f[@]}" 2>/dev/null || true
}

write_result() {
    local result="$1" hashfile="${2:-}"
    local out="${BACKUP_META}/result-${RUN_ID}.txt"
    {
        echo "result=$result"
        echo "script_version=$VERSION"
        echo "backup_id=$RUN_ID"
        echo "batocera_version=$BATOCERA_VERSION"
        echo "source=$USERDATA"
        echo "destination=$DESTINATION"
        echo "backup_data=$BACKUP_DATA"
        [[ -n "$hashfile" ]] && echo "hash_manifest=$hashfile"
        echo "log=${BACKUP_LOGS}/run-${RUN_ID}.log"
    } > "$out" || die 'No se pudo escribir result metadata.' 13
    cp -f "$out" "${BACKUP_CURRENT}/result.txt" 2>/dev/null || true
}

finalize_log() {
    mkdir -p "$BACKUP_LOGS" 2>/dev/null || return 0
    cp -f "$TMP_LOG" "${BACKUP_LOGS}/run-${RUN_ID}.log" 2>/dev/null || true
}

show_audit_summary() {
    say ''
    say '============================================================'
    say ' RESUMEN DE AUDITORÍA'
    say '============================================================'
    say "Batocera      : $BATOCERA_VERSION"
    say "Origen        : $USERDATA"
    say "Destino       : $DESTINATION"
    say "Filesystem    : $DEST_FS"
    say "Espacio libre : $(format_bytes "$DEST_AVAIL")"
    say ''
    say 'Los symlinks se conservan sin seguirlos; el contenido externo (por ejemplo'
    say 'ROMs del HDD de 12 TB) no se copia solo por estar referenciado desde /userdata.'
    say ''
}

confirm_full_backup() {
    (( NONINTERACTIVE == 1 )) && return 0
    say 'El proceso continuará automáticamente después de tu confirmación.'
    printf '¿Comenzar el backup? [S/n]: '
    local answer
    read -r answer </dev/tty || answer=""
    case "$answer" in
        ''|[sS]|[sS][iI]|[yY]|[yY][eE][sS]) return 0 ;;
        *) die 'Backup cancelado por el usuario.' 0 ;;
    esac
}

perform_audit_only() {
    check_batocera
    check_userdata_mount
    choose_destination
    check_destination_space
    write_audit_report
    say ''
    say '============================================================'
    say ' AUDITORÍA FINALIZADA'
    say '============================================================'
    say "Informe: /tmp/${SCRIPT_NAME}-audit-latest.txt"
}

perform_verify_only() {
    check_batocera
    check_userdata_mount
    choose_destination
    prepare_runtime
    [[ -d "$BACKUP_DATA" ]] || die "No existe backup en $BACKUP_DATA" 12

    local latest hashfile
    latest="$(find "$BACKUP_MANIFEST" -maxdepth 1 -type f -name 'sha256-*.txt' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
    [[ -n "$latest" && -f "$latest" ]] || die "No existe manifest SHA-256 válido en $BACKUP_MANIFEST" 12
    hashfile="$latest"

    if (( FULL_VERIFY == 1 )); then
        verify_hashes_full_manifest "$hashfile"
        verify_sync_dry_run || die 'La verificación exhaustiva encontró divergencias.' 12
    else
        # Verificación rápida: usa el hash-index existente para comprobar solo
        # que los registros estén presentes y deja la auditoría completa para
        # --full-verify. Esto evita releer todos los datos cada vez.
        [[ -s "$BACKUP_CURRENT/hash-index.tsv" ]] || die 'No existe hash-index.tsv; ejecuta un backup completo primero.' 12
        say 'Verificación rápida: hash-index presente y backup estructurado correctamente.'
        say 'Para SHA-256 completo de todos los archivos usa --full-verify.'
    fi
}

perform_full_backup() {
    check_batocera
    check_userdata_mount
    choose_destination
    check_destination_space
    prepare_runtime

    # Primera auditoría: todavía no se crea ni modifica el backup.
    say ''
    say '============================================================'
    say ' AUDITORÍA PREVIA'
    say '============================================================'
    write_audit_report
    show_audit_summary

    if wine_processes_present && (( ALLOW_LIVE_WINE == 0 )); then
        die 'Hay procesos Wine/Proton/Bottles activos. Cierra los juegos/aplicaciones antes del backup, o usa --allow-live-wine bajo tu responsabilidad.' 9
    fi

    confirm_full_backup

    ensure_backup_dirs
    acquire_lock
    write_metadata
    copy_boot_configs
    record_user_config_paths

    stop_emulationstation
    check_before_copy
    if wine_processes_present && (( ALLOW_LIVE_WINE == 0 )); then
        die 'Wine/Proton apareció activo antes de rsync; se aborta para proteger prefixes.' 9
    fi

    run_rsync

    say ''
    say '============================================================'
    say ' VERIFICACIÓN DEL BACKUP'
    say '============================================================'

    local hashfile
    generate_hash_manifests
    hashfile="$HASHFILE"
    [[ -f "$hashfile" ]] || die 'No se pudo generar el manifest SHA-256.' 11

    if (( FULL_VERIFY == 1 )); then
        verify_hashes_full_manifest "$hashfile"
        verify_sync_dry_run || die 'La verificación exhaustiva encontró divergencias.' 12
    fi

    write_result OK "$hashfile"
    prune_old_logs_and_manifests
    finalize_log

    say ''
    say '============================================================'
    say ' BACKUP COMPLETADO CORRECTAMENTE'
    say '============================================================'
    say "Batocera : $BATOCERA_VERSION"
    say "Destino  : $DESTINATION"
    say "Datos    : $BACKUP_DATA"
    say "Manifest : $hashfile"
    say "Log      : ${BACKUP_LOGS}/run-${RUN_ID}.log"
    if (( FULL_VERIFY == 1 )); then
        say 'Integridad: SHA-256 completo + rsync --checksum verificados.'
    else
        say 'Integridad: verificación incremental de archivos nuevos/modificados.'
        say 'Verificación total disponible con --full-verify.'
    fi
    say 'Los archivos reemplazados/eliminados se conservan como deltas en history/.'
    say 'No se han seguido symlinks ni copiado su contenido externo.'
}

main() {
    parse_args "$@"
    require_root
    prepare_runtime 2>/dev/null || true

    case "$MODE" in
        audit)
            perform_audit_only ;;
        verify)
            perform_verify_only ;;
        full)
            perform_full_backup ;;
        *)
            die "Modo interno desconocido: $MODE" 2 ;;
    esac
}

main "$@"
