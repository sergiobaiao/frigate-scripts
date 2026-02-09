#!/usr/bin/env bash
# =============================================================================
# FRIGATE-PRUNE-HD.SH
# =============================================================================
# Limpa gravações antigas do HD externo quando o espaço está baixo.
#
# DESCRIÇÃO:
#   Este script monitora o espaço livre no HD externo e remove os dias mais
#   antigos de gravações até atingir a porcentagem mínima de espaço livre
#   configurada.
#
# FUNCIONAMENTO:
#   1. Verifica a porcentagem de espaço livre no HD
#   2. Se estiver abaixo do mínimo (MIN_FREE_PCT):
#      a. Encontra o diretório de data mais antigo (YYYY-MM-DD)
#      b. Remove completamente esse diretório
#      c. Repete até atingir o espaço livre mínimo
#   3. Limpa diretórios vazios residuais
#
# USO:
#   ./frigate-prune-hd.sh
#
# CONFIGURAÇÕES (via .env):
#   MIN_FREE_PCT - Porcentagem mínima de espaço livre (padrão: 15)
#
# LOGS:
#   As operações são registradas em /var/log/frigate-prune-hd.log
#
# AUTOR: Sistema Marquise
# =============================================================================

# -----------------------------------------------------------------------------
# CARREGA CONFIGURAÇÕES E FUNÇÕES COMPARTILHADAS
# -----------------------------------------------------------------------------
source "$(dirname "$0")/common.sh"

# Tag para identificação nos logs
LOG_TAG="prune"

# Expressão regular para validar diretórios de data
DATE_RE='^20[0-9]{2}-[0-9]{2}-[0-9]{2}$'

# -----------------------------------------------------------------------------
# CONFIGURAÇÃO DE LOGS
# -----------------------------------------------------------------------------
# Garante que os diretórios necessários existem
ensure_dir "$LOCK_DIR"
ensure_dir "$(dirname "$LOG_PRUNE")"

# Cria o arquivo de log se não existir
touch "$LOG_PRUNE"

# Redireciona toda a saída (stdout e stderr) para o arquivo de log
# Modo append (>>) para preservar histórico
exec >>"$LOG_PRUNE" 2>&1

# -----------------------------------------------------------------------------
# AQUISIÇÃO DO LOCK
# -----------------------------------------------------------------------------
# Usa file descriptor 9 para o lock
exec 9>"$LOCK_MEDIA"
if ! flock -n 9; then
    log "$LOG_TAG" "Lock ocupado por outro processo, saindo."
    exit 0
fi

# -----------------------------------------------------------------------------
# FUNÇÃO: free_pct
# -----------------------------------------------------------------------------
# Retorna a porcentagem de espaço livre no HD externo
#
# RETORNO:
#   Número inteiro representando % de espaço livre
# -----------------------------------------------------------------------------
free_pct() {
    get_disk_free_pct "$HD_MOUNT"
}

# -----------------------------------------------------------------------------
# INÍCIO DO PROCESSAMENTO
# -----------------------------------------------------------------------------
log "$LOG_TAG" "Iniciando verificação de espaço"

# Obtém a porcentagem atual de espaço livre
free="$(free_pct)"
log "$LOG_TAG" "Espaço livre: ${free}% (mínimo: ${MIN_FREE_PCT}%)"

# -----------------------------------------------------------------------------
# VERIFICAÇÃO DE NECESSIDADE
# -----------------------------------------------------------------------------
# Se já temos espaço suficiente, não há nada a fazer
if (( free >= MIN_FREE_PCT )); then
    log "$LOG_TAG" "Espaço suficiente. Nenhuma ação necessária."
    exit 0
fi

# Verifica se o diretório de gravações existe
if [[ ! -d "$HD_RECORDINGS" ]]; then
    log "$LOG_TAG" "Diretório de gravações não existe: $HD_RECORDINGS"
    exit 0
fi

# -----------------------------------------------------------------------------
# LOOP DE LIMPEZA
# -----------------------------------------------------------------------------
# Continua removendo dias antigos até atingir o espaço livre mínimo
while (( free < MIN_FREE_PCT )); do
    # Busca o diretório de data mais antigo
    # -mindepth 1 -maxdepth 2: Busca em 1 ou 2 níveis de profundidade
    #   (para suportar estruturas como /recordings/YYYY-MM-DD ou
    #    /recordings/camera/YYYY-MM-DD)
    # awk: Filtra apenas diretórios que terminam com formato de data
    # sort: Ordena cronologicamente (mais antigo primeiro)
    # head -n 1: Pega apenas o primeiro (mais antigo)
    oldest="$(find "$HD_RECORDINGS" -mindepth 1 -maxdepth 2 -type d -printf "%p\n" 2>/dev/null \
        | awk -F/ -v re="$DATE_RE" '$NF ~ re {print}' \
        | sort | head -n 1)"
    
    # Se não encontrou nenhum diretório de data, sai do loop
    if [[ -z "${oldest:-}" ]]; then
        log "$LOG_TAG" "Nenhum diretório de data encontrado em $HD_RECORDINGS"
        break
    fi
    
    # Remove o diretório mais antigo encontrado
    log "$LOG_TAG" "Removendo: $oldest"
    rm -rf "$oldest"
    
    # Limpa diretórios vazios que possam ter ficado
    find "$HD_RECORDINGS" -mindepth 1 -type d -empty -delete 2>/dev/null || true
    
    # Recalcula o espaço livre
    free="$(free_pct)"
    log "$LOG_TAG" "Espaço livre atual: ${free}% (mínimo: ${MIN_FREE_PCT}%)"
done

# -----------------------------------------------------------------------------
# FINALIZAÇÃO
# -----------------------------------------------------------------------------
if (( free >= MIN_FREE_PCT )); then
    log "$LOG_TAG" "Meta de espaço livre atingida: ${free}%"
fi

log "$LOG_TAG" "Limpeza concluída"
