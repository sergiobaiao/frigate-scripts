#!/usr/bin/env bash
# VERSION: 1.0
# =============================================================================
# FRIGATE-LOGROTATE.SH
# =============================================================================
# Script de rotação de logs independente do logrotate do sistema.
#
# DESCRIÇÃO:
#   Faz a rotação manual dos logs do Frigate, mantendo 30 dias de histórico
#   com compressão. Útil quando o logrotate do sistema não está disponível
#   ou para ter controle mais fino sobre a rotação.
#
# USO:
#   ./frigate-logrotate.sh              # Rotaciona todos os logs
#   ./frigate-logrotate.sh --dry-run    # Simula sem executar
#   ./frigate-logrotate.sh --status     # Mostra status dos logs
#
# INSTALAÇÃO VIA CRON:
#   0 0 * * * /path/to/frigate-logrotate.sh
#
# AUTOR: Sistema Marquise
# =============================================================================

# -----------------------------------------------------------------------------
# CARREGA CONFIGURAÇÕES E FUNÇÕES COMPARTILHADAS
# -----------------------------------------------------------------------------
source "$(dirname "$0")/common.sh"

# -----------------------------------------------------------------------------
# CONFIGURAÇÕES
# -----------------------------------------------------------------------------
LOG_TAG="logrotate"

# Dias para manter logs (pode ser sobrescrito via .env)
LOG_RETENTION_DAYS="${LOG_RETENTION_DAYS:-30}"

# Lista de arquivos de log a rotacionar
LOG_FILES=(
    "/var/log/ssd_to_hd.log"
    "/var/log/frigate-archive.log"
    "/var/log/frigate-prune-hd.log"
    "/var/log/frigate-retention.log"
    "/var/log/frigate-vacuum.log"
    "/var/log/frigate-status.log"
)

# Modo de execução
DRY_RUN=0
SHOW_STATUS=0

# -----------------------------------------------------------------------------
# FUNÇÃO: show_help
# -----------------------------------------------------------------------------
show_help() {
    cat << 'EOF'
Uso: frigate-logrotate.sh [OPÇÃO]

Rotação manual de logs do sistema Frigate.

OPÇÕES:
  (sem opção)    Executa a rotação de logs
  --dry-run      Simula a rotação sem executar
  --status       Mostra informações sobre os logs
  --cleanup      Remove logs compactados mais antigos que 30 dias
  --help, -h     Mostra esta ajuda

CONFIGURAÇÕES (.env):
  LOG_RETENTION_DAYS=30   # Dias para manter logs

LOGS GERENCIADOS:
  /var/log/ssd_to_hd.log
  /var/log/frigate-archive.log
  /var/log/frigate-prune-hd.log
  /var/log/frigate-retention.log
  /var/log/frigate-vacuum.log
  /var/log/frigate-status.log
EOF
}

# -----------------------------------------------------------------------------
# FUNÇÃO: show_status
# -----------------------------------------------------------------------------
# Mostra informações sobre os arquivos de log
# -----------------------------------------------------------------------------
show_status() {
    echo "=== Status dos Logs Frigate ==="
    echo ""
    echo "Retenção configurada: ${LOG_RETENTION_DAYS} dias"
    echo ""
    
    local total_size=0
    local total_compressed=0
    
    printf "%-35s %10s %12s %s\n" "ARQUIVO" "TAMANHO" "MODIFICADO" "STATUS"
    printf "%s\n" "--------------------------------------------------------------------------------"
    
    for log_file in "${LOG_FILES[@]}"; do
        local basename
        basename=$(basename "$log_file")
        
        if [[ -f "$log_file" ]]; then
            local size size_human mod_time
            size=$(stat -c%s "$log_file" 2>/dev/null || echo 0)
            size_human=$(numfmt --to=iec-i --suffix=B "$size" 2>/dev/null || echo "${size}B")
            mod_time=$(stat -c%y "$log_file" 2>/dev/null | cut -d' ' -f1)
            
            printf "%-35s %10s %12s %s\n" "$basename" "$size_human" "$mod_time" "✓"
            total_size=$((total_size + size))
        else
            printf "%-35s %10s %12s %s\n" "$basename" "-" "-" "não existe"
        fi
        
        # Conta logs compactados
        local compressed_count
        compressed_count=$(ls "${log_file}"*.gz 2>/dev/null | wc -l)
        if [[ $compressed_count -gt 0 ]]; then
            local comp_size
            comp_size=$(du -cb "${log_file}"*.gz 2>/dev/null | tail -1 | cut -f1)
            total_compressed=$((total_compressed + comp_size))
            printf "%-35s %10s %12s %s\n" "  └─ ${compressed_count} arquivo(s) .gz" \
                "$(numfmt --to=iec-i --suffix=B "$comp_size" 2>/dev/null)" "" ""
        fi
    done
    
    echo ""
    echo "────────────────────────────────────────────────────────────────────────────────"
    printf "Total logs ativos:     %s\n" "$(numfmt --to=iec-i --suffix=B "$total_size" 2>/dev/null)"
    printf "Total compactados:     %s\n" "$(numfmt --to=iec-i --suffix=B "$total_compressed" 2>/dev/null)"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: rotate_log
# -----------------------------------------------------------------------------
# Rotaciona um único arquivo de log
#
# ARGUMENTOS:
#   $1 - Caminho do arquivo de log
# -----------------------------------------------------------------------------
rotate_log() {
    local log_file="$1"
    local basename
    basename=$(basename "$log_file")
    
    # Verifica se o arquivo existe e não está vazio
    if [[ ! -f "$log_file" ]]; then
        vlog "Arquivo não existe: $log_file"
        return 0
    fi
    
    if [[ ! -s "$log_file" ]]; then
        vlog "Arquivo vazio, ignorando: $log_file"
        return 0
    fi
    
    # Gera o nome do arquivo rotacionado com data
    local today
    today=$(date +%Y%m%d)
    local rotated_file="${log_file}-${today}"
    
    # Se já existe arquivo rotacionado hoje, adiciona sufixo
    local suffix=0
    while [[ -f "${rotated_file}.gz" ]] || [[ -f "${rotated_file}" ]]; do
        ((suffix++))
        rotated_file="${log_file}-${today}.${suffix}"
    done
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log "$LOG_TAG" "[DRY-RUN] Rotacionaria: $basename -> $(basename "$rotated_file").gz"
        return 0
    fi
    
    # Move o arquivo atual para o nome rotacionado
    mv "$log_file" "$rotated_file"
    
    # Compacta o arquivo rotacionado
    gzip "$rotated_file"
    
    # Cria novo arquivo vazio com as mesmas permissões
    touch "$log_file"
    chmod 644 "$log_file"
    
    log "$LOG_TAG" "Rotacionado: $basename -> $(basename "$rotated_file").gz"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: cleanup_old_logs
# -----------------------------------------------------------------------------
# Remove logs compactados mais antigos que LOG_RETENTION_DAYS
# -----------------------------------------------------------------------------
cleanup_old_logs() {
    log "$LOG_TAG" "Limpando logs com mais de ${LOG_RETENTION_DAYS} dias..."
    
    local removed=0
    
    for log_file in "${LOG_FILES[@]}"; do
        # Busca arquivos .gz mais antigos que LOG_RETENTION_DAYS
        while IFS= read -r -d '' old_file; do
            if [[ "$DRY_RUN" == "1" ]]; then
                log "$LOG_TAG" "[DRY-RUN] Removeria: $(basename "$old_file")"
            else
                rm -f "$old_file"
                vlog "Removido: $(basename "$old_file")"
            fi
            ((removed++))
        done < <(find "$(dirname "$log_file")" -name "$(basename "$log_file")*.gz" -mtime +"$LOG_RETENTION_DAYS" -print0 2>/dev/null)
    done
    
    if [[ $removed -eq 0 ]]; then
        log "$LOG_TAG" "Nenhum log antigo para remover"
    else
        log "$LOG_TAG" "Removidos $removed arquivos de log antigos"
    fi
}

# -----------------------------------------------------------------------------
# FUNÇÃO: vlog
# -----------------------------------------------------------------------------
# Log verboso (apenas se VERBOSE=1)
# -----------------------------------------------------------------------------
vlog() {
    [[ "${VERBOSE:-0}" == "1" ]] && log "$LOG_TAG" "$@"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: run_rotation
# -----------------------------------------------------------------------------
# Executa a rotação de todos os logs
# -----------------------------------------------------------------------------
run_rotation() {
    log "$LOG_TAG" "Iniciando rotação de logs..."
    
    local rotated=0
    
    for log_file in "${LOG_FILES[@]}"; do
        if [[ -f "$log_file" ]] && [[ -s "$log_file" ]]; then
            rotate_log "$log_file"
            ((rotated++))
        fi
    done
    
    # Limpa logs antigos
    cleanup_old_logs
    
    log "$LOG_TAG" "Rotação concluída. $rotated arquivos processados."
}

# -----------------------------------------------------------------------------
# PROCESSAMENTO DOS ARGUMENTOS
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            ;;
        --status)
            SHOW_STATUS=1
            ;;
        --cleanup)
            cleanup_old_logs
            exit 0
            ;;
        --verbose|-v)
            VERBOSE=1
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
# EXECUÇÃO PRINCIPAL
# -----------------------------------------------------------------------------
if [[ "$SHOW_STATUS" == "1" ]]; then
    show_status
else
    run_rotation
fi
