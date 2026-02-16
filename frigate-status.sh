#!/usr/bin/env bash
# VERSION: 1.2
# =============================================================================
# FRIGATE-STATUS.SH
# =============================================================================
# Script de health check unificado para o sistema Frigate.
#
# DESCRIÇÃO:
#   Exibe um relatório completo do estado do sistema de armazenamento,
#   incluindo uso de disco, status do container Frigate, locks ativos,
#   e potenciais problemas.
#
# USO:
#   ./frigate-status.sh              # Relatório completo
#   ./frigate-status.sh --brief      # Resumo em uma linha
#   ./frigate-status.sh --json       # Saída em JSON
#   ./frigate-status.sh --check      # Verifica problemas (exit code)
#   ./frigate-status.sh --watch      # Monitora em tempo real
#
# EXIT CODES (modo --check):
#   0 - Tudo OK
#   1 - Alerta (espaço baixo, mas não crítico)
#   2 - Crítico (ação necessária)
#
# AUTOR: Sistema Marquise
# =============================================================================

# -----------------------------------------------------------------------------
# CARREGA CONFIGURAÇÕES E FUNÇÕES COMPARTILHADAS
# -----------------------------------------------------------------------------
source "$(dirname "$0")/common.sh"

# -----------------------------------------------------------------------------
# CORES PARA OUTPUT
# -----------------------------------------------------------------------------
# Verifica se o terminal suporta cores
if [[ -t 1 ]] && command -v tput &>/dev/null; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    CYAN=$(tput setaf 6)
    BOLD=$(tput bold)
    RESET=$(tput sgr0)
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    CYAN=""
    BOLD=""
    RESET=""
fi

# -----------------------------------------------------------------------------
# VARIÁVEIS GLOBAIS
# -----------------------------------------------------------------------------
LOG_TAG="status"
LOG_FILE="${LOG_STATUS:-/var/log/frigate-status.log}"
MIRROR_STDOUT=1
MODE="full"
EXIT_CODE=0

# Thresholds para alertas (usa valores do .env)
WARN_THRESHOLD="${WARN_THRESHOLD:-75}"
CRIT_THRESHOLD="${CRIT_THRESHOLD:-90}"

# -----------------------------------------------------------------------------
# FUNÇÃO: show_help
# -----------------------------------------------------------------------------
show_help() {
    cat << 'EOF'
Uso: frigate-status.sh [OPÇÃO]

Exibe status e saúde do sistema de armazenamento Frigate.

OPÇÕES:
  (sem opção)    Relatório completo com todas as informações
  --brief, -b    Resumo em uma linha (para scripts/monitoramento)
  --json, -j     Saída formatada em JSON
  --check, -c    Verifica problemas e retorna exit code
  --watch, -w    Monitora em tempo real (atualiza a cada 5s)
  --help, -h     Mostra esta ajuda

EXIT CODES (modo --check):
  0 - Sistema OK
  1 - Alerta (espaço < 25% livre)
  2 - Crítico (espaço < 10% livre ou HD desmontado)

EXEMPLOS:
  frigate-status.sh                    # Relatório completo
  frigate-status.sh --brief            # Uma linha de resumo
  frigate-status.sh --check && echo OK # Verifica status
  watch -c frigate-status.sh           # Monitora externo
EOF
}

# -----------------------------------------------------------------------------
# FUNÇÃO: get_frigate_container_status
# -----------------------------------------------------------------------------
# Verifica o status do container Frigate
#
# RETORNO:
#   running - Container está rodando
#   stopped - Container existe mas está parado
#   missing - Container não existe
# -----------------------------------------------------------------------------
get_frigate_container_status() {
    if ! command -v docker &>/dev/null; then
        echo "no-docker"
        return
    fi
    
    local container_id
    container_id=$(docker ps -q --filter name=frigate 2>/dev/null | head -n1 || true)
    
    if [[ -n "$container_id" ]]; then
        echo "running"
    elif (docker ps -aq --filter name=frigate 2>/dev/null | head -n1 || true) | grep -q .; then
        echo "stopped"
    else
        echo "missing"
    fi
}

# -----------------------------------------------------------------------------
# FUNÇÃO: get_disk_info
# -----------------------------------------------------------------------------
# Obtém informações detalhadas de um disco
#
# ARGUMENTOS:
#   $1 - Caminho do ponto de montagem
#
# SAÍDA:
#   Variáveis globais: DISK_USAGE, DISK_FREE, DISK_TOTAL, DISK_AVAIL
# -----------------------------------------------------------------------------
get_disk_info() {
    local mount_path="$1"
    
    if [[ ! -d "$mount_path" ]]; then
        DISK_USAGE="-"
        DISK_FREE="-"
        DISK_TOTAL="-"
        DISK_AVAIL="-"
        return 1
    fi
    
    local df_output
    df_output=$(df -h "$mount_path" 2>/dev/null | tail -1)
    
    DISK_TOTAL=$(echo "$df_output" | awk '{print $2}')
    DISK_AVAIL=$(echo "$df_output" | awk '{print $4}')
    DISK_USAGE=$(echo "$df_output" | awk '{gsub(/%/,"",$5); print $5}')
    DISK_FREE=$((100 - DISK_USAGE))
}

# -----------------------------------------------------------------------------
# FUNÇÃO: count_recording_days
# -----------------------------------------------------------------------------
# Conta quantos dias de gravação existem em um diretório
#
# ARGUMENTOS:
#   $1 - Caminho do diretório de gravações
# -----------------------------------------------------------------------------
count_recording_days() {
    local rec_path="$1"
    
    if [[ ! -d "$rec_path" ]]; then
        echo "0"
        return
    fi
    
    find "$rec_path" -mindepth 1 -maxdepth 1 -type d -name "20*" 2>/dev/null | wc -l
}

# -----------------------------------------------------------------------------
# FUNÇÃO: get_oldest_newest_day
# -----------------------------------------------------------------------------
# Obtém o dia mais antigo e mais recente de gravações
#
# ARGUMENTOS:
#   $1 - Caminho do diretório de gravações
# -----------------------------------------------------------------------------
get_oldest_newest_day() {
    local rec_path="$1"
    OLDEST_DAY="-"
    NEWEST_DAY="-"
    
    if [[ ! -d "$rec_path" ]]; then
        return
    fi
    
    local days
    days="$(find "$rec_path" -mindepth 1 -maxdepth 1 -type d -name "20*" -printf '%f\n' 2>/dev/null | sort || true)"
    [[ -n "$days" ]] || return

    OLDEST_DAY="$(awk 'NR==1{print; exit}' <<< "$days")"
    NEWEST_DAY="$(awk 'END{print}' <<< "$days")"
}

count_files_in_dir() {
    local dir_path="$1"
    [[ -d "$dir_path" ]] || { echo 0; return; }
    find "$dir_path" -type f 2>/dev/null | wc -l
}

# -----------------------------------------------------------------------------
# FUNÇÃO: check_active_locks
# -----------------------------------------------------------------------------
# Verifica locks ativos no sistema
# -----------------------------------------------------------------------------
check_active_locks() {
    local locks=()

    if mkdir -p "$(dirname "$LOCK_STORAGE")" 2>/dev/null && touch "$LOCK_STORAGE" 2>/dev/null; then
        if exec 200>"$LOCK_STORAGE" 2>/dev/null; then
            flock -n 200 || locks+=("storage")
        fi
    fi

    if mkdir -p "$(dirname "$LOCK_MEDIA")" 2>/dev/null && touch "$LOCK_MEDIA" 2>/dev/null; then
        if exec 201>"$LOCK_MEDIA" 2>/dev/null; then
            flock -n 201 || locks+=("media")
        fi
    fi

    # LOCK_MOVER é legado; só reporta se existir e estiver realmente ocupado.
    if [[ -n "${LOCK_MOVER:-}" && "$LOCK_MOVER" != "$LOCK_STORAGE" && -e "$LOCK_MOVER" ]]; then
        if exec 202>"$LOCK_MOVER" 2>/dev/null; then
            flock -n 202 || locks+=("mover-legacy")
        fi
    fi
    
    if [[ ${#locks[@]} -eq 0 ]]; then
        echo "nenhum"
    else
        echo "${locks[*]}"
    fi
}

# -----------------------------------------------------------------------------
# FUNÇÃO: get_status_icon
# -----------------------------------------------------------------------------
# Retorna um ícone colorido baseado na porcentagem de uso
#
# ARGUMENTOS:
#   $1 - Porcentagem de uso
# -----------------------------------------------------------------------------
get_status_icon() {
    local usage="$1"
    
    if [[ "$usage" == "-" ]]; then
        echo "${RED}⊘${RESET}"
    elif (( usage >= CRIT_THRESHOLD )); then
        echo "${RED}●${RESET}"
    elif (( usage >= WARN_THRESHOLD )); then
        echo "${YELLOW}●${RESET}"
    else
        echo "${GREEN}●${RESET}"
    fi
}

# -----------------------------------------------------------------------------
# FUNÇÃO: print_header
# -----------------------------------------------------------------------------
print_header() {
    echo ""
    echo "${BOLD}╔══════════════════════════════════════════════════════════════════╗${RESET}"
    echo "${BOLD}║              FRIGATE STORAGE STATUS                              ║${RESET}"
    echo "${BOLD}╚══════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo "  ${CYAN}Timestamp:${RESET} $(date '+%Y-%m-%d %H:%M:%S %Z')"
    echo ""
}

# -----------------------------------------------------------------------------
# FUNÇÃO: print_storage_section
# -----------------------------------------------------------------------------
print_storage_section() {
    echo "${BOLD}┌─ ARMAZENAMENTO ──────────────────────────────────────────────────┐${RESET}"
    echo "│"
    
    # SSD
    get_disk_info "$SSD_ROOT"
    local ssd_icon=$(get_status_icon "$DISK_USAGE")
    local ssd_days=$(count_recording_days "$SSD_RECORDINGS")
    local ssd_clips_count=$(count_files_in_dir "$SSD_CLIPS")
    local ssd_exports_count=$(count_files_in_dir "$SSD_EXPORTS")
    local ssd_snapshots_count=$(count_files_in_dir "$SSD_SNAPSHOTS")
    get_oldest_newest_day "$SSD_RECORDINGS"
    
    echo "│  ${BOLD}📁 SSD${RESET} (${SSD_ROOT})"
    if [[ "$DISK_USAGE" != "-" ]]; then
        echo "│     $ssd_icon Uso: ${DISK_USAGE}% │ Total: ${DISK_TOTAL} │ Livre: ${DISK_AVAIL}"
        echo "│     📅 Dias: ${ssd_days} │ Range: ${OLDEST_DAY} → ${NEWEST_DAY}"
        echo "│     🗂️  Clips: ${ssd_clips_count} │ Exports: ${ssd_exports_count} │ Snapshots: ${ssd_snapshots_count}"
        
        # Alerta se necessário
        if (( DISK_USAGE >= CRIT_THRESHOLD )); then
            echo "│     ${RED}⚠️  CRÍTICO: SSD quase cheio!${RESET}"
            EXIT_CODE=2
        elif (( DISK_USAGE >= WARN_THRESHOLD )); then
            echo "│     ${YELLOW}⚠️  Alerta: SSD com espaço baixo${RESET}"
            [[ $EXIT_CODE -lt 1 ]] && EXIT_CODE=1
        fi
    else
        echo "│     ${RED}✗ Não encontrado${RESET}"
        EXIT_CODE=2
    fi
    
    echo "│"
    
    # HD Externo
    if check_mountpoint "$HD_MOUNT" 2>/dev/null; then
        get_disk_info "$HD_MOUNT"
        local hd_icon=$(get_status_icon "$DISK_USAGE")
        local hd_days=$(count_recording_days "$HD_RECORDINGS")
        local hd_clips_count=$(count_files_in_dir "$HD_CLIPS")
        local hd_exports_count=$(count_files_in_dir "$HD_EXPORTS")
        local hd_snapshots_count=$(count_files_in_dir "$HD_SNAPSHOTS")
        get_oldest_newest_day "$HD_RECORDINGS"
        
        echo "│  ${BOLD}💾 HD Externo${RESET} (${HD_MOUNT})"
        echo "│     $hd_icon Uso: ${DISK_USAGE}% │ Total: ${DISK_TOTAL} │ Livre: ${DISK_AVAIL}"
        echo "│     📅 Dias: ${hd_days} │ Range: ${OLDEST_DAY} → ${NEWEST_DAY}"
        echo "│     🗂️  Clips: ${hd_clips_count} │ Exports: ${hd_exports_count} │ Snapshots: ${hd_snapshots_count}"
        
        # Alerta se necessário
        if (( DISK_USAGE >= CRIT_THRESHOLD )); then
            echo "│     ${RED}⚠️  CRÍTICO: HD quase cheio!${RESET}"
            EXIT_CODE=2
        elif (( DISK_USAGE >= WARN_THRESHOLD )); then
            echo "│     ${YELLOW}⚠️  Alerta: HD com espaço baixo${RESET}"
            [[ $EXIT_CODE -lt 1 ]] && EXIT_CODE=1
        fi
    else
        echo "│  ${BOLD}💾 HD Externo${RESET} (${HD_MOUNT})"
        echo "│     ${RED}⊘ Não montado${RESET}"
        EXIT_CODE=2
    fi
    
    echo "│"
    echo "${BOLD}└──────────────────────────────────────────────────────────────────┘${RESET}"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: print_services_section
# -----------------------------------------------------------------------------
print_services_section() {
    echo ""
    echo "${BOLD}┌─ SERVIÇOS ───────────────────────────────────────────────────────┐${RESET}"
    echo "│"
    
    # Frigate Container
    local frigate_status=$(get_frigate_container_status)
    echo -n "│  🐋 Container Frigate: "
    case "$frigate_status" in
        running)
            echo "${GREEN}✓ Rodando${RESET}"
            ;;
        stopped)
            echo "${YELLOW}⊘ Parado${RESET}"
            [[ $EXIT_CODE -lt 1 ]] && EXIT_CODE=1
            ;;
        missing)
            echo "${RED}✗ Não encontrado${RESET}"
            ;;
        no-docker)
            echo "${CYAN}? Docker não instalado${RESET}"
            ;;
    esac
    
    # Locks ativos
    echo -n "│  🔒 Locks ativos: "
    local locks=$(check_active_locks)
    if [[ "$locks" == "nenhum" ]]; then
        echo "${GREEN}nenhum${RESET}"
    else
        echo "${YELLOW}$locks${RESET}"
    fi
    
    echo "│"
    echo "${BOLD}└──────────────────────────────────────────────────────────────────┘${RESET}"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: print_config_section
# -----------------------------------------------------------------------------
print_config_section() {
    echo ""
    echo "${BOLD}┌─ CONFIGURAÇÃO ───────────────────────────────────────────────────┐${RESET}"
    echo "│"
    echo "│  Manter no SSD:        ${KEEP_SSD_DAYS} dias"
    echo "│  Clips retenção:       ${CLIPS_KEEP_DAYS} dias"
    echo "│  Snapshots retenção:   ${SNAPSHOTS_KEEP_DAYS} dias"
    echo "│  Exports retenção:     ${EXPORTS_KEEP_DAYS} dias"
    echo "│  Espaço livre mín:     ${MIN_FREE_PCT}%"
    echo "│  Threshold emergência: ${SSD_EMERGENCY_THRESHOLD}%"
    echo "│  Limite de banda:      ${BWLIMIT} KB/s"
    echo "│"
    echo "${BOLD}└──────────────────────────────────────────────────────────────────┘${RESET}"
    echo ""
}

# -----------------------------------------------------------------------------
# FUNÇÃO: print_brief
# -----------------------------------------------------------------------------
# Imprime resumo em uma linha
# -----------------------------------------------------------------------------
print_brief() {
    get_disk_info "$SSD_ROOT"
    local ssd_usage="${DISK_USAGE}%"
    
    local hd_usage
    if check_mountpoint "$HD_MOUNT" 2>/dev/null; then
        get_disk_info "$HD_MOUNT"
        hd_usage="${DISK_USAGE}%"
    else
        hd_usage="N/A"
    fi
    
    local frigate_status=$(get_frigate_container_status)
    
    echo "SSD:${ssd_usage} HD:${hd_usage} Frigate:${frigate_status}"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: print_json
# -----------------------------------------------------------------------------
# Imprime saída em formato JSON
# -----------------------------------------------------------------------------
print_json() {
    get_disk_info "$SSD_ROOT"
    local ssd_usage="$DISK_USAGE"
    local ssd_total="$DISK_TOTAL"
    local ssd_avail="$DISK_AVAIL"
    local ssd_days=$(count_recording_days "$SSD_RECORDINGS")
    local ssd_clips_count=$(count_files_in_dir "$SSD_CLIPS")
    local ssd_exports_count=$(count_files_in_dir "$SSD_EXPORTS")
    local ssd_snapshots_count=$(count_files_in_dir "$SSD_SNAPSHOTS")
    
    local hd_mounted="false"
    local hd_usage="null"
    local hd_total="null"
    local hd_avail="null"
    local hd_days="0"
    local hd_clips_count="0"
    local hd_exports_count="0"
    local hd_snapshots_count="0"
    
    if check_mountpoint "$HD_MOUNT" 2>/dev/null; then
        hd_mounted="true"
        get_disk_info "$HD_MOUNT"
        hd_usage="$DISK_USAGE"
        hd_total="\"$DISK_TOTAL\""
        hd_avail="\"$DISK_AVAIL\""
        hd_days=$(count_recording_days "$HD_RECORDINGS")
        hd_clips_count=$(count_files_in_dir "$HD_CLIPS")
        hd_exports_count=$(count_files_in_dir "$HD_EXPORTS")
        hd_snapshots_count=$(count_files_in_dir "$HD_SNAPSHOTS")
    fi
    
    local frigate_status=$(get_frigate_container_status)
    
    cat << EOF
{
  "timestamp": "$(date -Is)",
  "ssd": {
    "path": "$SSD_ROOT",
    "usage_percent": $ssd_usage,
    "total": "$ssd_total",
    "available": "$ssd_avail",
    "recording_days": $ssd_days,
    "clips_files": $ssd_clips_count,
    "exports_files": $ssd_exports_count,
    "snapshots_files": $ssd_snapshots_count
  },
  "hd": {
    "path": "$HD_MOUNT",
    "mounted": $hd_mounted,
    "usage_percent": $hd_usage,
    "total": $hd_total,
    "available": $hd_avail,
    "recording_days": $hd_days,
    "clips_files": $hd_clips_count,
    "exports_files": $hd_exports_count,
    "snapshots_files": $hd_snapshots_count
  },
  "frigate": {
    "status": "$frigate_status"
  },
  "config": {
    "keep_ssd_days": $KEEP_SSD_DAYS,
    "clips_keep_days": $CLIPS_KEEP_DAYS,
    "snapshots_keep_days": $SNAPSHOTS_KEEP_DAYS,
    "exports_keep_days": $EXPORTS_KEEP_DAYS,
    "min_free_pct": $MIN_FREE_PCT,
    "bwlimit_kb": $BWLIMIT
  }
}
EOF
}

# -----------------------------------------------------------------------------
# FUNÇÃO: run_check
# -----------------------------------------------------------------------------
# Verifica problemas e retorna exit code apropriado
# -----------------------------------------------------------------------------
run_check() {
    EXIT_CODE=0
    
    # Verifica SSD
    get_disk_info "$SSD_ROOT"
    if [[ "$DISK_USAGE" == "-" ]]; then
        echo "CRITICAL: SSD not found"
        EXIT_CODE=2
    elif (( DISK_USAGE >= CRIT_THRESHOLD )); then
        echo "CRITICAL: SSD usage at ${DISK_USAGE}%"
        EXIT_CODE=2
    elif (( DISK_USAGE >= WARN_THRESHOLD )); then
        echo "WARNING: SSD usage at ${DISK_USAGE}%"
        EXIT_CODE=1
    fi
    
    # Verifica HD
    if ! check_mountpoint "$HD_MOUNT" 2>/dev/null; then
        echo "CRITICAL: HD not mounted"
        EXIT_CODE=2
    else
        get_disk_info "$HD_MOUNT"
        if (( DISK_USAGE >= CRIT_THRESHOLD )); then
            echo "CRITICAL: HD usage at ${DISK_USAGE}%"
            EXIT_CODE=2
        elif (( DISK_USAGE >= WARN_THRESHOLD )); then
            echo "WARNING: HD usage at ${DISK_USAGE}%"
            [[ $EXIT_CODE -lt 1 ]] && EXIT_CODE=1
        fi
    fi
    
    # Verifica Frigate
    local frigate_status=$(get_frigate_container_status)
    if [[ "$frigate_status" == "stopped" ]]; then
        echo "WARNING: Frigate container is stopped"
        [[ $EXIT_CODE -lt 1 ]] && EXIT_CODE=1
    fi
    
    if [[ $EXIT_CODE -eq 0 ]]; then
        echo "OK: All systems operational"
    fi
    
    return $EXIT_CODE
}

# -----------------------------------------------------------------------------
# FUNÇÃO: run_watch
# -----------------------------------------------------------------------------
# Monitora em tempo real
# -----------------------------------------------------------------------------
run_watch() {
    while true; do
        clear
        print_header
        print_storage_section
        print_services_section
        echo ""
        echo "  ${CYAN}Atualizando a cada 5 segundos... (Ctrl+C para sair)${RESET}"
        sleep 5
    done
}

# -----------------------------------------------------------------------------
# PROCESSAMENTO DOS ARGUMENTOS
# -----------------------------------------------------------------------------
case "${1:-}" in
    --brief|-b)
        MODE="brief"
        ;;
    --json|-j)
        MODE="json"
        ;;
    --check|-c)
        MODE="check"
        ;;
    --watch|-w)
        MODE="watch"
        ;;
    --help|-h)
        show_help
        exit 0
        ;;
    "")
        MODE="full"
        ;;
    *)
        echo "Opção desconhecida: $1"
        echo "Use --help para ver as opções."
        exit 1
        ;;
esac

setup_logging "$LOG_FILE" "$MIRROR_STDOUT"
setup_error_trap
log "$LOG_TAG" "Iniciando frigate-status (mode=$MODE)"

# -----------------------------------------------------------------------------
# EXECUÇÃO PRINCIPAL
# -----------------------------------------------------------------------------
case "$MODE" in
    full)
        print_header
        print_storage_section
        print_services_section
        print_config_section
        ;;
    brief)
        print_brief
        ;;
    json)
        print_json
        ;;
    check)
        run_check
        check_rc=$?
        if (( check_rc > 0 )); then
            log_warn "$LOG_TAG" "Resultado check: exit_code=$check_rc"
            notify_error "$LOG_TAG" "frigate-status --check retornou $check_rc"
        else
            log "$LOG_TAG" "Resultado check: OK"
        fi
        exit "$check_rc"
        ;;
    watch)
        run_watch
        ;;
esac

log "$LOG_TAG" "Finalizado frigate-status (mode=$MODE, exit_code=$EXIT_CODE)"
exit $EXIT_CODE
