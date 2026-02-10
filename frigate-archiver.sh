#!/bin/bash
# =============================================================================
# FRIGATE-ARCHIVER.SH (WRAPPER DE COMPATIBILIDADE)
# =============================================================================
# Este script foi consolidado no frigate-mover.sh
# Este wrapper mantém compatibilidade com crontabs e scripts existentes.
#
# EQUIVALÊNCIA:
#   ./frigate-archiver.sh  →  ./frigate-mover.sh --mode=file
#
# RECOMENDAÇÃO:
#   Atualize seus crontabs para usar diretamente:
#   ./frigate-mover.sh --mode=file
# =============================================================================

# Obtém o diretório do script
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Redireciona para o script unificado
exec "${SCRIPT_DIR}/frigate-mover.sh" --mode=file "$@"
