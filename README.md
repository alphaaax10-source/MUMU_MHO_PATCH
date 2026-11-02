# MUMU_MHO_PATCH — MHO MuMu Patcher

Modul **KernelSU** untuk **MuMu Player 15** yang memperbaiki kompatibilitas
game **MHOutlanders (MHO)** dan menambah patch opsional (resolusi, FPS,
unlock settings, dsb). Tekan **`<> Open`** di KernelSU Manager untuk membuka
WebUI-nya.

Versi saat ini: **v1.4.2** (`versionCode 143`) — lihat
[`dist/MHO_MuMu_Patcher_v1.4.2.zip`](dist/MHO_MuMu_Patcher_v1.4.2.zip).

## Fitur

**Kompatibilitas wajib di MuMu:**
- Perbaikan shader renderer MuMu (`renderer.config`) — menghapus paksaan
  GPU spoof untuk semua paket game yang dikenal.
- Override `libhp15` (crash MuMu ≥ 2026-08-20) — payload SHA-256 diverifikasi.
- **Baru v1.4.2:** `IgnoreGLError 1` otomatis di `renderer.config` —
  **wajib** untuk GPM Device Level 7 (tanpa ini renderer MuMu crash setelah
  logo game).
- **Baru v1.4.2:** Peringatan di WebUI bila GPM Level 7 aktif tetapi
  IgnoreGLError belum terpasang.

**Patch opsional (profil game):**
- Resolution Scale 10–200% (default WebUI 80)
- FPS Override 20–240 (kunci ke nilai yang stabil saat combat)
- Unlock Settings (GPM Device Level 7)
- Force Graphic Library (OpenGL/Vulkan), Cross-Platform, GPU Display,
  Extended Watermark, PixelFlow, Hide-UUID, Controller Mode

**Maintenance baru di v1.4.2:**
- **Reset Game GPU Cache** — hapus `shared_prefs/apm_cfg.xml` (backup
  disimpan) setelah mengganti model GPU di MuMu.
- **Streaming Fix (UE Engine.ini), eksperimental** — tambah blok
  `[SystemSettings]` (`r.Streaming.PoolSize`, dynamic-res off) ke
  `Engine.ini` Android game untuk mengurangi stutter kunjungan map baru.

## Instalasi

1. Buka **KernelSU Manager** di MuMu 15.
2. Modules → pasang `dist/MHO_MuMu_Patcher_v1.4.2.zip` → **Reboot**.
3. Buka modul → tekan **`<> Open`** (WebUI).
4. Pilih game/build → **Save** (atau **Repair** bila binary anomali).
5. Setelah ganti model GPU di MuMu: jalankan **Reset Game GPU Cache**.

## Struktur repo

```
module/   ← sumber modul v1.4.2 (zip dengan menyeret seluruh isi folder ini)
dist/     ← ZIP siap pasang
docs/     ← analisis lengkap arsitektur patcher + changelog v1.4.2
tests/    ← uji unit/integrasi (sh test_gler_awk.sh, dst.)
```

Membangun ulang ZIP dari sumber:

```sh
cd module && zip -r -X ../MHO_MuMu_Patcher_v1.4.2.zip .
```

## Peringatan

- Memodifikasi binary game (`libUnreal.so`) **berisiko kena ban**.
- Gunakan sepenuhnya **atas risiko Anda sendiri**.
- Patch opsional dapat dimatikan per-game lewat WebUI; perubahan selalu
  bisa dikembalikan (restore state per generasi + SHA-256).

## Kredit

- Modul asli (v1.0.0–v1.4.1): author `OpenAI` (lihat `module/module.prop`).
- Peningkatan v1.4.2 (IgnoreGLError/GPM7, reset GPU cache, UE streaming fix,
  default WebUI, pengujian): kontribusi repo ini.

Dokumentasi lengkap (arsitektur, alur lifecycle, analisis stutter):
[`docs/analisis_MHO_MuMu_Patcher.md`](docs/analisis_MHO_MuMu_Patcher.md).
