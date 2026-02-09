#!/bin/bash
# =============================================================================
# MOVER_FRIGATE_PARA_HD.SH (WRAPPER DE COMPATIBILIDADE)
# =============================================================================
# Este script foi consolidado no frigate-mover.sh
# Este wrapper mantém compatibilidade com crontabs e scripts existentes.
#
# EQUIVALÊNCIA:
#   ./mover_frigate_para_hd.sh  →  ./frigate-mover.sh --mode=full
#
# RECOMENDAÇÃO:
#   Atualize seus crontabs para usar diretamente:
#   ./frigate-mover.sh --mode=full
# =============================================================================

# Obtém o diretório do script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Redireciona para o script unificado
exec "${SCRIPT_DIR}/frigate-mover.sh" --mode=full "$@"
