#!/usr/bin/env bash
# =============================================================================
# FRIGATE-RETENTION.SH
# =============================================================================
# Gerencia a retenção de clips (snapshots de eventos) do Frigate.
#
# DESCRIÇÃO:
#   Este script implementa a política de retenção para os clips do Frigate.
#   Clips são imagens/vídeos curtos de eventos detectados (pessoas, carros, etc.)
#   que são armazenados separadamente das gravações contínuas.
#
# FUNCIONAMENTO:
#   1. Para cada local de armazenamento (SSD e HD):
#      a. Busca arquivos de clips mais antigos que CLIPS_KEEP_DAYS
#      b. Remove esses arquivos
#      c. Limpa diretórios vazios
#
# USO:
#   ./frigate-retention.sh
#
# CONFIGURAÇÕES (via .env):
#   CLIPS_KEEP_DAYS - Dias para manter clips (padrão: 2)
#
# LOGS:
#   As operações são registradas em /var/log/frigate-retention.log
#
# AUTOR: Sistema Marquise
# =============================================================================

# -----------------------------------------------------------------------------
# CARREGA CONFIGURAÇÕES E FUNÇÕES COMPARTILHADAS
# -----------------------------------------------------------------------------
source "$(dirname "$0")/common.sh"

# Tag para identificação nos logs
LOG_TAG="retention"

# -----------------------------------------------------------------------------
# CONFIGURAÇÃO DE LOGS
# -----------------------------------------------------------------------------
# Garante que os diretórios necessários existem
ensure_dir "$LOCK_DIR"
ensure_dir "$(dirname "$LOG_RETENTION")"

# Cria o arquivo de log se não existir
touch "$LOG_RETENTION"

# Redireciona toda a saída para o arquivo de log (modo append)
exec >>"$LOG_RETENTION" 2>&1

# -----------------------------------------------------------------------------
# AQUISIÇÃO DO LOCK
# -----------------------------------------------------------------------------
# Usa o mesmo lock dos scripts de mídia para evitar conflitos
exec 9>"$LOCK_MEDIA"
if ! flock -n 9; then
    log "$LOG_TAG" "Lock ocupado por outro processo, saindo."
    exit 0
fi

# -----------------------------------------------------------------------------
# INÍCIO DO PROCESSAMENTO
# -----------------------------------------------------------------------------
log "$LOG_TAG" "Iniciando limpeza de clips (retenção: ${CLIPS_KEEP_DAYS} dias)"

# -----------------------------------------------------------------------------
# PROCESSAMENTO DE CADA LOCAL DE ARMAZENAMENTO
# -----------------------------------------------------------------------------
# Processa tanto o SSD quanto o HD para garantir que clips antigos
# sejam removidos de ambos os locais

for base in "$SSD_CLIPS" "$HD_CLIPS"; do
    # Verifica se o diretório existe
    if [[ ! -d "$base" ]]; then
        log "$LOG_TAG" "Diretório não existe, pulando: $base"
        continue
    fi
    
    log "$LOG_TAG" "Processando: $base"
    
    # Remove arquivos de clips mais antigos que CLIPS_KEEP_DAYS
    # -type f: Apenas arquivos (não diretórios)
    # -mtime +N: Modificados há mais de N dias
    # -delete: Remove os arquivos encontrados
    #
    # Nota: +2 significa "mais de 2 dias", ou seja, 3+ dias atrás
    # O valor vem da variável CLIPS_KEEP_DAYS do .env
    log "$LOG_TAG" "Removendo clips com mais de ${CLIPS_KEEP_DAYS} dias"
    
    deleted_count=$(find "$base" -type f -mtime "+$CLIPS_KEEP_DAYS" -delete -print 2>/dev/null | wc -l)
    log "$LOG_TAG" "Arquivos removidos: $deleted_count"
    
    # Limpa diretórios vazios que ficaram após remoção dos arquivos
    # 2>/dev/null: Suprime erros (ex: diretório em uso)
    # || true: Não falha se o find retornar erro
    log "$LOG_TAG" "Limpando diretórios vazios"
    find "$base" -type d -empty -delete 2>/dev/null || true
done

# -----------------------------------------------------------------------------
# FINALIZAÇÃO
# -----------------------------------------------------------------------------
log "$LOG_TAG" "Limpeza de clips concluída"
