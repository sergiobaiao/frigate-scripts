#!/bin/bash
# =============================================================================
# FRIGATE-ARCHIVE.SH (WRAPPER DE COMPATIBILIDADE)
# =============================================================================
# Este script foi consolidado no frigate-mover.sh
# Este wrapper mantém compatibilidade com crontabs e scripts existentes.
#
# EQUIVALÊNCIA:
#   ./frigate-archive.sh  →  ./frigate-mover.sh --mode=incremental
#
# RECOMENDAÇÃO:
#   Atualize seus crontabs para usar diretamente:
#   ./frigate-mover.sh --mode=incremental
# =============================================================================

# Obtém o diretório do script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Redireciona para o script unificado
exec "${SCRIPT_DIR}/frigate-mover.sh" --mode=incremental "$@"
