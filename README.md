# Smart Farm — Deploy

Deploy backend + frontend Smart Farm ke server Linux dengan **satu perintah**.

```
                 ┌──────────── server ─────────────────────────────┐
 browser / HP ──▶│ Caddy :80/:443 ─┬─ /api/* ─▶ backend  (PM2, NestJS) ── volume: SQLite + backup
 ESP32        ──▶│                 └─ /*     ─▶ frontend (PM2, Next.js)
                 └─────────────────────────────────────────────────┘
```

Repo terkait: [backend](https://github.com/nizamajem/smart-farm-backend) ·
[frontend](https://github.com/nizamajem/smart-farm-frontend) ·
[mobile](https://github.com/nizamajem/smart-farm-mobile)

## Deploy pertama

Di server (Ubuntu/Debian, user dengan akses sudo):

```bash
git clone https://github.com/nizamajem/smart-farm-deploy.git
cd smart-farm-deploy
./deploy.sh
```

Skrip akan otomatis:

1. Memasang git & Docker bila belum ada
2. Membuat `.env` dengan `JWT_SECRET` dan password admin acak (ditampilkan di akhir — simpan!)
3. Clone / pull repo backend & frontend ke `apps/`
4. Build image Docker
5. Backup database SQLite (online, aman walau app berjalan; menyimpan 10 terakhir)
6. Menjalankan migrasi skema database (TypeORM)
7. Membuat atau me-restart container — di dalamnya aplikasi dijalankan PM2 (`pm2-runtime`)
8. Menunggu health check lulus, lalu menampilkan status PM2 dan URL akses

Untuk domain + HTTPS otomatis, sebelum deploy ubah `.env`: `SITE_ADDRESS=farm.domainanda.com`
(arahkan DNS A-record ke IP server, buka port 80 & 443).

## Cloudflare Tunnel (akses publik tanpa buka port)

```bash
./deploy.sh tunnel            # lalu tempel token (atau seluruh perintah "cloudflared service install ...")
```

Token disimpan di `.env` (tidak di-commit) dan service `cloudflared` berjalan sebagai container
(`restart: unless-stopped`, ikut menyala saat server boot).

Di **Cloudflare Zero Trust → Networks → Tunnels → (tunnel Anda) → Public Hostname**, arahkan hostname ke
**Type: HTTP**, **URL: `caddy:80`** (bukan `localhost`, karena cloudflared berada di jaringan Docker).
Biarkan `SITE_ADDRESS=:80`; HTTPS ditangani Cloudflare.

## Update

Setelah push ke repo backend/frontend, cukup jalankan lagi:

```bash
./deploy.sh
```

## Perintah lain

| Perintah | Fungsi |
|---|---|
| `./deploy.sh status` | Status container + `pm2 ls` di tiap container |
| `./deploy.sh logs` | Ikuti log semua service |
| `./deploy.sh restart` | `pm2 restart` di dalam container tanpa build ulang |
| `./deploy.sh backup` | Backup database sekarang |
| `./deploy.sh rollback` | Kembali ke image sebelum deploy terakhir |
| `./deploy.sh down` | Hentikan semua (data tetap di volume) |
| `./deploy.sh tunnel [TOKEN]` | Simpan token Cloudflare Tunnel lalu deploy |
| `./deploy.sh --no-cache` | Deploy dengan build ulang penuh |
| `./deploy.sh --skip-pull` | Deploy tanpa git pull |

## Repo private

Server butuh akses baca ke repo. Pilih salah satu:

- **Deploy key (disarankan):** `ssh-keygen -t ed25519`, tambahkan public key di
  GitHub → repo → Settings → Deploy keys, lalu ubah `BACKEND_REPO`/`FRONTEND_REPO` di `.env` ke format
  `git@github.com:nizamajem/smart-farm-backend.git`. (Satu deploy key hanya untuk satu repo — buat
  key terpisah per repo atau gunakan SSH key akun.)
- **Token:** `https://<TOKEN>@github.com/nizamajem/smart-farm-backend.git` (token fine-grained, read-only).

## Data & backup

- Database: volume Docker `smartfarm_backend-data` → `/app/data/smartfarm.sqlite`
- Backup: `/app/data/backups/` di volume yang sama
- Salin backup ke host:
  `docker compose cp backend:/app/data/backups ./backups`

## Mobile

Aplikasi Flutter tidak di-deploy ke server; build dengan URL server:

```bash
flutter build apk --dart-define=API_URL=https://farm.domainanda.com/api
```
