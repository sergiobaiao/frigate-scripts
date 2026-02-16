#!/bin/bash
# VERSION: 1.0
# =============================================================================
# HD-WATCHDOG-MIN.SH
# =============================================================================
# Watchdog que monitora o uso do SSD e aciona movimentação de emergência.
#
# DESCRIÇÃO:
#   Este é um script de monitoramento simples que deve ser executado
#   frequentemente (ex: a cada minuto via cron). Quando o SSD atinge
#   um nível crítico de uso, aciona automaticamente o script de
#   movimentação em modo emergência.
#
# FUNCIONAMENTO:
#   1. Verifica a porcentagem de uso do SSD (partição /)
#   2. Se ultrapassar SSD_EMERGENCY_THRESHOLD (ex: 85%):
#      a. Executa frigate-mover.sh --mode=emergency
#
# USO:
#   ./hd-watchdog-min.sh
#
# CRONTAB SUGERIDO:
#   * * * * * /path/to/hd-watchdog-min.sh
#
# CONFIGURAÇÕES (via .env):
#   SSD_EMERGENCY_THRESHOLD - % de uso que dispara emergência (padrão: 85)
#
# AUTOR: Sistema Marquise
# =============================================================================

# -----------------------------------------------------------------------------
# CARREGA CONFIGURAÇÕES E FUNÇÕES COMPARTILHADAS
# -----------------------------------------------------------------------------
source "$(dirname "$0")/common.sh"

# Tag para identificação nos logs
LOG_TAG="watchdog"

# Diretório onde os scripts estão localizados
SCRIPT_DIR="$(dirname "$0")"

# -----------------------------------------------------------------------------
# VERIFICAÇÃO DO USO DO SSD
# -----------------------------------------------------------------------------
# Obtém a porcentagem de uso do SSD configurado no .env
USO=$(get_disk_usage_pct "$SSD_ROOT")

# -----------------------------------------------------------------------------
# AÇÃO COM BASE NO USO
# -----------------------------------------------------------------------------
if [[ "$USO" -gt "$SSD_EMERGENCY_THRESHOLD" ]]; then
    log_simple "$LOG_TAG" "⚠️  ALERTA: SSD em ${USO}% (limite: ${SSD_EMERGENCY_THRESHOLD}%)"
    log_simple "$LOG_TAG" "Acionando movimentação de EMERGÊNCIA..."
    
    # Executa o script unificado em modo emergência (sem limite de banda)
    "${SCRIPT_DIR}/frigate-mover.sh" --mode=emergency
    
    log_simple "$LOG_TAG" "Movimentação de emergência concluída"
fi
