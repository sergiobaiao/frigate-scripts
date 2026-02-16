#!/usr/bin/env bash
# VERSION: 1.1
set -euo pipefail

# Instala todos os arquivos do diretório atual em /usr/local/sbin
# e recria o crontab do root apenas com os jobs do Frigate.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${DEST_DIR:-/usr/local/sbin}"
LOG_DIR="${LOG_DIR:-/var/log/frigate}"

copy_file() {
    local src="$1"
    local dst="$2"
    cp -f "$src" "$dst"
    chmod --reference="$src" "$dst"
}

assert_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo "ERRO: execute este instalador como root."
        exit 1
    fi
}

install_cron() {
    local cron_tmp backup_file timestamp
    cron_tmp="$(mktemp)"
    timestamp="$(date +%Y%m%d-%H%M%S)"
    backup_file="/var/backups/root-crontab-${timestamp}.bak"

    mkdir -p /var/backups
    if crontab -l >/dev/null 2>&1; then
        crontab -l > "$backup_file"
        echo "Backup do crontab atual salvo em: $backup_file"
    else
        echo "Nenhum crontab anterior encontrado para root."
    fi

    cat > "$cron_tmp" <<'EOF'
20 3 * * * /usr/local/sbin/frigate-mover.sh >> /var/log/frigate/frigate-mover.log 2>&1

# Limpa HD quando espaço livre < 15% (diário às 3h)
10 * * * * /usr/local/sbin/frigate-prune-hd.sh

# Remove clips antigos (diário às 4h)
20 3 * * * /usr/local/sbin/frigate-retention.sh

# Watchdog do SSD - verifica a cada minuto
* * * * * /usr/local/sbin/hd-watchdog-min.sh

# Vacuum de emergência (a cada 6 horas)
*/15 * * * * /usr/local/sbin/frigate-vacuum.sh >> /var/log/frigate/frigate-vacuum.log 2>&1
EOF

    crontab "$cron_tmp"
    rm -f "$cron_tmp"
    echo "Crontab do root atualizado: apenas agendamentos Frigate foram mantidos."
}

main() {
    assert_root

    if [[ ! -d "$DEST_DIR" ]]; then
        mkdir -p "$DEST_DIR"
    fi
    mkdir -p "$LOG_DIR"

    local copied=0
    local skipped=0

    while IFS= read -r -d '' src; do
        local name
        name="$(basename "$src")"

        # Não instala arquivos de metadados de controle de versão.
        if [[ "$name" == ".gitignore" || "$name" == ".git" ]]; then
            ((++skipped))
            continue
        fi

        copy_file "$src" "$DEST_DIR/$name"
        echo "Instalado: $name -> $DEST_DIR/$name"
        ((++copied))
    done < <(find "$SCRIPT_DIR" -mindepth 1 -maxdepth 1 -type f -print0)

    install_cron

    echo ""
    echo "Concluído: $copied arquivo(s) copiado(s), $skipped ignorado(s)."
    echo "Destino: $DEST_DIR"
    echo "Logs: $LOG_DIR"
}

main "$@"
