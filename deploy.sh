#!/usr/bin/env bash
# Smart Farm — deploy satu perintah.
#
#   ./deploy.sh            pull → build → backup DB → migrate → start/restart → health check
#   ./deploy.sh status     status container + proses PM2
#   ./deploy.sh logs       ikuti log semua service
#   ./deploy.sh restart    restart proses PM2 di dalam container (tanpa build)
#   ./deploy.sh backup     backup database sekarang
#   ./deploy.sh rollback   kembali ke image sebelum deploy terakhir
#   ./deploy.sh down       hentikan semua container (data tetap aman di volume)
#   ./deploy.sh tunnel [TOKEN]  simpan token Cloudflare Tunnel ke .env lalu deploy
#
# Opsi: --no-cache (build ulang penuh), --skip-pull (pakai kode yang sudah ada)
set -Eeuo pipefail

cd "$(dirname "$(readlink -f "$0")")"
ROOT=$PWD
APPS="$ROOT/apps"
SERVICES=(backend frontend)

c_green=$'\033[1;32m'; c_yellow=$'\033[1;33m'; c_red=$'\033[1;31m'; c_off=$'\033[0m'
log()  { printf '\n%s==> %s%s\n' "$c_green" "$*" "$c_off"; }
warn() { printf '%s[!] %s%s\n' "$c_yellow" "$*" "$c_off"; }
die()  { printf '%s[x] %s%s\n' "$c_red" "$*" "$c_off" >&2; exit 1; }
trap 'die "Gagal di baris $LINENO: $BASH_COMMAND"' ERR

CMD=
CMD_ARG=
NO_CACHE=
SKIP_PULL=
for arg in "$@"; do
  case "$arg" in
    --no-cache) NO_CACHE=--no-cache ;;
    --skip-pull) SKIP_PULL=1 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    -*) die "Opsi tidak dikenal: $arg" ;;
    *) if [ -z "$CMD" ]; then CMD=$arg; else CMD_ARG=$arg; fi ;;
  esac
done
CMD=${CMD:-deploy}

# ---------------------------------------------------------------- prasyarat

sudo_if_needed() { if [ "$(id -u)" -eq 0 ]; then "$@"; else sudo "$@"; fi; }

ensure_tools() {
  command -v git >/dev/null || {
    log "Memasang git"
    sudo_if_needed apt-get update -qq && sudo_if_needed apt-get install -y -qq git
  }
  if ! command -v docker >/dev/null || ! docker compose version >/dev/null 2>&1; then
    log "Memasang Docker + Compose"
    # Paket Ubuntu dulu (mendukung rilis terbaru), fallback ke skrip resmi Docker
    if ! { sudo_if_needed apt-get update -qq && sudo_if_needed apt-get install -y -qq docker.io docker-compose-v2 docker-buildx; }; then
      curl -fsSL https://get.docker.com | sudo_if_needed sh
    fi
    sudo_if_needed systemctl enable --now docker || true
  fi
  if ! docker buildx version >/dev/null 2>&1; then
    log "Memasang docker-buildx"
    sudo_if_needed apt-get install -y -qq docker-buildx || warn "docker-buildx gagal dipasang; build memakai builder lama"
  fi
  if [ "$(id -u)" -ne 0 ] && ! id -nG | grep -qw docker; then
    sudo usermod -aG docker "$(whoami)" || true
  fi

  # `docker compose version` tidak menyentuh daemon; `docker info` memastikan izin akses socket.
  if docker info >/dev/null 2>&1; then
    DC=(docker compose)
  elif sudo_if_needed docker info >/dev/null 2>&1; then
    warn "$(whoami) belum aktif di grup docker (login ulang untuk tanpa sudo); kali ini memakai sudo."
    DC=(sudo docker compose)
  else
    die "Docker daemon tidak berjalan. Cek: sudo systemctl status docker"
  fi
  DOCKER=("${DC[@]:0:${#DC[@]}-1}")   # "docker" atau "sudo docker"
}

dc() { "${DC[@]}" "$@"; }

# ---------------------------------------------------------------- .env

rand() { openssl rand -hex "$1" 2>/dev/null || head -c "$1" /dev/urandom | od -An -tx1 | tr -d ' \n'; }

set_env() { # set_env KEY VALUE  — isi nilai bila KEY kosong
  if grep -qE "^$1=.+" .env; then return; fi
  if grep -qE "^$1=" .env; then sed -i "s|^$1=.*|$1=$2|" .env; else echo "$1=$2" >> .env; fi
  return 0
}

ensure_env() {
  if [ ! -f .env ]; then
    log "Membuat .env dari .env.example"
    cp .env.example .env
  fi
  chmod 600 .env
  if ! grep -qE '^JWT_SECRET=.+' .env; then set_env JWT_SECRET "$(rand 32)"; fi
  if ! grep -qE '^ADMIN_PASSWORD=.+' .env && grep -qE '^ADMIN_EMAIL=.+' .env; then
    local pw; pw=$(rand 8)
    set_env ADMIN_PASSWORD "$pw"
    NEW_ADMIN_PASSWORD=$pw
  fi
  set -a; . ./.env; set +a
  : "${BACKEND_REPO:?BACKEND_REPO belum diisi di .env}" "${FRONTEND_REPO:?FRONTEND_REPO belum diisi di .env}"
  BRANCH=${BRANCH:-main}
  # Service cloudflared hanya ikut berjalan bila token tunnel diisi
  if [ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ] && [ -z "${TUNNEL_PROFILE_ADDED:-}" ]; then
    DC+=(--profile tunnel)
    TUNNEL_PROFILE_ADDED=1
  fi
}

TOKEN_GIST_DESC=smart-farm-tunnel-token

set_tunnel_token() {
  local token=$CMD_ARG gist=
  # Tanpa argumen: ambil dari secret gist sekali pakai (dibuat dari PC dengan gh), lalu gist dihapus.
  if [ -z "$token" ] && command -v gh >/dev/null; then
    gist=$(gh gist list --limit 100 2>/dev/null | awk -F'\t' -v d="$TOKEN_GIST_DESC" '$2==d {print $1; exit}') || true
    if [ -n "$gist" ]; then
      log "Mengambil token dari gist sekali pakai"
      token=$(gh gist view "$gist" --raw --filename tunnel-token.txt)
    fi
  fi
  if [ -z "$token" ]; then
    read -rsp "Tempel token Cloudflare Tunnel: " token; echo
  fi
  token=${token##*service install }   # boleh tempel seluruh perintah "cloudflared service install <token>"
  token=$(printf '%s' "$token" | tr -d '[:space:]')
  [[ "$token" =~ ^[A-Za-z0-9+/=_-]{50,}$ ]] || die "Token tidak valid"
  [ -f .env ] || cp .env.example .env
  if grep -qE '^CLOUDFLARE_TUNNEL_TOKEN=' .env; then
    sed -i "s|^CLOUDFLARE_TUNNEL_TOKEN=.*|CLOUDFLARE_TUNNEL_TOKEN=$token|" .env
  else
    printf '\nCLOUDFLARE_TUNNEL_TOKEN=%s\n' "$token" >> .env
  fi
  log "Token Cloudflare Tunnel disimpan di .env"
  if [ -n "$gist" ]; then
    { gh gist delete "$gist" --yes 2>/dev/null || gh gist delete "$gist"; } \
      && echo "   gist token sudah dihapus" \
      || warn "Gist $gist gagal dihapus, hapus manual: gh gist delete $gist"
  fi
}

# ---------------------------------------------------------------- git

self_update() {
  [ -d .git ] && [ -z "${SMARTFARM_UPDATED:-}" ] && [ -z "$SKIP_PULL" ] || return 0
  local before; before=$(git rev-parse HEAD)
  git pull --ff-only -q || { warn "Repo deploy tidak bisa di-pull, lanjut dengan versi lokal"; return 0; }
  if [ "$before" != "$(git rev-parse HEAD)" ]; then
    log "Skrip deploy diperbarui, menjalankan ulang"
    SMARTFARM_UPDATED=1 exec "$0" "$@"
  fi
}

sync_repo() { # sync_repo NAMA URL
  local dir="$APPS/$1"
  if [ -d "$dir/.git" ]; then
    git -C "$dir" remote set-url origin "$2"
    git -C "$dir" fetch -q origin "$BRANCH"
    git -C "$dir" checkout -q "$BRANCH"
    git -C "$dir" merge -q --ff-only "origin/$BRANCH" \
      || die "$1: ada perubahan lokal di $dir yang bentrok. Bersihkan dulu (git -C $dir status)."
  else
    mkdir -p "$APPS"
    git clone -q --branch "$BRANCH" "$2" "$dir"
  fi
  printf '   %-9s %s\n' "$1" "$(git -C "$dir" log -1 --format='%h %s (%cr)')"
}

# ---------------------------------------------------------------- docker

wait_healthy() {
  local timeout=120 start=$SECONDS id status
  for svc in "${SERVICES[@]}"; do
    id=$(dc ps -q "$svc")
    [ -n "$id" ] || die "Container $svc tidak berjalan"
    while :; do
      status=$("${DOCKER[@]}" inspect -f '{{.State.Health.Status}}' "$id" 2>/dev/null || echo unknown)
      [ "$status" = healthy ] && { printf '   %-9s healthy\n' "$svc"; break; }
      if [ "$status" = unhealthy ] || (( SECONDS - start > timeout )); then
        dc logs --tail 60 "$svc" || true
        die "$svc tidak sehat ($status). Lihat log di atas, atau jalankan: ./deploy.sh rollback"
      fi
      sleep 3
    done
  done
}

tag_previous() {
  for svc in "${SERVICES[@]}"; do
    "${DOCKER[@]}" image inspect "smartfarm-$svc:latest" >/dev/null 2>&1 \
      && "${DOCKER[@]}" tag "smartfarm-$svc:latest" "smartfarm-$svc:previous"
  done
  return 0
}

backup_db() {
  dc run --rm --no-deps -T backend node scripts/backup-db.js "${BACKUP_KEEP:-10}"
}

show_status() {
  dc ps
  for svc in "${SERVICES[@]}"; do
    echo; echo "PM2 @ $svc:"
    dc exec -T "$svc" pm2 ls 2>/dev/null || echo "   (tidak berjalan)"
  done
}

print_access() {
  local url
  if [[ "${SITE_ADDRESS:-:80}" == :* ]]; then
    url="http://$(hostname -I 2>/dev/null | awk '{print $1}')${HTTP_PORT:+:$HTTP_PORT}"
    url=${url%:80}
  else
    url="https://$SITE_ADDRESS"
  fi
  log "Selesai! Smart Farm berjalan"
  echo "   Web         : $url"
  echo "   API         : $url/api   (pakai untuk mobile: --dart-define=API_URL=$url/api)"
  if [ -n "${CLOUDFLARE_TUNNEL_TOKEN:-}" ]; then
    echo "   Publik      : lewat Cloudflare Tunnel → Public Hostname harus mengarah ke service HTTP  caddy:80"
  fi
  if [ -n "${NEW_ADMIN_PASSWORD:-}" ]; then
    echo "   Admin awal  : ${ADMIN_EMAIL} / ${NEW_ADMIN_PASSWORD}   ← simpan! (juga tersimpan di .env)"
  fi
}

# ---------------------------------------------------------------- perintah

deploy() {
  ensure_env

  if [ -z "$SKIP_PULL" ]; then
    log "Mengambil kode terbaru (branch $BRANCH)"
    sync_repo backend "$BACKEND_REPO"
    sync_repo frontend "$FRONTEND_REPO"
  fi

  log "Build image"
  tag_previous
  dc build --pull $NO_CACHE

  log "Backup database"
  backup_db

  log "Migrasi skema database"
  dc run --rm --no-deps -T backend npm run -s migration:run:prod

  log "Menjalankan / me-restart container (PM2 di dalamnya)"
  dc pull -q --ignore-buildable 2>/dev/null || warn "Gagal menarik image Caddy/cloudflared terbaru, memakai yang ada"
  dc up -d --remove-orphans

  log "Health check"
  wait_healthy

  "${DOCKER[@]}" image prune -f >/dev/null
  echo; show_status
  print_access
}

# Perbarui skrip ini dulu agar perbaikan terbaru langsung dipakai
case "$CMD" in deploy|tunnel) self_update "$@" ;; esac
ensure_tools
case "$CMD" in
  deploy)   deploy "$@" ;;
  tunnel)   set_tunnel_token; deploy "$@" ;;
  status)   ensure_env; show_status ;;
  logs)     ensure_env; dc logs -f --tail 100 ;;
  restart)  ensure_env; for s in "${SERVICES[@]}"; do dc exec -T "$s" pm2 restart all; done; wait_healthy ;;
  backup)   ensure_env; backup_db ;;
  down)     ensure_env; dc down ;;
  rollback)
    ensure_env
    for svc in "${SERVICES[@]}"; do
      "${DOCKER[@]}" image inspect "smartfarm-$svc:previous" >/dev/null 2>&1 || die "Tidak ada image sebelumnya untuk $svc"
      "${DOCKER[@]}" tag "smartfarm-$svc:previous" "smartfarm-$svc:latest"
    done
    dc up -d --no-build --remove-orphans
    wait_healthy
    warn "Rollback image selesai. Migrasi DB tidak dibatalkan; restore dari backup bila perlu."
    ;;
  *) die "Perintah tidak dikenal: $CMD (lihat ./deploy.sh --help)" ;;
esac
