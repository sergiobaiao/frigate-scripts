#!/usr/bin/env bash
# =============================================================================
# FRIGATE-MOVER.SH
# =============================================================================
# Script unificado para movimentação de gravações do SSD para o HD externo.
#
# DESCRIÇÃO:
#   Este script consolida as funcionalidades de arquivamento de gravações
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

# Configurações do .env com valores padrão
KEEP_SSD_DAYS="${KEEP_SSD_DAYS:-2}"
BWLIMIT="${BWLIMIT:-20000}"
MAX_DAYS_PER_RUN="${MAX_DAYS_PER_RUN:-30}"

# Caminhos
ORIGEM="$SSD_RECORDINGS"
DESTINO="$HD_RECORDINGS"
LOG_FILE="$LOG_MOVER"

# -----------------------------------------------------------------------------
# FUNÇÃO: show_help
# -----------------------------------------------------------------------------
# Exibe a mensagem de ajuda
# -----------------------------------------------------------------------------
show_help() {
    cat << 'EOF'
Uso: frigate-mover.sh [OPÇÕES]

Script unificado para movimentação de gravações do Frigate.

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
  --verbose, -v        Mostra mais detalhes durante execução
  --status             Mostra estatísticas de espaço e sai
  --help, -h           Mostra esta ajuda

EXEMPLOS:
  frigate-mover.sh                          # Modo incremental (padrão)
  frigate-mover.sh --mode=full              # Move tudo
  frigate-mover.sh --mode=incremental -v    # Incremental com detalhes
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
        ssd_days=$(find "$ORIGEM" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
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
        hd_days=$(find "$DESTINO" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l)
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
    [[ "$VERBOSE" == "1" ]] && log "$LOG_TAG" "$@"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: check_prerequisites
# -----------------------------------------------------------------------------
# Verifica pré-requisitos antes de executar
# -----------------------------------------------------------------------------
check_prerequisites() {
    # Verifica se o diretório de origem existe
    if [[ ! -d "$ORIGEM" ]]; then
        log "$LOG_TAG" "ERRO: Diretório de origem não existe: $ORIGEM"
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
    
    # Garante que o diretório de destino existe
    ensure_dir "$DESTINO"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: acquire_mover_lock
# -----------------------------------------------------------------------------
# Adquire o lock para operações de movimentação
# -----------------------------------------------------------------------------
acquire_mover_lock() {
    exec 200>"$LOCK_STORAGE"
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
        find "$ORIGEM" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' \
        | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' \
        | sort
    )
    
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
        ((processed++))
        
        if [[ "$DRY_RUN" == "1" ]]; then
            log "$LOG_TAG" "[DRY-RUN] Moveria: $ORIGEM/$day -> $DESTINO/$day"
        else
            if rsync -a --chown="${FRIGATE_UID}:${FRIGATE_GID}" \
                "$ORIGEM/$day/" "$DESTINO/$day/"; then
                rm -rf "$ORIGEM/$day"
                ((moved++))
                vlog "Movido: $day"
            else
                log "$LOG_TAG" "ERRO ao mover: $day"
            fi
        fi
    done
    
    log "$LOG_TAG" "Concluído: $moved/$processed dias movidos"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: mode_file
# -----------------------------------------------------------------------------
# Modo arquivo: move arquivos individuais mais antigos que 24h
# (Lógica do antigo frigate-archiver.sh)
# -----------------------------------------------------------------------------
mode_file() {
    log "$LOG_TAG" "Modo: FILE (mover arquivos > 24h)"
    
    local count=0
    
    # Busca arquivos mais antigos que 1 dia
    find "$ORIGEM" -type f -daystart -mtime +0 -print0 | while IFS= read -r -d '' file; do
        local rel_path="${file#$ORIGEM/}"
        local dest_file="$DESTINO/$rel_path"
        local dest_dir
        dest_dir="$(dirname "$dest_file")"
        
        if [[ "$DRY_RUN" == "1" ]]; then
            log "$LOG_TAG" "[DRY-RUN] Moveria: $rel_path"
        else
            mkdir -p "$dest_dir"
            chown "${FRIGATE_UID}:${FRIGATE_GID}" "$dest_dir"
            
            if rsync -a --chown="${FRIGATE_UID}:${FRIGATE_GID}" \
                --remove-source-files "$file" "$dest_file"; then
                vlog "Movido: $rel_path"
                ((count++))
            fi
        fi
    done
    
    # Limpa diretórios vazios
    if [[ "$DRY_RUN" != "1" ]]; then
        find "$ORIGEM" -type d -empty -delete 2>/dev/null || true
    fi
    
    log "$LOG_TAG" "Concluído: arquivos processados"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: mode_full
# -----------------------------------------------------------------------------
# Modo full: move TUDO de uma vez com limite de banda
# (Lógica do antigo mover_frigate_para_hd.sh)
# -----------------------------------------------------------------------------
mode_full() {
    local bw="${1:-$BWLIMIT}"
    
    log "$LOG_TAG" "Modo: FULL (mover tudo, bwlimit=${bw} KB/s)"
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log "$LOG_TAG" "[DRY-RUN] Moveria todo conteúdo de $ORIGEM para $DESTINO"
        rsync -av --dry-run --bwlimit="$bw" "$ORIGEM/" "$DESTINO/"
    else
        # Executa rsync com todas as opções
        rsync -a \
            --bwlimit="$bw" \
            --remove-source-files \
            --ignore-missing-args \
            "$ORIGEM/" "$DESTINO/"
        
        # Limpa diretórios vazios
        find "$ORIGEM" -type d -empty -not -path "$ORIGEM" -delete 2>/dev/null || true
        
        log "$LOG_TAG" "Movimentação completa concluída"
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
