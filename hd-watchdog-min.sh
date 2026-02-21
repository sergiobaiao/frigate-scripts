#!/bin/bash
# VERSION: 1.8
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
STATE_DIR="${SCRIPT_DIR}/.runtime"
STATE_FILE="${STATE_DIR}/watchdog.last"

# Configurações opcionais (.env)
WATCHDOG_COOLDOWN_MINUTES="${WATCHDOG_COOLDOWN_MINUTES:-15}"
WATCHDOG_MODE="${WATCHDOG_MODE:-file}"
WATCHDOG_USE_EMERGENCY="${WATCHDOG_USE_EMERGENCY:-0}"

# -----------------------------------------------------------------------------
# VERIFICAÇÃO DO USO DO SSD
# -----------------------------------------------------------------------------
# Obtém a porcentagem de uso do SSD configurado no .env
USO=$(get_disk_usage_pct "$SSD_ROOT")
NOW_EPOCH="$(date +%s)"
LAST_EPOCH=0

if [[ -f "$STATE_FILE" ]]; then
    LAST_EPOCH="$(cat "$STATE_FILE" 2>/dev/null || echo 0)"
fi

if ! [[ "$LAST_EPOCH" =~ ^[0-9]+$ ]]; then
    LAST_EPOCH=0
fi

COOLDOWN_SEC=$((WATCHDOG_COOLDOWN_MINUTES * 60))

# -----------------------------------------------------------------------------
# AÇÃO COM BASE NO USO
# -----------------------------------------------------------------------------
if [[ "$USO" -gt "$SSD_EMERGENCY_THRESHOLD" ]]; then
    if (( NOW_EPOCH - LAST_EPOCH < COOLDOWN_SEC )); then
        log_simple "$LOG_TAG" "SSD em ${USO}% (limite ${SSD_EMERGENCY_THRESHOLD}%), mas em cooldown (${WATCHDOG_COOLDOWN_MINUTES} min)"
        exit 0
    fi

    mkdir -p "$STATE_DIR"

    RUN_MODE="$WATCHDOG_MODE"
    if [[ "$WATCHDOG_USE_EMERGENCY" == "1" ]]; then
        RUN_MODE="emergency"
    fi

    case "$RUN_MODE" in
        file|incremental|full|emergency) ;;
        *)
            log_simple "$LOG_TAG" "WATCHDOG_MODE inválido ($RUN_MODE), usando file"
            RUN_MODE="file"
            ;;
    esac

    log_simple "$LOG_TAG" "⚠️  ALERTA: SSD em ${USO}% (limite: ${SSD_EMERGENCY_THRESHOLD}%)"
    log_simple "$LOG_TAG" "Acionando movimentação automática (mode=${RUN_MODE})..."
    
    "${SCRIPT_DIR}/frigate-mover.sh" --mode="$RUN_MODE"
    
    echo "$NOW_EPOCH" > "$STATE_FILE"
    log_simple "$LOG_TAG" "Movimentação concluída (mode=${RUN_MODE})"
fi
