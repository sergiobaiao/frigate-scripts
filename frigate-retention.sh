#!/usr/bin/env bash
# VERSION: 1.2
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
DRY_RUN="${DRY_RUN:-0}"

# -----------------------------------------------------------------------------
# CONFIGURAÇÃO DE LOGS
# -----------------------------------------------------------------------------
# Resolve lock com fallback para /tmp
LOCK_FILE="${LOCK_MEDIA:-/tmp/frigate-media.lock}"
if ! mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || ! (: >>"$LOCK_FILE") 2>/dev/null; then
    LOCK_FILE="${SCRIPT_DIR}/.runtime/frigate-media.lock"
    mkdir -p "$(dirname "$LOCK_FILE")"
    : >>"$LOCK_FILE"
fi

# Resolve log com fallback para /tmp
LOG_FILE="${LOG_RETENTION:-/tmp/frigate-retention.log}"
setup_logging "$LOG_FILE"
setup_error_trap

# -----------------------------------------------------------------------------
# AQUISIÇÃO DO LOCK
# -----------------------------------------------------------------------------
# Usa o mesmo lock dos scripts de mídia para evitar conflitos
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "$LOG_TAG" "Lock ocupado por outro processo, saindo."
    exit 0
fi

compute_date_range_for_retention() {
    local base="$1"
    local keep_days="$2"
    local dates

    RET_OLDEST_DATE="-"
    RET_NEWEST_DATE="-"

    dates="$(find "$base" -type f -mtime "+$keep_days" -printf '%TY-%Tm-%Td\n' 2>/dev/null | sort || true)"
    if [[ -z "$dates" ]]; then
        return 0
    fi

    RET_OLDEST_DATE="$(awk 'NR==1{print; exit}' <<< "$dates")"
    RET_NEWEST_DATE="$(awk 'END{print}' <<< "$dates")"
}

# -----------------------------------------------------------------------------
# INÍCIO DO PROCESSAMENTO
# -----------------------------------------------------------------------------
log "$LOG_TAG" "Iniciando limpeza de mídia de evento (clips/snapshots/exports)"
[[ "$DRY_RUN" == "1" ]] && log "$LOG_TAG" "Modo DRY-RUN ativo"

TOTAL_DELETED_FILES=0
TOTAL_DELETED_BYTES=0

# -----------------------------------------------------------------------------
# PROCESSAMENTO DE CADA LOCAL DE ARMAZENAMENTO
# -----------------------------------------------------------------------------
clean_media() {
    local media="$1"
    local base="$2"
    local keep_days="$3"
    local candidates=0
    local candidate_bytes=0
    local oldest_date="-"
    local newest_date="-"
    local deleted_count=0
    local err_file
    local err_tail

    if [[ ! -d "$base" ]]; then
        log "$LOG_TAG" "Diretório não existe, pulando: $base"
        return 0
    fi

    candidates=$(find "$base" -type f -mtime "+$keep_days" -printf . 2>/dev/null | wc -c)
    candidate_bytes=$(find "$base" -type f -mtime "+$keep_days" -printf '%s\n' 2>/dev/null | awk '{sum+=$1} END{print sum+0}')
    compute_date_range_for_retention "$base" "$keep_days"
    oldest_date="$RET_OLDEST_DATE"
    newest_date="$RET_NEWEST_DATE"

    log "$LOG_TAG" "Processando $media: $base (retenção=${keep_days}d, candidatos=$candidates, bytes=$(bytes_human "$candidate_bytes"), datas=${oldest_date}..${newest_date})"

    if [[ "$DRY_RUN" == "1" ]]; then
        log "$LOG_TAG" "[DRY-RUN] $media: removeria $candidates arquivos ($(bytes_human "$candidate_bytes"))"
        return 0
    fi

    err_file="$(mktemp)"
    deleted_count=$(find "$base" -type f -mtime "+$keep_days" -delete -print 2>"$err_file" | wc -l)
    if [[ -s "$err_file" ]]; then
        err_tail="$(tail -n 20 "$err_file" | tr '\n' '; ')"
        log_error "$LOG_TAG" "Erros durante limpeza de $media em $base: $err_tail"
        notify_error "$LOG_TAG" "Erros na limpeza de $media em $base"
    fi
    rm -f "$err_file"

    TOTAL_DELETED_FILES=$((TOTAL_DELETED_FILES + deleted_count))
    TOTAL_DELETED_BYTES=$((TOTAL_DELETED_BYTES + candidate_bytes))
    log "$LOG_TAG" "$media removidos: arquivos=$deleted_count bytes=$(bytes_human "$candidate_bytes") datas=${oldest_date}..${newest_date}"
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
if [[ "$DRY_RUN" == "1" ]]; then
    log "$LOG_TAG" "Limpeza de mídia de evento concluída (DRY-RUN)"
else
    log "$LOG_TAG" "Limpeza de mídia de evento concluída: arquivos=$TOTAL_DELETED_FILES bytes=$(bytes_human "$TOTAL_DELETED_BYTES")"
fi
