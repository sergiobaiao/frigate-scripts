#!/usr/bin/env bash
# VERSION: 1.8
# =============================================================================
# FRIGATE-VACUUM.SH
# =============================================================================
# Limpa gravações antigas do HD quando o uso ultrapassa o limite.
#
# DESCRIÇÃO:
#   Este script é uma versão simplificada do prune que é acionado quando
#   o uso do HD ultrapassa um threshold específico (ex: 90%). Remove os
#   dias mais antigos de gravações até o uso voltar abaixo do limite.
#
# DIFERENÇA DO frigate-prune-hd.sh:
#   - vacuum.sh: Reage ao uso ALTO (>90%), mais agressivo
#   - prune-hd.sh: Mantém espaço LIVRE mínimo (>15%), preventivo
#
# FUNCIONAMENTO:
#   1. Verifica se o HD está montado
#   2. Se uso > HD_USAGE_THRESHOLD:
#      a. Remove o dia mais antigo de gravações
#      b. Repete até uso < threshold
#
# USO:
#   ./frigate-vacuum.sh
#
# CONFIGURAÇÕES (via .env):
#   HD_USAGE_THRESHOLD - % máximo de uso permitido (padrão: 90)
#   PROTECT_DAYS       - Dias protegidos contra limpeza (padrão: 3)
#
# AUTOR: Sistema Marquise
# =============================================================================

# -----------------------------------------------------------------------------
# CARREGA CONFIGURAÇÕES E FUNÇÕES COMPARTILHADAS
# -----------------------------------------------------------------------------
source "$(dirname "$0")/common.sh"

# Tag para identificação nos logs
LOG_TAG="vacuum"

# Threshold de uso (usa valor do .env ou padrão)
THRESHOLD="${HD_USAGE_THRESHOLD:-90}"
LOG_FILE="${LOG_VACUUM:-/var/log/frigate-vacuum.log}"
MIRROR_STDOUT="${MIRROR_STDOUT:-0}"

setup_logging "$LOG_FILE" "$MIRROR_STDOUT"
setup_error_trap

# Lock compartilhado com operações de mídia para evitar concorrência.
LOCK_FILE="${LOCK_STORAGE:-${LOCK_MEDIA:-/tmp/frigate-media.lock}}"
if ! mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || ! (: >>"$LOCK_FILE") 2>/dev/null; then
    LOCK_FILE="${SCRIPT_DIR}/.runtime/frigate-media.lock"
    mkdir -p "$(dirname "$LOCK_FILE")"
    : >>"$LOCK_FILE"
fi

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log_simple "$LOG_TAG" "Lock ocupado por outro processo, saindo"
    exit 0
fi

# -----------------------------------------------------------------------------
# VERIFICAÇÃO DO PONTO DE MONTAGEM
# -----------------------------------------------------------------------------
# Se o HD não estiver montado, sai silenciosamente
# (pode estar desconectado temporariamente)
if ! check_mountpoint "$HD_MOUNT"; then
    log_simple "$LOG_TAG" "HD não montado em $HD_MOUNT, saindo"
    exit 0
fi

# -----------------------------------------------------------------------------
# FUNÇÃO: usage_pct
# -----------------------------------------------------------------------------
# Retorna a porcentagem de uso atual do HD
#
# RETORNO:
#   Número inteiro representando % de uso
# -----------------------------------------------------------------------------
usage_pct() {
    get_disk_usage_pct "$HD_MOUNT"
}

# -----------------------------------------------------------------------------
# CONFIGURAÇÃO DOS DIRETÓRIOS DE MÍDIA
# -----------------------------------------------------------------------------
DATE_RE='^20[0-9]{2}-[0-9]{2}-[0-9]{2}$'
HOUR_RE='^([01][0-9]|2[0-3])$'

hour_dirs_for_media() {
    local root="$1"
    local media="$2"
    local day_path day hour_path hour emitted
    [[ -d "$root" ]] || return 0

    while IFS= read -r day_path; do
        day="${day_path##*/}"
        [[ "$day" =~ $DATE_RE ]] || continue

        emitted=0
        while IFS= read -r hour_path; do
            hour="${hour_path##*/}"
            [[ "$hour" =~ $HOUR_RE ]] || continue
            printf '%s/%s\t%s\t%s\n' "$day" "$hour" "$media" "$hour_path"
            emitted=1
        done < <(find "$day_path" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort || true)

        # Fallback para layouts sem subpastas por hora.
        if (( emitted == 0 )); then
            printf '%s/99\t%s\t%s\n' "$day" "$media" "$day_path"
        fi
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -print 2>/dev/null | sort || true)
}

# -----------------------------------------------------------------------------
# VERIFICAÇÃO INICIAL
# -----------------------------------------------------------------------------
current_usage=$(usage_pct)
log_simple "$LOG_TAG" "Uso atual: ${current_usage}% (limite: ${THRESHOLD}%)"

removed_count=0
freed_bytes=0
removed_slots=()

# -----------------------------------------------------------------------------
# LOOP DE LIMPEZA
# -----------------------------------------------------------------------------
# Continua removendo a faixa mais antiga (YYYY-MM-DD/HH) enquanto acima do threshold.
while [[ "$(usage_pct)" -ge "$THRESHOLD" ]]; do
    oldest_entry="$(
        {
            hour_dirs_for_media "$HD_RECORDINGS" "recordings"
            hour_dirs_for_media "$HD_CLIPS" "clips"
            hour_dirs_for_media "$HD_EXPORTS" "exports"
            hour_dirs_for_media "$HD_SNAPSHOTS" "snapshots"
        } | sort | sed -n '1p'
    )"

    if [[ -z "$oldest_entry" ]]; then
        log_simple "$LOG_TAG" "Nenhuma faixa de data/hora encontrada para remover (recordings/clips/exports/snapshots)"
        break
    fi

    IFS=$'\t' read -r slot media oldest_path <<< "$oldest_entry"
    size_b="$(du -sb "$oldest_path" 2>/dev/null | awk '{print $1}')"
    size_b="${size_b:-0}"
    log "$LOG_TAG" "Removendo faixa: $slot ($media) em $oldest_path (tamanho=$(bytes_human "$size_b"))"
    if rm -rf "$oldest_path"; then
        ((removed_count++))
        freed_bytes=$((freed_bytes + size_b))
        removed_slots+=("$slot")
    else
        log_error "$LOG_TAG" "Falha ao remover $oldest_path"
        notify_error "$LOG_TAG" "Falha ao remover $oldest_path"
        break
    fi
    
    # Mostra o novo uso após remoção
    new_usage=$(usage_pct)
    log "$LOG_TAG" "Uso após remoção: ${new_usage}%"
done

if (( ${#removed_slots[@]} > 0 )); then
    removed_slots_summary="$(printf '%s\n' "${removed_slots[@]}" | sort -u | paste -sd, -)"
else
    removed_slots_summary="nenhuma"
fi

final_usage=$(usage_pct)
if [[ "$final_usage" -ge "$THRESHOLD" ]]; then
    log_warn "$LOG_TAG" "Vacuum finalizado acima do limite: uso_final=${final_usage}% limite=${THRESHOLD}%"
    notify_error "$LOG_TAG" "Vacuum finalizado acima do limite: ${final_usage}%"
fi

log "$LOG_TAG" "Vacuum concluído: removidos=$removed_count bytes_liberados=$(bytes_human "$freed_bytes") faixas=$removed_slots_summary uso_final=${final_usage}%"
