#!/usr/bin/env bash
# VERSION: 1.8
set -euo pipefail

# Instala os scripts em /usr/local/sbin, instala /etc/cron.d/frigate-cron
# e zera o crontab pessoal do root.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${DEST_DIR:-/usr/local/sbin}"
LOG_DIR="${LOG_DIR:-/var/log/frigate}"
CRON_SOURCE="${CRON_SOURCE:-$SCRIPT_DIR/frigate-cron}"
CRON_DEST="${CRON_DEST:-/etc/cron.d/frigate-cron}"

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

install_cron_d() {
    if [[ ! -f "$CRON_SOURCE" ]]; then
        echo "ERRO: arquivo de cron não encontrado: $CRON_SOURCE"
        exit 1
    fi

    install -o root -g root -m 0644 "$CRON_SOURCE" "$CRON_DEST"
    echo "Cron instalado em: $CRON_DEST"
}

clear_root_user_crontab() {
    local backup_file timestamp
    timestamp="$(date +%Y%m%d-%H%M%S)"
    backup_file="/var/backups/root-crontab-${timestamp}.bak"

    mkdir -p /var/backups
    if crontab -l >/dev/null 2>&1; then
        crontab -l > "$backup_file"
        echo "Backup do crontab pessoal do root salvo em: $backup_file"
        crontab -r
        echo "Crontab pessoal do root removido."
    else
        echo "Crontab pessoal do root já estava vazio."
    fi
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

        # Não instala metadados, backups e arquivo de cron dedicado.
        if [[ "$name" == ".gitignore" || "$name" == ".git" || "$name" == "frigate-cron" ]]; then
            ((++skipped))
            continue
        fi
        if [[ "$name" == .* && "$name" != ".env" ]]; then
            ((++skipped))
            continue
        fi
        if [[ "$name" == *.bak.* || "$name" == ".env.bak." || "$name" == "changelog.md" || "$name" == "README.md" ]]; then
            ((++skipped))
            continue
        fi

        copy_file "$src" "$DEST_DIR/$name"
        echo "Instalado: $name -> $DEST_DIR/$name"
        ((++copied))
    done < <(find "$SCRIPT_DIR" -mindepth 1 -maxdepth 1 -type f -print0)

    install_cron_d
    clear_root_user_crontab

    echo ""
    echo "Concluído: $copied arquivo(s) copiado(s), $skipped ignorado(s)."
    echo "Destino: $DEST_DIR"
    echo "Logs: $LOG_DIR"
    echo "Cron: $CRON_DEST"
}

main "$@"
