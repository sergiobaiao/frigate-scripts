#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

# NIVELAMENTO v1 — 2026-01-31
# Objetivos:
#  - Detectar se /mnt/frigate-ssd é disco montado (mountpoint) ou só diretório do root
#  - Se NÃO for mountpoint e o root estiver crítico, drenar recordings antigos do SSD->HD para aliviar o /
#  - Padronizar estrutura em:
#       /mnt/frigate-ssd/frigate/{recordings,clips,exports,snapshots}
#       /mnt/hdexterno/frigate/{recordings,clips,exports,snapshots}
#    e criar links compatíveis:
#       /mnt/frigate-ssd/recordings -> frigate/recordings (link RELATIVO, docker-safe)
#       /mnt/hdexterno/recordings   -> frigate/recordings
#  - Padronizar MergerFS em /media/frigate-merged via /etc/fstab

VERSION="2026-01-31_v1"
HOST="$(hostname -s 2>/dev/null || hostname)"

SSD_MOUNT="/mnt/frigate-ssd"
HDD_MOUNT="/mnt/hdexterno"

SSD_FRIG="${SSD_MOUNT}/frigate"
HDD_FRIG="${HDD_MOUNT}/frigate"

MERGED="/media/frigate-merged"

# --- parâmetros (sobrescreva via env no sudo env VAR=... ) ---
DRAIN_ROOT_PCT="${DRAIN_ROOT_PCT:-97}"               # se / >= isso, considera crítico
DRAIN_ROOT_MIN_AVAIL_G="${DRAIN_ROOT_MIN_AVAIL_G:-10}" # ou se / tiver < isso (GiB)
KEEP_SSD_DAYS="${KEEP_SSD_DAYS:-2}"                  # mantém HOJE+ONTEM no SSD (mínimo 1)
SKIP_IF_MODIFIED_WITHIN_MIN="${SKIP_IF_MODIFIED_WITHIN_MIN:-180}" # pula dia modificado recentemente
BW_LIMIT_KIB="${BW_LIMIT_KIB:-15000}"                # ~15MB/s
DRY_RUN="${DRY_RUN:-0}"                              # 1 = não move nem edita fstab

log(){ echo "[$(date -Is)] [nivelamento] $*"; }

need_root(){
  if [ "$(id -u)" -ne 0 ]; then
    log "ERRO: rode como root: sudo /usr/local/sbin/nivelamento.sh"
    exit 1
  fi
}

is_mounted(){
  mountpoint -q "$1" 2>/dev/null
}

findmnt_opts(){
  findmnt -n -o OPTIONS -T "$1" 2>/dev/null || true
}

is_ro_mount(){
  local opts
  opts="$(findmnt_opts "$1")"
  echo "$opts" | tr ',' '\n' | grep -qx ro
}

pct_used(){
  df -P "$1" | awk 'NR==2{gsub(/%/,"",$5); print $5}'
}

avail_gib(){
  df -P -BG "$1" | awk 'NR==2{gsub(/G/,"",$4); print $4}'
}

check_hd_ready(){
  # 0 = ok / 1 = não montado / 2 = RO
  if ! is_mounted "$HDD_MOUNT"; then return 1; fi
  if is_ro_mount "$HDD_MOUNT"; then return 2; fi
  return 0
}

ensure_dirs_safe(){
  mkdir -p "$SSD_MOUNT" "$MERGED"
  mkdir -p "$SSD_FRIG"

  # NÃO cria coisa dentro de /mnt/hdexterno se ele não estiver montado (senão escreve no root sem querer)
  if is_mounted "$HDD_MOUNT"; then
    mkdir -p "$HDD_FRIG"
  else
    mkdir -p "$HDD_MOUNT"
  fi
}

ensure_rsync(){
  if command -v rsync >/dev/null 2>&1; then return 0; fi
  log "rsync não encontrado. Tentando instalar..."
  if command -v apt-get >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "1" ]; then
      log "DRY_RUN=1: apt-get install rsync (pulado)"
      return 0
    fi
    apt-get update -y
    apt-get install -y rsync
  else
    log "ERRO: rsync ausente e sem apt-get. Instale rsync manualmente."
    exit 1
  fi
}

ensure_mergerfs(){
  if command -v mergerfs >/dev/null 2>&1; then return 0; fi
  log "mergerfs não encontrado. Tentando instalar..."
  if command -v apt-get >/dev/null 2>&1; then
    if [ "$DRY_RUN" = "1" ]; then
      log "DRY_RUN=1: apt-get install mergerfs (pulado)"
      return 0
    fi
    apt-get update -y
    apt-get install -y mergerfs
  else
    log "ERRO: mergerfs ausente e sem apt-get. Instale mergerfs manualmente."
    exit 1
  fi
}

uncomment_allow_other(){
  local f="/etc/fuse.conf"
  [ -f "$f" ] || return 0

  if grep -q '^[[:space:]]*user_allow_other' "$f"; then
    return 0
  fi

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1: ajustaria $f para user_allow_other"
    return 0
  fi

  if grep -q '^[[:space:]]*#user_allow_other' "$f"; then
    sed -i 's/^[[:space:]]*#user_allow_other/user_allow_other/' "$f"
  else
    echo 'user_allow_other' >> "$f"
  fi
}

migrate_subdir_inside_base(){
  # Move base/{recordings,clips,...} -> base/frigate/{...} e cria symlink RELATIVO de compatibilidade
  # Ex: /mnt/frigate-ssd/recordings -> frigate/recordings
  local base="$1" sub="$2"

  # Só mexe se "base" estiver montado OU se for SSD_MOUNT (que pode ser diretório mesmo)
  if [ "$base" != "$SSD_MOUNT" ] && ! is_mounted "$base"; then
    return 0
  fi

  local src="${base}/${sub}"
  local dst="${base}/frigate/${sub}"

  mkdir -p "${base}/frigate"

  # se já é symlink, deixa
  if [ -L "$src" ]; then
    return 0
  fi

  # move/merge
  if [ -d "$src" ] && [ ! -e "$dst" ]; then
    log "MIGRATE: mv $src -> $dst"
    if [ "$DRY_RUN" != "1" ]; then
      mv -- "$src" "$dst"
    fi
  elif [ -d "$src" ] && [ -d "$dst" ]; then
    # Ambos existem: mescla e remove src (cuidado: pode ser grande)
    log "MIGRATE: merge $src -> $dst"
    if [ "$DRY_RUN" != "1" ]; then
      rsync -a -- "$src/" "$dst/"
      rm -rf -- "$src"
    fi
  fi

  # cria symlink RELATIVO (docker-safe)
  if [ ! -e "$src" ]; then
    log "LINK: $src -> frigate/$sub"
    if [ "$DRY_RUN" != "1" ]; then
      ln -sfn "frigate/$sub" "$src"
    fi
  fi
}

standardize_layout(){
  for d in recordings clips exports snapshots; do
    migrate_subdir_inside_base "$SSD_MOUNT" "$d"
    migrate_subdir_inside_base "$HDD_MOUNT" "$d"
  done
}

drain_old_recordings_ssd_to_hdd(){
  local hd_state=0
  if ! check_hd_ready; then
    hd_state=$?
    if [ "$hd_state" -eq 1 ]; then
      log "ERRO: $HDD_MOUNT NÃO está montado. Não dá pra drenar."
    else
      log "ERRO: $HDD_MOUNT está RO. Não dá pra drenar."
    fi
    return 1
  fi

  local src_rec="$SSD_FRIG/recordings"
  local dst_rec="$HDD_FRIG/recordings"

  [ -d "$src_rec" ] || { log "DRAIN: não existe $src_rec (nada a drenar)"; return 0; }
  mkdir -p "$dst_rec"

  if ! [[ "$KEEP_SSD_DAYS" =~ ^[0-9]+$ ]]; then KEEP_SSD_DAYS=2; fi
  if [ "$KEEP_SSD_DAYS" -lt 1 ]; then KEEP_SSD_DAYS=1; fi

  local offset=$(( KEEP_SSD_DAYS - 1 ))
  local keep_from
  keep_from="$(date -d "-$offset days" +%F)"

  log "DRAIN: src=$src_rec dst=$dst_rec keep_from=$keep_from bwlimit=${BW_LIMIT_KIB}KiB/s skip_mod<${SKIP_IF_MODIFIED_WITHIN_MIN}min dry_run=$DRY_RUN"

  local moved=0
  while IFS= read -r day; do
    local src_day="$src_rec/$day"
    local dst_day="$dst_rec/$day"

    [[ "$day" < "$keep_from" ]] || continue

    # Se teve modificação muito recente, pula (não mexe com dia "quente")
    if find "$src_day" -type f -mmin "-$SKIP_IF_MODIFIED_WITHIN_MIN" -print -quit 2>/dev/null | grep -q .; then
      log "DRAIN: skip $day (modificado nos últimos ${SKIP_IF_MODIFIED_WITHIN_MIN}min)"
      continue
    fi

    log "DRAIN: movendo dia $day"
    if [ "$DRY_RUN" = "1" ]; then
      moved=$((moved+1))
      continue
    fi

    mkdir -p "$dst_day"
    if rsync -a --no-owner --no-group --inplace --partial --bwlimit="$BW_LIMIT_KIB" -- "$src_day/" "$dst_day/"; then
      rm -rf -- "$src_day"
      moved=$((moved+1))
    else
      log "ERRO: rsync falhou no dia $day (abortando sem apagar origem)"
      return 1
    fi
  done < <(
    find "$src_rec" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
      | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' | sort || true
  )

  log "DRAIN: done moved_days=$moved"
}

maybe_drain_root(){
  local ssd_is_mnt="NO"
  is_mounted "$SSD_MOUNT" && ssd_is_mnt="YES"

  local root_used root_avail
  root_used="$(pct_used /)"
  root_avail="$(avail_gib /)"

  log "DETECT: SSD_MOUNTPOINT=$ssd_is_mnt ROOT_USED=${root_used}% ROOT_AVAIL=${root_avail}GiB thresholds: used>=${DRAIN_ROOT_PCT}% OR avail<${DRAIN_ROOT_MIN_AVAIL_G}GiB"

  # Só drena root quando /mnt/frigate-ssd NÃO é mountpoint (ou seja: está consumindo root)
  if [ "$ssd_is_mnt" = "YES" ]; then
    log "OK: /mnt/frigate-ssd é disco montado -> sem DRAIN de root"
    return 0
  fi

  if [ "$root_used" -ge "$DRAIN_ROOT_PCT" ] || [ "$root_avail" -lt "$DRAIN_ROOT_MIN_AVAIL_G" ]; then
    log "ROOT crítico e SSD é diretório -> DRAIN SSD->HD para aliviar /"
    drain_old_recordings_ssd_to_hdd
  else
    log "ROOT ok -> sem DRAIN"
  fi
}

update_fstab_mergerfs(){
  ensure_mergerfs
  uncomment_allow_other

  local fstab="/etc/fstab"
  local ts="$(date +%F_%H%M%S)"
  local backup="${fstab}.bak.${ts}"

  log "fstab backup: $backup"
  if [ "$DRY_RUN" != "1" ]; then
    cp -a "$fstab" "$backup"
  fi

  local tmp
  tmp="$(mktemp)"

  awk '
    BEGIN{skip=0}
    $0 ~ /^# FRIGATE_MERGERFS_BEGIN$/ {skip=1; next}
    $0 ~ /^# FRIGATE_MERGERFS_END$/ {skip=0; next}
    skip==1 {next}
    # remove linha ativa que monta /media/frigate-merged
    $0 !~ /^[[:space:]]*#/ && $2=="/media/frigate-merged" {next}
    {print}
  ' "$fstab" > "$tmp"

  cat >> "$tmp" <<EOF
# FRIGATE_MERGERFS_BEGIN
${SSD_FRIG}:${HDD_FRIG} ${MERGED} fuse.mergerfs defaults,allow_other,use_ino,cache.files=partial,dropcacheonclose=true,category.create=ff,moveonenospc=true,fsname=frigate-merged,nofail,x-systemd.requires-mounts-for=${HDD_MOUNT} 0 0
# FRIGATE_MERGERFS_END
EOF

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1: /etc/fstab seria atualizado (não aplicado)"
    rm -f "$tmp"
    return 0
  fi

  cp "$tmp" "$fstab"
  rm -f "$tmp"
}

mount_mergerfs_now(){
  mkdir -p "$MERGED"

  # Só tenta montar se o HD estiver montado; senão, risco de mergerfs usar diretório do root como branch.
  if ! is_mounted "$HDD_MOUNT"; then
    log "INFO: $HDD_MOUNT não montado -> não vou montar $MERGED agora (fstab já padronizado)."
    return 0
  fi

  if is_mounted "$MERGED"; then
    log "OK: $MERGED já está montado."
    return 0
  fi

  log "Mount: tentando montar $MERGED"
  if [ "$DRY_RUN" = "1" ]; then return 0; fi

  if ! mount "$MERGED" 2>/dev/null; then
    log "WARN: mount direto falhou. Tentando mount -a ..."
    mount -a 2>/dev/null || true
  fi

  is_mounted "$MERGED" && log "OK: $MERGED montado." || log "WARN: $MERGED ainda não montado (verifique fstab/mergerfs)."
}

show_summary(){
  echo
  log "===== SUMMARY host=$HOST version=$VERSION ====="
  log "findmnt:"
  findmnt "$SSD_MOUNT" "$HDD_MOUNT" "$MERGED" -no TARGET,SOURCE,FSTYPE,OPTIONS 2>/dev/null || true
  log "df:"
  df -hT / "$SSD_MOUNT" "$SSD_FRIG" "$HDD_MOUNT" "$HDD_FRIG" "$MERGED" 2>/dev/null || true
  echo
}

main(){
  need_root
  log "START host=$HOST version=$VERSION dry_run=$DRY_RUN"

  ensure_dirs_safe
  ensure_rsync

  # 1) padroniza layout e cria links compatíveis
  standardize_layout

  # 2) se /mnt/frigate-ssd é só pasta e o root está crítico, drena recordings antigos para o HD
  maybe_drain_root

  # 3) padroniza mergerfs em fstab e tenta montar
  update_fstab_mergerfs
  mount_mergerfs_now

  show_summary
  log "DONE"
}

main "$@"
