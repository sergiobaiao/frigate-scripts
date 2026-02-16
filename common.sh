#!/usr/bin/env bash
# VERSION: 1.0
# =============================================================================
# FRIGATE NVR - FUNÇÕES E CONFIGURAÇÕES COMPARTILHADAS
# =============================================================================
# Este script deve ser incluído (source) por todos os outros scripts.
# Ele carrega as variáveis do .env e define funções utilitárias comuns.
#
# USO:
#   source "$(dirname "$0")/common.sh"
# =============================================================================

# -----------------------------------------------------------------------------
# CONFIGURAÇÕES DO BASH
# -----------------------------------------------------------------------------
# -e: Sai imediatamente se qualquer comando falhar
# -u: Trata variáveis não definidas como erro
# -o pipefail: Retorna erro se qualquer comando em um pipe falhar
set -Eeuo pipefail

# nullglob: Padrões glob que não casam expandem para string vazia
shopt -s nullglob

# -----------------------------------------------------------------------------
# CARREGAMENTO DO ARQUIVO DE CONFIGURAÇÃO
# -----------------------------------------------------------------------------
# Determina o diretório onde este script está localizado
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Arquivo de configuração padrão
ENV_FILE="${SCRIPT_DIR}/.env"

# Arquivo de configuração local (override) - tem prioridade
ENV_LOCAL="${SCRIPT_DIR}/.env.local"

# Carrega o .env principal se existir
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
else
    echo "[ERRO] Arquivo de configuração não encontrado: $ENV_FILE" >&2
    exit 1
fi

# Carrega o .env.local se existir (sobrescreve valores do .env)
if [[ -f "$ENV_LOCAL" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_LOCAL"
fi

# -----------------------------------------------------------------------------
# NORMALIZAÇÃO DE CAMINHOS DE MÍDIA
# -----------------------------------------------------------------------------
# Alguns ambientes usam layout com subdiretório "frigate" (ex:
# /mnt/frigate-ssd/frigate/recordings). Se o caminho configurado não existir,
# tenta automaticamente variantes comuns para manter compatibilidade.
resolve_media_path() {
    local configured="$1"
    shift

    if [[ -d "$configured" ]]; then
        echo "$configured"
        return
    fi

    local candidate
    for candidate in "$@"; do
        if [[ -d "$candidate" ]]; then
            echo "$candidate"
            return
        fi
    done

    echo "$configured"
}

SSD_RECORDINGS="$(resolve_media_path "$SSD_RECORDINGS" \
    "${SSD_ROOT}/frigate/recordings" \
    "${SSD_ROOT}/recordings")"
SSD_CLIPS="$(resolve_media_path "$SSD_CLIPS" \
    "${SSD_ROOT}/frigate/clips" \
    "${SSD_ROOT}/clips")"
SSD_EXPORTS="$(resolve_media_path "${SSD_EXPORTS:-${SSD_ROOT}/exports}" \
    "${SSD_ROOT}/frigate/exports" \
    "${SSD_ROOT}/exports")"
SSD_SNAPSHOTS="$(resolve_media_path "${SSD_SNAPSHOTS:-${SSD_ROOT}/snapshots}" \
    "${SSD_ROOT}/frigate/snapshots" \
    "${SSD_ROOT}/snapshots")"
HD_RECORDINGS="$(resolve_media_path "$HD_RECORDINGS" \
    "${HD_MOUNT}/frigate/recordings" \
    "${HD_MOUNT}/recordings")"
HD_CLIPS="$(resolve_media_path "$HD_CLIPS" \
    "${HD_MOUNT}/frigate/clips" \
    "${HD_MOUNT}/clips")"
HD_EXPORTS="$(resolve_media_path "${HD_EXPORTS:-${HD_MOUNT}/exports}" \
    "${HD_MOUNT}/frigate/exports" \
    "${HD_MOUNT}/exports")"
HD_SNAPSHOTS="$(resolve_media_path "${HD_SNAPSHOTS:-${HD_MOUNT}/snapshots}" \
    "${HD_MOUNT}/frigate/snapshots" \
    "${HD_MOUNT}/snapshots")"

# -----------------------------------------------------------------------------
# FUNÇÃO: log
# -----------------------------------------------------------------------------
# Imprime mensagem de log formatada com timestamp ISO 8601
#
# ARGUMENTOS:
#   $1 - Prefixo/tag do log (ex: "archive", "prune")
#   $* - Mensagem a ser logada
#
# EXEMPLO:
#   log "archive" "Iniciando processamento..."
#   # Saída: [2024-01-15T10:30:00-03:00] [archive] Iniciando processamento...
# -----------------------------------------------------------------------------
log() {
    local tag="${1:-script}"
    shift
    echo "[$(date -Is)] [$tag] [INFO] $*"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: log_simple
# -----------------------------------------------------------------------------
# Versão simplificada do log com formato mais compacto
#
# ARGUMENTOS:
#   $1 - Prefixo/tag do log
#   $* - Mensagem a ser logada
#
# EXEMPLO:
#   log_simple "vacuum" "Limpeza concluída"
#   # Saída: 2024-01-15 10:30:00 [vacuum] Limpeza concluída
# -----------------------------------------------------------------------------
log_simple() {
    local tag="${1:-script}"
    shift
    echo "$(date '+%F %T') [$tag] $*"
}

log_warn() {
    local tag="${1:-script}"
    shift
    echo "[$(date -Is)] [$tag] [WARN] $*"
}

log_error() {
    local tag="${1:-script}"
    shift
    echo "[$(date -Is)] [$tag] [ERROR] $*" >&2
}

bytes_human() {
    local bytes="${1:-0}"
    numfmt --to=iec --suffix=B "$bytes" 2>/dev/null || echo "${bytes}B"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: setup_logging
# -----------------------------------------------------------------------------
# Configura redirecionamento de logs para arquivo com opção de espelhamento
# no stdout.
# -----------------------------------------------------------------------------
setup_logging() {
    local log_file="$1"
    local mirror_stdout="${2:-0}"
    local runtime_dir
    local fallback_log_file

    runtime_dir="${RUNTIME_DIR:-${SCRIPT_DIR}/.runtime}"
    fallback_log_file="${runtime_dir}/$(basename "$log_file")"

    if ! mkdir -p "$(dirname "$log_file")" 2>/dev/null || ! (: >>"$log_file") 2>/dev/null; then
        log_file="$fallback_log_file"
        mkdir -p "$(dirname "$log_file")"
        : >>"$log_file"
    fi

    if [[ "$mirror_stdout" == "1" || -t 1 ]]; then
        exec > >(tee -a "$log_file") 2>&1
    else
        exec >>"$log_file" 2>&1
    fi

    log "${LOG_TAG:-script}" "Log inicializado em $log_file (pid=$$, user=${USER:-unknown})"
}

notify_event() {
    local severity="${1:-info}"
    local tag="${2:-script}"
    shift 2
    local message="$*"

    if command -v logger >/dev/null 2>&1; then
        logger -t "frigate-${tag}" -p "user.${severity}" -- "$message" >/dev/null 2>&1 || true
    fi

    if [[ -n "${NOTIFY_CMD:-}" ]]; then
        "$NOTIFY_CMD" "$severity" "$tag" "$message" >/dev/null 2>&1 || true
    fi
}

notify_error() {
    local tag="${1:-script}"
    shift
    local message="$*"
    notify_event err "$tag" "$message"
}

__ERR_TRAP_ACTIVE=0
on_error() {
    local tag="${1:-script}"
    local line="${2:-?}"
    local cmd="${3:-?}"
    local code="${4:-1}"

    if [[ "$__ERR_TRAP_ACTIVE" == "1" ]]; then
        return
    fi
    __ERR_TRAP_ACTIVE=1

    log_error "$tag" "Falha na linha $line (exit=$code): $cmd"
    notify_error "$tag" "Falha na linha $line (exit=$code): $cmd"

    __ERR_TRAP_ACTIVE=0
}

setup_error_trap() {
    trap 'on_error "${LOG_TAG:-script}" "$LINENO" "$BASH_COMMAND" "$?"' ERR
}

collect_path_stats() {
    local path="$1"
    local filter="${2:-}"

    STATS_FILES=0
    STATS_BYTES=0
    STATS_OLDEST="-"
    STATS_NEWEST="-"

    [[ -d "$path" ]] || return 0

    if [[ -n "$filter" ]]; then
        STATS_FILES=$(find "$path" -type f $filter -printf . 2>/dev/null | wc -c)
        STATS_BYTES=$(find "$path" -type f $filter -printf '%s\n' 2>/dev/null | awk '{sum+=$1} END{print sum+0}')
        local dates
        dates=$(find "$path" -type f $filter -printf '%TY-%Tm-%Td\n' 2>/dev/null | sort -u)
        STATS_OLDEST="$(echo "$dates" | head -n1)"
        STATS_NEWEST="$(echo "$dates" | tail -n1)"
    else
        STATS_FILES=$(find "$path" -type f -printf . 2>/dev/null | wc -c)
        STATS_BYTES=$(find "$path" -type f -printf '%s\n' 2>/dev/null | awk '{sum+=$1} END{print sum+0}')
        local dates
        dates=$(find "$path" -type f -printf '%TY-%Tm-%Td\n' 2>/dev/null | sort -u)
        STATS_OLDEST="$(echo "$dates" | head -n1)"
        STATS_NEWEST="$(echo "$dates" | tail -n1)"
    fi

    [[ -z "$STATS_OLDEST" ]] && STATS_OLDEST="-"
    [[ -z "$STATS_NEWEST" ]] && STATS_NEWEST="-"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: check_mountpoint
# -----------------------------------------------------------------------------
# Verifica se um ponto de montagem está ativo
#
# ARGUMENTOS:
#   $1 - Caminho do ponto de montagem
#
# RETORNO:
#   0 - Ponto de montagem está ativo
#   1 - Ponto de montagem não está ativo
#
# EXEMPLO:
#   if check_mountpoint "/mnt/hdexterno"; then
#       echo "HD montado!"
#   fi
# -----------------------------------------------------------------------------
check_mountpoint() {
    local mount_path="$1"
    mountpoint -q "$mount_path"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: get_disk_usage_pct
# -----------------------------------------------------------------------------
# Retorna a porcentagem de uso de um disco/partição
#
# ARGUMENTOS:
#   $1 - Caminho do ponto de montagem
#
# SAÍDA:
#   Número inteiro representando % de uso (ex: 75)
#
# EXEMPLO:
#   usage=$(get_disk_usage_pct "/mnt/hdexterno")
#   echo "Uso: ${usage}%"
# -----------------------------------------------------------------------------
get_disk_usage_pct() {
    local mount_path="$1"
    df -P "$mount_path" | awk 'NR==2{gsub(/%/,"",$5); print $5}'
}

# -----------------------------------------------------------------------------
# FUNÇÃO: get_disk_free_pct
# -----------------------------------------------------------------------------
# Retorna a porcentagem de espaço livre de um disco/partição
#
# ARGUMENTOS:
#   $1 - Caminho do ponto de montagem
#
# SAÍDA:
#   Número inteiro representando % livre (ex: 25)
#
# EXEMPLO:
#   free=$(get_disk_free_pct "/mnt/hdexterno")
#   echo "Livre: ${free}%"
# -----------------------------------------------------------------------------
get_disk_free_pct() {
    local mount_path="$1"
    df -P "$mount_path" | awk 'NR==2{gsub(/%/,"",$5); print 100-$5}'
}

# -----------------------------------------------------------------------------
# FUNÇÃO: acquire_lock
# -----------------------------------------------------------------------------
# Tenta adquirir um lock exclusivo usando flock
#
# ARGUMENTOS:
#   $1 - Caminho do arquivo de lock
#   $2 - File descriptor a usar (ex: 9, 200)
#
# RETORNO:
#   0 - Lock adquirido com sucesso
#   1 - Lock já está em uso por outro processo
#
# EXEMPLO:
#   exec 9>"$LOCK_FILE"
#   if ! acquire_lock "$LOCK_FILE" 9; then
#       echo "Outro processo está rodando"
#       exit 0
#   fi
# -----------------------------------------------------------------------------
acquire_lock() {
    local lock_file="$1"
    local fd="$2"
    
    # Garante que o diretório do lock existe
    mkdir -p "$(dirname "$lock_file")"
    
    # Tenta adquirir o lock sem bloquear (-n)
    flock -n "$fd"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: ensure_dir
# -----------------------------------------------------------------------------
# Garante que um diretório existe, criando se necessário
#
# ARGUMENTOS:
#   $1 - Caminho do diretório
#
# EXEMPLO:
#   ensure_dir "/var/log/frigate"
# -----------------------------------------------------------------------------
ensure_dir() {
    local dir_path="$1"
    mkdir -p "$dir_path"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: detect_frigate_media
# -----------------------------------------------------------------------------
# Detecta o caminho de mídia do Frigate através do container Docker
#
# RETORNO:
#   Imprime o caminho do volume montado em /media/frigate
#   Retorna 1 se não conseguir detectar
#
# EXEMPLO:
#   MEDIA_PATH=$(detect_frigate_media) || MEDIA_PATH="$SSD_ROOT/frigate"
# -----------------------------------------------------------------------------
detect_frigate_media() {
    # Verifica se o Docker está disponível
    command -v docker >/dev/null 2>&1 || return 1
    
    # Busca o ID do container do Frigate
    local cid
    cid="$(docker ps -q --filter name=frigate 2>/dev/null | head -n1 || true)"
    
    # Se não encontrou container, retorna erro
    [[ -z "$cid" ]] && return 1
    
    # Extrai o caminho do volume montado em /media/frigate
    docker inspect "$cid" \
        --format '{{range .Mounts}}{{if eq .Destination "/media/frigate"}}{{.Source}}{{end}}{{end}}' \
        2>/dev/null
}

# -----------------------------------------------------------------------------
# FUNÇÃO: is_valid_date_dir
# -----------------------------------------------------------------------------
# Verifica se um nome de diretório está no formato YYYY-MM-DD
#
# ARGUMENTOS:
#   $1 - Nome do diretório a verificar
#
# RETORNO:
#   0 - É um diretório de data válido
#   1 - Não é um diretório de data válido
#
# EXEMPLO:
#   if is_valid_date_dir "2024-01-15"; then
#       echo "Data válida!"
#   fi
# -----------------------------------------------------------------------------
is_valid_date_dir() {
    local dirname="$1"
    [[ "$dirname" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]
}

# -----------------------------------------------------------------------------
# FUNÇÃO: cleanup_empty_dirs
# -----------------------------------------------------------------------------
# Remove diretórios vazios recursivamente
#
# ARGUMENTOS:
#   $1 - Diretório base para limpar
#
# EXEMPLO:
#   cleanup_empty_dirs "/mnt/frigate-ssd/recordings"
# -----------------------------------------------------------------------------
cleanup_empty_dirs() {
    local base_dir="$1"
    find "$base_dir" -type d -empty -delete 2>/dev/null || true
}

# =============================================================================
# VALIDAÇÃO DE DEPENDÊNCIAS
# =============================================================================
# Funções para verificar se os comandos e recursos necessários estão disponíveis

# -----------------------------------------------------------------------------
# DEPENDÊNCIAS REQUERIDAS POR SCRIPT
# -----------------------------------------------------------------------------
# Mapeamento de scripts para suas dependências
declare -A SCRIPT_DEPENDENCIES=(
    ["frigate-mover"]="rsync flock find"
    ["frigate-prune-hd"]="find flock df"
    ["frigate-retention"]="find flock"
    ["frigate-vacuum"]="find df"
    ["frigate-status"]="df find"
    ["frigate-logrotate"]="gzip find"
    ["hd-watchdog-min"]="df awk"
    ["reset-usb"]="lsusb usbreset"
)

# Dependências opcionais (não bloqueiam execução)
OPTIONAL_DEPENDENCIES="docker numfmt tput"

# -----------------------------------------------------------------------------
# FUNÇÃO: check_command
# -----------------------------------------------------------------------------
# Verifica se um comando está disponível no sistema
#
# ARGUMENTOS:
#   $1 - Nome do comando a verificar
#
# RETORNO:
#   0 - Comando existe
#   1 - Comando não existe
#
# EXEMPLO:
#   if check_command "rsync"; then
#       echo "rsync está instalado"
#   fi
# -----------------------------------------------------------------------------
check_command() {
    local cmd="$1"
    command -v "$cmd" &>/dev/null
}

# -----------------------------------------------------------------------------
# FUNÇÃO: require_command
# -----------------------------------------------------------------------------
# Verifica se um comando existe, exibe erro e sai se não existir
#
# ARGUMENTOS:
#   $1 - Nome do comando requerido
#   $2 - (opcional) Mensagem de erro customizada
#
# EXEMPLO:
#   require_command "rsync" "Instale com: apt install rsync"
# -----------------------------------------------------------------------------
require_command() {
    local cmd="$1"
    local msg="${2:-}"
    
    if ! check_command "$cmd"; then
        echo "[ERRO] Comando requerido não encontrado: $cmd" >&2
        [[ -n "$msg" ]] && echo "       $msg" >&2
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# FUNÇÃO: require_commands
# -----------------------------------------------------------------------------
# Verifica múltiplos comandos de uma vez
#
# ARGUMENTOS:
#   $@ - Lista de comandos a verificar
#
# RETORNO:
#   0 - Todos os comandos existem
#   1 - Um ou mais comandos não existem (lista os faltantes)
#
# EXEMPLO:
#   require_commands rsync flock find
# -----------------------------------------------------------------------------
require_commands() {
    local missing=()
    
    for cmd in "$@"; do
        if ! check_command "$cmd"; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "[ERRO] Comandos requeridos não encontrados: ${missing[*]}" >&2
        return 1
    fi
    
    return 0
}

# -----------------------------------------------------------------------------
# FUNÇÃO: check_all_dependencies
# -----------------------------------------------------------------------------
# Verifica todas as dependências do sistema e retorna relatório
#
# RETORNO:
#   Imprime relatório de dependências
#   Retorna 0 se todas obrigatórias presentes, 1 caso contrário
#
# EXEMPLO:
#   check_all_dependencies
# -----------------------------------------------------------------------------
check_all_dependencies() {
    local all_ok=0
    local required_cmds="rsync flock find df awk gzip"
    
    echo "=== Verificação de Dependências ==="
    echo ""
    echo "Comandos Obrigatórios:"
    
    for cmd in $required_cmds; do
        if check_command "$cmd"; then
            local path
            path=$(command -v "$cmd")
            printf "  %-15s %s %s\n" "$cmd" "✓" "($path)"
        else
            printf "  %-15s %s %s\n" "$cmd" "✗" "NÃO ENCONTRADO"
            all_ok=1
        fi
    done
    
    echo ""
    echo "Comandos Opcionais:"
    
    for cmd in $OPTIONAL_DEPENDENCIES; do
        if check_command "$cmd"; then
            local path
            path=$(command -v "$cmd")
            printf "  %-15s %s %s\n" "$cmd" "✓" "($path)"
        else
            printf "  %-15s %s %s\n" "$cmd" "○" "(não instalado)"
        fi
    done
    
    echo ""
    echo "Recursos do Sistema:"
    
    # Verifica diretórios
    for dir in "$SSD_ROOT" "$HD_MOUNT"; do
        if [[ -d "$dir" ]]; then
            printf "  %-15s %s %s\n" "$(basename "$dir")" "✓" "$dir"
        else
            printf "  %-15s %s %s\n" "$(basename "$dir")" "○" "$dir (não existe)"
        fi
    done
    
    # Verifica mount do HD
    if check_mountpoint "$HD_MOUNT" 2>/dev/null; then
        printf "  %-15s %s\n" "HD Montado" "✓"
    else
        printf "  %-15s %s\n" "HD Montado" "✗ (não montado)"
    fi
    
    echo ""
    
    if [[ $all_ok -eq 0 ]]; then
        echo "Status: ✓ Todas as dependências obrigatórias estão instaladas"
    else
        echo "Status: ✗ Algumas dependências estão faltando"
        echo ""
        echo "Para instalar dependências faltantes (Debian/Ubuntu):"
        echo "  sudo apt install rsync util-linux findutils coreutils gzip"
        echo ""
        echo "Para reset-usb.sh:"
        echo "  sudo apt install usbutils"
    fi
    
    return $all_ok
}

# -----------------------------------------------------------------------------
# FUNÇÃO: get_install_command
# -----------------------------------------------------------------------------
# Retorna o comando de instalação para uma dependência
#
# ARGUMENTOS:
#   $1 - Nome do comando
#
# SAÍDA:
#   Comando de instalação sugerido
# -----------------------------------------------------------------------------
get_install_command() {
    local cmd="$1"
    
    case "$cmd" in
        rsync)      echo "apt install rsync" ;;
        flock)      echo "apt install util-linux" ;;
        find)       echo "apt install findutils" ;;
        df|awk)     echo "apt install coreutils" ;;
        gzip)       echo "apt install gzip" ;;
        docker)     echo "curl -fsSL https://get.docker.com | sh" ;;
        lsusb|usbreset) echo "apt install usbutils" ;;
        numfmt)     echo "apt install coreutils" ;;
        tput)       echo "apt install ncurses-bin" ;;
        *)          echo "Verifique a documentação do pacote" ;;
    esac
}
