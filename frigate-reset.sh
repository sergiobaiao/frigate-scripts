#!/usr/bin/env bash
# VERSION: 1.8
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
#   3. Move toda mídia do SSD para o HD externo (mode=full)
#   4. Remove mídia restante do SSD
#   5. Apaga o banco de dados do Frigate (frigate.db*)
#   6. Reinicia o container do Frigate
#
# USO:
#   ./frigate-reset.sh
#   ./frigate-reset.sh --dry-run
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
#   SSD_EXPORTS       - Caminho dos exports no SSD
#   SSD_SNAPSHOTS     - Caminho dos snapshots no SSD
#   HD_RECORDINGS     - Caminho das gravações no HD
#   HD_CLIPS          - Caminho dos clips no HD
#   HD_EXPORTS        - Caminho dos exports no HD
#   HD_SNAPSHOTS      - Caminho dos snapshots no HD
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
LOG_FILE="${LOG_RESET:-/var/log/frigate-reset.log}"
MIRROR_STDOUT=1

# Variáveis com valores padrão caso não definidas no .env
FRIGATE_CONFIG="${FRIGATE_CONFIG:-/home/castro/marquise/config/frigate}"
FRIGATE_CONTAINER="${FRIGATE_CONTAINER:-frigate}"
DRY_RUN="${DRY_RUN:-0}"
MOVER_SCRIPT="${SCRIPT_DIR}/frigate-mover.sh"

# Nome do banco de dados do Frigate (padrão)
FRIGATE_DB_NAME="frigate.db"

show_help() {
    cat <<EOF
Uso: ./frigate-reset.sh [OPÇÕES]

Opções:
  --dry-run      Simula o reset sem apagar dados e sem parar/iniciar container
  --yes          Não pede confirmação interativa
  --help, -h     Mostra esta ajuda
EOF
}

ASSUME_YES=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            ;;
        --yes)
            ASSUME_YES=1
            ;;
        --help|-h)
            show_help
            exit 0
            ;;
        *)
            echo "[ERRO] Opção desconhecida: $1" >&2
            show_help
            exit 1
            ;;
    esac
    shift
done

# Inicializa logs e tratamento de erro.
setup_logging "$LOG_FILE" "$MIRROR_STDOUT"
setup_error_trap
log "$LOG_TAG" "Iniciando frigate-reset (dry_run=$DRY_RUN, assume_yes=$ASSUME_YES)"

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
        
        # Tamanho total (segue symlink quando aplicável)
        size="$(du -sbL "$dir_path" 2>/dev/null | awk 'NR==1{print $1; exit}' || true)"
        [[ -z "$size" ]] && size=0
        
        # Contagem de arquivos (segue symlink)
        count="$(find -L "$dir_path" -type f 2>/dev/null | wc -l || true)"
        [[ -z "$count" ]] && count=0

        # Datas extrema (não falha quando não há arquivos)
        oldest="$(find -L "$dir_path" -type f -printf '%TY-%Tm-%Td\n' 2>/dev/null | sort | head -n1 || true)"
        newest="$(find -L "$dir_path" -type f -printf '%TY-%Tm-%Td\n' 2>/dev/null | sort | tail -n1 || true)"
        
        echo "  $label:"
        echo "    Caminho: $dir_path"
        
        if [[ -n "$size" ]] && (( size > 0 )); then
            echo "    Tamanho: $(format_size "$size")"
            echo "    Arquivos: $count"
            if [[ -n "$oldest" ]]; then
                echo "    Mais antigo: $oldest"
            fi
            if [[ -n "$newest" ]]; then
                echo "    Mais recente: $newest"
            fi
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
# FUNÇÃO: get_loss_dates
# -----------------------------------------------------------------------------
# Lista datas (YYYY-MM-DD) dos arquivos que seriam removidos em um diretório.
# -----------------------------------------------------------------------------
get_loss_dates() {
    local dir_path="$1"
    if [[ ! -d "$dir_path" ]]; then
        return 0
    fi

    find -L "$dir_path" -type f -printf '%TY-%Tm-%Td\n' 2>/dev/null | sort -u || true
}

# -----------------------------------------------------------------------------
# FUNÇÃO: print_loss_dates
# -----------------------------------------------------------------------------
# Exibe resumo de datas que seriam perdidas por tipo de mídia.
# -----------------------------------------------------------------------------
print_loss_dates() {
    local dir_path="$1"
    local label="$2"
    local dates

    mapfile -t dates < <(get_loss_dates "$dir_path")

    echo "  $label:"
    if (( ${#dates[@]} == 0 )); then
        echo "    Datas que serão perdidas: nenhuma"
        return
    fi

    local joined
    joined="$(IFS=', '; echo "${dates[*]}")"
    echo "    Datas que serão perdidas (${#dates[@]}): $joined"
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
    if [[ "$DRY_RUN" == "1" ]]; then
        log "$LOG_TAG" "[DRY-RUN] Pararia container $FRIGATE_CONTAINER"
        return 0
    fi

    log "$LOG_TAG" "Parando container $FRIGATE_CONTAINER..."
    
    if ! docker stop "$FRIGATE_CONTAINER" 2>/dev/null; then
        log_error "$LOG_TAG" "Falha ao parar o container $FRIGATE_CONTAINER"
        notify_error "$LOG_TAG" "Falha ao parar container $FRIGATE_CONTAINER"
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
    if [[ "$DRY_RUN" == "1" ]]; then
        log "$LOG_TAG" "[DRY-RUN] Iniciaria container $FRIGATE_CONTAINER"
        return 0
    fi

    log "$LOG_TAG" "Iniciando container $FRIGATE_CONTAINER..."
    
    if ! docker start "$FRIGATE_CONTAINER" 2>/dev/null; then
        log_error "$LOG_TAG" "Falha ao iniciar o container $FRIGATE_CONTAINER"
        notify_error "$LOG_TAG" "Falha ao iniciar container $FRIGATE_CONTAINER"
        return 1
    fi
    
    log "$LOG_TAG" "Container $FRIGATE_CONTAINER iniciado com sucesso"
    return 0
}

# -----------------------------------------------------------------------------
# FUNÇÃO: run_full_migration
# -----------------------------------------------------------------------------
# Move toda a mídia do SSD para o HD usando frigate-mover.sh --mode=full.
#
# RETORNO:
#   0 - Sucesso
#   1 - Erro
# -----------------------------------------------------------------------------
run_full_migration() {
    if [[ ! -x "$MOVER_SCRIPT" ]]; then
        log_error "$LOG_TAG" "Script de mover não encontrado/executável: $MOVER_SCRIPT"
        notify_error "$LOG_TAG" "MIGRACAO FULL indisponivel: $MOVER_SCRIPT"
        return 1
    fi

    log "$LOG_TAG" "Iniciando migração FULL SSD->HD via $MOVER_SCRIPT"

    local mover_args=(--mode=full)
    if [[ "$DRY_RUN" == "1" ]]; then
        mover_args+=(--dry-run)
    fi

    if "$MOVER_SCRIPT" "${mover_args[@]}"; then
        log "$LOG_TAG" "Migração FULL concluída com sucesso"
        return 0
    fi

    log_error "$LOG_TAG" "Falha na migração FULL SSD->HD"
    notify_error "$LOG_TAG" "Falha na migracao FULL SSD->HD no frigate-reset"
    return 1
}

# -----------------------------------------------------------------------------
# FUNÇÃO: delete_media
# -----------------------------------------------------------------------------
# Remove recordings/clips/exports/snapshots apenas do SSD
#
# RETORNO:
#   0 - Sucesso
#   1 - Erro
# -----------------------------------------------------------------------------
delete_media() {
    local errors=0

    wipe_media_dir() {
        local label="$1"
        local dir="$2"

        if [[ ! -d "$dir" ]]; then
            log "$LOG_TAG" "$label não existe, pulando: $dir"
            return 0
        fi

        log "$LOG_TAG" "Removendo $label de $dir..."
        if [[ "$DRY_RUN" == "1" ]]; then
            log "$LOG_TAG" "[DRY-RUN] Removeria todo conteúdo de $dir"
            return 0
        fi

        if rm -rf "${dir:?}"/*; then
            log "$LOG_TAG" "$label removido com sucesso"
        else
            log_error "$LOG_TAG" "Erro ao remover $label em $dir"
            notify_error "$LOG_TAG" "Erro ao remover $label em $dir"
            errors=$((errors + 1))
        fi
    }

    wipe_media_dir "recordings (SSD)" "$SSD_RECORDINGS"
    wipe_media_dir "clips (SSD)" "$SSD_CLIPS"
    wipe_media_dir "exports (SSD)" "$SSD_EXPORTS"
    wipe_media_dir "snapshots (SSD)" "$SSD_SNAPSHOTS"
    
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
    
    if [[ "$DRY_RUN" == "1" ]]; then
        log "$LOG_TAG" "[DRY-RUN] Removeria arquivos: $FRIGATE_CONFIG/${FRIGATE_DB_NAME}* ($files_found arquivos)"
        return 0
    fi

    if rm -f "$FRIGATE_CONFIG"/${FRIGATE_DB_NAME}*; then
        log "$LOG_TAG" "Banco de dados removido com sucesso ($files_found arquivos)"
        return 0
    else
        log_error "$LOG_TAG" "Erro ao remover banco de dados"
        notify_error "$LOG_TAG" "Erro ao remover banco de dados em $FRIGATE_CONFIG"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# VERIFICAÇÕES INICIAIS
# -----------------------------------------------------------------------------

# Verifica Docker/container apenas fora do dry-run
if [[ "$DRY_RUN" != "1" ]]; then
    if ! command -v docker &>/dev/null; then
        echo "[ERRO] Docker não encontrado. Este script requer Docker." >&2
        exit 1
    fi

    if ! docker ps -a --format '{{.Names}}' | grep -q "^${FRIGATE_CONTAINER}$"; then
        echo "[ERRO] Container '$FRIGATE_CONTAINER' não encontrado." >&2
        echo "       Use a variável FRIGATE_CONTAINER no .env para configurar." >&2
        exit 1
    fi
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
get_dir_info "$SSD_EXPORTS" "📦 Exports"
echo ""
get_dir_info "$SSD_SNAPSHOTS" "🖼️ Snapshots"
echo ""
get_dir_info "$HD_RECORDINGS" "📹 Gravações HD (recordings)"
echo ""
get_dir_info "$HD_CLIPS" "🎬 Clips HD"
echo ""
get_dir_info "$HD_EXPORTS" "📦 Exports HD"
echo ""
get_dir_info "$HD_SNAPSHOTS" "🖼️ Snapshots HD"
echo ""
get_db_info "$FRIGATE_CONFIG"
echo ""
echo "📅 Datas que serão perdidas:"
echo ""
print_loss_dates "$SSD_RECORDINGS" "📹 Recordings"
print_loss_dates "$SSD_CLIPS" "🎬 Clips"
print_loss_dates "$SSD_EXPORTS" "📦 Exports"
print_loss_dates "$SSD_SNAPSHOTS" "🖼️ Snapshots"
print_loss_dates "$HD_RECORDINGS" "📹 Recordings HD"
print_loss_dates "$HD_CLIPS" "🎬 Clips HD"
print_loss_dates "$HD_EXPORTS" "📦 Exports HD"
print_loss_dates "$HD_SNAPSHOTS" "🖼️ Snapshots HD"
echo ""

echo "───────────────────────────────────────────────────────────────────────────"
echo ""

# Status do container
if [[ "$DRY_RUN" == "1" ]]; then
    container_status="simulação (não consultado)"
elif command -v docker &>/dev/null; then
    container_status=$(docker inspect -f '{{.State.Status}}' "$FRIGATE_CONTAINER" 2>/dev/null || echo "desconhecido")
else
    container_status="docker indisponível"
fi
echo "🐳 Container Frigate: $container_status"
echo ""

echo "📝 O que será feito:"
echo "   1. Parar o container do Frigate"
echo "   2. Mover todas as mídias do SSD para o HD Externo (mode=full)"
echo "   3. Remover mídias do SSD (recordings/clips/exports/snapshots)"
echo "   4. Apagar o banco de dados do Frigate"
echo "   5. Reiniciar o container do Frigate"
[[ "$DRY_RUN" == "1" ]] && echo "   (modo DRY-RUN: nenhuma alteração será aplicada)"
echo ""

if [[ "$DRY_RUN" == "1" ]]; then
    echo "ℹ️  DRY-RUN ativo: execução em modo simulação."
elif [[ "$ASSUME_YES" == "1" ]]; then
    echo "ℹ️  Confirmação ignorada (--yes)."
else
    read -r -p "❓ Tem certeza que deseja continuar? Digite 'SIM' para confirmar: " confirmation

    if [[ "$confirmation" != "SIM" ]]; then
        echo ""
        echo "❌ Operação cancelada pelo usuário."
        exit 0
    fi
fi

echo ""
echo "🔄 Iniciando reset do Frigate..."
echo ""

# -----------------------------------------------------------------------------
# EXECUÇÃO DO RESET
# -----------------------------------------------------------------------------

errors=0

# Passo 1: Para o container
echo "▶️  [1/4] Parando container..."
if ! stop_frigate; then
    echo "[ERRO] Não foi possível parar o container. Abortando." >&2
    exit 1
fi
echo "✅ Container parado"
echo ""

# Passo 2: Migra dados para o HD
echo "▶️  [2/5] Migrando mídias do SSD para HD (mode=full)..."
if ! run_full_migration; then
    echo "[ERRO] Falha na migração FULL para o HD. Abortando para evitar perda de dados." >&2
    if ! start_frigate; then
        echo "[ERRO] Também falhou ao reiniciar o container após abortar." >&2
    fi
    exit 1
fi
echo "✅ Migração para HD concluída"
echo ""

# Passo 3: Remove gravações do SSD
echo "▶️  [3/5] Removendo mídias do SSD (recordings/clips/exports/snapshots)..."
if ! delete_media; then
    echo "[AVISO] Houve erros ao remover algumas mídias" >&2
    errors=$((errors + 1))
fi
echo "✅ Mídias do SSD removidas"
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
