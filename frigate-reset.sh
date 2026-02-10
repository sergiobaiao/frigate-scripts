#!/usr/bin/env bash
# =============================================================================
# FRIGATE-RESET.SH
# =============================================================================
# Remove todas as gravações do SSD, limpa o banco de dados do Frigate e 
# reinicia o container - útil para reset completo do sistema.
#
# DESCRIÇÃO:
#   Este script realiza um reset completo do Frigate:
#   1. Para o container do Frigate
#   2. Lista e pede confirmação sobre as gravações a serem deletadas
#   3. Remove todas as gravações do SSD
#   4. Apaga o banco de dados do Frigate (frigate.db*)
#   5. Reinicia o container do Frigate
#
# USO:
#   ./frigate-reset.sh
#
# ATENÇÃO:
#   - Este script é DESTRUTIVO - remove permanentemente todas as gravações!
#   - Requer confirmação do usuário antes de prosseguir
#   - O container Frigate ficará indisponível durante a execução
#
# CONFIGURAÇÕES (via .env):
#   SSD_ROOT          - Caminho raíz do SSD do Frigate
#   SSD_RECORDINGS    - Caminho das gravações no SSD
#   SSD_CLIPS         - Caminho dos clips no SSD
#   FRIGATE_CONFIG    - Caminho da configuração do Frigate (contém o DB)
#   FRIGATE_CONTAINER - Nome do container Docker do Frigate
#
# AUTOR: Sistema Marquise
# =============================================================================

# -----------------------------------------------------------------------------
# CARREGA CONFIGURAÇÕES E FUNÇÕES COMPARTILHADAS
# -----------------------------------------------------------------------------
source "$(dirname "$0")/common.sh"

# Tag para identificação nos logs
LOG_TAG="reset"

# Variáveis com valores padrão caso não definidas no .env
FRIGATE_CONFIG="${FRIGATE_CONFIG:-/home/castro/marquise/config/frigate}"
FRIGATE_CONTAINER="${FRIGATE_CONTAINER:-frigate}"

# Nome do banco de dados do Frigate (padrão)
FRIGATE_DB_NAME="frigate.db"

# -----------------------------------------------------------------------------
# FUNÇÃO: format_size
# -----------------------------------------------------------------------------
# Formata um tamanho em bytes para formato legível (KB, MB, GB, etc.)
#
# ARGUMENTOS:
#   $1 - Tamanho em bytes
#
# RETORNO:
#   String formatada (ex: "1.5G", "256M")
# -----------------------------------------------------------------------------
format_size() {
    local bytes="$1"
    if command -v numfmt &>/dev/null; then
        numfmt --to=iec --suffix=B "$bytes"
    else
        # Fallback se numfmt não estiver disponível
        echo "${bytes}B"
    fi
}

# -----------------------------------------------------------------------------
# FUNÇÃO: get_dir_info
# -----------------------------------------------------------------------------
# Obtém informações sobre um diretório (tamanho, data de modificação, arquivos)
#
# ARGUMENTOS:
#   $1 - Caminho do diretório
#
# SAÍDA:
#   Imprime informações formatadas sobre o diretório
# -----------------------------------------------------------------------------
get_dir_info() {
    local dir_path="$1"
    local label="$2"
    
    if [[ -d "$dir_path" ]]; then
        local size oldest newest count
        
        # Tamanho total
        size=$(du -sb "$dir_path" 2>/dev/null | cut -f1)
        
        # Contagem de arquivos
        count=$(find "$dir_path" -type f 2>/dev/null | wc -l)
        
        # Data mais antiga
        oldest=$(find "$dir_path" -type f -printf '%T+ %p\n' 2>/dev/null | sort | head -n1 | cut -d' ' -f1 | cut -d'T' -f1)
        
        # Data mais recente
        newest=$(find "$dir_path" -type f -printf '%T+ %p\n' 2>/dev/null | sort -r | head -n1 | cut -d' ' -f1 | cut -d'T' -f1)
        
        echo "  $label:"
        echo "    Caminho: $dir_path"
        
        if [[ -n "$size" && "$size" -gt 0 ]]; then
            echo "    Tamanho: $(format_size "$size")"
            echo "    Arquivos: $count"
            [[ -n "$oldest" ]] && echo "    Mais antigo: $oldest"
            [[ -n "$newest" ]] && echo "    Mais recente: $newest"
        else
            echo "    (vazio)"
        fi
    else
        echo "  $label: (não existe)"
    fi
}

# -----------------------------------------------------------------------------
# FUNÇÃO: get_db_info
# -----------------------------------------------------------------------------
# Obtém informações sobre os arquivos do banco de dados do Frigate
#
# ARGUMENTOS:
#   $1 - Caminho do diretório de configuração
#
# SAÍDA:
#   Imprime informações sobre os arquivos de banco de dados
# -----------------------------------------------------------------------------
get_db_info() {
    local config_dir="$1"
    
    echo "  Banco de dados Frigate:"
    echo "    Caminho: $config_dir"
    
    # Lista arquivos do banco de dados
    local db_files=()
    while IFS= read -r -d '' file; do
        db_files+=("$file")
    done < <(find "$config_dir" -maxdepth 1 -name "${FRIGATE_DB_NAME}*" -print0 2>/dev/null)
    
    if [[ ${#db_files[@]} -eq 0 ]]; then
        echo "    (nenhum arquivo de banco de dados encontrado)"
        return
    fi
    
    local total_size=0
    for db_file in "${db_files[@]}"; do
        local filename size mod_date
        filename=$(basename "$db_file")
        size=$(stat -c %s "$db_file" 2>/dev/null || echo 0)
        mod_date=$(stat -c %y "$db_file" 2>/dev/null | cut -d' ' -f1)
        total_size=$((total_size + size))
        echo "    - $filename: $(format_size "$size") (modificado: $mod_date)"
    done
    
    echo "    Total: $(format_size "$total_size")"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: stop_frigate
# -----------------------------------------------------------------------------
# Para o container do Frigate
#
# RETORNO:
#   0 - Container parado com sucesso
#   1 - Erro ao parar o container
# -----------------------------------------------------------------------------
stop_frigate() {
    log "$LOG_TAG" "Parando container $FRIGATE_CONTAINER..."
    
    if ! docker stop "$FRIGATE_CONTAINER" 2>/dev/null; then
        echo "[ERRO] Falha ao parar o container $FRIGATE_CONTAINER" >&2
        return 1
    fi
    
    # Aguarda um momento para garantir que tudo foi liberado
    sleep 2
    
    log "$LOG_TAG" "Container $FRIGATE_CONTAINER parado com sucesso"
    return 0
}

# -----------------------------------------------------------------------------
# FUNÇÃO: start_frigate
# -----------------------------------------------------------------------------
# Inicia o container do Frigate
#
# RETORNO:
#   0 - Container iniciado com sucesso
#   1 - Erro ao iniciar o container
# -----------------------------------------------------------------------------
start_frigate() {
    log "$LOG_TAG" "Iniciando container $FRIGATE_CONTAINER..."
    
    if ! docker start "$FRIGATE_CONTAINER" 2>/dev/null; then
        echo "[ERRO] Falha ao iniciar o container $FRIGATE_CONTAINER" >&2
        return 1
    fi
    
    log "$LOG_TAG" "Container $FRIGATE_CONTAINER iniciado com sucesso"
    return 0
}

# -----------------------------------------------------------------------------
# FUNÇÃO: delete_recordings
# -----------------------------------------------------------------------------
# Remove todas as gravações do SSD
#
# RETORNO:
#   0 - Sucesso
#   1 - Erro
# -----------------------------------------------------------------------------
delete_recordings() {
    local errors=0
    
    # Remove gravações
    if [[ -d "$SSD_RECORDINGS" ]]; then
        log "$LOG_TAG" "Removendo gravações de $SSD_RECORDINGS..."
        if rm -rf "${SSD_RECORDINGS:?}"/*; then
            log "$LOG_TAG" "Gravações removidas com sucesso"
        else
            log "$LOG_TAG" "Erro ao remover gravações"
            errors=$((errors + 1))
        fi
    fi
    
    # Remove clips
    if [[ -d "$SSD_CLIPS" ]]; then
        log "$LOG_TAG" "Removendo clips de $SSD_CLIPS..."
        if rm -rf "${SSD_CLIPS:?}"/*; then
            log "$LOG_TAG" "Clips removidos com sucesso"
        else
            log "$LOG_TAG" "Erro ao remover clips"
            errors=$((errors + 1))
        fi
    fi
    
    return $errors
}

# -----------------------------------------------------------------------------
# FUNÇÃO: delete_database
# -----------------------------------------------------------------------------
# Remove os arquivos de banco de dados do Frigate
#
# RETORNO:
#   0 - Sucesso
#   1 - Erro
# -----------------------------------------------------------------------------
delete_database() {
    log "$LOG_TAG" "Removendo banco de dados do Frigate..."
    
    local db_pattern="${FRIGATE_CONFIG}/${FRIGATE_DB_NAME}*"
    local files_found
    files_found=$(find "$FRIGATE_CONFIG" -maxdepth 1 -name "${FRIGATE_DB_NAME}*" 2>/dev/null | wc -l)
    
    if [[ "$files_found" -eq 0 ]]; then
        log "$LOG_TAG" "Nenhum arquivo de banco de dados encontrado"
        return 0
    fi
    
    if rm -f "$FRIGATE_CONFIG"/${FRIGATE_DB_NAME}*; then
        log "$LOG_TAG" "Banco de dados removido com sucesso ($files_found arquivos)"
        return 0
    else
        log "$LOG_TAG" "Erro ao remover banco de dados"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# VERIFICAÇÕES INICIAIS
# -----------------------------------------------------------------------------

# Verifica se o Docker está disponível
if ! command -v docker &>/dev/null; then
    echo "[ERRO] Docker não encontrado. Este script requer Docker." >&2
    exit 1
fi

# Verifica se o container existe
if ! docker ps -a --format '{{.Names}}' | grep -q "^${FRIGATE_CONTAINER}$"; then
    echo "[ERRO] Container '$FRIGATE_CONTAINER' não encontrado." >&2
    echo "       Use a variável FRIGATE_CONTAINER no .env para configurar." >&2
    exit 1
fi

# Verifica se o diretório de configuração existe
if [[ ! -d "$FRIGATE_CONFIG" ]]; then
    echo "[AVISO] Diretório de configuração não encontrado: $FRIGATE_CONFIG" >&2
    echo "        O banco de dados não será removido." >&2
fi

# -----------------------------------------------------------------------------
# EXIBE INFORMAÇÕES E PEDE CONFIRMAÇÃO
# -----------------------------------------------------------------------------
echo ""
echo "╔══════════════════════════════════════════════════════════════════════════╗"
echo "║                      FRIGATE - RESET COMPLETO                            ║"
echo "╠══════════════════════════════════════════════════════════════════════════╣"
echo "║  ⚠️  ATENÇÃO: Esta operação é IRREVERSÍVEL!                              ║"
echo "║      Todos os dados abaixo serão PERMANENTEMENTE removidos.              ║"
echo "╚══════════════════════════════════════════════════════════════════════════╝"
echo ""

echo "📊 Resumo dos dados a serem removidos:"
echo ""

get_dir_info "$SSD_RECORDINGS" "📹 Gravações (recordings)"
echo ""
get_dir_info "$SSD_CLIPS" "🎬 Clips"
echo ""
get_db_info "$FRIGATE_CONFIG"
echo ""

echo "───────────────────────────────────────────────────────────────────────────"
echo ""

# Status do container
container_status=$(docker inspect -f '{{.State.Status}}' "$FRIGATE_CONTAINER" 2>/dev/null || echo "desconhecido")
echo "🐳 Container Frigate: $container_status"
echo ""

echo "📝 O que será feito:"
echo "   1. Parar o container do Frigate"
echo "   2. Remover todas as gravações do SSD"
echo "   3. Remover todos os clips do SSD"
echo "   4. Apagar o banco de dados do Frigate"
echo "   5. Reiniciar o container do Frigate"
echo ""

# Pede confirmação
read -r -p "❓ Tem certeza que deseja continuar? Digite 'SIM' para confirmar: " confirmation

if [[ "$confirmation" != "SIM" ]]; then
    echo ""
    echo "❌ Operação cancelada pelo usuário."
    exit 0
fi

echo ""
echo "🔄 Iniciando reset do Frigate..."
echo ""

# -----------------------------------------------------------------------------
# EXECUÇÃO DO RESET
# -----------------------------------------------------------------------------

errors=0

# Passo 1: Para o container
echo "▶️  [1/5] Parando container..."
if ! stop_frigate; then
    echo "[ERRO] Não foi possível parar o container. Abortando." >&2
    exit 1
fi
echo "✅ Container parado"
echo ""

# Passo 2: Remove gravações
echo "▶️  [2/5] Removendo gravações..."
if ! delete_recordings; then
    echo "[AVISO] Houve erros ao remover algumas gravações" >&2
    errors=$((errors + 1))
fi
echo "✅ Gravações removidas"
echo ""

# Passo 3: (incluído no passo 2 para clips)
echo "▶️  [3/5] Clips removidos (junto com gravações)"
echo ""

# Passo 4: Remove banco de dados
echo "▶️  [4/5] Removendo banco de dados..."
if [[ -d "$FRIGATE_CONFIG" ]]; then
    if ! delete_database; then
        echo "[AVISO] Houve erros ao remover o banco de dados" >&2
        errors=$((errors + 1))
    fi
    echo "✅ Banco de dados removido"
else
    echo "⏭️  Diretório de configuração não encontrado, pulando..."
fi
echo ""

# Passo 5: Reinicia o container
echo "▶️  [5/5] Reiniciando container..."
if ! start_frigate; then
    echo "[ERRO] Não foi possível reiniciar o container!" >&2
    echo "       Execute manualmente: docker start $FRIGATE_CONTAINER" >&2
    errors=$((errors + 1))
fi
echo "✅ Container reiniciado"
echo ""

# -----------------------------------------------------------------------------
# RESUMO FINAL
# -----------------------------------------------------------------------------
echo "═══════════════════════════════════════════════════════════════════════════"
if [[ $errors -eq 0 ]]; then
    echo "✅ RESET COMPLETO REALIZADO COM SUCESSO!"
else
    echo "⚠️  RESET CONCLUÍDO COM $errors ERRO(S)"
fi
echo "═══════════════════════════════════════════════════════════════════════════"
echo ""
echo "📋 Próximos passos:"
echo "   - Aguarde alguns segundos para o Frigate inicializar"
echo "   - Acesse a interface web para verificar o status"
echo "   - O banco de dados será recriado automaticamente"
echo ""

log "$LOG_TAG" "Reset concluído com $errors erro(s)"

exit $errors
