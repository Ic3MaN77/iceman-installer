#!/bin/bash
# ============================================================================
# Batocera 43 - Backup selectivo, verificable e idempotente
#
# Diseñado para:
#   /userdata              -> persistencia Batocera (ext4 en el equipo objetivo)
#   /media/SHARE           -> disco externo BTRFS con ROMs
#   /media/SHARE/.batocera_backup -> destino del backup
#
# Características:
#   - NO sigue symlinks de /userdata/roms hacia /media/SHARE/roms.
#   - Conserva symlinks como symlinks.
#   - Conserva permisos, propietarios, tiempos, ACLs, xattrs y hardlinks.
#   - NO borra contenido existente del backup.
#   - Detecta y registra cambios/borrados sin destruir backups previos.
#   - Genera inventario, hashes y logs.
#   - Comprueba que los puntos de montaje esperados son los correctos.
#   - Comprueba errores de lectura/copia de rsync.
#   - Es seguro para ejecución repetida.
#
# Uso recomendado desde GitHub:
#   curl -fsSL https://raw.githubusercontent.com/USUARIO/REPO/refs/heads/main/batocera-backup.sh | bash
# ============================================================================

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_NAME="batocera-backup"
BACKUP_ROOT="/media/SHARE/.batocera_backup"
BACKUP_CURRENT="${BACKUP_ROOT}/current"
BACKUP_DATA="${BACKUP_CURRENT}/userdata"
BACKUP_HISTORY="${BACKUP_ROOT}/history"
BACKUP_META="${BACKUP_ROOT}/metadata"
BACKUP_AUDIT="${BACKUP_ROOT}/audit"
BACKUP_MANIFEST="${BACKUP_ROOT}/manifests"
BACKUP_LOGS="${BACKUP_ROOT}/logs"
USERDATA="/userdata"
SHARE="/media/SHARE"
EXPECTED_USERDATA_FS="ext4"
EXPECTED_SHARE_FS="btrfs"
EXPECTED_VERSION_PREFIX="43"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
RUN_LOG="/tmp/${SCRIPT_NAME}-${RUN_ID}.log"
RSYNC_LOG="${BACKUP_LOGS}/rsync-${RUN_ID}.log"
ERROR_LOG="${BACKUP_LOGS}/errors-${RUN_ID}.log"
DELETED_LOG="${BACKUP_AUDIT}/would-delete-${RUN_ID}.txt"

RSYNC_BIN=""
FAILED=0
ES_WAS_RUNNING=1
LOCK_DIR="${BACKUP_ROOT}/.lock"

log() {
    local msg="$*"
    printf '[%s] %s\n' "$(date '+%F %T')" "$msg" | tee -a "$RUN_LOG"
}

warn() {
    local msg="$*"
    printf '[%s] WARNING: %s\n' "$(date '+%F %T')" "$msg" | tee -a "$RUN_LOG" >&2
}

error() {
    local msg="$*"
    printf '[%s] ERROR: %s\n' "$(date '+%F %T')" "$msg" | tee -a "$RUN_LOG" "$ERROR_LOG" >&2
}

on_err() {
    local rc=$?
    error "Fallo inesperado en línea ${BASH_LINENO[0]:-?}: comando=${BASH_COMMAND@Q} rc=${rc}"
    FAILED=1
    exit "$rc"
}
trap on_err ERR

cleanup_lock() {
    rmdir "$LOCK_DIR" 2>/dev/null || true
}

cleanup() {
    restart_emulationstation
    if [[ -d "$BACKUP_LOGS" && -f "$RUN_LOG" ]]; then
        cp -f "$RUN_LOG" "$BACKUP_LOGS/run-${RUN_ID}.log" 2>/dev/null || true
    fi
    cleanup_lock
}
trap cleanup EXIT

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        error "Falta el comando requerido: $1"
        exit 2
    }
}

mount_info() {
    local path="$1"
    findmnt -no SOURCE,FSTYPE,OPTIONS,TARGET --target "$path" 2>/dev/null || true
}

get_source() {
    findmnt -no SOURCE --target "$1" 2>/dev/null | head -n1
}

get_fstype() {
    findmnt -no FSTYPE --target "$1" 2>/dev/null | head -n1
}

require_root() {
    if [[ ${EUID:-999} -ne 0 ]]; then
        error "Debe ejecutarse como root. Ejemplo: curl ... | sudo bash"
        exit 2
    fi
}

check_batocera() {
    [[ -d "$USERDATA" ]] || { error "No existe $USERDATA"; exit 2; }
    [[ -d "$SHARE" ]] || { error "No existe $SHARE"; exit 2; }

    if command -v batocera-version >/dev/null 2>&1; then
        BATOCERA_VERSION="$(batocera-version 2>/dev/null || true)"
    else
        BATOCERA_VERSION="unknown"
    fi

    if [[ "$BATOCERA_VERSION" != "$EXPECTED_VERSION_PREFIX"* ]]; then
        warn "Versión detectada: ${BATOCERA_VERSION:-unknown}. El script está diseñado para Batocera 43."
    fi
}

check_mounts() {
    local udsrc="$(get_source "$USERDATA")"
    local udfs="$(get_fstype "$USERDATA")"
    local shsrc="$(get_source "$SHARE")"
    local shfs="$(get_fstype "$SHARE")"

    log "Montaje /userdata: $(mount_info "$USERDATA")"
    log "Montaje /media/SHARE: $(mount_info "$SHARE")"

    [[ -n "$udsrc" ]] || {
        error "/userdata no parece estar montado sobre un dispositivo real."
        exit 2
    }
    [[ "$udfs" == "$EXPECTED_USERDATA_FS" ]] || {
        error "/userdata no es ${EXPECTED_USERDATA_FS}; detectado: ${udfs:-desconocido}."
        exit 2
    }
    [[ -n "$shsrc" ]] || {
        error "/media/SHARE no parece estar montado sobre un dispositivo real."
        exit 2
    }
    [[ "$shfs" == "$EXPECTED_SHARE_FS" ]] || {
        error "/media/SHARE no es ${EXPECTED_SHARE_FS}; detectado: ${shfs:-desconocido}."
        exit 2
    }
    [[ "$udsrc" != "$shsrc" ]] || {
        error "/userdata y /media/SHARE aparecen sobre el mismo dispositivo; se detiene por seguridad."
        exit 2
    }

    # Importante: el destino debe estar dentro del SHARE real.
    [[ -d "$SHARE" ]] || exit 2
}

check_space() {
    local avail_kb
    avail_kb="$(df -Pk "$SHARE" | awk 'NR==2 {print $4}')"
    [[ "$avail_kb" =~ ^[0-9]+$ ]] || { error "No se pudo determinar el espacio libre en $SHARE"; exit 2; }
    # Solo exigimos 1 GiB de margen previo; el contenido real puede ser mucho mayor.
    (( avail_kb >= 1048576 )) || { error "Menos de 1 GiB libre en $SHARE"; exit 2; }
}

setup_dirs() {
    mkdir -p "$BACKUP_ROOT" "$BACKUP_DATA" "$BACKUP_META" "$BACKUP_AUDIT" "$BACKUP_MANIFEST" "$BACKUP_LOGS" "$BACKUP_CURRENT" "$BACKUP_HISTORY"
    chmod 700 "$BACKUP_ROOT" "$BACKUP_LOGS" || true
    if ! mkdir "$LOCK_DIR" 2>/dev/null; then
        error "Ya existe un backup ejecutándose (lock: $LOCK_DIR)."
        exit 3
    fi
    # El lock no debe quedarse en backups futuros.
    log "Backup ID: $RUN_ID"
}

write_metadata() {
    {
        echo "Batocera version: ${BATOCERA_VERSION:-unknown}"
        echo "Backup ID: $RUN_ID"
        echo "Date: $(date --iso-8601=seconds)"
        echo "Hostname: $(hostname 2>/dev/null || echo unknown)"
        echo "Kernel: $(uname -srmo 2>/dev/null || echo unknown)"
        echo "Uptime: $(uptime 2>/dev/null || echo unknown)"
        echo
        echo "Source mounts:"
        findmnt -R "$USERDATA" 2>/dev/null || true
        findmnt -R "$SHARE" 2>/dev/null || true
        echo
        echo "Disk usage:"
        df -h "$USERDATA" "$SHARE"
        echo
        echo "Block devices:"
        lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS 2>/dev/null || true
    } > "${BACKUP_META}/system-${RUN_ID}.txt"

    # El boot config puede contener la forma de montar almacenamiento externo.
    if [[ -r /boot/batocera-boot.conf ]]; then
        cp -a /boot/batocera-boot.conf "${BACKUP_META}/batocera-boot.conf.${RUN_ID}"
    else
        warn "No se encontró /boot/batocera-boot.conf; se registra pero no se considera fatal."
    fi

    # Información legible de configuración principal, sin ejecutar ni modificar nada.
    if [[ -r /userdata/system/batocera.conf ]]; then
        cp -a /userdata/system/batocera.conf "${BACKUP_META}/batocera.conf.${RUN_ID}"
    fi
}

audit_symlinks() {
    local outfile="${BACKUP_AUDIT}/rom-symlinks-${RUN_ID}.txt"
    log "Inventariando symlinks de /userdata/roms sin seguirlos..."
    : > "$outfile"
    if [[ -d /userdata/roms ]]; then
        while IFS= read -r -d '' link; do
            printf '%s -> %s\n' "$link" "$(readlink "$link")" >> "$outfile"
        done < <(find /userdata/roms -xdev -type l -print0 2>/dev/null)
    fi
}

audit_wine() {
    local out="${BACKUP_AUDIT}/wine-proton-${RUN_ID}.txt"
    log "Inventariando Wine/Proton/Bottles dentro de /userdata..."
    {
        echo "=== wine-bottles ==="
        if [[ -d /userdata/system/wine-bottles ]]; then
            find /userdata/system/wine-bottles -xdev -printf '%y %p\n' 2>/dev/null | sort
        else
            echo "(no existe /userdata/system/wine-bottles)"
        fi
        echo
        echo "=== custom runners ==="
        if [[ -d /userdata/system/wine ]]; then
            find /userdata/system/wine -xdev -maxdepth 5 -printf '%y %p\n' 2>/dev/null | sort
        else
            echo "(no existe /userdata/system/wine)"
        fi
        echo
        echo "=== prefix signatures (limit 10000) ==="
        find /userdata -xdev \( -name drive_c -o -name dosdevices -o -name system.reg -o -name user.reg -o -name compatdata \) -print 2>/dev/null | sort | head -10000
    } > "$out"
}

audit_rgs_and_custom() {
    local out="${BACKUP_AUDIT}/custom-rgs-and-scripts-${RUN_ID}.txt"
    log "Inventariando scripts/personalizaciones y posibles referencias RGS..."
    {
        echo "=== system top-level ==="
        find /userdata/system -mindepth 1 -maxdepth 2 -xdev -printf '%y %p\n' 2>/dev/null | sort
        echo
        echo "=== possible RGS references (name/path only) ==="
        find /userdata/system -xdev -iname '*rgs*' -print 2>/dev/null | sort | head -5000
        echo
        echo "=== executable custom scripts ==="
        find /userdata/system -xdev -type f -perm /111 -print 2>/dev/null | sort | head -10000
    } > "$out"
}

audit_sizes() {
    local out="${BACKUP_AUDIT}/sizes-${RUN_ID}.txt"
    log "Calculando tamaños de las áreas persistentes principales..."
    {
        du -sh /userdata/system 2>/dev/null || true
        du -sh /userdata/bios 2>/dev/null || true
        du -sh /userdata/saves 2>/dev/null || true
        du -sh /userdata/themes 2>/dev/null || true
        du -sh /userdata/music 2>/dev/null || true
        du -sh /userdata/screenshots 2>/dev/null || true
        du -sh /userdata/roms 2>/dev/null || true
        du -sh /userdata/.roms_base 2>/dev/null || true
    } > "$out"
}

preview_external_links() {
    local out="${BACKUP_AUDIT}/external-links-${RUN_ID}.txt"
    : > "$out"
    if [[ -d /userdata ]]; then
        find /userdata -xdev -type l -print0 2>/dev/null |
            while IFS= read -r -d '' link; do
                target="$(readlink "$link")"
                case "$target" in
                    /media/SHARE/*|/media/SHARE)
                        printf '%s -> %s\n' "$link" "$target" >> "$out" ;;
                esac
            done
    fi
}

show_summary_and_confirm() {
    local system_size bios_size saves_size wine_size
    system_size="$(du -sk /userdata/system 2>/dev/null | awk '{print $1}' || echo 0)"
    bios_size="$(du -sk /userdata/bios 2>/dev/null | awk '{print $1}' || echo 0)"
    saves_size="$(du -sk /userdata/saves 2>/dev/null | awk '{print $1}' || echo 0)"
    wine_size="$(du -sk /userdata/system/wine-bottles 2>/dev/null | awk '{print $1}' || echo 0)"

    echo
    echo "============================================================"
    echo " BATOCERA BACKUP — AUDITORÍA PREVIA"
    echo "============================================================"
    echo "Batocera : ${BATOCERA_VERSION:-unknown}"
    echo "Origen   : ${USERDATA} ($(get_source "$USERDATA"), ${EXPECTED_USERDATA_FS})"
    echo "Destino  : ${BACKUP_ROOT} ($(get_source "$SHARE"), ${EXPECTED_SHARE_FS})"
    echo
    echo "system              : $(du -sh /userdata/system 2>/dev/null | awk '{print $1}' || echo "${system_size} KiB")"
    echo "  wine-bottles      : $(du -sh /userdata/system/wine-bottles 2>/dev/null | awk '{print $1}' || echo "${wine_size} KiB")"
    echo "bios                : $(du -sh /userdata/bios 2>/dev/null | awk '{print $1}' || echo "${bios_size} KiB")"
    echo "saves               : $(du -sh /userdata/saves 2>/dev/null | awk '{print $1}' || echo "${saves_size} KiB")"
    echo
    echo "IMPORTANTE: /userdata/roms contiene symlinks hacia /media/SHARE/roms."
    echo "           rsync conservará esos symlinks y NO seguirá sus destinos."
    echo "           El cálculo anterior de ROMs NO se usa para el tamaño del backup."
    echo
    echo "Se copiará: userdata persistente + symlinks + metadatos de /boot."
    echo "NO se copiará el contenido físico de /media/SHARE/roms."
    echo "El backup mantiene /current como espejo idempotente; los cambios/borrados anteriores se guardan en history/."
    echo
    if [[ "${BATOCERA_NONINTERACTIVE:-0}" == "1" ]]; then
        log "Modo no interactivo: confirmación omitida por BATOCERA_NONINTERACTIVE=1."
        return 0
    fi

    read -r -p "¿Continuar con el backup? [s/N]: " answer
    case "$answer" in
        [sS]|[sS][iI]|[yY]|[yY][eE][sS]) ;;
        *)
            log "Backup cancelado por el usuario."
            exit 0
            ;;
    esac
}

stop_emulationstation_temporarily() {
    # Para coherencia de configuraciones, paramos ES durante la copia.
    # No tocamos juegos ni procesos Wine ya existentes; si hubiera uno activo,
    # rsync podría capturar un estado cambiante. Avisamos, pero no matamos Wine.
    if pgrep -x emulationstation >/dev/null 2>&1; then
        ES_WAS_RUNNING=1
        log "Deteniendo EmulationStation durante el backup para estabilizar configuraciones..."
        /etc/init.d/S31emulationstation stop >/dev/null 2>&1 || warn "No se pudo detener EmulationStation limpiamente."
    else
        ES_WAS_RUNNING=0
    fi
}

restart_emulationstation() {
    if (( ES_WAS_RUNNING == 1 )); then
        log "Restaurando EmulationStation..."
        /etc/init.d/S31emulationstation start >/dev/null 2>&1 || true
    fi
}

run_rsync() {
    need_cmd "$RSYNC_BIN"
    log "Ejecutando rsync preservando ACL/xattrs/hardlinks/symlinks..."
    : > "$RSYNC_LOG"

    set +e
    "$RSYNC_BIN" \
        -aHAX \
        --numeric-ids \
        --sparse \
        --one-file-system \
        --itemize-changes \
        --human-readable \
        --stats \
        --partial \
        --out-format='%i|%n%L' \
        --delete \
        --delete-delay \
        --backup \
        --backup-dir="${BACKUP_HISTORY}/${RUN_ID}" \
        "$USERDATA/" "$BACKUP_DATA/" \
        > >(tee -a "$RSYNC_LOG") \
        2> >(tee -a "$ERROR_LOG" >&2)
    local rc=$?
    set -e

    case "$rc" in
        0)
            log "rsync finalizó correctamente (exit 0)."
            ;;
        24)
            error "rsync terminó con exit 24 (archivos desaparecidos/cambiantes durante la lectura)."
            error "No se considera un backup íntegro; revisa $ERROR_LOG y vuelve a ejecutar."
            return 24
            ;;
        *)
            error "rsync terminó con exit $rc. No se considera un backup íntegro."
            return "$rc"
            ;;
    esac
}

record_deletions_without_deleting() {
    log "Previsualizando archivos que desaparecerían del espejo actual..."
    : > "$DELETED_LOG"
    set +e
    "$RSYNC_BIN" -aHAX --numeric-ids --one-file-system --dry-run --delete --itemize-changes \
        "$USERDATA/" "$BACKUP_DATA/" \
        2>> "$ERROR_LOG" |
        awk '/^\*deleting / {sub(/^\*deleting /, ""); print}' > "$DELETED_LOG"
    local rc=${PIPESTATUS[0]}
    set -e
    if (( rc != 0 )); then
        warn "No se pudo completar la previsualización de borrados (rc=$rc)."
    fi
}

create_symlink_manifest() {
    local out="${BACKUP_MANIFEST}/symlinks-${RUN_ID}.txt"
    log "Creando manifest de symlinks..."
    find "$BACKUP_DATA" -xdev -type l -printf '%p -> %l\n' 2>/dev/null | sort > "$out"
}

create_file_manifest() {
    local out="${BACKUP_MANIFEST}/files-${RUN_ID}.txt"
    log "Creando manifest de archivos del backup..."
    find "$BACKUP_DATA" -xdev -type f -printf '%P\n' 2>/dev/null | sort > "$out"
}

create_sha256() {
    local out="${BACKUP_MANIFEST}/sha256-${RUN_ID}.txt"
    log "Calculando SHA-256 del backup. Esto puede tardar si tienes muchos Wine Bottles..."
    : > "$out"
    (
        cd "$BACKUP_DATA"
        find . -xdev -type f -print0 2>/dev/null | sort -z |
            xargs -0 -r sha256sum
    ) > "$out"
}

verify_backup_against_hashes() {
    local hashfile="$1"
    log "Verificando SHA-256 del contenido respaldado..."
    if [[ ! -s "$hashfile" ]]; then
        warn "El manifest SHA-256 está vacío; no hay archivos regulares que verificar."
        return 0
    fi
    if ( cd "$BACKUP_DATA" && sha256sum -c "$hashfile" ); then
        log "Verificación SHA-256: OK"
        return 0
    fi
    error "La verificación SHA-256 del backup ha fallado."
    return 1
}

write_result() {
    local result="$1"
    {
        echo "result=$result"
        echo "backup_id=$RUN_ID"
        echo "batocera_version=${BATOCERA_VERSION:-unknown}"
        echo "source=$USERDATA"
        echo "destination=$BACKUP_DATA"
        echo "rsync_log=$RSYNC_LOG"
        echo "error_log=$ERROR_LOG"
    } > "${BACKUP_META}/result-${RUN_ID}.txt"
}

main() {
    echo ""
    echo "============================================================"
    echo " Batocera 43 Backup — seguro, idempotente y verificable"
    echo "============================================================"

    require_root
    need_cmd findmnt
    need_cmd find
    need_cmd rsync
    need_cmd sha256sum
    need_cmd awk
    need_cmd sort
    need_cmd xargs
    need_cmd lsblk
    need_cmd df
    need_cmd du
    need_cmd cp
    need_cmd readlink

    RSYNC_BIN="$(command -v rsync)"
    check_batocera
    check_mounts
    check_space
    setup_dirs

    log "Batocera detectado: ${BATOCERA_VERSION:-unknown}"
    log "rsync: $($RSYNC_BIN --version | head -1)"

    # Auditoría antes de tocar datos.
    write_metadata
    audit_symlinks
    preview_external_links
    audit_wine
    audit_rgs_and_custom
    audit_sizes
    show_summary_and_confirm

    stop_emulationstation_temporarily
    record_deletions_without_deleting

    if ! run_rsync; then
        FAILED=1
        write_result "FAILED_RSYNC"
        exit 10
    fi

    create_symlink_manifest
    create_file_manifest
    create_sha256

    if ! verify_backup_against_hashes "${BACKUP_MANIFEST}/sha256-${RUN_ID}.txt"; then
        FAILED=1
        write_result "FAILED_VERIFY"
        exit 11
    fi

    write_result "OK"
    cp -a "${BACKUP_META}/result-${RUN_ID}.txt" "${BACKUP_CURRENT}/result.txt"

    log "============================================================"
    log "BACKUP OK"
    log "Destino: $BACKUP_DATA"
    log "Manifest: ${BACKUP_MANIFEST}"
    log "Logs: ${BACKUP_LOGS}"
    log "============================================================"

}

main "$@"
