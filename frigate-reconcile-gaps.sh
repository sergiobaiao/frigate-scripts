#!/usr/bin/env bash
# VERSION: 1.8
set -Eeuo pipefail

source "$(dirname "$0")/common.sh"

LOG_TAG="reconcile"
LOG_FILE="${LOG_RECONCILE:-/var/log/frigate-reconcile.log}"

SOURCE_ROOT="$(readlink -f "$SSD_RECORDINGS")"
DEST_ROOT="$(readlink -f "$HD_RECORDINGS")"
RECONCILE_MIN_AGE_MINUTES="${RECONCILE_MIN_AGE_MINUTES:-120}"
RECONCILE_MAX_DIRS_PER_RUN="${RECONCILE_MAX_DIRS_PER_RUN:-20}"
BWLIMIT="${BWLIMIT:-8000}"
DRY_RUN=0
MIRROR_STDOUT=0

run_rsync() {
  local step_label="${1:-transfer}"
  shift
  local err_file rc err_tail

  err_file="$(mktemp)"
  rc=0
  rsync "$@" 2>"$err_file" || rc=$?

  if (( rc != 0 )); then
    err_tail="$(tail -n 20 "$err_file" | tr '\n' '; ')"
    [[ -z "$err_tail" ]] && err_tail="sem detalhes de stderr"
    log_error "$LOG_TAG" "Falha no rsync ($step_label): exit=$rc, detalhes=$err_tail"
    rm -f "$err_file"
    return "$rc"
  fi

  rm -f "$err_file"
  return 0
}

show_help() {
  cat <<EOF
Usage: frigate-reconcile-gaps.sh [options]

Finds and repairs missing files on HD by comparing SSD and HD per day/hour/camera.

Options:
  --min-age-min N     Only reconcile UTC hour dirs older than N minutes (default: ${RECONCILE_MIN_AGE_MINUTES})
  --max-dirs N        Max camera dirs to reconcile per run (default: ${RECONCILE_MAX_DIRS_PER_RUN})
  --dry-run           Do not copy, only report
  --stdout            Mirror logs to terminal
  --help, -h          Show this help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --min-age-min)
      RECONCILE_MIN_AGE_MINUTES="${2:-}"
      shift
      ;;
    --min-age-min=*)
      RECONCILE_MIN_AGE_MINUTES="${1#*=}"
      ;;
    --max-dirs)
      RECONCILE_MAX_DIRS_PER_RUN="${2:-}"
      shift
      ;;
    --max-dirs=*)
      RECONCILE_MAX_DIRS_PER_RUN="${1#*=}"
      ;;
    --dry-run)
      DRY_RUN=1
      ;;
    --stdout)
      MIRROR_STDOUT=1
      ;;
    --help|-h)
      show_help
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      show_help
      exit 1
      ;;
  esac
  shift
done

if ! [[ "$RECONCILE_MIN_AGE_MINUTES" =~ ^[0-9]+$ ]]; then
  echo "Invalid RECONCILE_MIN_AGE_MINUTES=$RECONCILE_MIN_AGE_MINUTES" >&2
  exit 1
fi
if ! [[ "$RECONCILE_MAX_DIRS_PER_RUN" =~ ^[0-9]+$ ]]; then
  echo "Invalid RECONCILE_MAX_DIRS_PER_RUN=$RECONCILE_MAX_DIRS_PER_RUN" >&2
  exit 1
fi

setup_logging "$LOG_FILE" "$MIRROR_STDOUT"
setup_error_trap

if ! check_mountpoint "$HD_MOUNT"; then
  log "$LOG_TAG" "HD externo n?o montado em $HD_MOUNT"
  exit 0
fi

if [[ ! -d "$SOURCE_ROOT" || ! -d "$DEST_ROOT" ]]; then
  log "$LOG_TAG" "Origem/destino ausentes: src=$SOURCE_ROOT dst=$DEST_ROOT"
  exit 0
fi

# Shared lock with mover to avoid concurrent rsync load.
lock_file="${LOCK_STORAGE:-${LOCK_MEDIA:-/tmp/frigate-storage.lock}}"
fallback_lock="${SCRIPT_DIR}/.runtime/frigate-storage.lock"
if ! (: >>"$lock_file") 2>/dev/null; then
  lock_file="$fallback_lock"
  mkdir -p "$(dirname "$lock_file")"
  : >>"$lock_file"
fi
exec 200>"$lock_file"
if ! flock -n 200; then
  log "$LOG_TAG" "Lock ocupado por outro processo"
  exit 0
fi

tmp_candidates="$(mktemp)"
processed=0
repaired_dirs=0
failed_dirs=0
total_gap=0
now_utc="$(date -u +%s)"

log "$LOG_TAG" "Start: src=$SOURCE_ROOT dst=$DEST_ROOT min_age=${RECONCILE_MIN_AGE_MINUTES} max_dirs=${RECONCILE_MAX_DIRS_PER_RUN} dry_run=$DRY_RUN"

while IFS= read -r -d '' camdir; do
  rel="${camdir#${SOURCE_ROOT}/}"
  IFS='/' read -r day hour cam extra <<< "$rel"
  [[ -z "${extra:-}" ]] || continue
  [[ "$day" =~ ^20[0-9]{2}-[0-9]{2}-[0-9]{2}$ ]] || continue
  [[ "$hour" =~ ^[0-2][0-9]$ ]] || continue

  hour_ts="$(date -u -d "${day} ${hour}:00:00" +%s 2>/dev/null || true)"
  [[ -n "$hour_ts" ]] || continue
  age_min=$(( (now_utc - hour_ts) / 60 ))
  (( age_min >= RECONCILE_MIN_AGE_MINUTES )) || continue

  src_n="$(find "$camdir" -maxdepth 1 -type f 2>/dev/null | wc -l)"
  dst_dir="$DEST_ROOT/$day/$hour/$cam"
  if [[ -d "$dst_dir" ]]; then
    dst_n="$(find "$dst_dir" -maxdepth 1 -type f 2>/dev/null | wc -l)"
  else
    dst_n=0
  fi

  if (( dst_n < src_n )); then
    gap=$((src_n-dst_n))
    printf '%s;%s;%s;%s;%s;%s\n' "$day" "$hour" "$cam" "$src_n" "$dst_n" "$gap" >> "$tmp_candidates"
  fi
done < <(find "$SOURCE_ROOT" -mindepth 3 -maxdepth 3 -type d -print0 2>/dev/null | sort -z)

if [[ ! -s "$tmp_candidates" ]]; then
  log "$LOG_TAG" "No gaps found"
  rm -f "$tmp_candidates"
  exit 0
fi

while IFS=';' read -r day hour cam src_n dst_n gap; do
  ((++processed))
  if (( RECONCILE_MAX_DIRS_PER_RUN > 0 && processed > RECONCILE_MAX_DIRS_PER_RUN )); then
    break
  fi

  src_dir="$SOURCE_ROOT/$day/$hour/$cam"
  dst_dir="$DEST_ROOT/$day/$hour/$cam"
  (( total_gap += gap ))

  if [[ "$DRY_RUN" == "1" ]]; then
    log "$LOG_TAG" "[DRY-RUN] $day/$hour/$cam src=$src_n dst=$dst_n gap=$gap"
    continue
  fi

  mkdir -p "$dst_dir"
  if run_rsync "reconcile:$day/$hour/$cam" -a --bwlimit="$BWLIMIT" --chown="${FRIGATE_UID}:${FRIGATE_GID}" --ignore-existing "$src_dir/" "$dst_dir/"; then
    if [[ -d "$dst_dir" ]]; then
      after_n="$(find "$dst_dir" -maxdepth 1 -type f 2>/dev/null | wc -l)"
    else
      after_n=0
    fi
    fixed=$(( after_n - dst_n ))
    (( fixed < 0 )) && fixed=0
    (( repaired_dirs += 1 ))
    log "$LOG_TAG" "Repaired $day/$hour/$cam src=$src_n before=$dst_n after=$after_n gap=$gap copied=$fixed"
  else
    (( failed_dirs += 1 ))
    log_warn "$LOG_TAG" "Falha ao reparar $day/$hour/$cam src=$src_n dst=$dst_n gap=$gap"
  fi
done < <(sort -t';' -k1,1 -k2,2 -k3,3 "$tmp_candidates")

log "$LOG_TAG" "Summary: repaired_dirs=$repaired_dirs failed_dirs=$failed_dirs scanned_gaps=$(wc -l < "$tmp_candidates") total_gap_detected=$total_gap"
rm -f "$tmp_candidates"

if (( failed_dirs > 0 )); then
  exit 1
fi
