#!/usr/bin/env bash
set -euo pipefail

# Instala todos os arquivos do diretório atual em /usr/local/bin,
# incluindo arquivos ocultos como .env.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${DEST_DIR:-/usr/local/bin}"

copy_file() {
    local src="$1"
    local dst="$2"
    cp -f "$src" "$dst"
    chmod --reference="$src" "$dst"
}

main() {
    if [[ ! -d "$DEST_DIR" ]]; then
        mkdir -p "$DEST_DIR"
    fi

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

    echo ""
    echo "Concluído: $copied arquivo(s) copiado(s), $skipped ignorado(s)."
    echo "Destino: $DEST_DIR"
}

main "$@"
