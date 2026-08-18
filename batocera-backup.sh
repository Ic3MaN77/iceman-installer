#!/bin/bash
# ============================================================================
# Batocera 43 - Backup seguro, auditable, idempotente y verificable
#
# Target real:
#   /userdata              -> ext4, persistencia Batocera
#   /media/SHARE           -> BTRFS, ROMs externas
#   /media/SHARE/.batocera_backup -> destino
#
# IMPORTANT:
#   - Por defecto: AUDIT solamente. No crea ni modifica el backup.
#   - backup: copia /userdata preservando symlinks/ACL/xattrs/hardlinks.
#   - verify: verifica SHA-256 y puede comprobar divergencias origen/backup.
#   - NO sigue symlinks de /userdata/roms hacia /media/SHARE/roms.
#   - NO borra nada del origen.
#   - NO usa rsync --delete.
#   - /boot/batocera-boot.conf y /boot/config.txt se guardan como metadata,
#     no se copia el sistema /boot completo.
#
# Ejemplos:
#   curl -fsSL URL | bash
#       -> audit
#   curl -fsSL URL | bash -s -- backup
#   curl -fsSL URL | bash -s -- verify
#
# Opciones:
#   --non-interactive      no pedir confirmación (solo backup/verify)
#   --allow-live-wine      permitir backup aunque haya Wine/Proton activo
#   --full-verify          además compara origen vs backup con rsync --dry-run
# ============================================================================

set -u
set -o pipefail
IFS=$'\n\t'

SCRIPT_NAME="batocera-backup"
VERSION="2.0.0"

USERDATA="/userdata"
SHARE="/media/SHARE"
BOOT_CONF="/boot/batocera-boot.conf"
BOOT_CONFIG="/boot/config.txt"

BACKUP_ROOT="${SHARE}/.batocera_backup"
BACKUP_CURRENT="${BACKUP_ROOT}/current"
BACKUP_DATA="${BACKUP_CURRENT}/userdata"
BACKUP_META="${BACKUP_ROOT}/metadata"
BACKUP_AUDIT="${BACKUP_ROOT}/audit"
BACKUP_MANIFEST="${BACKUP_ROOT}/manifests"
BACKUP_LOGS="${BACKUP_ROOT}/logs"
BACKUP_HISTORY="${BACKUP_ROOT}/history"
LOCK_DIR="${BACKUP_ROOT}/.lock"

EXPECTED_USERDATA_FS="ext4"
EXPECTED_SHARE_FS="btrfs"
EXPECTED_VERSION_PREFIX="43"

RUN_ID="$(date +%Y%m%d-%H%M%S)"
TMP_ROOT="/tmp/${SCRIPT_NAME}-${RUN_ID}"
RUN_LOG="${TMP_ROOT}/run.log"
TMP_AUDIT="${TMP_ROOT}/audit.txt"

MODE="${1:-audit}"
NONINTERACTIVE=0
ALLOW_LIVE_WINE=0
FULL_VERIFY=0

BATOCERA_VERSION="unknown"
RSYNC_BIN=""
ES_WAS_RUNNING=0
LOCK_ACQUIRED=0
TMP_READY=0

mkdir -p "$TMP_ROOT" 2>/dev/null || {
    printf 'ERROR: no se pudo crear %s\n' "$TMP_ROOT" >&2
    exit 2
}
TMP_READY=1
: > "$RUN_LOG"

timestamp() { date '+%F %T'; }

log() {
    local msg="${1:-}"
    printf '[%s] %s\n' "$(timestamp)" "$msg" | tee -a "$RUN_LOG"
}

warn() {
    local msg="${1:-}"
    printf '[%s] WARNING: %s\n' "$(timestamp)" "$msg" | tee -a "$RUN_LOG" >&2
}

die() {
    local rc="${2:-2}"
    local msg="${1:-Error}"
    printf '[%s] ERROR: %s\n' "$(timestamp)" "$msg" | tee -a "$RUN_LOG" >&2
    exit "$rc"
}

cleanup() {
    local rc=$?
    if (( ES_WAS_RUNNING == 1 )); then
        restart_emulationstation
    fi
    if (( LOCK_ACQUIRED == 1 )); then
        rm -f "${LOCK_DIR}/pid" 2>/dev/null || true
        rmdir "$LOCK_DIR" 2>/dev/null || true
    fi
    if (( TMP_READY == 1 )); then
        # Keep failed runs for debugging; remove successful audit-only temp later.
        if [[ "$MODE" == "audit" || "$rc" -eq 0 ]]; then
            rm -rf "$TMP_ROOT" 2>/dev/null || true
        else
            cp -f "$RUN_LOG" "/tmp/${SCRIPT_NAME}-last-failed.log" 2>/dev/null || true
        fi
    fi
    exit "$rc"
}
trap cleanup EXIT

require_root() {
    [[ "${EUID:-999}" -eq 0 ]] || die "Este script debe ejecutarse como root. En Batocera normalmente la consola SSH/xterm ya es root; no necesitas sudo." 2
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Falta el comando requerido: $1" 2
}

validate_mode() {
    case "$MODE" in
        audit|backup|verify) ;;
        -h|--help)
            cat <<EOF
Uso:
  $SCRIPT_NAME [audit|backup|verify] [opciones]

Por defecto: audit

Opciones:
  --non-interactive
  --allow-live-wine
  --full-verify
EOF
            exit 0
            ;;
        *) die "Modo desconocido: $MODE (usa audit, backup o verify)." 2 ;;
    esac
}

parse_args() {
    shift || true
    while (($#)); do
        case "$1" in
            --non-interactive) NONINTERACTIVE=1 ;;
            --allow-live-wine) ALLOW_LIVE_WINE=1 ;;
            --full-verify) FULL_VERIFY=1 ;;
            -h|--help)
                cat <<EOF
Uso:
  curl -fsSL URL | bash
  curl -fsSL URL | bash -s -- backup
  curl -fsSL URL | bash -s -- verify

Opciones:
  --non-interactive
  --allow-live-wine
  --full-verify
EOF
                exit 0
                ;;
            *) die "Opción desconocida: $1" 2 ;;
        esac
        shift
    done
}

check_batocera() {
    [[ -d "$USERDATA" ]] || die "No existe $USERDATA."
    [[ -d "$SHARE" ]] || die "No existe $SHARE."

    if command -v batocera-version >/dev/null 2>&1; then
        BATOCERA_VERSION="$(batocera-version 2>/dev/null || true)"
        [[ -n "$BATOCERA_VERSION" ]] || BATOCERA_VERSION="unknown"
    fi

    if [[ "$BATOCERA_VERSION" != "$EXPECTED_VERSION_PREFIX"* ]]; then
        warn "Batocera detectado: $BATOCERA_VERSION. El script está diseñado para Batocera 43."
    fi
}

get_source() {
    findmnt -no SOURCE --target "$1" 2>/dev/null | head -n1
}

get_fstype() {
    findmnt -no FSTYPE --target "$1" 2>/dev/null | head -n1
}

check_mounts() {
    local udsrc shsrc udfs shfs
    udsrc="$(get_source "$USERDATA")"
    shsrc="$(get_source "$SHARE")"
    udfs="$(get_fstype "$USERDATA")"
    shfs="$(get_fstype "$SHARE")"

    log "/userdata: $(findmnt -no SOURCE,FSTYPE,OPTIONS,TARGET --target "$USERDATA" 2>/dev/null || echo unknown)"
    log "/media/SHARE: $(findmnt -no SOURCE,FSTYPE,OPTIONS,TARGET --target "$SHARE" 2>/dev/null || echo unknown)"

    [[ -n "$udsrc" ]] || die "/userdata no parece estar montado."
    [[ -n "$shsrc" ]] || die "/media/SHARE no parece estar montado."
    [[ "$udfs" == "$EXPECTED_USERDATA_FS" ]] || die "/userdata debe ser $EXPECTED_USERDATA_FS; detectado: ${udfs:-unknown}."
    [[ "$shfs" == "$EXPECTED_SHARE_FS" ]] || die "/media/SHARE debe ser $EXPECTED_SHARE_FS; detectado: ${shfs:-unknown}."
    [[ "$udsrc" != "$shsrc" ]] || die "/userdata y /media/SHARE aparecen en el mismo origen; se detiene por seguridad."

    # El backup debe quedar físicamente bajo el punto de montaje SHARE.
    [[ -d "$SHARE" ]] || die "El destino SHARE no existe."
    if [[ -e "$BACKUP_ROOT" || -L "$BACKUP_ROOT" ]]; then
        [[ -d "$BACKUP_ROOT" ]] || die "$BACKUP_ROOT existe pero no es un directorio."
        [[ ! -L "$BACKUP_ROOT" ]] || die "$BACKUP_ROOT es un symlink; por seguridad no se usa."
    fi
}

check_space() {
    local avail_kb
    avail_kb="$(df -Pk "$SHARE" | awk 'NR==2 {print $4}')"
    [[ "$avail_kb" =~ ^[0-9]+$ ]] || die "No se pudo determinar el espacio libre en $SHARE."
    (( avail_kb >= 1048576 )) || die "Menos de 1 GiB libre en $SHARE."
    log "Espacio libre en SHARE: $(df -h "$SHARE" | awk 'NR==2 {print $4}')"
}

ensure_backup_dirs() {
    mkdir -p "$BACKUP_CURRENT" "$BACKUP_META" "$BACKUP_AUDIT" "$BACKUP_MANIFEST" "$BACKUP_LOGS" "$BACKUP_HISTORY" ||
        die "No se pudo crear la estructura del backup."
    chmod 700 "$BACKUP_ROOT" 2>/dev/null || true
}

acquire_lock() {
    mkdir -p "$LOCK_DIR" 2>/dev/null || {
        local oldpid=""
        [[ -r "$LOCK_DIR/pid" ]] && oldpid="$(cat "$LOCK_DIR/pid" 2>/dev/null || true)"
        if [[ "$oldpid" =~ ^[0-9]+$ ]] && kill -0 "$oldpid" 2>/dev/null; then
            die "Ya hay otra ejecución activa (PID $oldpid)." 3
        fi
        rm -rf "$LOCK_DIR" 2>/dev/null || die "No se pudo recuperar un lock antiguo."
        mkdir "$LOCK_DIR" 2>/dev/null || die "No se pudo adquirir el lock."
    }
    printf '%s\n' "$$" > "$LOCK_DIR/pid" || die "No se pudo escribir el PID del lock."
    LOCK_ACQUIRED=1
}

write_metadata() {
    local out="${BACKUP_META}/run-${RUN_ID}.txt"
    {
        echo "script_version=$VERSION"
        echo "backup_id=$RUN_ID"
        echo "date=$(date --iso-8601=seconds 2>/dev/null || date)"
        echo "batocera_version=$BATOCERA_VERSION"
        echo "kernel=$(uname -srmo 2>/dev/null || echo unknown)"
        echo "hostname=$(hostname 2>/dev/null || echo unknown)"
        echo
        echo "[userdata_mount]"
        findmnt --target "$USERDATA" 2>/dev/null || true
        echo
        echo "[share_mount]"
        findmnt --target "$SHARE" 2>/dev/null || true
        echo
        echo "[disk_usage]"
        df -h "$USERDATA" "$SHARE"
        echo
        echo "[block_devices]"
        lsblk -o NAME,PATH,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS 2>/dev/null || true
    } > "$out"
}

copy_boot_configs() {
    local outdir="${BACKUP_META}/boot"
    mkdir -p "$outdir"
    for f in "$BOOT_CONF" "$BOOT_CONFIG"; do
        if [[ -r "$f" ]]; then
            cp -a "$f" "$outdir/$(basename "$f")" || die "No se pudo copiar $f a metadata."
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
        [[ -r "$BOOT_CONF" ]] && echo "$BOOT_CONF"
        [[ -r "$BOOT_CONFIG" ]] && echo "$BOOT_CONFIG"
    } > "$out"
}

audit_symlinks() {
    local out="${TMP_ROOT}/rom-symlinks.txt"
    : > "$out"
    if [[ -d "$USERDATA/roms" ]]; then
        find "$USERDATA/roms" -xdev -type l -print0 2>/dev/null |
            while IFS= read -r -d '' link; do
                printf '%s -> %s\n' "$link" "$(readlink "$link")" >> "$out"
            done
    fi
    echo "=== Symlinks bajo /userdata/roms ==="
    if [[ -s "$out" ]]; then cat "$out"; else echo "(ninguno)"; fi
    echo
    echo "Total symlinks ROM: $(wc -l < "$out" 2>/dev/null || echo 0)"
}

audit_external_links() {
    local out="${TMP_ROOT}/external-links.txt"
    : > "$out"
    find "$USERDATA" -xdev -type l -print0 2>/dev/null |
        while IFS= read -r -d '' link; do
            local target
            target="$(readlink "$link" 2>/dev/null || true)"
            case "$target" in
                "$SHARE"|"${SHARE}"/*)
                    printf '%s -> %s\n' "$link" "$target" >> "$out"
                    ;;
            esac
        done
    echo "=== Symlinks de /userdata hacia /media/SHARE ==="
    if [[ -s "$out" ]]; then cat "$out"; else echo "(ninguno)"; fi
}

audit_wine() {
    local out="${TMP_ROOT}/wine.txt"
    : > "$out"
    {
        echo "=== /userdata/system/wine-bottles ==="
        if [[ -d "$USERDATA/system/wine-bottles" ]]; then
            find "$USERDATA/system/wine-bottles" -xdev -printf '%y %p\n' 2>/dev/null | sort
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

    echo "=== Wine/Proton/Bottles ==="
    if [[ -d "$USERDATA/system/wine-bottles" ]]; then
        echo "wine-bottles size: $(du -sh "$USERDATA/system/wine-bottles" 2>/dev/null | awk '{print $1}' || echo '?')"
        echo "wine-bottles entries: $(find "$USERDATA/system/wine-bottles" -xdev -type f 2>/dev/null | wc -l)"
    else
        echo "wine-bottles: no existe"
    fi
    echo "prefix signatures: $(grep -c '^/' < <(grep -v '^=' "$out" | sed -n '/=== firmas/q;p') 2>/dev/null || true)"
    echo
    echo "--- Detalle guardado en $out ---"
}

audit_custom_rgs() {
    local out="${TMP_ROOT}/custom-rgs.txt"
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
    echo "=== Personalizaciones/RGS ==="
    echo "Paths con 'rgs': $(grep -ic rgs "$out" 2>/dev/null || echo 0)"
    echo "Scripts ejecutables: $(grep -c '^/userdata/system/' "$out" 2>/dev/null || echo 0)"
    echo "--- Detalle guardado en $out ---"
}

audit_sizes() {
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
            # du no sigue symlinks; /userdata/roms seguirá siendo pequeño.
            printf '%-45s %s\n' "$p" "$(du -sh "$p" 2>/dev/null | awk '{print $1}' || echo '?')"
        fi
    done
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
    if grep -qE '[^[:space:]]' "$out"; then
        # Ignore the section headers themselves.
        if grep -vE '^===|^[[:space:]]*$' "$out" | grep -q .; then
            echo "ATENCIÓN: hay procesos relacionados con Wine/Proton/Bottles activos."
            cat "$out"
        else
            echo "Procesos Wine/Proton/Bottles: ninguno detectado."
        fi
    fi
}

write_audit_report() {
    local report="${TMP_ROOT}/audit-report.txt"
    {
        echo "Batocera backup audit v$VERSION"
        echo "Run: $RUN_ID"
        echo "Batocera: $BATOCERA_VERSION"
        echo
        audit_sizes
        echo
        audit_symlinks
        echo
        audit_external_links
        echo
        audit_wine
        echo
        audit_custom_rgs
        echo
        audit_processes
    } > "$report" 2>&1
    cat "$report"
    cp -f "$report" "/tmp/${SCRIPT_NAME}-audit-latest.txt" 2>/dev/null || true
}

wine_processes_present() {
    pgrep -af '(^|/)(wine|wine64|wineserver|wineboot|proton|protontricks)([^/[:alnum:]_-]|$)' >/dev/null 2>&1
}

stop_emulationstation() {
    if pgrep -x emulationstation >/dev/null 2>&1; then
        ES_WAS_RUNNING=1
        if [[ -x /etc/init.d/S31emulationstation ]]; then
            log "Deteniendo EmulationStation temporalmente..."
            if ! /etc/init.d/S31emulationstation stop >/dev/null 2>&1; then
                warn "No se pudo detener EmulationStation limpiamente; se continúa."
            fi
        else
            warn "EmulationStation está activo pero no se encontró su init script; se continúa sin detenerlo."
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

run_backup() {
    local rsync_log="${BACKUP_LOGS}/rsync-${RUN_ID}.log"
    local error_log="${BACKUP_LOGS}/errors-${RUN_ID}.log"
    local source="$USERDATA/"
    local dest="$BACKUP_DATA/"

    : > "$rsync_log"
    : > "$error_log"

    log "Iniciando copia selectiva de /userdata -> $dest"
    log "Se conservan symlinks; no se usa --delete ni --copy-links."

    "$RSYNC_BIN" \
        -aHAX \
        --numeric-ids \
        --sparse \
        --one-file-system \
        --partial \
        --delay-updates \
        --info=progress2,name0 \
        --out-format='%i|%n%L' \
        "$source" "$dest" \
        >"$rsync_log" 2>"$error_log"
    local rc=$?

    case "$rc" in
        0)
            log "rsync finalizó correctamente."
            ;;
        24)
            die "rsync terminó con exit 24: archivos cambiaron/desaparecieron durante la copia. Backup NO se considera íntegro. Repite el backup con las aplicaciones cerradas." 10
            ;;
        *)
            [[ -s "$error_log" ]] && cat "$error_log" >&2
            die "rsync terminó con exit $rc. Backup NO se considera íntegro. Revisa $error_log." 10
            ;;
    esac
}

create_manifests() {
    local files="${BACKUP_MANIFEST}/files-${RUN_ID}.txt"
    local symlinks="${BACKUP_MANIFEST}/symlinks-${RUN_ID}.txt"
    local sha="${BACKUP_MANIFEST}/sha256-${RUN_ID}.txt"

    find "$BACKUP_DATA" -xdev -type f -printf '%P\n' 2>/dev/null | sort > "$files" ||
        die "No se pudo crear el manifest de archivos."
    find "$BACKUP_DATA" -xdev -type l -printf '%P -> %l\n' 2>/dev/null | sort > "$symlinks" ||
        die "No se pudo crear el manifest de symlinks."

    log "Calculando SHA-256 del backup..."
    (
        cd "$BACKUP_DATA" || exit 1
        find . -xdev -type f -print0 2>/dev/null |
            sort -z |
            xargs -0 -r sha256sum
    ) > "$sha" || die "No se pudo crear el manifest SHA-256."

    printf '%s\n' "$sha"
}

verify_hashes() {
    local hashfile="$1"
    [[ -f "$hashfile" ]] || die "No existe manifest SHA-256: $hashfile."
    if [[ -s "$hashfile" ]]; then
        ( cd "$BACKUP_DATA" && sha256sum -c "$hashfile" ) || die "La verificación SHA-256 ha fallado." 11
    fi
    log "SHA-256: OK"
}

verify_sync_dry_run() {
    local out="${BACKUP_LOGS}/verify-dry-run-${RUN_ID}.log"
    log "Comprobando divergencias origen/backup con rsync --dry-run (sin modificar nada)..."
    "$RSYNC_BIN" \
        -aHAXn \
        --numeric-ids \
        --one-file-system \
        --itemize-changes \
        --out-format='%i|%n%L' \
        "$USERDATA/" "$BACKUP_DATA/" >"$out" 2>&1
    local rc=$?
    case "$rc" in
        0)
            if grep -qE '^[><ch.*]|^\*deleting ' "$out"; then
                warn "Hay diferencias entre /userdata y current/userdata. Detalle: $out"
                return 4
            fi
            log "Origen y backup están sincronizados según rsync --dry-run."
            ;;
        *)
            die "La comprobación rsync --dry-run falló con rc=$rc. Detalle: $out." 12
            ;;
    esac
}

perform_audit() {
    check_batocera
    check_mounts
    check_space
    write_audit_report
    echo
    echo "============================================================"
    echo " AUDITORÍA FINALIZADA"
    echo "============================================================"
    echo "No se ha creado ni modificado:"
    echo "  $BACKUP_ROOT"
    echo
    echo "Informe disponible en:"
    echo "  /tmp/${SCRIPT_NAME}-audit-latest.txt"
    echo
}

perform_backup() {
    check_batocera
    check_mounts
    check_space
    need_cmd rsync
    RSYNC_BIN="$(command -v rsync)"

    # Auditoría temporal antes de crear destino.
    write_audit_report

    if wine_processes_present && (( ALLOW_LIVE_WINE == 0 )); then
        die "Hay procesos Wine/Proton activos. No se inicia el backup para evitar copiar prefixes en uso. Cierra los juegos y vuelve a ejecutar, o usa --allow-live-wine si asumes el riesgo." 9
    fi

    if [[ "$NONINTERACTIVE" -eq 0 ]]; then
        echo
        echo "============================================================"
        echo " CONFIRMACIÓN DE BACKUP"
        echo "============================================================"
        echo "Origen : $USERDATA"
        echo "Destino: $BACKUP_ROOT"
        echo "IMPORTANTE: NO se copiará el contenido de /media/SHARE/roms."
        echo "Los symlinks de /userdata/roms se conservarán como symlinks."
        echo "El backup NO borra nada del origen y NO usa rsync --delete."
        printf '¿Continuar? [s/N]: '
        read -r answer </dev/tty || answer=""
        case "$answer" in
            [sS]|[sS][iI]|[yY]|[yY][eE][sS]) ;;
            *) die "Backup cancelado por el usuario." 0 ;;
        esac
    fi

    ensure_backup_dirs
    acquire_lock
    write_metadata
    copy_boot_configs
    record_user_config_paths

    stop_emulationstation
    if wine_processes_present && (( ALLOW_LIVE_WINE == 0 )); then
        die "Wine/Proton apareció activo antes de rsync; se aborta para proteger prefixes." 9
    fi

    run_backup
    create_manifests

    local hashfile="${BACKUP_MANIFEST}/sha256-${RUN_ID}.txt"
    verify_hashes "$hashfile"

    {
        echo "result=OK"
        echo "script_version=$VERSION"
        echo "backup_id=$RUN_ID"
        echo "batocera_version=$BATOCERA_VERSION"
        echo "source=$USERDATA"
        echo "destination=$BACKUP_DATA"
        echo "hash_manifest=$hashfile"
        echo "run_log=${BACKUP_LOGS}/run-${RUN_ID}.log"
    } > "${BACKUP_META}/result-${RUN_ID}.txt"

    cp -f "${BACKUP_META}/result-${RUN_ID}.txt" "${BACKUP_CURRENT}/result.txt" ||
        die "No se pudo escribir result.txt en current."

    cp -f "$RUN_LOG" "${BACKUP_LOGS}/run-${RUN_ID}.log" 2>/dev/null || true

    echo
    echo "============================================================"
    echo " BACKUP COMPLETADO Y VERIFICADO"
    echo "============================================================"
    echo "Destino : $BACKUP_DATA"
    echo "Manifest: $hashfile"
    echo "Log     : ${BACKUP_LOGS}/run-${RUN_ID}.log"
    echo
    echo "IMPORTANTE: no se ha borrado nada del origen."
}

perform_verify() {
    check_batocera
    check_mounts
    [[ -d "$BACKUP_DATA" ]] || die "No existe un backup en $BACKUP_DATA." 12

    local latest
    latest="$(find "$BACKUP_MANIFEST" -maxdepth 1 -type f -name 'sha256-*.txt' -printf '%T@ %p\n' 2>/dev/null | sort -nr | head -n1 | cut -d' ' -f2-)"
    [[ -n "$latest" && -f "$latest" ]] || die "No existe un manifest SHA-256 válido en $BACKUP_MANIFEST." 12

    verify_hashes "$latest"

    if (( FULL_VERIFY == 1 )); then
        verify_sync_dry_run
    fi

    echo
    echo "============================================================"
    echo " VERIFICACIÓN COMPLETADA"
    echo "============================================================"
    echo "Backup: $BACKUP_DATA"
    echo "SHA256: OK"
    if (( FULL_VERIFY == 1 )); then
        echo "Origen vs backup: comprobado con rsync --dry-run"
    fi
}

main() {
    printf '\n%s\n' "============================================================"
    printf ' Batocera 43 Backup %s — modo %s\n' "$VERSION" "$MODE"
    printf '%s\n\n' "============================================================"

    require_root
    validate_mode
    parse_args "$@"

    # Commands used in audit/backup/verify.
    need_cmd findmnt
    need_cmd find
    need_cmd sha256sum
    need_cmd awk
    need_cmd sort
    need_cmd wc
    need_cmd du
    need_cmd df
    need_cmd readlink
    need_cmd lsblk
    need_cmd pgrep
    need_cmd cp
    need_cmd grep
    need_cmd date
    need_cmd sed
    need_cmd xargs

    case "$MODE" in
        audit)
            perform_audit
            ;;
        backup)
            perform_backup
            ;;
        verify)
            need_cmd rsync
            RSYNC_BIN="$(command -v rsync)"
            perform_verify
            ;;
    esac
}

main "$@"
