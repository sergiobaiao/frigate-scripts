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
# CONFIGURAÇÃO DO DIRETÓRIO DE GRAVAÇÕES
# -----------------------------------------------------------------------------
# Nota: Este caminho usa /frigate/recordings (diferente de alguns outros scripts)
# TODO: Considerar unificar com HD_RECORDINGS do .env
DEST_REC="$HD_MOUNT/frigate/recordings"

# Verifica se o diretório existe
if [[ ! -d "$DEST_REC" ]]; then
    log_simple "$LOG_TAG" "Diretório de gravações não existe: $DEST_REC"
    exit 0
fi

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
    # Busca o diretório de data mais antigo
    # -mindepth 1 -maxdepth 1: Apenas primeiro nível (diretórios de data)
    # -printf '%f\n': Imprime apenas o nome do diretório (sem caminho)
    # sort: Ordena alfabeticamente (funciona para datas ISO)
    # head -n1: Pega o primeiro (mais antigo)
    day=$(find "$DEST_REC" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | head -n1)
    
    # Se não encontrou nenhum diretório, sai do loop
    if [[ -z "$day" ]]; then
        log_simple "$LOG_TAG" "Nenhum diretório de data encontrado para remover"
        break
    fi
    
    # Remove o diretório mais antigo
    log_simple "$LOG_TAG" "Removendo dia: $day"
    rm -rf "$DEST_REC/$day"
    
    # Mostra o novo uso após remoção
    new_usage=$(usage_pct)
    log_simple "$LOG_TAG" "Uso após remoção: ${new_usage}%"
done

log_simple "$LOG_TAG" "Vacuum concluído"
