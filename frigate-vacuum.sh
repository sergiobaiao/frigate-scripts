#!/usr/bin/env bash
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

date_dirs_for_media() {
    local root="$1"
    local media="$2"
    [[ -d "$root" ]] || return 0

    find "$root" -mindepth 1 -maxdepth 2 -type d -printf '%p\n' 2>/dev/null \
        | awk -F/ -v re="$DATE_RE" -v media="$media" '$NF ~ re {printf "%s\t%s\t%s\n", $NF, media, $0}' \
        | sort
}

# -----------------------------------------------------------------------------
# VERIFICAÇÃO INICIAL
# -----------------------------------------------------------------------------
current_usage=$(usage_pct)
log_simple "$LOG_TAG" "Uso atual: ${current_usage}% (limite: ${THRESHOLD}%)"

# -----------------------------------------------------------------------------
# LOOP DE LIMPEZA
# -----------------------------------------------------------------------------
# Continua removendo dias antigos enquanto o uso estiver acima do threshold
while [[ "$(usage_pct)" -ge "$THRESHOLD" ]]; do
    oldest_entry="$(
        {
            date_dirs_for_media "$HD_RECORDINGS" "recordings"
            date_dirs_for_media "$HD_CLIPS" "clips"
            date_dirs_for_media "$HD_EXPORTS" "exports"
            date_dirs_for_media "$HD_SNAPSHOTS" "snapshots"
        } | sort | head -n1
    )"

    if [[ -z "$oldest_entry" ]]; then
        log_simple "$LOG_TAG" "Nenhum diretório de data encontrado para remover (recordings/clips/exports/snapshots)"
        break
    fi

    IFS=$'\t' read -r day media oldest_path <<< "$oldest_entry"
    log_simple "$LOG_TAG" "Removendo dia: $day ($media) em $oldest_path"
    rm -rf "$oldest_path"
    
    # Mostra o novo uso após remoção
    new_usage=$(usage_pct)
    log_simple "$LOG_TAG" "Uso após remoção: ${new_usage}%"
done

log_simple "$LOG_TAG" "Vacuum concluído"
