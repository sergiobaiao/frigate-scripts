#!/usr/bin/env bash
# =============================================================================
# FRIGATE-CHECK.SH
# =============================================================================
# Verifica se o sistema está pronto para executar os scripts Frigate.
#
# DESCRIÇÃO:
#   Este script verifica todas as dependências, configurações e recursos
#   necessários para o funcionamento correto do sistema de gerenciamento
#   de mídia do Frigate.
#
# USO:
#   ./frigate-check.sh              # Verificação completa
#   ./frigate-check.sh --quick      # Verificação rápida (apenas obrigatórios)
#   ./frigate-check.sh --fix        # Tenta corrigir problemas (requer sudo)
#   ./frigate-check.sh --install    # Mostra comandos de instalação
#
# EXIT CODES:
#   0 - Sistema pronto
#   1 - Problemas encontrados
#
# AUTOR: Sistema Marquise
# =============================================================================

# -----------------------------------------------------------------------------
# CARREGA CONFIGURAÇÕES E FUNÇÕES COMPARTILHADAS
# -----------------------------------------------------------------------------
source "$(dirname "$0")/common.sh"

# -----------------------------------------------------------------------------
# CORES PARA OUTPUT
# -----------------------------------------------------------------------------
if [[ -t 1 ]] && command -v tput &>/dev/null; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    CYAN=$(tput setaf 6)
    BOLD=$(tput bold)
    RESET=$(tput sgr0)
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    CYAN=""
    BOLD=""
    RESET=""
fi

# -----------------------------------------------------------------------------
# VARIÁVEIS GLOBAIS
# -----------------------------------------------------------------------------
MODE="full"
EXIT_CODE=0
PROBLEMS=()
WARNINGS=()

# -----------------------------------------------------------------------------
# FUNÇÃO: show_help
# -----------------------------------------------------------------------------
show_help() {
    cat << 'EOF'
Uso: frigate-check.sh [OPÇÃO]

Verifica se o sistema está pronto para executar os scripts Frigate.

OPÇÕES:
  (sem opção)    Verificação completa do sistema
  --quick, -q    Verificação rápida (apenas dependências obrigatórias)
  --fix, -f      Tenta criar diretórios faltantes (requer sudo)
  --install, -i  Mostra comandos para instalar dependências
  --help, -h     Mostra esta ajuda

EXIT CODES:
  0 - Sistema pronto
  1 - Problemas encontrados

EXEMPLOS:
  frigate-check.sh                 # Verificação completa
  frigate-check.sh --quick         # Verificação rápida
  frigate-check.sh --install       # Comandos de instalação
EOF
}

# -----------------------------------------------------------------------------
# FUNÇÃO: print_header
# -----------------------------------------------------------------------------
print_header() {
    echo ""
    echo "${BOLD}╔══════════════════════════════════════════════════════════════════╗${RESET}"
    echo "${BOLD}║            FRIGATE SYSTEM CHECK                                  ║${RESET}"
    echo "${BOLD}╚══════════════════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

# -----------------------------------------------------------------------------
# FUNÇÃO: check_ok
# -----------------------------------------------------------------------------
check_ok() {
    printf "  ${GREEN}✓${RESET} %s\n" "$1"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: check_fail
# -----------------------------------------------------------------------------
check_fail() {
    printf "  ${RED}✗${RESET} %s\n" "$1"
    PROBLEMS+=("$1")
    EXIT_CODE=1
}

# -----------------------------------------------------------------------------
# FUNÇÃO: check_warn
# -----------------------------------------------------------------------------
check_warn() {
    printf "  ${YELLOW}○${RESET} %s\n" "$1"
    WARNINGS+=("$1")
}

# -----------------------------------------------------------------------------
# FUNÇÃO: check_info
# -----------------------------------------------------------------------------
check_info() {
    printf "  ${CYAN}ℹ${RESET} %s\n" "$1"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: section_header
# -----------------------------------------------------------------------------
section_header() {
    echo ""
    echo "${BOLD}┌─ $1 ─────────────────────────────────────────────────────────────┐${RESET}"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: section_footer
# -----------------------------------------------------------------------------
section_footer() {
    echo "${BOLD}└──────────────────────────────────────────────────────────────────┘${RESET}"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: check_required_commands
# -----------------------------------------------------------------------------
check_required_commands() {
    section_header "COMANDOS OBRIGATÓRIOS"
    
    local required_cmds="rsync flock find df awk gzip"
    
    for cmd in $required_cmds; do
        if check_command "$cmd"; then
            local path
            path=$(command -v "$cmd")
            check_ok "$cmd ($path)"
        else
            check_fail "$cmd - NÃO ENCONTRADO"
        fi
    done
    
    section_footer
}

# -----------------------------------------------------------------------------
# FUNÇÃO: check_optional_commands
# -----------------------------------------------------------------------------
check_optional_commands() {
    section_header "COMANDOS OPCIONAIS"
    
    local optional_cmds="docker numfmt tput lsusb usbreset"
    
    for cmd in $optional_cmds; do
        if check_command "$cmd"; then
            local path
            path=$(command -v "$cmd")
            check_ok "$cmd ($path)"
        else
            check_warn "$cmd - não instalado (funcionalidade limitada)"
        fi
    done
    
    section_footer
}

# -----------------------------------------------------------------------------
# FUNÇÃO: check_directories
# -----------------------------------------------------------------------------
check_directories() {
    section_header "DIRETÓRIOS"
    
    # Diretório de scripts
    if [[ -d "$SCRIPT_DIR" ]]; then
        check_ok "Scripts: $SCRIPT_DIR"
    else
        check_fail "Scripts: $SCRIPT_DIR não existe"
    fi
    
    # SSD Root
    if [[ -d "$SSD_ROOT" ]]; then
        check_ok "SSD Root: $SSD_ROOT"
    else
        check_warn "SSD Root: $SSD_ROOT não existe"
    fi
    
    # SSD Recordings
    if [[ -d "$SSD_RECORDINGS" ]]; then
        check_ok "SSD Recordings: $SSD_RECORDINGS"
    else
        check_warn "SSD Recordings: $SSD_RECORDINGS não existe"
    fi

    if [[ -d "$SSD_CLIPS" ]]; then
        check_ok "SSD Clips: $SSD_CLIPS"
    else
        check_warn "SSD Clips: $SSD_CLIPS não existe"
    fi

    if [[ -d "$SSD_EXPORTS" ]]; then
        check_ok "SSD Exports: $SSD_EXPORTS"
    else
        check_warn "SSD Exports: $SSD_EXPORTS não existe"
    fi

    if [[ -d "$SSD_SNAPSHOTS" ]]; then
        check_ok "SSD Snapshots: $SSD_SNAPSHOTS"
    else
        check_warn "SSD Snapshots: $SSD_SNAPSHOTS não existe"
    fi
    
    # HD Mount
    if [[ -d "$HD_MOUNT" ]]; then
        check_ok "HD Mount: $HD_MOUNT"
    else
        check_warn "HD Mount: $HD_MOUNT não existe"
    fi

    if [[ -d "$HD_RECORDINGS" ]]; then
        check_ok "HD Recordings: $HD_RECORDINGS"
    else
        check_warn "HD Recordings: $HD_RECORDINGS não existe"
    fi

    if [[ -d "$HD_CLIPS" ]]; then
        check_ok "HD Clips: $HD_CLIPS"
    else
        check_warn "HD Clips: $HD_CLIPS não existe"
    fi

    if [[ -d "$HD_EXPORTS" ]]; then
        check_ok "HD Exports: $HD_EXPORTS"
    else
        check_warn "HD Exports: $HD_EXPORTS não existe"
    fi

    if [[ -d "$HD_SNAPSHOTS" ]]; then
        check_ok "HD Snapshots: $HD_SNAPSHOTS"
    else
        check_warn "HD Snapshots: $HD_SNAPSHOTS não existe"
    fi
    
    # Log directory
    if [[ -d "$LOG_DIR" ]]; then
        check_ok "Logs: $LOG_DIR"
        
        # Verifica permissão de escrita
        if [[ -w "$LOG_DIR" ]]; then
            check_ok "Logs: permissão de escrita OK"
        else
            check_fail "Logs: sem permissão de escrita em $LOG_DIR"
        fi
    else
        check_warn "Logs: $LOG_DIR não existe"
    fi
    
    # Lock directory
    if [[ -d "$LOCK_DIR" ]]; then
        check_ok "Locks: $LOCK_DIR"
    else
        check_warn "Locks: $LOCK_DIR não existe (será criado automaticamente)"
    fi
    
    section_footer
}

# -----------------------------------------------------------------------------
# FUNÇÃO: check_mounts
# -----------------------------------------------------------------------------
check_mounts() {
    section_header "PONTOS DE MONTAGEM"
    
    # HD Externo
    if check_mountpoint "$HD_MOUNT" 2>/dev/null; then
        local usage free
        usage=$(get_disk_usage_pct "$HD_MOUNT")
        free=$((100 - usage))
        check_ok "HD Externo montado em $HD_MOUNT (${usage}% usado, ${free}% livre)"
    else
        check_warn "HD Externo NÃO montado em $HD_MOUNT"
    fi
    
    # SSD (assumindo que é /)
    if [[ -d "/" ]]; then
        local usage
        usage=$(df / | tail -1 | awk '{print $5}' | sed 's/%//')
        if (( usage >= 90 )); then
            check_fail "Partição raiz com ${usage}% de uso (crítico!)"
        elif (( usage >= 80 )); then
            check_warn "Partição raiz com ${usage}% de uso"
        else
            check_ok "Partição raiz com ${usage}% de uso"
        fi
    fi
    
    section_footer
}

# -----------------------------------------------------------------------------
# FUNÇÃO: check_configuration
# -----------------------------------------------------------------------------
check_configuration() {
    section_header "CONFIGURAÇÃO"
    
    # .env file
    if [[ -f "$ENV_FILE" ]]; then
        check_ok "Arquivo .env: $ENV_FILE"
    else
        check_fail "Arquivo .env não encontrado: $ENV_FILE"
    fi
    
    # .env.local file (opcional)
    if [[ -f "$ENV_LOCAL" ]]; then
        check_info "Arquivo .env.local: $ENV_LOCAL (override ativo)"
    fi
    
    # Verifica variáveis importantes
    [[ -n "${SSD_ROOT:-}" ]] && check_ok "SSD_ROOT: $SSD_ROOT" || check_fail "SSD_ROOT não definido"
    [[ -n "${HD_MOUNT:-}" ]] && check_ok "HD_MOUNT: $HD_MOUNT" || check_fail "HD_MOUNT não definido"
    [[ -n "${KEEP_SSD_DAYS:-}" ]] && check_ok "KEEP_SSD_DAYS: $KEEP_SSD_DAYS" || check_warn "KEEP_SSD_DAYS não definido"
    [[ -n "${BWLIMIT:-}" ]] && check_ok "BWLIMIT: ${BWLIMIT} KB/s" || check_warn "BWLIMIT não definido"
    
    section_footer
}

# -----------------------------------------------------------------------------
# FUNÇÃO: check_docker
# -----------------------------------------------------------------------------
check_docker() {
    section_header "DOCKER / FRIGATE"
    
    if ! check_command "docker"; then
        check_warn "Docker não instalado"
        section_footer
        return
    fi
    
    # Verifica se o daemon está rodando
    if docker info &>/dev/null; then
        check_ok "Docker daemon rodando"
    else
        check_fail "Docker daemon não está rodando ou sem permissão"
        section_footer
        return
    fi
    
    # Verifica container Frigate
    local container_id
    container_id=$(docker ps -q --filter name=frigate 2>/dev/null | head -n1)
    
    if [[ -n "$container_id" ]]; then
        local container_name
        container_name=$(docker inspect --format '{{.Name}}' "$container_id" | sed 's/^\/*//')
        check_ok "Container Frigate rodando: $container_name"
        
        # Verifica volume de mídia
        local media_path
        media_path=$(detect_frigate_media 2>/dev/null || echo "")
        if [[ -n "$media_path" ]]; then
            check_ok "Volume de mídia: $media_path"
        else
            check_warn "Volume /media/frigate não detectado"
        fi
    else
        check_warn "Container Frigate não está rodando"
    fi
    
    section_footer
}

# -----------------------------------------------------------------------------
# FUNÇÃO: check_scripts
# -----------------------------------------------------------------------------
check_scripts() {
    section_header "SCRIPTS"
    
    local scripts=(
        "frigate-mover.sh"
        "frigate-prune-hd.sh"
        "frigate-retention.sh"
        "frigate-vacuum.sh"
        "frigate-status.sh"
        "frigate-logrotate.sh"
        "hd-watchdog-min.sh"
        "reset-usb.sh"
        "common.sh"
    )
    
    for script in "${scripts[@]}"; do
        local path="${SCRIPT_DIR}/${script}"
        if [[ -f "$path" ]]; then
            if [[ -x "$path" ]]; then
                check_ok "$script (executável)"
            else
                check_warn "$script (sem permissão de execução)"
            fi
        else
            check_fail "$script não encontrado"
        fi
    done
    
    section_footer
}

# -----------------------------------------------------------------------------
# FUNÇÃO: show_install_commands
# -----------------------------------------------------------------------------
show_install_commands() {
    echo ""
    echo "${BOLD}Comandos de Instalação (Debian/Ubuntu):${RESET}"
    echo ""
    echo "  # Dependências obrigatórias"
    echo "  sudo apt update"
    echo "  sudo apt install -y rsync util-linux findutils coreutils gzip"
    echo ""
    echo "  # Para reset-usb.sh"
    echo "  sudo apt install -y usbutils"
    echo ""
    echo "  # Para Docker (opcional)"
    echo "  curl -fsSL https://get.docker.com | sh"
    echo "  sudo usermod -aG docker \$USER"
    echo ""
    echo "  # Tornar scripts executáveis"
    echo "  chmod +x ${SCRIPT_DIR}/*.sh"
    echo ""
}

# -----------------------------------------------------------------------------
# FUNÇÃO: try_fix
# -----------------------------------------------------------------------------
try_fix() {
    echo ""
    echo "${BOLD}Tentando corrigir problemas...${RESET}"
    echo ""
    
    # Cria diretórios faltantes
    local dirs=("$LOCK_DIR" "$LOG_DIR")
    for dir in "${dirs[@]}"; do
        if [[ ! -d "$dir" ]]; then
            echo "Criando diretório: $dir"
            sudo mkdir -p "$dir"
            sudo chmod 755 "$dir"
        fi
    done
    
    # Torna scripts executáveis
    echo "Tornando scripts executáveis..."
    chmod +x "${SCRIPT_DIR}"/*.sh 2>/dev/null || true
    
    echo ""
    echo "Correções aplicadas. Execute novamente para verificar."
}

# -----------------------------------------------------------------------------
# FUNÇÃO: print_summary
# -----------------------------------------------------------------------------
print_summary() {
    echo ""
    echo "${BOLD}┌─ RESUMO ─────────────────────────────────────────────────────────┐${RESET}"
    
    if [[ ${#PROBLEMS[@]} -eq 0 ]] && [[ ${#WARNINGS[@]} -eq 0 ]]; then
        echo "│"
        echo "│  ${GREEN}✓ Sistema pronto!${RESET} Todos os requisitos foram atendidos."
        echo "│"
    else
        echo "│"
        if [[ ${#PROBLEMS[@]} -gt 0 ]]; then
            echo "│  ${RED}Problemas (${#PROBLEMS[@]}):${RESET}"
            for p in "${PROBLEMS[@]}"; do
                echo "│    • $p"
            done
        fi
        
        if [[ ${#WARNINGS[@]} -gt 0 ]]; then
            echo "│  ${YELLOW}Avisos (${#WARNINGS[@]}):${RESET}"
            for w in "${WARNINGS[@]}"; do
                echo "│    • $w"
            done
        fi
        echo "│"
        echo "│  Execute com --install para ver comandos de instalação"
        echo "│  Execute com --fix para tentar corrigir automaticamente"
        echo "│"
    fi
    
    echo "${BOLD}└──────────────────────────────────────────────────────────────────┘${RESET}"
    echo ""
}

# -----------------------------------------------------------------------------
# FUNÇÃO: quick_check
# -----------------------------------------------------------------------------
quick_check() {
    local required_cmds="rsync flock find df awk gzip"
    local missing=()
    
    for cmd in $required_cmds; do
        if ! check_command "$cmd"; then
            missing+=("$cmd")
        fi
    done
    
    if [[ ${#missing[@]} -eq 0 ]]; then
        echo "OK: Todas as dependências obrigatórias estão instaladas"
        return 0
    else
        echo "ERRO: Comandos faltando: ${missing[*]}"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# PROCESSAMENTO DOS ARGUMENTOS
# -----------------------------------------------------------------------------
case "${1:-}" in
    --quick|-q)
        MODE="quick"
        ;;
    --fix|-f)
        MODE="fix"
        ;;
    --install|-i)
        MODE="install"
        ;;
    --help|-h)
        show_help
        exit 0
        ;;
    "")
        MODE="full"
        ;;
    *)
        echo "Opção desconhecida: $1"
        echo "Use --help para ver as opções."
        exit 1
        ;;
esac

# -----------------------------------------------------------------------------
# EXECUÇÃO PRINCIPAL
# -----------------------------------------------------------------------------
case "$MODE" in
    full)
        print_header
        check_required_commands
        check_optional_commands
        check_directories
        check_mounts
        check_configuration
        check_docker
        check_scripts
        print_summary
        ;;
    quick)
        quick_check
        exit $?
        ;;
    fix)
        try_fix
        ;;
    install)
        show_install_commands
        ;;
esac

exit $EXIT_CODE
