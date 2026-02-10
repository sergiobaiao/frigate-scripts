#!/usr/bin/env bash
set -euo pipefail

# list_files_by_date.sh
# Uso:
#   ./list_files_by_date.sh /caminho
#   ./list_files_by_date.sh /caminho --time mtime|ctime|atime
#   ./list_files_by_date.sh /caminho --csv /tmp/relatorio.csv
#   ./list_files_by_date.sh /caminho --follow-symlinks

TIME_FIELD="mtime"   # mtime | ctime | atime
CSV_OUT=""
FOLLOW_SYMLINKS=0

usage() {
  cat <<'EOF'
Uso:
  list_files_by_date.sh PATH [--time mtime|ctime|atime] [--csv ARQ.csv] [--follow-symlinks]

Gera relatório consolidado por data (YYYY-MM-DD) para todos os arquivos regulares em PATH (recursivo).

Opções:
  --time            Qual timestamp consolidar:
                    mtime (modificação), ctime (mudança de metadata), atime (acesso)
  --csv             Salva também em CSV (data,arquivos,bytes)
  --follow-symlinks Segue symlinks (cuidado com loops)
EOF
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

ROOT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --time)
      TIME_FIELD="${2:-}"
      shift 2
      ;;
    --csv)
      CSV_OUT="${2:-}"
      shift 2
      ;;
    --follow-symlinks)
      FOLLOW_SYMLINKS=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -z "${ROOT}" ]]; then
        ROOT="$1"
        shift
      else
        echo "Argumento desconhecido: $1" >&2
        usage
        exit 1
      fi
      ;;
  esac
done

if [[ -z "${ROOT}" ]]; then
  echo "ERRO: PATH não informado." >&2
  usage
  exit 1
fi

if [[ ! -d "${ROOT}" ]]; then
  echo "ERRO: Diretório não existe: ${ROOT}" >&2
  exit 1
fi

case "${TIME_FIELD}" in
  mtime|ctime|atime) ;;
  *)
    echo "ERRO: --time deve ser mtime, ctime ou atime (recebido: ${TIME_FIELD})." >&2
    exit 1
    ;;
esac

# Define o formato do stat conforme o tipo de tempo escolhido.
# GNU stat:
#   %y = mtime human
#   %z = ctime human
#   %x = atime human
STAT_TIME_FMT="%y"
case "${TIME_FIELD}" in
  mtime) STAT_TIME_FMT="%y" ;;
  ctime) STAT_TIME_FMT="%z" ;;
  atime) STAT_TIME_FMT="%x" ;;
esac

# find flags
FIND_FLAGS=()
if [[ "${FOLLOW_SYMLINKS}" -eq 1 ]]; then
  FIND_FLAGS+=("-L")
fi

# Coleta: data(YYYY-MM-DD) e tamanho(bytes) de cada arquivo regular
# Depois consolida por data somando contagem e bytes.
# Observação: usa NUL como separador para aguentar nomes com espaço/newline.
report="$(
  find "${FIND_FLAGS[@]}" "${ROOT}" -type f -print0 \
  | xargs -0 -r stat --printf="${STAT_TIME_FMT}\t%s\n" \
  | awk -F'\t' '
      {
        # $1: timestamp tipo "YYYY-MM-DD HH:MM:SS.######### +TZ"
        # pega somente a data:
        split($1, a, " ");
        d=a[1];

        files[d] += 1;
        bytes[d] += $2;

        total_files += 1;
        total_bytes += $2;
      }
      END {
        # imprime ordenado por data (YYYY-MM-DD ordena lexicograficamente)
        # gawk suporta PROCINFO["sorted_in"]; se não tiver, usamos sort fora.
        for (d in files) {
          printf "%s\t%d\t%d\n", d, files[d], bytes[d];
        }
        # totals em linhas separadas (prefixadas) para processarmos depois
        printf "__TOTAL__\t%d\t%d\n", total_files, total_bytes;
      }
    ' \
  | sort
)"

# Separa totais da lista (a linha __TOTAL__ fica no final por causa do sort)
totals_line="$(echo "$report" | tail -n 1)"
data_lines="$(echo "$report" | sed '$d')"

total_files="$(echo "$totals_line" | awk -F'\t' '{print $2}')"
total_bytes="$(echo "$totals_line" | awk -F'\t' '{print $3}')"

human_bytes() {
  # converte bytes para formato humano (KiB, MiB, GiB...)
  local b="$1"
  awk -v b="$b" '
    function human(x,  units, i) {
      split("B KiB MiB GiB TiB PiB EiB", units, " ");
      i=1;
      while (x>=1024 && i<7) { x/=1024; i++; }
      return sprintf("%.2f %s", x, units[i]);
    }
    BEGIN { print human(b); }
  '
}

echo "Relatório consolidado por data (${TIME_FIELD})"
echo "Root: ${ROOT}"
echo
printf "%-12s  %12s  %15s  %12s\n" "Data" "Arquivos" "Bytes" "Bytes(h)"
printf "%-12s  %12s  %15s  %12s\n" "------------" "------------" "---------------" "----------"

# imprime tabela
echo "$data_lines" | awk -F'\t' -v hb_func=1 '
  function human(x,  units, i) {
    split("B KiB MiB GiB TiB PiB EiB", units, " ");
    i=1;
    while (x>=1024 && i<7) { x/=1024; i++; }
    return sprintf("%.2f %s", x, units[i]);
  }
  {
    printf "%-12s  %12d  %15d  %12s\n", $1, $2, $3, human($3);
  }
'

echo
echo "TOTAL: ${total_files} arquivos, ${total_bytes} bytes ($(human_bytes "$total_bytes"))"

# CSV opcional
if [[ -n "${CSV_OUT}" ]]; then
  {
    echo "date,files,bytes"
    echo "$data_lines" | awk -F'\t' '{printf "%s,%s,%s\n",$1,$2,$3}'
  } > "${CSV_OUT}"
  echo "CSV gerado em: ${CSV_OUT}"
fi
