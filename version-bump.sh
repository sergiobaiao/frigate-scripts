#!/usr/bin/env bash
# VERSION: 1.8
set -euo pipefail

usage() {
  cat <<'USAGE'
Uso:
  ./version-bump.sh --all
  ./version-bump.sh arquivo1 [arquivo2 ...]

Incrementa a versão no marcador "VERSION: X.Y" de cada arquivo.
Regra de incremento:
  - incrementa 0.1 (ex.: 1.0 -> 1.1, 1.9 -> 2.0)

Se o arquivo não possuir marcador VERSION, ele será iniciado em 1.0.
USAGE
}

bump_version_value() {
  local current="$1"
  local major minor
  major="${current%%.*}"
  minor="${current#*.}"

  if ! [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]]; then
    echo "1.0"
    return
  fi

  minor=$((minor + 1))
  if (( minor >= 10 )); then
    major=$((major + 1))
    minor=0
  fi
  echo "${major}.${minor}"
}

bump_file() {
  local file="$1"
  local was_exec=0

  if [[ ! -f "$file" ]]; then
    echo "[WARN] Arquivo não encontrado: $file" >&2
    return 0
  fi

  [[ -x "$file" ]] && was_exec=1

  local line current next_version
  line="$(grep -n -m1 'VERSION:' "$file" || true)"

  if [[ -z "$line" ]]; then
    if [[ "$(head -n1 "$file")" =~ ^#! ]]; then
      awk 'NR==1{print; print "# VERSION: 1.0"; next} {print}' "$file" > "$file.tmp"
    elif [[ "$file" == "README.md" ]]; then
      awk 'NR==1{print; print ""; print "> VERSION: 1.0"; next} {print}' "$file" > "$file.tmp"
    else
      awk 'NR==1{print "# VERSION: 1.0"} {print}' "$file" > "$file.tmp"
    fi
    mv "$file.tmp" "$file"
    (( was_exec == 1 )) && chmod +x "$file"
    echo "[OK] $file -> 1.0"
    return 0
  fi

  local ln
  ln="${line%%:*}"
  current="$(echo "$line" | sed -E 's/.*VERSION:[[:space:]]*([0-9]+\.[0-9]+).*/\1/')"
  next_version="$(bump_version_value "$current")"

  awk -v target="$ln" -v next_version="$next_version" '
    NR==target {
      sub(/VERSION:[[:space:]]*[0-9]+\.[0-9]+/, "VERSION: " next_version)
    }
    {print}
  ' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
  (( was_exec == 1 )) && chmod +x "$file"

  echo "[OK] $file -> $current -> $next_version"
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
  usage
  exit 0
fi

files=()
if [[ "$1" == "--all" ]]; then
  mapfile -t files < <(rg --files)
else
  files=("$@")
fi

for f in "${files[@]}"; do
  bump_file "$f"
done
