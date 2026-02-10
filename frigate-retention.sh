#!/usr/bin/env bash
# =============================================================================
# FRIGATE-RETENTION.SH
# =============================================================================
# Gerencia a retenção de clips, snapshots e exports do Frigate.
#
# DESCRIÇÃO:
#   Este script implementa a política de retenção para mídias de evento
#   (clips, snapshots e exports) do Frigate.
#
# FUNCIONAMENTO:
#   1. Para cada local de armazenamento (SSD e HD):
#      a. Busca arquivos mais antigos que o período de retenção configurado
#      b. Remove esses arquivos
#      c. Limpa diretórios vazios
#
# USO:
#   ./frigate-retention.sh
#
# CONFIGURAÇÕES (via .env):
#   CLIPS_KEEP_DAYS      - Dias para manter clips (padrão: 2)
#   SNAPSHOTS_KEEP_DAYS  - Dias para manter snapshots (padrão: 2)
#   EXPORTS_KEEP_DAYS    - Dias para manter exports (padrão: 30)
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
# Resolve lock com fallback para /tmp
LOCK_FILE="${LOCK_MEDIA:-/tmp/frigate-media.lock}"
if ! mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || ! touch "$LOCK_FILE" 2>/dev/null; then
    LOCK_FILE="/tmp/frigate-media.lock"
    mkdir -p "$(dirname "$LOCK_FILE")"
    touch "$LOCK_FILE"
fi

# Resolve log com fallback para /tmp
LOG_FILE="${LOG_RETENTION:-/tmp/frigate-retention.log}"
if ! mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || ! touch "$LOG_FILE" 2>/dev/null; then
    LOG_FILE="/tmp/frigate-retention.log"
    mkdir -p "$(dirname "$LOG_FILE")"
    touch "$LOG_FILE"
fi

# Redireciona toda a saída para o arquivo de log (modo append)
exec >>"$LOG_FILE" 2>&1

# -----------------------------------------------------------------------------
# AQUISIÇÃO DO LOCK
# -----------------------------------------------------------------------------
# Usa o mesmo lock dos scripts de mídia para evitar conflitos
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "$LOG_TAG" "Lock ocupado por outro processo, saindo."
    exit 0
fi

# -----------------------------------------------------------------------------
# INÍCIO DO PROCESSAMENTO
# -----------------------------------------------------------------------------
log "$LOG_TAG" "Iniciando limpeza de mídia de evento (clips/snapshots/exports)"

# -----------------------------------------------------------------------------
# PROCESSAMENTO DE CADA LOCAL DE ARMAZENAMENTO
# -----------------------------------------------------------------------------
clean_media() {
    local media="$1"
    local base="$2"
    local keep_days="$3"

    if [[ ! -d "$base" ]]; then
        log "$LOG_TAG" "Diretório não existe, pulando: $base"
        return
    fi

    log "$LOG_TAG" "Processando $media: $base (retenção: ${keep_days} dias)"
    deleted_count=$(find "$base" -type f -mtime "+$keep_days" -delete -print 2>/dev/null | wc -l)
    log "$LOG_TAG" "Arquivos $media removidos: $deleted_count"
    find "$base" -type d -empty -delete 2>/dev/null || true
}

# Processa SSD e HD para clips/snapshots/exports
clean_media "clips" "$SSD_CLIPS" "$CLIPS_KEEP_DAYS"
clean_media "clips" "$HD_CLIPS" "$CLIPS_KEEP_DAYS"
clean_media "snapshots" "$SSD_SNAPSHOTS" "$SNAPSHOTS_KEEP_DAYS"
clean_media "snapshots" "$HD_SNAPSHOTS" "$SNAPSHOTS_KEEP_DAYS"
clean_media "exports" "$SSD_EXPORTS" "$EXPORTS_KEEP_DAYS"
clean_media "exports" "$HD_EXPORTS" "$EXPORTS_KEEP_DAYS"

# -----------------------------------------------------------------------------
# FINALIZAÇÃO
# -----------------------------------------------------------------------------
log "$LOG_TAG" "Limpeza de mídia de evento concluída"
