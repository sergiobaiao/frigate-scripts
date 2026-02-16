#!/usr/bin/env bash
# VERSION: 1.1
# =============================================================================
# FRIGATE-MOVER.SH
# =============================================================================
# Script unificado para movimentação de gravações, clips, exports e snapshots
# do SSD para o HD externo.
#
# DESCRIÇÃO:
#   Este script consolida as funcionalidades de arquivamento de mídia
#   em um único utilitário com diferentes modos de operação.
#
# MODOS DE OPERAÇÃO:
#   --mode=incremental  Move diretórios de data mais antigos que KEEP_SSD_DAYS
#                       (substitui frigate-archive.sh)
#
#   --mode=file         Move arquivos individuais mais antigos que 24h
#                       (substitui frigate-archiver.sh)
#
#   --mode=full         Move TUDO do SSD para HD de uma vez
#                       (substitui mover_frigate_para_hd.sh)
#
#   --mode=emergency    Igual ao full, mas sem limite de banda (máxima velocidade)
#
# USO:
#   ./frigate-mover.sh                     # Usa modo padrão (incremental)
#   ./frigate-mover.sh --mode=full         # Move tudo
#   ./frigate-mover.sh --mode=incremental --dry-run  # Simula sem executar
#   ./frigate-mover.sh --status            # Mostra estatísticas de espaço
#
# OPÇÕES:
#   --mode=MODE     Modo de operação (incremental|file|full|emergency)
#   --dry-run       Simula as operações sem executar
#   --progress      Mostra progresso em tempo real do rsync
#   --verbose       Mostra mais detalhes durante execução
#   --status        Mostra estatísticas de espaço e sai
#   --help          Mostra esta ajuda
#
# CONFIGURAÇÕES (via .env):
#   KEEP_SSD_DAYS   - Dias para manter no SSD (padrão: 2)
#   BWLIMIT         - Limite de banda KB/s (padrão: 20000)
#
# AUTOR: Sistema Marquise
# =============================================================================

# -----------------------------------------------------------------------------
# CARREGA CONFIGURAÇÕES E FUNÇÕES COMPARTILHADAS
# -----------------------------------------------------------------------------
source "$(dirname "$0")/common.sh"

# -----------------------------------------------------------------------------
# VARIÁVEIS GLOBAIS
# -----------------------------------------------------------------------------
LOG_TAG="mover"
MODE="incremental"           # Modo padrão
DRY_RUN="${DRY_RUN:-0}"
VERBOSE="${VERBOSE:-0}"
SHOW_PROGRESS="${SHOW_PROGRESS:-0}"

# Configurações do .env com valores padrão
KEEP_SSD_DAYS="${KEEP_SSD_DAYS:-2}"
BWLIMIT="${BWLIMIT:-20000}"
MAX_DAYS_PER_RUN="${MAX_DAYS_PER_RUN:-30}"

# Caminhos (resolve symlinks para que find funcione corretamente)
ORIGEM_RECORDINGS="$(readlink -f "$SSD_RECORDINGS")"
DESTINO_RECORDINGS="$(readlink -f "$HD_RECORDINGS")"
ORIGEM_CLIPS="$(readlink -f "$SSD_CLIPS")"
DESTINO_CLIPS="$(readlink -f "$HD_CLIPS")"
ORIGEM_EXPORTS="$(readlink -f "$SSD_EXPORTS")"
DESTINO_EXPORTS="$(readlink -f "$HD_EXPORTS")"
ORIGEM_SNAPSHOTS="$(readlink -f "$SSD_SNAPSHOTS")"
DESTINO_SNAPSHOTS="$(readlink -f "$HD_SNAPSHOTS")"
LOG_FILE="$LOG_MOVER"

# -----------------------------------------------------------------------------
# FUNÇÃO: show_help
# -----------------------------------------------------------------------------
# Exibe a mensagem de ajuda
# -----------------------------------------------------------------------------
show_help() {
    cat << 'EOF'
Uso: frigate-mover.sh [OPÇÕES]

Script unificado para movimentação de recordings, clips, exports e snapshots do Frigate.

MODOS:
  --mode=incremental   Move diretórios de data mais antigos que KEEP_SSD_DAYS
                       Ideal para uso em cron (a cada hora)
                       
  --mode=file          Move arquivos individuais mais antigos que 24h
                       Mais granular, porém mais lento
                       
  --mode=full          Move TUDO do SSD para HD com limite de banda
                       Use para manutenção programada
                       
  --mode=emergency     Move TUDO sem limite de banda (máxima velocidade)
                       Use apenas em emergências de espaço

OPÇÕES:
  --dry-run            Simula as operações sem executar
  --progress           Mostra progresso em tempo real do rsync
  --verbose, -v        Mostra mais detalhes durante execução
  --status             Mostra estatísticas de espaço e sai
  --help, -h           Mostra esta ajuda

EXEMPLOS:
  frigate-mover.sh                          # Modo incremental (padrão)
  frigate-mover.sh --mode=full              # Move tudo
  frigate-mover.sh --mode=incremental -v    # Incremental com detalhes
  frigate-mover.sh --mode=full --progress   # Full com progresso do rsync
  frigate-mover.sh --dry-run                # Apenas simula

CONFIGURAÇÕES (.env):
  KEEP_SSD_DAYS=$KEEP_SSD_DAYS
  BWLIMIT=$BWLIMIT KB/s
  MAX_DAYS_PER_RUN=$MAX_DAYS_PER_RUN
EOF
}

# -----------------------------------------------------------------------------
# FUNÇÃO: show_status
# -----------------------------------------------------------------------------
# Mostra estatísticas de espaço em disco
# -----------------------------------------------------------------------------
show_status() {
    echo "=== Frigate Storage Status ==="
    echo ""
    
    # SSD
    if [[ -d "$SSD_ROOT" ]]; then
        local ssd_usage ssd_free ssd_total
        ssd_usage=$(get_disk_usage_pct "$SSD_ROOT")
        ssd_total=$(df -h "$SSD_ROOT" | awk 'NR==2{print $2}')
        ssd_free=$(df -h "$SSD_ROOT" | awk 'NR==2{print $4}')
        echo "📁 SSD ($SSD_ROOT)"
        echo "   Uso: ${ssd_usage}% | Total: $ssd_total | Livre: $ssd_free"
        
        # Conta diretórios de data no SSD
        local ssd_days
        ssd_days=$(find "$ORIGEM_RECORDINGS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        echo "   Dias de gravação: $ssd_days"
    else
        echo "📁 SSD: Não encontrado em $SSD_ROOT"
    fi
    
    echo ""
    
    # HD
    if check_mountpoint "$HD_MOUNT"; then
        local hd_usage hd_total hd_free
        hd_usage=$(get_disk_usage_pct "$HD_MOUNT")
        hd_total=$(df -h "$HD_MOUNT" | awk 'NR==2{print $2}')
        hd_free=$(df -h "$HD_MOUNT" | awk 'NR==2{print $4}')
        echo "💾 HD Externo ($HD_MOUNT)"
        echo "   Uso: ${hd_usage}% | Total: $hd_total | Livre: $hd_free"
        
        # Conta diretórios de data no HD
        local hd_days
        hd_days=$(find "$DESTINO_RECORDINGS" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
        echo "   Dias de gravação: $hd_days"
    else
        echo "💾 HD Externo: Não montado em $HD_MOUNT"
    fi
    
    echo ""
    echo "=== Configurações Atuais ==="
    echo "   Manter no SSD: $KEEP_SSD_DAYS dias"
    echo "   Limite de banda: $BWLIMIT KB/s"
    echo "   Máx dias por execução: $MAX_DAYS_PER_RUN"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: vlog
# -----------------------------------------------------------------------------
# Log condicional baseado no modo verbose
# -----------------------------------------------------------------------------
vlog() {
    if [[ "$VERBOSE" == "1" ]]; then
        log "$LOG_TAG" "$@"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# FUNÇÃO: run_rsync
# -----------------------------------------------------------------------------
# Executa rsync com flags de progresso opcionais.
# -----------------------------------------------------------------------------
run_rsync() {
    local step_label="${1:-transfer}"
    shift
    local err_file
    err_file="$(mktemp)"
    local rc=0

    if [[ "$SHOW_PROGRESS" == "1" ]]; then
        rsync --human-readable --info=progress2 "$@" 2>"$err_file" || rc=$?
    else
        rsync "$@" 2>"$err_file" || rc=$?
    fi

    if (( rc != 0 )); then
        local err_tail
        err_tail="$(tail -n 20 "$err_file" | tr '\n' '; ')"
        [[ -z "$err_tail" ]] && err_tail="sem detalhes de stderr"
        log_error "$LOG_TAG" "Falha no rsync ($step_label): exit=$rc, detalhes=$err_tail"
        notify_error "$LOG_TAG" "Falha no rsync ($step_label): exit=$rc"
        rm -f "$err_file"
        return "$rc"
    fi

    rm -f "$err_file"
    return 0
}

compute_date_range() {
    local src="$1"
    shift

    local dates
    local oldest="-"
    local newest="-"

    dates="$(find "$src" -type f "$@" -printf '%TY-%Tm-%Td\n' 2>/dev/null | sort || true)"
    if [[ -n "$dates" ]]; then
        oldest="$(awk 'NR==1{print; exit}' <<< "$dates")"
        newest="$(awk 'END{print}' <<< "$dates")"
    fi

    DATE_RANGE_OLDEST="$oldest"
    DATE_RANGE_NEWEST="$newest"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: move_media_before_date
# -----------------------------------------------------------------------------
# Move arquivos de uma mídia que sejam mais antigos que a data de corte.
# -----------------------------------------------------------------------------
move_media_before_date() {
    local label="$1"
    local src="$2"
    local dst="$3"
    local cutoff_date="$4"

    local processed=0
    local moved=0
    local total=0
    local total_bytes=0
    local moved_bytes=0
    local file rel_path dest_file dest_dir
    local progress_step="${MEDIA_PROGRESS_STEP:-${CLIPS_PROGRESS_STEP:-500}}"
    local remaining=0
    local oldest_date="-"
    local newest_date="-"

    [[ -d "$src" ]] || {
        log "$LOG_TAG" "Diretório $label não existe, pulando: $src"
        return 0
    }

    total=$(find "$src" -type f ! -newermt "${cutoff_date} 00:00:00" -printf . 2>/dev/null | wc -c)
    total_bytes=$(find "$src" -type f ! -newermt "${cutoff_date} 00:00:00" -printf '%s\n' 2>/dev/null | awk '{sum+=$1} END{print sum+0}')
    compute_date_range "$src" ! -newermt "${cutoff_date} 00:00:00"
    oldest_date="$DATE_RANGE_OLDEST"
    newest_date="$DATE_RANGE_NEWEST"
    log "$LOG_TAG" "Iniciando etapa de $label (corte: < ${cutoff_date}, candidatos=${total}, bytes=$(bytes_human "$total_bytes"), datas=${oldest_date}..${newest_date})"

    while IFS= read -r -d '' file; do
        rel_path="${file#$src/}"
        dest_file="$dst/$rel_path"
        dest_dir="$(dirname "$dest_file")"
        ((++processed))

        if [[ "$DRY_RUN" == "1" ]]; then
            vlog "[DRY-RUN] Moveria $label: $rel_path"
        else
            local size_b=0
            size_b="$(stat -c%s "$file" 2>/dev/null || echo 0)"
            mkdir -p "$dest_dir"
            chown "${FRIGATE_UID}:${FRIGATE_GID}" "$dest_dir"

            if run_rsync "$label:$rel_path" -a --chown="${FRIGATE_UID}:${FRIGATE_GID}" \
                --remove-source-files "$file" "$dest_file"; then
                ((++moved))
                moved_bytes=$((moved_bytes + size_b))
                vlog "$label movido: $rel_path"
            else
                log_error "$LOG_TAG" "ERRO ao mover $label: $rel_path"
            fi
        fi

        if (( processed % progress_step == 0 )); then
            remaining=$((total - processed))
            (( remaining < 0 )) && remaining=0
            if [[ "$DRY_RUN" == "1" ]]; then
                log "$LOG_TAG" "Progresso $label: processados=$processed restante=$remaining"
            else
                log "$LOG_TAG" "Progresso $label: processados=$processed movidos=$moved restante=$remaining"
            fi
        fi
    done < <(find "$src" -type f ! -newermt "${cutoff_date} 00:00:00" -print0 2>/dev/null)

    if [[ "$DRY_RUN" == "1" ]]; then
        log "$LOG_TAG" "[DRY-RUN] ${label^}: candidatos=$processed bytes=$(bytes_human "$total_bytes") datas=${oldest_date}..${newest_date}"
    else
        find "$src" -type d -empty -delete 2>/dev/null || true
        log "$LOG_TAG" "${label^} concluído: movidos=$moved/$processed bytes=$(bytes_human "$moved_bytes") de $(bytes_human "$total_bytes") datas=${oldest_date}..${newest_date}"
    fi
}

# -----------------------------------------------------------------------------
# FUNÇÃO: move_media_older_than_day
# -----------------------------------------------------------------------------
# Move arquivos com mtime > 24h de uma mídia para outra.
# -----------------------------------------------------------------------------
move_media_older_than_day() {
    local label="$1"
    local src="$2"
    local dst="$3"

    local moved=0
    local moved_bytes=0
    local total=0
    local total_bytes=0
    local file rel_path dest_file dest_dir
    local oldest_date="-"
    local newest_date="-"

    [[ -d "$src" ]] || {
        log "$LOG_TAG" "Diretório $label não existe, pulando: $src"
        echo 0
        return 0
    }

    total=$(find "$src" -type f -daystart -mtime +0 -printf . 2>/dev/null | wc -c)
    total_bytes=$(find "$src" -type f -daystart -mtime +0 -printf '%s\n' 2>/dev/null | awk '{sum+=$1} END{print sum+0}')
    compute_date_range "$src" -daystart -mtime +0
    oldest_date="$DATE_RANGE_OLDEST"
    newest_date="$DATE_RANGE_NEWEST"
    log "$LOG_TAG" "Etapa $label (>24h): candidatos=$total bytes=$(bytes_human "$total_bytes") datas=${oldest_date}..${newest_date}"

    while IFS= read -r -d '' file; do
        rel_path="${file#$src/}"
        dest_file="$dst/$rel_path"
        dest_dir="$(dirname "$dest_file")"

        if [[ "$DRY_RUN" == "1" ]]; then
            log "$LOG_TAG" "[DRY-RUN] Moveria $label: $rel_path"
        else
            local size_b=0
            size_b="$(stat -c%s "$file" 2>/dev/null || echo 0)"
            mkdir -p "$dest_dir"
            chown "${FRIGATE_UID}:${FRIGATE_GID}" "$dest_dir"

            if run_rsync "$label:$rel_path" -a --chown="${FRIGATE_UID}:${FRIGATE_GID}" \
                --remove-source-files "$file" "$dest_file"; then
                vlog "$label movido: $rel_path"
                ((++moved))
                moved_bytes=$((moved_bytes + size_b))
            fi
        fi
    done < <(find "$src" -type f -daystart -mtime +0 -print0 2>/dev/null)

    if [[ "$DRY_RUN" != "1" ]]; then
        find "$src" -type d -empty -delete 2>/dev/null || true
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        log "$LOG_TAG" "[DRY-RUN] $label (>24h): candidatos=$total bytes=$(bytes_human "$total_bytes") datas=${oldest_date}..${newest_date}"
    else
        log "$LOG_TAG" "$label (>24h) concluído: movidos=$moved/$total bytes=$(bytes_human "$moved_bytes") de $(bytes_human "$total_bytes") datas=${oldest_date}..${newest_date}"
    fi

    echo "$moved|$moved_bytes"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: check_prerequisites
# -----------------------------------------------------------------------------
# Verifica pré-requisitos antes de executar
# -----------------------------------------------------------------------------
check_prerequisites() {
    # Verifica se pelo menos um diretório de origem existe
    if [[ ! -d "$ORIGEM_RECORDINGS" && ! -d "$ORIGEM_CLIPS" && ! -d "$ORIGEM_EXPORTS" && ! -d "$ORIGEM_SNAPSHOTS" ]]; then
        log "$LOG_TAG" "ERRO: nenhum diretório de origem existe (recordings/clips/exports/snapshots)"
        exit 1
    fi
    
    # Verifica se o HD está montado
    if ! check_mountpoint "$HD_MOUNT"; then
        log "$LOG_TAG" "HD externo não montado em $HD_MOUNT"
        exit 0
    fi
    
    # Verifica rsync
    if ! command -v rsync &>/dev/null; then
        log "$LOG_TAG" "ERRO: rsync não encontrado"
        exit 1
    fi
    
    # Garante que os diretórios de destino existem
    ensure_dir "$DESTINO_RECORDINGS"
    ensure_dir "$DESTINO_CLIPS"
    ensure_dir "$DESTINO_EXPORTS"
    ensure_dir "$DESTINO_SNAPSHOTS"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: acquire_mover_lock
# -----------------------------------------------------------------------------
# Adquire o lock para operações de movimentação
# -----------------------------------------------------------------------------
acquire_mover_lock() {
    local lock_file="${LOCK_STORAGE:-/tmp/frigate-storage.lock}"
    local fallback_lock="${SCRIPT_DIR}/.runtime/frigate-storage.lock"

    # Fallback automático quando /var/lock não é gravável por usuário comum.
    if ! (: >>"$lock_file") 2>/dev/null; then
        lock_file="$fallback_lock"
        : >>"$lock_file" || {
            log "$LOG_TAG" "ERRO: não foi possível criar lock em $fallback_lock"
            exit 1
        }
        vlog "Aviso: usando lock fallback em $fallback_lock"
    fi
    exec 200>"$lock_file"

    if ! flock -n 200; then
        log "$LOG_TAG" "Lock ocupado por outro processo"
        exit 0
    fi
}

# -----------------------------------------------------------------------------
# FUNÇÃO: mode_incremental
# -----------------------------------------------------------------------------
# Modo incremental: move diretórios de data mais antigos que KEEP_SSD_DAYS
# (Lógica do antigo frigate-archive.sh)
# -----------------------------------------------------------------------------
mode_incremental() {
    log "$LOG_TAG" "Modo: INCREMENTAL (mover dias > ${KEEP_SSD_DAYS} dias)"
    
    # Calcula a data de corte
    local offset=$((KEEP_SSD_DAYS - 1))
    local keep_from
    keep_from="$(date -d "-$offset day" +%F)"
    
    log "$LOG_TAG" "Mantendo dias >= $keep_from no SSD"
    
    # Lista diretórios de data
    local days
    mapfile -t days < <(
        find "$ORIGEM_RECORDINGS" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
        | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
        | sort
    )

    if (( ${#days[@]} == 0 )); then
        log "$LOG_TAG" "Datas encontradas: nenhuma"
    else
        local days_list
        days_list="$(IFS=', '; echo "${days[*]}")"
        log "$LOG_TAG" "Datas encontradas (${#days[@]}): $days_list"
    fi
    
    local processed=0
    local moved=0
    local moved_files=0
    local moved_bytes=0
    local moved_days=()
    
    for day in "${days[@]}"; do
        # Limite de dias por execução
        if (( processed >= MAX_DAYS_PER_RUN )); then
            log "$LOG_TAG" "Limite de $MAX_DAYS_PER_RUN dias atingido"
            break
        fi
        
        # Pula dias recentes
        [[ "$day" < "$keep_from" ]] || continue
        
        vlog "Processando: $day"
        ((++processed))
        
        if [[ "$DRY_RUN" == "1" ]]; then
            local day_files day_bytes
            day_files=$(find "$ORIGEM_RECORDINGS/$day" -type f -printf . 2>/dev/null | wc -c)
            day_bytes=$(find "$ORIGEM_RECORDINGS/$day" -type f -printf '%s\n' 2>/dev/null | awk '{sum+=$1} END{print sum+0}')
            log "$LOG_TAG" "[DRY-RUN] recordings dia=$day: arquivos=$day_files bytes=$(bytes_human "$day_bytes")"
        else
            local day_files day_bytes
            day_files=$(find "$ORIGEM_RECORDINGS/$day" -type f -printf . 2>/dev/null | wc -c)
            day_bytes=$(find "$ORIGEM_RECORDINGS/$day" -type f -printf '%s\n' 2>/dev/null | awk '{sum+=$1} END{print sum+0}')
            if run_rsync "recordings:$day" -a --chown="${FRIGATE_UID}:${FRIGATE_GID}" \
                "$ORIGEM_RECORDINGS/$day/" "$DESTINO_RECORDINGS/$day/"; then
                rm -rf "$ORIGEM_RECORDINGS/$day"
                ((++moved))
                moved_files=$((moved_files + day_files))
                moved_bytes=$((moved_bytes + day_bytes))
                moved_days+=("$day")
                vlog "Movido: $day"
            else
                log_error "$LOG_TAG" "ERRO ao mover recordings: $day"
            fi
        fi
    done
    
    local moved_days_summary="nenhuma"
    if (( ${#moved_days[@]} > 0 )); then
        moved_days_summary="$(printf '%s\n' "${moved_days[@]}" | sort -u | paste -sd, -)"
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        log "$LOG_TAG" "[DRY-RUN] Recordings incremental: dias_candidatos=$processed"
    else
        log "$LOG_TAG" "Recordings concluído: dias_movidos=$moved/$processed arquivos=$moved_files bytes=$(bytes_human "$moved_bytes") datas=$moved_days_summary"
    fi

    move_media_before_date "clips" "$ORIGEM_CLIPS" "$DESTINO_CLIPS" "$keep_from"
    move_media_before_date "exports" "$ORIGEM_EXPORTS" "$DESTINO_EXPORTS" "$keep_from"
    move_media_before_date "snapshots" "$ORIGEM_SNAPSHOTS" "$DESTINO_SNAPSHOTS" "$keep_from"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: mode_file
# -----------------------------------------------------------------------------
# Modo arquivo: move arquivos individuais mais antigos que 24h
# (Lógica do antigo frigate-archiver.sh)
# -----------------------------------------------------------------------------
mode_file() {
    log "$LOG_TAG" "Modo: FILE (mover arquivos > 24h em recordings/clips/exports/snapshots)"

    local rec_stats clips_stats exports_stats snapshots_stats
    local rec_count clips_count exports_count snapshots_count
    local rec_bytes clips_bytes exports_bytes snapshots_bytes

    rec_stats=$(move_media_older_than_day "recordings" "$ORIGEM_RECORDINGS" "$DESTINO_RECORDINGS")
    clips_stats=$(move_media_older_than_day "clips" "$ORIGEM_CLIPS" "$DESTINO_CLIPS")
    exports_stats=$(move_media_older_than_day "exports" "$ORIGEM_EXPORTS" "$DESTINO_EXPORTS")
    snapshots_stats=$(move_media_older_than_day "snapshots" "$ORIGEM_SNAPSHOTS" "$DESTINO_SNAPSHOTS")

    IFS='|' read -r rec_count rec_bytes <<< "$rec_stats"
    IFS='|' read -r clips_count clips_bytes <<< "$clips_stats"
    IFS='|' read -r exports_count exports_bytes <<< "$exports_stats"
    IFS='|' read -r snapshots_count snapshots_bytes <<< "$snapshots_stats"

    log "$LOG_TAG" "Concluído FILE: recordings=${rec_count}($(bytes_human "${rec_bytes:-0}")) clips=${clips_count}($(bytes_human "${clips_bytes:-0}")) exports=${exports_count}($(bytes_human "${exports_bytes:-0}")) snapshots=${snapshots_count}($(bytes_human "${snapshots_bytes:-0}"))"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: mode_full
# -----------------------------------------------------------------------------
# Modo full: move TUDO de uma vez com limite de banda
# (Lógica do antigo mover_frigate_para_hd.sh)
# -----------------------------------------------------------------------------
mode_full() {
    local bw="${1:-$BWLIMIT}"
    local total_moved_files=0
    local total_moved_bytes=0
    
    log "$LOG_TAG" "Modo: FULL (mover tudo: recordings + clips + exports + snapshots, bwlimit=${bw} KB/s)"

    move_tree_full() {
        local label="$1"
        local src="$2"
        local dst="$3"
        local before_files before_bytes before_old before_new
        local after_files after_bytes moved_files moved_bytes

        [[ -d "$src" ]] || {
            log_warn "$LOG_TAG" "$label ausente, pulando: $src"
            return 0
        }

        collect_path_stats "$src"
        before_files="$STATS_FILES"
        before_bytes="$STATS_BYTES"
        before_old="$STATS_OLDEST"
        before_new="$STATS_NEWEST"

        log "$LOG_TAG" "FULL $label: origem=$src destino=$dst candidatos=${before_files} bytes=$(bytes_human "$before_bytes") datas=${before_old}..${before_new}"
        if (( before_files == 0 )); then
            return 0
        fi

        if [[ "$DRY_RUN" == "1" ]]; then
            run_rsync "full:$label:dry-run" -av --dry-run --bwlimit="$bw" "$src/" "$dst/" || return 1
            log "$LOG_TAG" "[DRY-RUN] FULL $label: candidatos=${before_files} bytes=$(bytes_human "$before_bytes")"
            return 0
        fi

        run_rsync "full:$label" -a --bwlimit="$bw" --remove-source-files --ignore-missing-args "$src/" "$dst/" || return 1
        find "$src" -type d -empty -not -path "$src" -delete 2>/dev/null || true

        collect_path_stats "$src"
        after_files="$STATS_FILES"
        after_bytes="$STATS_BYTES"
        moved_files=$((before_files - after_files))
        moved_bytes=$((before_bytes - after_bytes))
        (( moved_files < 0 )) && moved_files=0
        (( moved_bytes < 0 )) && moved_bytes=0

        total_moved_files=$((total_moved_files + moved_files))
        total_moved_bytes=$((total_moved_bytes + moved_bytes))

        log "$LOG_TAG" "FULL $label concluído: movidos=${moved_files}/${before_files} bytes=$(bytes_human "$moved_bytes") restante_origem=${after_files} ($(bytes_human "$after_bytes"))"
    }
    
    if [[ "$DRY_RUN" == "1" ]]; then
        move_tree_full "recordings" "$ORIGEM_RECORDINGS" "$DESTINO_RECORDINGS"
        move_tree_full "clips" "$ORIGEM_CLIPS" "$DESTINO_CLIPS"
        move_tree_full "exports" "$ORIGEM_EXPORTS" "$DESTINO_EXPORTS"
        move_tree_full "snapshots" "$ORIGEM_SNAPSHOTS" "$DESTINO_SNAPSHOTS"
    else
        move_tree_full "recordings" "$ORIGEM_RECORDINGS" "$DESTINO_RECORDINGS"
        move_tree_full "clips" "$ORIGEM_CLIPS" "$DESTINO_CLIPS"
        move_tree_full "exports" "$ORIGEM_EXPORTS" "$DESTINO_EXPORTS"
        move_tree_full "snapshots" "$ORIGEM_SNAPSHOTS" "$DESTINO_SNAPSHOTS"
        log "$LOG_TAG" "Movimentação completa concluída: arquivos=${total_moved_files} bytes=$(bytes_human "$total_moved_bytes")"
    fi
}

# -----------------------------------------------------------------------------
# FUNÇÃO: mode_emergency
# -----------------------------------------------------------------------------
# Modo emergência: move TUDO sem limite de banda
# -----------------------------------------------------------------------------
mode_emergency() {
    log "$LOG_TAG" "⚠️  Modo: EMERGENCY (sem limite de banda!)"
    mode_full 0  # bwlimit=0 significa sem limite
}

# -----------------------------------------------------------------------------
# PROCESSAMENTO DOS ARGUMENTOS
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode=*)
            MODE="${1#*=}"
            ;;
        --dry-run)
            DRY_RUN=1
            ;;
        --progress)
            SHOW_PROGRESS=1
            ;;
        --verbose|-v)
            VERBOSE=1
            ;;
        --status)
            show_status
            exit 0
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "Opção desconhecida: $1"
            echo "Use --help para ver as opções."
            exit 1
            ;;
    esac
    shift
done

# -----------------------------------------------------------------------------
# VALIDAÇÃO DO MODO
# -----------------------------------------------------------------------------
case "$MODE" in
    incremental|file|full|emergency)
        # Modo válido
        ;;
    *)
        echo "Modo inválido: $MODE"
        echo "Modos disponíveis: incremental, file, full, emergency"
        exit 1
        ;;
esac

# -----------------------------------------------------------------------------
# EXECUÇÃO PRINCIPAL
# -----------------------------------------------------------------------------
# Configura logging e rastreio de erro
setup_logging "$LOG_FILE"
setup_error_trap

# Verifica pré-requisitos
check_prerequisites

# Adquire lock
acquire_mover_lock

# Registra início
log "$LOG_TAG" "=========================================="
log "$LOG_TAG" "Iniciando (mode=$MODE, dry_run=$DRY_RUN)"
[[ "$VERBOSE" == "1" ]] && show_status

# Executa o modo selecionado
case "$MODE" in
    incremental)
        mode_incremental
        ;;
    file)
        mode_file
        ;;
    full)
        mode_full
        ;;
    emergency)
        mode_emergency
        ;;
esac

log "$LOG_TAG" "Finalizado"
log "$LOG_TAG" "=========================================="
