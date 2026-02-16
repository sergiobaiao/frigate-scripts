#!/bin/bash
# VERSION: 1.2
# =============================================================================
# RESET-USB.SH
# =============================================================================
# Reseta um dispositivo USB específico para resolver travamentos.
#
# DESCRIÇÃO:
#   Este script é utilizado para resetar o HD externo USB quando ele
#   trava ou para de responder. É uma solução de software que evita
#   ter que desconectar fisicamente o dispositivo.
#
# FUNCIONAMENTO:
#   1. Identifica o dispositivo USB pelo seu ID (vendor:product)
#   2. Obtém o barramento e número do dispositivo
#   3. Usa o comando usbreset para reinicializar o dispositivo
#
# MODOS DE USO:
#   ./reset-usb.sh              # Reseta o dispositivo configurado no .env
#   ./reset-usb.sh --select     # Lista dispositivos e permite escolher/salvar
#   ./reset-usb.sh --list       # Apenas lista os dispositivos USB
#
# COMO DESCOBRIR O ID DO DISPOSITIVO:
#   Execute: lsusb
#   Procure pelo seu HD, o ID será algo como "174c:1153"
#
# CONFIGURAÇÕES (via .env):
#   USB_DEVICE_ID - ID do dispositivo USB (formato: vendor:product)
#
# DEPENDÊNCIAS:
#   - lsusb (pacote usbutils)
#   - usbreset (pacote usbutils ou compilar manualmente)
#
# AUTOR: Sistema Marquise
# =============================================================================

# -----------------------------------------------------------------------------
# CARREGA CONFIGURAÇÕES E FUNÇÕES COMPARTILHADAS
# -----------------------------------------------------------------------------
source "$(dirname "$0")/common.sh"

# Tag para identificação nos logs
LOG_TAG="usb-reset"
LOG_FILE="${LOG_USB_RESET:-/var/log/frigate-usb-reset.log}"
MIRROR_STDOUT=1

# Diretório do script (para localizar o .env)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

setup_logging "$LOG_FILE" "$MIRROR_STDOUT"
setup_error_trap
log "$LOG_TAG" "Iniciando reset-usb (args: ${*:-<sem argumentos>})"

# -----------------------------------------------------------------------------
# FUNÇÃO: list_usb_devices
# -----------------------------------------------------------------------------
# Lista todos os dispositivos USB conectados de forma formatada
#
# SAÍDA:
#   Lista numerada de dispositivos com ID e descrição
#
# EXEMPLO DE SAÍDA:
#   1) 174c:1153 - ASMedia Technology Inc. ASM1153 SATA adapter
#   2) 0781:5583 - SanDisk Corp. Ultra Fit
# -----------------------------------------------------------------------------
list_usb_devices() {
    echo ""
    echo "=== Dispositivos USB Conectados ==="
    echo ""
    
    # Contador para numerar os dispositivos
    local i=1
    
    local lsusb_output
    if ! lsusb_output="$(lsusb 2>&1)"; then
        log_error "$LOG_TAG" "Falha ao executar lsusb: $lsusb_output"
        notify_error "$LOG_TAG" "Falha ao executar lsusb"
        return 1
    fi

    # Lê a saída do lsusb e processa cada linha
    # Formato típico: Bus 002 Device 003: ID 174c:1153 ASMedia Technology Inc. ASM1153
    while IFS= read -r line; do
        # Extrai o ID (vendor:product)
        local id
        id=$(echo "$line" | sed -n 's/.*ID \([0-9a-f]\{4\}:[0-9a-f]\{4\}\).*/\1/p')
        [[ -n "$id" ]] || continue
        
        # Extrai a descrição (tudo após o ID)
        local desc
        desc=$(echo "$line" | sed 's/.*ID [0-9a-f]\{4\}:[0-9a-f]\{4\} //')
        
        # Ignora hubs e dispositivos de sistema comuns
        if [[ "$desc" == *"Hub"* ]] || [[ "$desc" == *"root hub"* ]]; then
            continue
        fi
        
        # Imprime a linha formatada
        printf "%2d) %s - %s\n" "$i" "$id" "$desc"
        
        # Armazena em arrays para seleção posterior
        USB_IDS[$i]="$id"
        USB_DESCS[$i]="$desc"
        
        ((i++))
    done <<< "$lsusb_output"
    
    echo ""
    
    # Retorna o total de dispositivos listados
    return $((i - 1))
}

# -----------------------------------------------------------------------------
# FUNÇÃO: select_usb_device
# -----------------------------------------------------------------------------
# Permite ao usuário escolher um dispositivo USB da lista
#
# RETORNO:
#   Define SELECTED_USB_ID com o ID escolhido
# -----------------------------------------------------------------------------
select_usb_device() {
    # Arrays para armazenar os dispositivos
    declare -a USB_IDS
    declare -a USB_DESCS
    
    # Lista os dispositivos e obtém a contagem
    if ! list_usb_devices; then
        exit 1
    fi
    local total=$?
    
    if [[ $total -eq 0 ]]; then
        echo "Nenhum dispositivo USB encontrado (excluindo hubs)."
        exit 1
    fi
    
    # Solicita a escolha do usuário
    echo "Digite o número do dispositivo USB desejado (1-$total):"
    echo "(Este será salvo no .env para uso futuro)"
    echo ""
    read -rp "Escolha: " choice
    
    # Valida a entrada
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || [[ "$choice" -lt 1 ]] || [[ "$choice" -gt $total ]]; then
        echo "Escolha inválida: $choice"
        exit 1
    fi
    
    # Define o dispositivo selecionado
    SELECTED_USB_ID="${USB_IDS[$choice]}"
    SELECTED_USB_DESC="${USB_DESCS[$choice]}"
    
    echo ""
    echo "Dispositivo selecionado: $SELECTED_USB_ID - $SELECTED_USB_DESC"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: save_to_env
# -----------------------------------------------------------------------------
# Salva o ID do dispositivo USB selecionado no arquivo .env
#
# ARGUMENTOS:
#   $1 - ID do dispositivo (formato vendor:product)
#
# COMPORTAMENTO:
#   - Se USB_DEVICE_ID já existe no .env, atualiza o valor
#   - Se não existe, adiciona no final do arquivo
# -----------------------------------------------------------------------------
save_to_env() {
    local device_id="$1"
    local env_file="${SCRIPT_DIR}/.env"
    
    # Verifica se o arquivo .env existe
    if [[ ! -f "$env_file" ]]; then
        log_error "$LOG_TAG" "Arquivo .env não encontrado em $env_file"
        notify_error "$LOG_TAG" "Arquivo .env ausente: $env_file"
        exit 1
    fi
    
    # Verifica se a variável já existe no arquivo
    if grep -q "^USB_DEVICE_ID=" "$env_file"; then
        # Atualiza o valor existente usando sed
        # O padrão busca linhas que começam com USB_DEVICE_ID= e substitui
        sed -i "s/^USB_DEVICE_ID=.*/USB_DEVICE_ID=\"$device_id\"/" "$env_file"
        echo "✓ Atualizado USB_DEVICE_ID no .env"
    else
        # Adiciona a variável no final do arquivo
        echo "" >> "$env_file"
        echo "# ID do dispositivo USB (configurado via reset-usb.sh --select)" >> "$env_file"
        echo "USB_DEVICE_ID=\"$device_id\"" >> "$env_file"
        echo "✓ Adicionado USB_DEVICE_ID ao .env"
    fi
    
    echo ""
    echo "Configuração salva! Próximas execuções usarão: $device_id"
}

# -----------------------------------------------------------------------------
# FUNÇÃO: reset_usb_device
# -----------------------------------------------------------------------------
# Executa o reset do dispositivo USB configurado
#
# ARGUMENTOS:
#   $1 - ID do dispositivo (opcional, usa USB_DEVICE_ID do .env se não fornecido)
# -----------------------------------------------------------------------------
reset_usb_device() {
    local dev="${1:-$USB_DEVICE_ID}"
    
    # Verifica se temos um ID configurado
    if [[ -z "$dev" ]]; then
        log_error "$LOG_TAG" "Nenhum dispositivo USB configurado"
        echo ""
        echo "Execute com --select para escolher um dispositivo:"
        echo "  $0 --select"
        exit 1
    fi
    
    # Busca o dispositivo no lsusb
    local usb_info
    usb_info=$(lsusb | grep "$dev")
    
    if [[ -z "$usb_info" ]]; then
        log_error "$LOG_TAG" "Dispositivo $dev não encontrado"
        notify_error "$LOG_TAG" "Dispositivo USB $dev não encontrado"
        echo "Verifique se o dispositivo está conectado com: lsusb"
        exit 1
    fi
    
    # Extrai o número do barramento (Bus)
    local bus
    bus=$(echo "$usb_info" | awk '{print $2}')
    
    # Extrai o número do dispositivo (Device)
    local devnum
    devnum=$(echo "$usb_info" | awk '{print $4}' | sed 's/://')
    
    # Mostra informações do reset
    log_simple "$LOG_TAG" "Resetando dispositivo USB $dev"
    log_simple "$LOG_TAG" "Bus: $bus, Device: $devnum"
    log_simple "$LOG_TAG" "Caminho: /dev/bus/usb/$bus/$devnum"
    
    # Executa o reset
    if usbreset "/dev/bus/usb/$bus/$devnum"; then
        log "$LOG_TAG" "Reset concluído com sucesso para $dev em /dev/bus/usb/$bus/$devnum"
    else
        log_error "$LOG_TAG" "Erro ao resetar dispositivo $dev em /dev/bus/usb/$bus/$devnum"
        notify_error "$LOG_TAG" "Falha ao resetar USB $dev"
        exit 1
    fi
}

# -----------------------------------------------------------------------------
# PROCESSAMENTO DOS ARGUMENTOS
# -----------------------------------------------------------------------------
case "${1:-}" in
    --list|-l)
        # Apenas lista os dispositivos, sem interação
        list_usb_devices
        ;;
    
    --select|-s)
        # Modo interativo: lista, permite escolher e salva no .env
        echo "=== Seleção de Dispositivo USB ==="
        select_usb_device
        
        # Confirma antes de salvar
        echo ""
        read -rp "Salvar '$SELECTED_USB_ID' no .env? (s/n): " confirm
        
        if [[ "${confirm,,}" == "s" ]] || [[ "${confirm,,}" == "y" ]]; then
            save_to_env "$SELECTED_USB_ID"
        else
            echo "Operação cancelada."
        fi
        ;;
    
    --help|-h)
        # Mostra ajuda
        echo "Uso: $0 [OPÇÃO]"
        echo ""
        echo "Opções:"
        echo "  (sem opção)    Reseta o dispositivo USB configurado no .env"
        echo "  --select, -s   Lista dispositivos e permite escolher/salvar no .env"
        echo "  --list, -l     Apenas lista os dispositivos USB conectados"
        echo "  --help, -h     Mostra esta ajuda"
        echo ""
        echo "Dispositivo atual configurado: ${USB_DEVICE_ID:-<não configurado>}"
        ;;
    
    "")
        # Sem argumentos: executa o reset do dispositivo configurado
        reset_usb_device
        ;;
    
    *)
        echo "Opção desconhecida: $1"
        echo "Use --help para ver as opções disponíveis."
        exit 1
        ;;
esac
