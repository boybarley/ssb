
<div align="center">

# 🧠 Smart Switch Brain

### OpenClaw AI Mode Selector

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Bash](https://img.shields.io/badge/Bash-4%2B-green.svg)](https://www.gnu.org/software/bash/)
[![Node](https://img.shields.io/badge/Node.js-16%2B-339933.svg)](https://nodejs.org/)
[![Platform](https://img.shields.io/badge/Platform-Linux%20%7C%20macOS%20%7C%20WSL2-blue.svg)](#sistem-yang-didukung)

**Smart Switch Brain** adalah sistem routing AI yang memungkinkan kamu berpindah
antar mode AI secara real-time — dari mode kerja keras hingga mode santai —
dalam satu klik.

[Instalasi Cepat](#-instalasi-cepat) •
[Panduan Lengkap](#-panduan-instalasi-lengkap) •
[Penggunaan](#-cara-penggunaan) •
[API](#-api-endpoints) •
[Troubleshooting](#-troubleshooting)

---

**Created by [Boy Barley](https://boybarley.com)**

</div>

---

## 📋 Daftar Isi

- [Tentang Proyek](#-tentang-proyek)
- [Mode AI](#-mode-ai)
- [Prasyarat](#-prasyarat)
- [Instalasi Cepat](#-instalasi-cepat)
- [Panduan Instalasi Lengkap](#-panduan-instalasi-lengkap)
- [Cara Penggunaan](#-cara-penggunaan)
- [API Endpoints](#-api-endpoints)
- [Manajemen Service](#-manajemen-service)
- [Konfigurasi](#-konfigurasi)
- [CLI Flags](#-cli-flags)
- [Upgrade](#-upgrade)
- [Uninstall](#-uninstall)
- [Troubleshooting](#-troubleshooting)
- [Struktur Proyek](#-struktur-proyek)
- [Keamanan](#-keamanan)
- [Lisensi](#-lisensi)
- [Kredit](#-kredit)

---

## 🧠 Tentang Proyek

Smart Switch Brain adalah **orchestrator AI** berbasis OpenClaw architecture
yang mengarahkan permintaan ke model AI yang tepat berdasarkan mode kerja
yang dipilih pengguna.

**Kenapa ini berguna?**

| Situasi | Masalah | Solusi Smart Switch |
|---------|---------|---------------------|
| Kerja berat / analisis kompleks | Butuh AI paling cerdas | Otomatis route ke Claude Opus |
| Kerja fokus / coding | Butuh respons cepat & akurat | Route ke Claude Haiku |
| Eksplorasi / brainstorming | Butuh kreativitas | Route ke Step-3.5 Flash |

Cukup **satu klik** untuk pindah mode — tidak perlu ganti tab, ganti app,
atau copy-paste API key.

---

## 🎯 Mode AI

| Mode | Model | Icon | Kegunaan |
|------|-------|------|----------|
| **Work Hard** | Claude Opus | 🔥 | Tugas kompleks, analisis mendalam, reasoning berat |
| **Focus Serius** | Claude Haiku | 🎯 | Coding, tugas terstruktur, respons cepat |
| **Relax** | Step-3.5 Flash | 🌊 | Brainstorming, eksplorasi kreatif, chat santai |

> Mode dapat dikustomisasi melalui file `config/modes.yaml`

---

## ✅ Prasyarat

Pastikan sistem kamu memenuhi persyaratan berikut sebelum instalasi:

| Komponen | Minimum | Cek Versi |
|----------|---------|-----------|
| **OS** | Linux / macOS / WSL2 | `uname -a` |
| **Node.js** | v16+ | `node --version` |
| **npm** | v8+ | `npm --version` |
| **Git** | v2.30+ | `git --version` |
| **RAM** | 2 GB | `free -m` |
| **Disk** | 500 MB tersedia | `df -h` |

### Instalasi Prasyarat (jika belum ada)

<details>
<summary><strong>Ubuntu / Debian</strong></summary>

```bash
# Update package list
sudo apt update

# Install Node.js 20 LTS
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs git curl wget

# Verifikasi
node --version && npm --version && git --version
```

</details>

<details>
<summary><strong>macOS</strong></summary>

```bash
# Install Homebrew (jika belum ada)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Install dependencies
brew install node git curl wget

# Verifikasi
node --version && npm --version && git --version
```

</details>

<details>
<summary><strong>Arch Linux</strong></summary>

```bash
sudo pacman -S nodejs npm git curl wget

# Verifikasi
node --version && npm --version && git --version
```

</details>

<details>
<summary><strong>RHEL / CentOS / Fedora</strong></summary>

```bash
# Fedora
sudo dnf install nodejs npm git curl wget

# CentOS / RHEL (aktifkan NodeSource dulu)
curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
sudo yum install -y nodejs git curl wget

# Verifikasi
node --version && npm --version && git --version
```

</details>

<details>
<summary><strong>Windows WSL2</strong></summary>

```bash
# Pastikan WSL2 sudah terinstall, lalu di terminal WSL:
sudo apt update
curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
sudo apt install -y nodejs git curl wget

# Verifikasi
node --version && npm --version && git --version
```

</details>

### Mendapatkan OpenRouter API Key

1. Buka [https://openrouter.ai](https://openrouter.ai)
2. Daftar / Login
3. Buka halaman **Keys** → [https://openrouter.ai/keys](https://openrouter.ai/keys)
4. Klik **"Create Key"**
5. Simpan key-nya (format: `sk-or-...`)
6. Kamu akan membutuhkan key ini saat instalasi

---

## ⚡ Instalasi Cepat

**Satu perintah untuk install semuanya:**

```bash
curl -fsSL https://raw.githubusercontent.com/boybarley/ssb/main/install.sh | bash
```

Atau jika ingin lebih aman (download dulu, review, baru jalankan):

```bash
# Download
wget https://raw.githubusercontent.com/boybarley/ssb/main/install.sh

# Review isinya (opsional tapi disarankan)
less install.sh

# Beri permission & jalankan
chmod +x install.sh
./install.sh
```

---

## 📖 Panduan Instalasi Lengkap

### Langkah 1: Clone Repository

```bash
git clone https://github.com/boybarley/ssb.git
cd smart-switch-brain
```

### Langkah 2: Beri Permission

```bash
chmod +x install.sh
```

### Langkah 3: Jalankan Installer

#### Opsi A — Interaktif (disarankan untuk pertama kali)

```bash
./install.sh
```

Installer akan memandu kamu langkah demi langkah:
- ✅ Cek sistem otomatis
- ✅ Install dependency yang kurang
- ✅ Minta API key secara aman (input tersembunyi)
- ✅ Setup backend & frontend
- ✅ Inisialisasi database
- ✅ Konfigurasi service
- ✅ Jalankan smoke test

#### Opsi B — Non-interaktif (untuk server / CI)

```bash
./install.sh --api-key sk-or-XXXXXXXXXXXXXXXX --port 5000 --no-systemd --skip-tests
```

#### Opsi C — Dengan verbose output

```bash
./install.sh --verbose
```

### Langkah 4: Verifikasi Instalasi

```bash
./install.sh --status
```

Output yang diharapkan:
```
✅ Service: running
✅ API: healthy
```

### Langkah 5: Akses Aplikasi

Buka browser dan kunjungi:

```
http://localhost:5000
```

---

## 🚀 Cara Penggunaan

### Menggunakan Web Interface

1. Buka `http://localhost:5000` di browser
2. Kamu akan melihat 3 tombol mode: **Work Hard** 🔥, **Focus Serius** 🎯, **Relax** 🌊
3. Klik mode yang diinginkan
4. Mode aktif akan berubah secara real-time
5. Semua permintaan AI selanjutnya akan di-route ke model yang dipilih

### Menggunakan API (cURL)

#### Lihat semua mode yang tersedia

```bash
curl http://localhost:5000/api/modes
```

#### Lihat mode yang sedang aktif

```bash
curl http://localhost:5000/api/modes/current
```

#### Pindah mode

```bash
# Pindah ke mode Work Hard
curl -X POST http://localhost:5000/api/modes/switch \
  -H "Content-Type: application/json" \
  -d '{"mode_id": "work-hard"}'

# Pindah ke mode Focus Serius
curl -X POST http://localhost:5000/api/modes/switch \
  -H "Content-Type: application/json" \
  -d '{"mode_id": "focus-serius"}'

# Pindah ke mode Relax
curl -X POST http://localhost:5000/api/modes/switch \
  -H "Content-Type: application/json" \
  -d '{"mode_id": "relax"}'
```

#### Cek kesehatan service

```bash
curl http://localhost:5000/health
```

Response:
```json
{
  "status": "ok",
  "version": "1.0.0",
  "uptime": 3600.5
}
```

### Menggunakan dari Aplikasi Lain

```javascript
// Contoh integrasi JavaScript/Node.js
const response = await fetch('http://localhost:5000/api/modes/switch', {
  method: 'POST',
  headers: { 'Content-Type': 'application/json' },
  body: JSON.stringify({ mode_id: 'work-hard' })
});
const result = await response.json();
console.log(`Switched to: ${result.switched}`);
```

```python
# Contoh integrasi Python
import requests

# Switch mode
response = requests.post('http://localhost:5000/api/modes/switch',
    json={'mode_id': 'work-hard'})
print(response.json())
```

---

## 📡 API Endpoints

| Method | Endpoint | Deskripsi | Body |
|--------|----------|-----------|------|
| `GET` | `/health` | Health check | — |
| `GET` | `/api/modes` | List semua mode AI | — |
| `GET` | `/api/modes/current` | Mode yang sedang aktif | — |
| `POST` | `/api/modes/switch` | Pindah ke mode lain | `{"mode_id": "work-hard"}` |

### Mode ID yang Valid

| mode_id | Mode Name |
|---------|-----------|
| `work-hard` | Work Hard (Claude Opus) |
| `focus-serius` | Focus Serius (Claude Haiku) |
| `relax` | Relax (Step-3.5 Flash) |

---

## ⚙️ Manajemen Service

### Dengan Systemd (Linux)

```bash
# Start service
sudo systemctl start smart-switch-brain

# Stop service
sudo systemctl stop smart-switch-brain

# Restart service
sudo systemctl restart smart-switch-brain

# Cek status
sudo systemctl status smart-switch-brain

# Lihat log
journalctl -u smart-switch-brain -f

# Enable auto-start saat boot
sudo systemctl enable smart-switch-brain

# Disable auto-start
sudo systemctl disable smart-switch-brain
```

### Tanpa Systemd (macOS / Manual)

```bash
# Start
cd ~/smart-switch-brain
./start.sh

# Stop
./stop.sh

# Atau start manual
cd ~/smart-switch-brain/backend
node src/index.js

# Start di background
nohup node src/index.js > ../logs/service.log 2>&1 &
```

### Cek Status via Installer

```bash
./install.sh --status
```

---

## 🔧 Konfigurasi

### Environment Variables (`.env`)

File lokasi: `~/smart-switch-brain/.env`

| Variable | Default | Deskripsi |
|----------|---------|-----------|
| `NODE_ENV` | `production` | Environment mode |
| `PORT` | `5000` | Port backend server |
| `HOST` | `0.0.0.0` | Bind address |
| `OPENROUTER_API_KEY` | — | API key dari OpenRouter |
| `OPENROUTER_BASE_URL` | `https://openrouter.ai/api/v1` | Base URL API |
| `DATABASE_PATH` | `./data/smartswitch.db` | Path database SQLite |
| `LOG_LEVEL` | `info` | Level logging |
| `LOG_DIR` | `./logs` | Direktori log |
| `RATE_LIMIT_WINDOW_MS` | `60000` | Window rate limiter (ms) |
| `RATE_LIMIT_MAX_REQUESTS` | `100` | Max request per window |

> ⚠️ **Jangan pernah commit file `.env` ke Git!** File ini sudah otomatis
> masuk `.gitignore`.

#### Mengganti Port

```bash
# Via environment variable
export SMART_SWITCH_PORT=3000
./install.sh

# Via flag
./install.sh --port 3000

# Atau edit langsung
nano ~/smart-switch-brain/.env
# Ubah PORT=3000, lalu restart service
```

#### Mengganti API Key

```bash
# Edit .env
nano ~/smart-switch-brain/.env
# Ubah baris OPENROUTER_API_KEY=sk-or-xxxxx

# Restart service
sudo systemctl restart smart-switch-brain
# atau
cd ~/smart-switch-brain && ./stop.sh && ./start.sh
```

### Mode Configuration (`config/modes.yaml`)

File lokasi: `~/smart-switch-brain/config/modes.yaml`

Kamu bisa menambah, menghapus, atau memodifikasi mode AI:

```yaml
modes:
  - id: work-hard
    name: "Work Hard"
    description: "Maximum reasoning power for complex tasks"
    model: "anthropic/claude-opus-4"
    provider: "openrouter"
    parameters:
      temperature: 0.3
      max_tokens: 8192
      top_p: 0.9
    icon: "🔥"
    color: "#FF6B35"

  # Tambah mode baru
  - id: coding-mode
    name: "Coding Mode"
    description: "Optimized for programming tasks"
    model: "anthropic/claude-sonnet-4"
    provider: "openrouter"
    parameters:
      temperature: 0.1
      max_tokens: 8192
      top_p: 0.85
    icon: "💻"
    color: "#00D4FF"
```

Setelah edit, restart service untuk menerapkan perubahan.

> 💡 Installer **tidak akan pernah** menimpa `modes.yaml` yang sudah kamu
> modifikasi tanpa backup terlebih dahulu.

---

## 🏳️ CLI Flags

```
Usage: install.sh [flags]

Flag                Deskripsi
─────────────────────────────────────────────────────
-h, --help          Tampilkan bantuan
-v, --verbose       Output lebih detail
--skip-tests        Lewati smoke test setelah instalasi
--no-systemd        Jangan daftarkan service systemd
--api-key KEY       Set API key (tanpa prompt interaktif)
--port PORT         Set port (default: 5000)
--repo URL          Override URL repository git
--dir PATH          Override direktori instalasi
--upgrade           Upgrade instalasi yang sudah ada
--clean             Bersihkan artifact build lalu reinstall
--uninstall         Hapus Smart Switch Brain
--status            Tampilkan status service
--diagnostic        Generate laporan diagnostik
```

### Contoh Penggunaan Flags

```bash
# Install lengkap tanpa interaksi (cocok untuk server)
./install.sh --api-key sk-or-xxx --port 8080 --no-systemd --skip-tests

# Install dengan verbose (untuk debug)
./install.sh --verbose

# Cek apakah semuanya berjalan baik
./install.sh --status

# Generate laporan untuk troubleshooting
./install.sh --diagnostic

# Bersihkan build lama, install ulang
./install.sh --clean
./install.sh

# Upgrade ke versi terbaru
./install.sh --upgrade
```

---

## 🔄 Upgrade

### Upgrade Otomatis

```bash
./install.sh --upgrade
```

Yang terjadi saat upgrade:
1. ✅ Backup otomatis (config, data, .env) ke `backups/`
2. ✅ Pull kode terbaru dari GitHub
3. ✅ Reinstall dependencies
4. ✅ Backup database
5. ✅ Konfigurasi yang sudah diubah **tidak ditimpa**
6. ✅ Smoke test

### Upgrade Manual

```bash
cd ~/smart-switch-brain

# Backup dulu
cp -r config backups/config_$(date +%Y%m%d)
cp data/smartswitch.db backups/smartswitch_$(date +%Y%m%d).db

# Pull update
git pull origin main

# Reinstall
cd backend && npm install --production
cd ../frontend && npm install && npm run build

# Restart
sudo systemctl restart smart-switch-brain
```

---

## 🗑️ Uninstall

```bash
./install.sh --uninstall
```

Proses uninstall akan:
1. Menanyakan konfirmasi
2. Menawarkan backup database
3. Menawarkan preservasi data pengguna (config, data, backups)
4. Menghentikan dan menghapus service systemd
5. Menghapus direktori instalasi

> Data yang di-preserve akan disimpan di
> `~/smart-switch-brain-userdata_[timestamp]/`

---

## 🔍 Troubleshooting

### Service tidak bisa start

```bash
# Cek log error
cat ~/smart-switch-brain/logs/service-error.log

# Atau via journalctl
journalctl -u smart-switch-brain --no-pager -n 50

# Generate diagnostic
./install.sh --diagnostic
```

### Port sudah dipakai

```bash
# Cek apa yang pakai port 5000
sudo lsof -i :5000
# atau
sudo ss -tlnp | grep 5000

# Ganti port
./install.sh --port 3001
# atau edit .env
```

### npm install gagal

```bash
# Bersihkan cache
npm cache clean --force

# Clean install
./install.sh --clean
./install.sh
```

### Permission denied

```bash
# Fix ownership
sudo chown -R $(whoami) ~/smart-switch-brain

# Jalankan ulang
./install.sh
```

### API key tidak valid

```bash
# Edit .env
nano ~/smart-switch-brain/.env

# Pastikan format: sk-or-xxxxxxxxx
# Restart service setelah edit
```

### Database corrupt

```bash
# Restore dari backup
ls ~/smart-switch-brain/backups/
cp ~/smart-switch-brain/backups/smartswitch_XXXXXXXX.db \
   ~/smart-switch-brain/data/smartswitch.db

# Restart
sudo systemctl restart smart-switch-brain
```

### Diagnostic Report

Untuk masalah lainnya, generate laporan diagnostik:

```bash
./install.sh --diagnostic
```

Laporan berisi:
- Info OS & hardware
- Versi Node.js, npm, git
- Status service & port
- Log error terbaru
- Status file konfigurasi

Simpan atau kirim laporan ini jika butuh bantuan.

---

## 📁 Struktur Proyek

```
smart-switch-brain/
├── install.sh              # 🔧 Installer utama (satu-satunya file yang perlu dijalankan)
├── start.sh                # ▶️  Start script (auto-generated)
├── stop.sh                 # ⏹️  Stop script (auto-generated)
├── .env                    # 🔒 Environment config (auto-generated, JANGAN commit)
├── .env.example            # 📄 Template .env (aman untuk commit)
├── .gitignore              # 🛡️ Git ignore rules (auto-generated)
│
├── backend/                # ⚙️ Backend Node.js
│   ├── package.json
│   ├── node_modules/
│   └── src/
│       └── index.js        # Entry point server Express
│
├── frontend/               # 🎨 Frontend web
│   ├── package.json
│   ├── public/
│   │   └── index.html      # UI mode selector
│   └── dist/               # Build output
│
├── config/                 # 📋 Konfigurasi runtime
│   ├── modes.yaml          # Definisi mode AI (EDITABLE)
│   └── logrotate.conf      # Konfigurasi log rotation
│
├── data/                   # 🗄️ Database
│   └── smartswitch.db      # SQLite database
│
├── logs/                   # 📝 Log files
│   ├── install_*.log       # Log instalasi
│   ├── service.log         # Log runtime service
│   └── diagnostic_*.txt    # Laporan diagnostik
│
├── backups/                # 💾 Auto-backup
│   ├── pre_upgrade_*/      # Backup sebelum upgrade
│   └── smartswitch_*.db    # Backup database
│
└── docs/                   # 📚 Dokumentasi (auto-generated)
    └── README.md
```

---

## 🔒 Keamanan

Smart Switch Brain dibangun dengan prinsip **Security First**:

| Fitur | Implementasi |
|-------|-------------|
| **API Key Protection** | Input tersembunyi, chmod 600 pada `.env`, tidak pernah di-log |
| **Git Protection** | `.gitignore` + pre-commit hook memblokir commit file sensitif |
| **File Permissions** | `.env` (600), `config/` (700), `data/` (700) |
| **Rate Limiting** | 100 request per menit per IP (configurable) |
| **HTTP Security Headers** | Helmet.js (XSS, HSTS, Content-Type sniffing, dll.) |
| **CORS** | Enabled dan configurable |
| **Systemd Hardening** | NoNewPrivileges, ProtectSystem, PrivateTmp |
| **Database** | WAL mode, file permission 600 |
| **Backup** | Otomatis sebelum setiap upgrade |

### Best Practices

- ❌ Jangan pernah share file `.env`
- ❌ Jangan commit `.env` ke repository
- ✅ Gunakan `.env.example` sebagai referensi
- ✅ Rotasi API key secara berkala di [OpenRouter Dashboard](https://openrouter.ai/keys)
- ✅ Jalankan `npm audit` secara berkala: `cd backend && npm audit`

---

## 🤝 Kontribusi

Kontribusi sangat diterima! Silakan:

1. Fork repository ini
2. Buat branch fitur: `git checkout -b fitur-baru`
3. Commit: `git commit -m "Tambah fitur baru"`
4. Push: `git push origin fitur-baru`
5. Buat Pull Request

---

## 📄 Lisensi

Proyek ini dilisensikan di bawah **MIT License** — lihat file [LICENSE](LICENSE) untuk detail.

```
MIT License

Copyright (c) 2025 Boy Barley

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## ✨ Kredit

<div align="center">

### Dibuat dengan ❤️ oleh **Boy Barley**

[![GitHub](https://img.shields.io/badge/GitHub-boybarley-181717?style=for-the-badge&logo=github)](https://github.com/boybarley)

**Smart Switch Brain** — OpenClaw AI Mode Selector

© 2026 Boy Barley. All rights reserved.

</div>
```

---
