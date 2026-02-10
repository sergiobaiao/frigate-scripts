#!/usr/bin/env bash
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
    if [[ "$SHOW_PROGRESS" == "1" ]]; then
        rsync --human-readable --info=progress2 "$@"
    else
        rsync "$@"
    fi
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
    local file rel_path dest_file dest_dir
    local progress_step="${MEDIA_PROGRESS_STEP:-${CLIPS_PROGRESS_STEP:-500}}"
    local remaining=0

    [[ -d "$src" ]] || {
        log "$LOG_TAG" "Diretório $label não existe, pulando: $src"
        return 0
    }

    total=$(find "$src" -type f ! -newermt "${cutoff_date} 00:00:00" -printf . 2>/dev/null | wc -c)
    log "$LOG_TAG" "Iniciando etapa de $label (corte: < ${cutoff_date}, candidatos=${total})"

    while IFS= read -r -d '' file; do
        rel_path="${file#$src/}"
        dest_file="$dst/$rel_path"
        dest_dir="$(dirname "$dest_file")"
        ((++processed))

        if [[ "$DRY_RUN" == "1" ]]; then
            vlog "[DRY-RUN] Moveria $label: $rel_path"
        else
            mkdir -p "$dest_dir"
            chown "${FRIGATE_UID}:${FRIGATE_GID}" "$dest_dir"

            if run_rsync -a --chown="${FRIGATE_UID}:${FRIGATE_GID}" \
                --remove-source-files "$file" "$dest_file"; then
                ((++moved))
                vlog "$label movido: $rel_path"
            else
                log "$LOG_TAG" "ERRO ao mover $label: $rel_path"
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
        log "$LOG_TAG" "${label^} candidatos para mover (< ${cutoff_date}): $processed"
    else
        find "$src" -type d -empty -delete 2>/dev/null || true
        log "$LOG_TAG" "${label^} concluído: $moved/$processed arquivos movidos"
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
    local file rel_path dest_file dest_dir

    [[ -d "$src" ]] || {
        log "$LOG_TAG" "Diretório $label não existe, pulando: $src"
        echo 0
        return 0
    }

    while IFS= read -r -d '' file; do
        rel_path="${file#$src/}"
        dest_file="$dst/$rel_path"
        dest_dir="$(dirname "$dest_file")"

        if [[ "$DRY_RUN" == "1" ]]; then
            log "$LOG_TAG" "[DRY-RUN] Moveria $label: $rel_path"
        else
            mkdir -p "$dest_dir"
            chown "${FRIGATE_UID}:${FRIGATE_GID}" "$dest_dir"

            if run_rsync -a --chown="${FRIGATE_UID}:${FRIGATE_GID}" \
                --remove-source-files "$file" "$dest_file"; then
                vlog "$label movido: $rel_path"
                ((++moved))
            fi
        fi
    done < <(find "$src" -type f -daystart -mtime +0 -print0 2>/dev/null)

    if [[ "$DRY_RUN" != "1" ]]; then
        find "$src" -type d -empty -delete 2>/dev/null || true
    fi

    echo "$moved"
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
    local fallback_lock="/tmp/frigate-storage.lock"

    # Fallback automático quando /var/lock não é gravável por usuário comum.
    if ! touch "$lock_file" 2>/dev/null; then
        lock_file="$fallback_lock"
        touch "$lock_file" || {
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
            log "$LOG_TAG" "[DRY-RUN] Moveria recordings: $ORIGEM_RECORDINGS/$day -> $DESTINO_RECORDINGS/$day"
        else
            if run_rsync -a --chown="${FRIGATE_UID}:${FRIGATE_GID}" \
                "$ORIGEM_RECORDINGS/$day/" "$DESTINO_RECORDINGS/$day/"; then
                rm -rf "$ORIGEM_RECORDINGS/$day"
                ((++moved))
                vlog "Movido: $day"
            else
                log "$LOG_TAG" "ERRO ao mover recordings: $day"
            fi
        fi
    done
    
    log "$LOG_TAG" "Recordings concluído: $moved/$processed dias movidos"
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

    local rec_count clips_count exports_count snapshots_count

    rec_count=$(move_media_older_than_day "recordings" "$ORIGEM_RECORDINGS" "$DESTINO_RECORDINGS")
    clips_count=$(move_media_older_than_day "clips" "$ORIGEM_CLIPS" "$DESTINO_CLIPS")
    exports_count=$(move_media_older_than_day "exports" "$ORIGEM_EXPORTS" "$DESTINO_EXPORTS")
    snapshots_count=$(move_media_older_than_day "snapshots" "$ORIGEM_SNAPSHOTS" "$DESTINO_SNAPSHOTS")

    log "$LOG_TAG" "Concluído: arquivos processados (recordings=$rec_count, clips=$clips_count, exports=$exports_count, snapshots=$snapshots_count)"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: mode_full
# -----------------------------------------------------------------------------
# Modo full: move TUDO de uma vez com limite de banda
# (Lógica do antigo mover_frigate_para_hd.sh)
# -----------------------------------------------------------------------------
mode_full() {
    local bw="${1:-$BWLIMIT}"
    
    log "$LOG_TAG" "Modo: FULL (mover tudo: recordings + clips + exports + snapshots, bwlimit=${bw} KB/s)"
    
    if [[ "$DRY_RUN" == "1" ]]; then
        if [[ -d "$ORIGEM_RECORDINGS" ]]; then
            log "$LOG_TAG" "[DRY-RUN] Moveria recordings: $ORIGEM_RECORDINGS -> $DESTINO_RECORDINGS"
            run_rsync -av --dry-run --bwlimit="$bw" "$ORIGEM_RECORDINGS/" "$DESTINO_RECORDINGS/"
        else
            log "$LOG_TAG" "[DRY-RUN] recordings ausente, pulando: $ORIGEM_RECORDINGS"
        fi
        if [[ -d "$ORIGEM_CLIPS" ]]; then
            log "$LOG_TAG" "[DRY-RUN] Moveria clips: $ORIGEM_CLIPS -> $DESTINO_CLIPS"
            run_rsync -av --dry-run --bwlimit="$bw" "$ORIGEM_CLIPS/" "$DESTINO_CLIPS/"
        else
            log "$LOG_TAG" "[DRY-RUN] clips ausente, pulando: $ORIGEM_CLIPS"
        fi
        if [[ -d "$ORIGEM_EXPORTS" ]]; then
            log "$LOG_TAG" "[DRY-RUN] Moveria exports: $ORIGEM_EXPORTS -> $DESTINO_EXPORTS"
            run_rsync -av --dry-run --bwlimit="$bw" "$ORIGEM_EXPORTS/" "$DESTINO_EXPORTS/"
        else
            log "$LOG_TAG" "[DRY-RUN] exports ausente, pulando: $ORIGEM_EXPORTS"
        fi
        if [[ -d "$ORIGEM_SNAPSHOTS" ]]; then
            log "$LOG_TAG" "[DRY-RUN] Moveria snapshots: $ORIGEM_SNAPSHOTS -> $DESTINO_SNAPSHOTS"
            run_rsync -av --dry-run --bwlimit="$bw" "$ORIGEM_SNAPSHOTS/" "$DESTINO_SNAPSHOTS/"
        else
            log "$LOG_TAG" "[DRY-RUN] snapshots ausente, pulando: $ORIGEM_SNAPSHOTS"
        fi
    else
        # Executa rsync com todas as opções para recordings
        if [[ -d "$ORIGEM_RECORDINGS" ]]; then
            run_rsync -a \
                --bwlimit="$bw" \
                --remove-source-files \
                --ignore-missing-args \
                "$ORIGEM_RECORDINGS/" "$DESTINO_RECORDINGS/"
        fi

        # Executa rsync com todas as opções para clips
        if [[ -d "$ORIGEM_CLIPS" ]]; then
            run_rsync -a \
                --bwlimit="$bw" \
                --remove-source-files \
                --ignore-missing-args \
                "$ORIGEM_CLIPS/" "$DESTINO_CLIPS/"
        fi

        # Executa rsync com todas as opções para exports
        if [[ -d "$ORIGEM_EXPORTS" ]]; then
            run_rsync -a \
                --bwlimit="$bw" \
                --remove-source-files \
                --ignore-missing-args \
                "$ORIGEM_EXPORTS/" "$DESTINO_EXPORTS/"
        fi

        # Executa rsync com todas as opções para snapshots
        if [[ -d "$ORIGEM_SNAPSHOTS" ]]; then
            run_rsync -a \
                --bwlimit="$bw" \
                --remove-source-files \
                --ignore-missing-args \
                "$ORIGEM_SNAPSHOTS/" "$DESTINO_SNAPSHOTS/"
        fi
        
        # Limpa diretórios vazios
        [[ -d "$ORIGEM_RECORDINGS" ]] && find "$ORIGEM_RECORDINGS" -type d -empty -not -path "$ORIGEM_RECORDINGS" -delete 2>/dev/null || true
        [[ -d "$ORIGEM_CLIPS" ]] && find "$ORIGEM_CLIPS" -type d -empty -not -path "$ORIGEM_CLIPS" -delete 2>/dev/null || true
        [[ -d "$ORIGEM_EXPORTS" ]] && find "$ORIGEM_EXPORTS" -type d -empty -not -path "$ORIGEM_EXPORTS" -delete 2>/dev/null || true
        [[ -d "$ORIGEM_SNAPSHOTS" ]] && find "$ORIGEM_SNAPSHOTS" -type d -empty -not -path "$ORIGEM_SNAPSHOTS" -delete 2>/dev/null || true
        
        log "$LOG_TAG" "Movimentação completa concluída (recordings + clips + exports + snapshots)"
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
