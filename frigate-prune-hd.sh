#!/usr/bin/env bash
# VERSION: 1.7
# =============================================================================
# FRIGATE-PRUNE-HD.SH
# =============================================================================
# Limpa gravações antigas do HD externo quando o espaço está baixo.
#
# DESCRIÇÃO:
#   Este script monitora o espaço livre no HD externo e remove os dias mais
#   antigos de gravações até atingir a porcentagem mínima de espaço livre
#   configurada.
#
# FUNCIONAMENTO:
#   1. Verifica a porcentagem de espaço livre no HD
#   2. Se estiver abaixo do mínimo (MIN_FREE_PCT):
#      a. Encontra o diretório de data mais antigo (YYYY-MM-DD)
#      b. Remove completamente esse diretório
#      c. Repete até atingir o espaço livre mínimo
#   3. Limpa diretórios vazios residuais
#
# USO:
#   ./frigate-prune-hd.sh
#   ./frigate-prune-hd.sh --dry-run
#
# CONFIGURAÇÕES (via .env):
#   MIN_FREE_PCT - Porcentagem mínima de espaço livre (padrão: 15)
#
# LOGS:
#   As operações são registradas em /var/log/frigate-prune-hd.log
#
# AUTOR: Sistema Marquise
# =============================================================================

# -----------------------------------------------------------------------------
# CARREGA CONFIGURAÇÕES E FUNÇÕES COMPARTILHADAS
# -----------------------------------------------------------------------------
source "$(dirname "$0")/common.sh"

# Tag para identificação nos logs
LOG_TAG="prune"
DRY_RUN="${DRY_RUN:-0}"
MANUAL_BEFORE_DATE=""
MANUAL_MODE="date-dir"
MANUAL_ROOT=""

# Expressão regular para validar diretórios de data
DATE_RE='^20[0-9]{2}-[0-9]{2}-[0-9]{2}$'

show_help() {
    cat <<EOF
Uso: ./frigate-prune-hd.sh [OPÇÕES]

Opções:
  --dry-run      Simula a limpeza sem remover diretórios
  --before-date  Remove manualmente tudo anterior a YYYY-MM-DD
                 Exemplo: --before-date 2026-02-01
  --manual-mode  Modo manual: date-dir (padrão) ou mtime
                 date-dir: remove por nome da pasta de data (YYYY-MM-DD)
                 mtime: remove por mtime real dos arquivos
  --stdout       Também imprime logs no terminal (além do arquivo)
  --help, -h     Mostra esta ajuda
EOF
}

MIRROR_STDOUT=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            ;;
        --before-date)
            MANUAL_BEFORE_DATE="${2:-}"
            shift
            ;;
        --before-date=*)
            MANUAL_BEFORE_DATE="${1#*=}"
            ;;
        --manual-mode)
            MANUAL_MODE="${2:-}"
            shift
            ;;
        --manual-mode=*)
            MANUAL_MODE="${1#*=}"
            ;;
        --stdout)
            MIRROR_STDOUT=1
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

if [[ -n "$MANUAL_BEFORE_DATE" ]]; then
    if ! [[ "$MANUAL_BEFORE_DATE" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]] || ! date -d "$MANUAL_BEFORE_DATE" +%F >/dev/null 2>&1; then
        echo "[ERRO] Data inválida para --before-date: $MANUAL_BEFORE_DATE (use YYYY-MM-DD)" >&2
        exit 1
    fi
fi

if [[ "$MANUAL_MODE" != "date-dir" && "$MANUAL_MODE" != "mtime" ]]; then
    echo "[ERRO] --manual-mode inválido: $MANUAL_MODE (use date-dir ou mtime)" >&2
    exit 1
fi

# -----------------------------------------------------------------------------
# CONFIGURAÇÃO DE LOGS
# -----------------------------------------------------------------------------
# Resolve arquivo de lock com fallback para /tmp quando necessário
LOCK_FILE="${LOCK_MEDIA:-/tmp/frigate-media.lock}"
if ! mkdir -p "$(dirname "$LOCK_FILE")" 2>/dev/null || ! (: >>"$LOCK_FILE") 2>/dev/null; then
    LOCK_FILE="${SCRIPT_DIR}/.runtime/frigate-media.lock"
    mkdir -p "$(dirname "$LOCK_FILE")"
    : >>"$LOCK_FILE"
fi

# Resolve arquivo de log com fallback para /tmp quando necessário
LOG_FILE="${LOG_PRUNE:-/tmp/frigate-prune-hd.log}"
setup_logging "$LOG_FILE" "$MIRROR_STDOUT"
setup_error_trap

# -----------------------------------------------------------------------------
# AQUISIÇÃO DO LOCK
# -----------------------------------------------------------------------------
# Usa file descriptor 9 para o lock
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
    log "$LOG_TAG" "Lock ocupado por outro processo, saindo."
    exit 0
fi

# -----------------------------------------------------------------------------
# FUNÇÃO: free_pct
# -----------------------------------------------------------------------------
# Retorna a porcentagem de espaço livre no HD externo
#
# RETORNO:
#   Número inteiro representando % de espaço livre
# -----------------------------------------------------------------------------
free_pct() {
    get_disk_free_pct "$HD_MOUNT"
}

mount_total_bytes() {
    df -PB1 "$HD_MOUNT" | awk 'NR==2{print $2}'
}

mount_free_bytes() {
    df -PB1 "$HD_MOUNT" | awk 'NR==2{print $4}'
}

date_dirs_for_media() {
    local root="$1"
    local media="$2"

    [[ -d "$root" ]] || return 0

    find "$root" -mindepth 1 -maxdepth 2 -type d -printf "%p\n" 2>/dev/null \
        | awk -F/ -v re="$DATE_RE" -v media="$media" '$NF ~ re {printf "%s\t%s\t%s\n", $NF, media, $0}' \
        | sort
}

# -----------------------------------------------------------------------------
# INÍCIO DO PROCESSAMENTO
# -----------------------------------------------------------------------------
log "$LOG_TAG" "Iniciando verificação de espaço"
[[ "$DRY_RUN" == "1" ]] && log "$LOG_TAG" "Modo DRY-RUN ativo (simulação sem remoções)"
if [[ -n "$MANUAL_BEFORE_DATE" ]]; then
    log "$LOG_TAG" "Modo MANUAL ativo: remover tudo anterior a $MANUAL_BEFORE_DATE (modo=$MANUAL_MODE)"
fi

# Verifica se ao menos um diretório de mídia existe
if [[ ! -d "$HD_RECORDINGS" ]]; then
    if [[ ! -d "$HD_CLIPS" && ! -d "$HD_EXPORTS" && ! -d "$HD_SNAPSHOTS" ]]; then
        log "$LOG_TAG" "Nenhum diretório de mídia existe em HD (recordings/clips/exports/snapshots)"
        exit 0
    fi
fi

# Coleta candidatos de recordings, clips, exports e snapshots
mapfile -t candidates < <(
    {
        date_dirs_for_media "$HD_RECORDINGS" "recordings"
        date_dirs_for_media "$HD_CLIPS" "clips"
        date_dirs_for_media "$HD_EXPORTS" "exports"
        date_dirs_for_media "$HD_SNAPSHOTS" "snapshots"
    } | sort
)

if (( ${#candidates[@]} == 0 )); then
    log "$LOG_TAG" "Nenhum diretório de data encontrado em recordings/clips/exports/snapshots no HD"
    exit 0
fi

rec_dates=()
clip_dates=()
exports_dates=()
snapshots_dates=()
removed_count=0
freed_bytes=0
simulated_freed=0

# -----------------------------------------------------------------------------
# MODO MANUAL POR DATA
# -----------------------------------------------------------------------------
if [[ -n "$MANUAL_BEFORE_DATE" ]]; then
    if [[ "$MANUAL_MODE" == "date-dir" ]]; then
        log "$LOG_TAG" "Critério manual: remove apenas diretórios de data (YYYY-MM-DD) em recordings/clips/exports/snapshots no HD"

        older_candidates=0
        for entry in "${candidates[@]}"; do
            IFS=$'\t' read -r day _media _path <<< "$entry"
            [[ "$day" < "$MANUAL_BEFORE_DATE" ]] && ((++older_candidates))
        done
        log "$LOG_TAG" "Candidatos com data < $MANUAL_BEFORE_DATE: $older_candidates"

        for entry in "${candidates[@]}"; do
            IFS=$'\t' read -r day media path <<< "$entry"

            [[ "$day" < "$MANUAL_BEFORE_DATE" ]] || continue

            size_b="$(du -sb "$path" 2>/dev/null | awk '{print $1}')"
            size_b="${size_b:-0}"

            if [[ "$DRY_RUN" == "1" ]]; then
                log "$LOG_TAG" "[DRY-RUN] Removeria ($media): $path (data=$day, tamanho=$(bytes_human "$size_b"))"
                simulated_freed=$((simulated_freed + size_b))
            else
                log "$LOG_TAG" "Removendo manualmente ($media): $path (data=$day, tamanho=$(bytes_human "$size_b"))"
                if rm -rf "$path"; then
                    freed_bytes=$((freed_bytes + size_b))
                else
                    log_error "$LOG_TAG" "Falha ao remover manualmente ($media): $path"
                    notify_error "$LOG_TAG" "Falha ao remover manualmente $path"
                    continue
                fi
            fi

            ((++removed_count))
            case "$media" in
                recordings) rec_dates+=("$day") ;;
                clips) clip_dates+=("$day") ;;
                exports) exports_dates+=("$day") ;;
                snapshots) snapshots_dates+=("$day") ;;
            esac
        done

        [[ -d "$HD_RECORDINGS" ]] && find "$HD_RECORDINGS" -mindepth 1 -type d -empty -delete 2>/dev/null || true
        [[ -d "$HD_CLIPS" ]] && find "$HD_CLIPS" -mindepth 1 -type d -empty -delete 2>/dev/null || true
        [[ -d "$HD_EXPORTS" ]] && find "$HD_EXPORTS" -mindepth 1 -type d -empty -delete 2>/dev/null || true
        [[ -d "$HD_SNAPSHOTS" ]] && find "$HD_SNAPSHOTS" -mindepth 1 -type d -empty -delete 2>/dev/null || true
    else
        MANUAL_ROOT="${HD_MOUNT}/frigate"
        [[ -d "$MANUAL_ROOT" ]] || MANUAL_ROOT="$HD_MOUNT"

        log "$LOG_TAG" "Critério manual: remove por mtime dos arquivos em $MANUAL_ROOT (corte < ${MANUAL_BEFORE_DATE} 00:00:00)"

        while IFS= read -r -d '' rec; do
            IFS=$'\t' read -r file_day size_b file_path <<< "$rec"
            size_b="${size_b:-0}"

            media="other"
            [[ "$file_path" == *"/recordings/"* ]] && media="recordings"
            [[ "$file_path" == *"/clips/"* ]] && media="clips"
            [[ "$file_path" == *"/exports/"* ]] && media="exports"
            [[ "$file_path" == *"/snapshots/"* ]] && media="snapshots"

            if [[ "$DRY_RUN" == "1" ]]; then
                simulated_freed=$((simulated_freed + size_b))
            else
                if rm -f "$file_path"; then
                    freed_bytes=$((freed_bytes + size_b))
                else
                    log_error "$LOG_TAG" "Falha ao remover arquivo manualmente: $file_path"
                    notify_error "$LOG_TAG" "Falha ao remover arquivo manual: $file_path"
                    continue
                fi
            fi

            ((++removed_count))
            case "$media" in
                recordings) rec_dates+=("$file_day") ;;
                clips) clip_dates+=("$file_day") ;;
                exports) exports_dates+=("$file_day") ;;
                snapshots) snapshots_dates+=("$file_day") ;;
            esac
        done < <(
            find "$MANUAL_ROOT" -type f ! -newermt "${MANUAL_BEFORE_DATE} 00:00:00" \
                -printf '%TY-%Tm-%Td\t%s\t%p\0' 2>/dev/null
        )

        [[ -d "$MANUAL_ROOT" ]] && find "$MANUAL_ROOT" -mindepth 1 -type d -empty -delete 2>/dev/null || true
        log "$LOG_TAG" "Candidatos por mtime com data < $MANUAL_BEFORE_DATE: $removed_count arquivo(s)"
    fi

    if (( ${#rec_dates[@]} > 0 )); then
        rec_summary="$(printf '%s\n' "${rec_dates[@]}" | sort -u | paste -sd, -)"
        log "$LOG_TAG" "Datas removidas/afetadas (recordings): $rec_summary"
    else
        log "$LOG_TAG" "Datas removidas/afetadas (recordings): nenhuma"
    fi

    if (( ${#clip_dates[@]} > 0 )); then
        clip_summary="$(printf '%s\n' "${clip_dates[@]}" | sort -u | paste -sd, -)"
        log "$LOG_TAG" "Datas removidas/afetadas (clips): $clip_summary"
    else
        log "$LOG_TAG" "Datas removidas/afetadas (clips): nenhuma"
    fi

    if (( ${#exports_dates[@]} > 0 )); then
        exports_summary="$(printf '%s\n' "${exports_dates[@]}" | sort -u | paste -sd, -)"
        log "$LOG_TAG" "Datas removidas/afetadas (exports): $exports_summary"
    else
        log "$LOG_TAG" "Datas removidas/afetadas (exports): nenhuma"
    fi

    if (( ${#snapshots_dates[@]} > 0 )); then
        snapshots_summary="$(printf '%s\n' "${snapshots_dates[@]}" | sort -u | paste -sd, -)"
        log "$LOG_TAG" "Datas removidas/afetadas (snapshots): $snapshots_summary"
    else
        log "$LOG_TAG" "Datas removidas/afetadas (snapshots): nenhuma"
    fi

    if [[ "$DRY_RUN" == "1" ]]; then
        log "$LOG_TAG" "[DRY-RUN] Resumo manual: removidos=$removed_count bytes_estimados=$(bytes_human "$simulated_freed") corte<$MANUAL_BEFORE_DATE modo=$MANUAL_MODE"
    else
        log "$LOG_TAG" "Resumo manual: removidos=$removed_count bytes_liberados=$(bytes_human "$freed_bytes") corte<$MANUAL_BEFORE_DATE modo=$MANUAL_MODE"
    fi

    if (( removed_count == 0 )); then
        if [[ "$MANUAL_MODE" == "date-dir" ]]; then
            log "$LOG_TAG" "Nenhuma pasta de data anterior ao corte foi encontrada no HD"
        else
            log "$LOG_TAG" "Nenhum arquivo com mtime anterior ao corte foi encontrado no HD"
        fi
    fi

    log "$LOG_TAG" "Limpeza manual concluída"
    exit 0
fi

# Obtém a porcentagem atual de espaço livre
free="$(free_pct)"
log "$LOG_TAG" "Espaço livre: ${free}% (mínimo: ${MIN_FREE_PCT}%)"

# -----------------------------------------------------------------------------
# VERIFICAÇÃO DE NECESSIDADE
# -----------------------------------------------------------------------------
# Se já temos espaço suficiente, não há nada a fazer
if (( free >= MIN_FREE_PCT )); then
    log "$LOG_TAG" "Espaço suficiente. Nenhuma ação necessária."
    exit 0
fi

# -----------------------------------------------------------------------------
# LOOP DE LIMPEZA
# -----------------------------------------------------------------------------
# Continua removendo dias antigos até atingir o espaço livre mínimo
if [[ "$DRY_RUN" == "1" ]]; then
    total_b="$(mount_total_bytes)"
    free_b="$(mount_free_bytes)"
    required_b=$(( (total_b * MIN_FREE_PCT + 99) / 100 ))
    needed_b=$(( required_b - free_b ))
    (( needed_b < 0 )) && needed_b=0
    simulated_freed=0

    log "$LOG_TAG" "Simulação: necessário liberar ~$(numfmt --to=iec --suffix=B "$needed_b" 2>/dev/null || echo "${needed_b}B")"

    for entry in "${candidates[@]}"; do
        (( free >= MIN_FREE_PCT )) && break

        IFS=$'\t' read -r day media path <<< "$entry"
        size_b="$(du -sb "$path" 2>/dev/null | awk '{print $1}')"
        size_b="${size_b:-0}"

        log "$LOG_TAG" "[DRY-RUN] Removeria ($media): $path ($(numfmt --to=iec --suffix=B "$size_b" 2>/dev/null || echo "${size_b}B"))"
        ((++removed_count))
        simulated_freed=$((simulated_freed + size_b))

        case "$media" in
            recordings) rec_dates+=("$day") ;;
            clips) clip_dates+=("$day") ;;
            exports) exports_dates+=("$day") ;;
            snapshots) snapshots_dates+=("$day") ;;
        esac

        free_b=$((free_b + size_b))
        free=$(( (free_b * 100) / total_b ))
        log "$LOG_TAG" "[DRY-RUN] Espaço livre estimado: ${free}% (mínimo: ${MIN_FREE_PCT}%)"
    done
else
    while (( free < MIN_FREE_PCT )); do
        if (( removed_count >= ${#candidates[@]} )); then
            log "$LOG_TAG" "Sem mais diretórios candidatos para remoção"
            break
        fi

        entry="${candidates[$removed_count]}"
        IFS=$'\t' read -r day media oldest <<< "$entry"
        size_b="$(du -sb "$oldest" 2>/dev/null | awk '{print $1}')"
        size_b="${size_b:-0}"

        log "$LOG_TAG" "Removendo ($media): $oldest (tamanho=$(bytes_human "$size_b"))"
        if rm -rf "$oldest"; then
            freed_bytes=$((freed_bytes + size_b))
        else
            log_error "$LOG_TAG" "Falha ao remover ($media): $oldest"
            notify_error "$LOG_TAG" "Falha ao remover $oldest"
            continue
        fi

        case "$media" in
            recordings) rec_dates+=("$day") ;;
            clips) clip_dates+=("$day") ;;
            exports) exports_dates+=("$day") ;;
            snapshots) snapshots_dates+=("$day") ;;
        esac

        ((++removed_count))

        find "$HD_RECORDINGS" -mindepth 1 -type d -empty -delete 2>/dev/null || true
        find "$HD_CLIPS" -mindepth 1 -type d -empty -delete 2>/dev/null || true
        find "$HD_EXPORTS" -mindepth 1 -type d -empty -delete 2>/dev/null || true
        find "$HD_SNAPSHOTS" -mindepth 1 -type d -empty -delete 2>/dev/null || true

        free="$(free_pct)"
        log "$LOG_TAG" "Espaço livre atual: ${free}% (mínimo: ${MIN_FREE_PCT}%)"
    done
fi

if (( ${#rec_dates[@]} > 0 )); then
    rec_summary="$(printf '%s\n' "${rec_dates[@]}" | sort -u | paste -sd, -)"
    log "$LOG_TAG" "Datas removidas/afetadas (recordings): $rec_summary"
else
    log "$LOG_TAG" "Datas removidas/afetadas (recordings): nenhuma"
fi

if (( ${#clip_dates[@]} > 0 )); then
    clip_summary="$(printf '%s\n' "${clip_dates[@]}" | sort -u | paste -sd, -)"
    log "$LOG_TAG" "Datas removidas/afetadas (clips): $clip_summary"
else
    log "$LOG_TAG" "Datas removidas/afetadas (clips): nenhuma"
fi

if (( ${#exports_dates[@]} > 0 )); then
    exports_summary="$(printf '%s\n' "${exports_dates[@]}" | sort -u | paste -sd, -)"
    log "$LOG_TAG" "Datas removidas/afetadas (exports): $exports_summary"
else
    log "$LOG_TAG" "Datas removidas/afetadas (exports): nenhuma"
fi

if (( ${#snapshots_dates[@]} > 0 )); then
    snapshots_summary="$(printf '%s\n' "${snapshots_dates[@]}" | sort -u | paste -sd, -)"
    log "$LOG_TAG" "Datas removidas/afetadas (snapshots): $snapshots_summary"
else
    log "$LOG_TAG" "Datas removidas/afetadas (snapshots): nenhuma"
fi

# -----------------------------------------------------------------------------
# FINALIZAÇÃO
# -----------------------------------------------------------------------------
if (( free >= MIN_FREE_PCT )); then
    log "$LOG_TAG" "Meta de espaço livre atingida: ${free}%"
else
    log_warn "$LOG_TAG" "Meta não atingida: espaço livre final ${free}% (mínimo ${MIN_FREE_PCT}%)"
    notify_error "$LOG_TAG" "Prune finalizou abaixo da meta: ${free}% livre (mínimo ${MIN_FREE_PCT}%)"
fi

if [[ "$DRY_RUN" == "1" ]]; then
    log "$LOG_TAG" "[DRY-RUN] Resumo: candidatos_removidos=$removed_count bytes_estimados=$(bytes_human "${simulated_freed:-0}")"
else
    log "$LOG_TAG" "Resumo: removidos=$removed_count bytes_liberados=$(bytes_human "$freed_bytes") free_final=${free}%"
fi
log "$LOG_TAG" "Limpeza concluída"
