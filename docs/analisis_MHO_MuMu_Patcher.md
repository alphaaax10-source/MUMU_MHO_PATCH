# Analisis: MHO MuMu Patcher v1.4.1

> **Sumber:** share link Proton Drive (`drive.proton.me/urls/06DJEG3H6G`) — folder `MHO_MuMu_Patcher`
> **File utama:** `MHO_MuMu_Patcher_v1.4.1.zip` (versi terbaru; ada 11 versi lama di folder `Old/`)
> **Ringkasan:** Modul **KernelSU** untuk emulator **MuMu Player 15** yang mempatch binary game
> **Monster Hunter Outlanders** (`libUnreal.so`) untuk membuka fitur, memperbaiki crash/kompatibilitas,
> dan menyediakan WebUI pengaturan.

---

## 1. Gambaran umum

| Aspek | Isi |
|---|---|
| Nama / ID | MHO MuMu Patcher (`mho_mumu_patcher`), v1.4.1 (versionCode 141) |
| Author | `OpenAI` (module.prop) — modul yang tampaknya dibuat dengan bantuan AI |
| Tipe | Modul **KernelSU** (bukan Magisk murni; script-only, `skip_mount`) |
| Target | MuMu Player 15 (Android x86_64, terdeteksi via properti `nemu*`) |
| Game | MH Outlanders 2 region: `com.tencent.mhadv` (Europe/Global) & `com.garena.game.mho` (Asia) |
| Objek patch | `lib/arm64/libUnreal.so` di dalam APK game (game UE5 berjalan via translasi arm64) |
| UI | WebUI standar KernelSU (`webroot/`, dibuka via tombol `<> Open` di KernelSU Manager) |
| Peringatan resmi | *"binary modification may result in a game ban — use entirely at your own risk"* |

**Alur inti:** saat boot, modul memverifikasi SHA-256 `libUnreal.so` terhadap profil build game,
lalu menulis patch byte pada offset persis (ARM64 instructions) **hanya jika** byte lama cocok
dengan signature `before`. Jika signature tidak dikenal → **tidak menulis apa pun** (fail-safe).

---

## 2. Struktur paket

```
MHO_MuMu_Patcher_v1.4.1.zip
├── module.prop            # metadata modul
├── customize.sh           # skrip instalasi (KernelSU), verifikasi SHA payload libhp15
├── apply_patch.sh         # entry point: memuat lib/ lalu main()
├── post-fs-data.sh        # tahap awal boot → hp15-boot + service.sh (watcher)
├── boot-completed.sh      # tahap boot selesai → apply patch "boot"
├── service.sh             # watcher persisten (disable/enable, renderer & hp15 monitoring)
├── uninstall.sh           # restore pristine saat uninstall (retry 5x)
├── skip_mount             # "Script-only module; no system overlay"
├── lib/
│   ├── engine.sh          # ← MESIN UTAMA (3.547 baris): patch binary, validasi, restore
│   ├── multi.sh           # dispatcher mode (status/save/repair/boot/restore/…), state multi-game
│   ├── renderer.sh        # manajemen patch renderer.config MuMu (per package, snapshot generasi)
│   ├── renderer.awk       # parse/merge/hapus baris CustomizedRendererString
│   └── profile_json.awk   # parser JSON profil (format flat, key=value)
├── payload/
│   └── libhp15_x86_64.so  # 463 KB, ELF x86-64 NDK r29 — pengganti libhp15 MuMu
├── profiles/
│   ├── mho_europe_0.30.25.0.2828873.json   # Stable
│   ├── mho_europe_1.0.9.0.3308842.json     # Stable
│   └── mho_asia_1.0.11.0.3284123.json      # Experimental
└── webroot/               # WebUI KernelSU
    ├── index.html / style.css / app.js
```

**State di perangkat:** `/data/adb/mho_mumu_patcher/` (preferensi, log `status.log`, backup,
generasi snapshot renderer, lock operasi) + per-game subfolder.

---

## 3. Profil = "peta patch" per build game

Setiap JSON profil berisi **offset byte + signature `before` + byte `after`** untuk
`libUnreal.so` build tertentu. Pemilihan profil: **package + versionName harus persis cocok**,
kemudian semua byte di lokasi patch harus berada di state `before` ATAU `after`.

Contoh (Asia 1.0.11.0.3284123, `original_sha256=8ca36d3a…`):

```json
"patch_1_name": "DeviceCheck_LocalFlag",   // offset 226312796: 0a905239 → ea031f2a
"patch_2_name": "DeviceCheck_ForceFlag",   // offset 226312800: 29014039 → e9031f2a
"resolution_native_offset": 231510120,     // 2819201e → e803271e
"gpm_get_local_native_offset": 223782444,  // → e0008052 c0035fd6  (mov w0,#0 ; ret)
"graphic_library_offset": 222342984,       // OpenGL: mov w0,#0 ; Vulkan: mov w0,#1 ; ret
...
```

**Build yang didukung:**

| Profil | Package | Versi | Status | Catatan |
|---|---|---|---|---|
| mho_europe_0.30.25.0.2828873 | com.tencent.mhadv | 0.30.25.0.2828873 | Stable | basis lama (dari v1.0.0) |
| mho_europe_1.0.9.0.3308842 | com.tencent.mhadv | 1.0.9.0.3308842 | Stable | hampir semua fitur ready |
| mho_asia_1.0.11.0.3284123 | com.garena.game.mho | 1.0.11.0.3284123 | Experimental | controller & watermark belum ready |

Fitur yang `*_ready: false` otomatis **disembunyikan** di WebUI ("Optional features are hidden
when a profile marks them not ready").

---

## 4. Katalog patch (arti tiap fitur)

Semua patch ditulis via `dd bs=1 seek=<offset>` setelah verifikasi signature, dengan rencana
(`build_patch_plan`) yang menggabungkan semua edit + `sync`.

### Wajib (mandatory di MuMu)
1. **DeviceCheck bypass** (`patch_1/2`) — memaksa flag deteksi device/anti-emulator:
   `strb/ldrb` diganti jadi `mov w10, #0x3f` / `mov w9, #0x3f`. Dijelaskan modul sebagai
   *"Device/system patches are mandatory on MuMu"* — tanpa ini game mendeteksi emulator.
2. **MuMu libhp15 override** (lihat §5) — selalu aktif kecuali dimatikan manual.
3. **Renderer shader fix** (lihat §5).

### Opsional (dikontrol WebUI)
4. **Resolution Scale (10–200%)** — patch 3 titik: instruksi native resolution,
   nilai scale (immediate float, dari persen via `percent_to_instruction_hex`),
   dan instruksi logika (`fmov`-style, `0018291e → 2040201e`).
5. **FPS Override (20–240) — jenis `cvar_lock`** — mendaftarkan ulang cvar FPS game:
   * hook cave (area nol di dalam binary) yang menulis value float pada `fps_value_offset`,
   * patch registrasi cvar (`84f21f94 → 4da9d496`, branch ke cave),
   * patch handler perubahan nilai. Batas 240 disengaja: encoding `MOVZ` satu instruksi
     tidak bisa merepresentasikan float integer >240 tertentu.
6. **PixelFlow (frame interpolation)** — kontrol low/medium: cave + patch registrasi/change
   (varian enabled/disabled berbeda byte).
7. **Max GPM Device Level (Level 7)** — menimpa fungsi *native* dan *blueprint* device level
   dengan stub `mov w0, #7 ; ret` (dan variannya) supaya game menganggap device kelas atas.
8. **Force Graphic Library** — fungsi penentu API grafis di-stub `mov w0, #0` (OpenGL)
   atau `#1` (Vulkan).
9. **Force Cross Platform (PC/Mobile/Console)** — menimpa fungsi deteksi platform dengan
   stub yang mengembalikan enum platform tertentu. Ditandai **High risk**.
10. **GPU Model display** — tweak branch (`b3000094 → 1e090094`) agar nama GPU tampil.
11. **Extended Watermark Info** — menampilkan Graphic API / Platform di watermark in-game
    (hanya profil Europe 0.30 yang ready).
12. **Hide UUID / UID display filter** — 5 patch: 4 fungsi `SetText` (UTextBlock,
    UMHTextBlock, UMHAdaptiveTextBlock, UMHRichTextBlock) di-hook + **shellcode cave besar**
    di offset 143826176 yang mem-filter device UID/UUID dari teks UI (regex-like filter
    ala ARM64: cek pola 8-4-4-4-12 dan sembunyikan).
13. **Force Input Device Gamepad (Controller Mode)** — 12 patch memaksa input gamepad
    (force device, keep gamepad enabled, `IsGamePadActive → true`, dll.) — belum ready di
    semua profil.
14. **Force Device Check** — toggle manual di luar MuMu (untuk device non-MuMu).

### Mekanisme "Save vs Repair"
- **Save** → menerapkan pilihan patch ke library terpasang, setelah memastikan semua byte
  managed dalam state dikenal (`before`/`after`). Ada token konteks SHA-256 agar UI tidak
  menimpa perubahan yang tidak dikenali.
- **Repair** → mengekstrak `libUnreal.so` **pristine dari APK** (`pm path` → unzip), verifikasi
  SHA-256 `original_sha256` dari profil, lalu apply ulang konfigurasi. Ini jalur pemulihan
  bila binary sudah mengandung byte tak dikenal.
- **Restore** → mengembalikan library pristine + renderer.config + libhp15 (dipakai saat
  disable/remove/uninstall).

---

## 5. Perbaikan khusus MuMu Player 15

### a. libhp15 crash override
- MuMu menyimpan `libhp15_x86_64.so` (library helper native milik MuMu, terkait AIDL
  `INemuInit`/`libnemuinitaidl.so`) di
  `/data/system/etc/mumu-configs/shared_libs/libhp15_x86_64.so`.
- Modul mendeteksi build libhp15 MuMu **setelah 2026-08-20** (`HP15_BAD_CUTOFF_EPOCH`) yang
  dianggap *crash-prone*, lalu **mengganti fisik** file itu dengan payload modul
  (ELF x86-64 NDK r29, SHA-256 terkunci `f6f7ea74…`), dengan:
  - backup `.old` + marker `createdbymodule` (bukti kepemilikan),
  - penolakan publish bila marker/SHA tidak cocok (anti tamper),
  - restore otomatis bila MuMu mengganti lagi / modul di-disable.
- Payload sendiri adalah rekayasa ulang library helper MuMu (simbol `BnNemuInitProxyCallback`,
  log Android, dll.) — tujuannya kompatibilitas/crash fix, bukan cheat.

### b. Renderer / shader compatibility fix
- MuMu punya fitur kustomisasi renderer: `/system/etc/mumu-configs/renderer.config`
  dengan baris `CustomizedRendererString` per package (spoof nama GPU — di WebUI ada pilihan
  Adreno 830/750/840, Mali-G925, dll.).
- Modul **menghapus baris CustomizedRendererString untuk package game** (via `renderer.awk`)
  agar game membaca renderer asli → shader path kompatibel ("MuMu renderer shader
  compatibility fix"). Konfigurasi efektif di-merge ke
  `/data/system/etc/mumu-configs/renderer.config` (override data, diprioritaskan MuMu),
  dengan snapshot "generasi" untuk restore presisi (byte-identik bila tidak ada perubahan
  eksternal), plus watcher per detik yang memantau perubahan file (fingerprint inode:size:mtime).

---

## 6. Sistem lifecycle & keamanan

- **post-fs-data.sh** → `hp15-boot` + watcher `service.sh` (diluncurkan dini; sengaja
  unconditional agar race disable/remove tetap terlihat).
- **boot-completed.sh** → `boot` (reconcile semua patch + hp15 + renderer).
- **service.sh (watcher)** — satu proses per boot dengan lock berbasis
  PID + boot_id + start_ticks (anti dual-watcher), loop 1 detik:
  - deteksi marker `disable`/`remove` → **restore pristine** (retry dengan backoff),
  - deteksi re-enable di boot yang sama → apply ulang konfigurasi,
  - pantau `renderer.config` tiap detik (fingerprint) & cek berkala libhp15 tiap 15 tick,
  - watcher bisa dimatikan independen per fitur (`hp15_watcher_disabled`,
    `renderer_watcher_disabled`).
- **Integritas:** SHA-256 menyeluruh — payload libhp15, library asli dari APK, setiap field
  profil (`before`), file restore, snapshot renderer. `umask 077`, lock operasi, atomic install
  (tmp + rename), validasi path anti-symlink.
- **uninstall.sh** → restore via jalur filesystem langsung (tanpa `pm`, karena KernelSU
  menjalankannya saat post-fs-data), retry 5×; recovery history tetap disimpan.
- **Log:** `logcat -s MHO_PATCH` + `/data/adb/mho_mumu_patcher/status.log` (dan log per-game).

---

## 7. WebUI (webroot/)

- WebUI standar **KernelSU** (bridge `window.ksu.exec`), dijalankan dari KernelSU Manager
  (tombol `<> Open` di deskripsi modul).
- app.js memanggil `apply_patch.sh` sebagai root dengan mode:
  `catalog`, `status`, `select`, `save`, `repair`, `shared-save`, `shared-status`, dst.
- UI menyediakan: status build terpasang & efektivitas patch, pemilih game (Europe/Asia),
  toggles Resolution/FPS/PixelFlow/GPM/GPU library/Platform/GPU display/Watermark/Hide UUID/
  Controller mode, pengaturan bersama MuMu (hp15 & renderer + watcher), tombol
  **Default / Save / Repair**.
- Angka parameter divalidasi di backend (`validate_requested_settings`, rentang FPS 20–240,
  scale 10–200) — meski WebUI dimodifikasi pun server menolak nilai di luar batas.

---

## 8. Catatan analis

1. **Ini binary patcher, bukan sekadar "config"** — ia menyunting native library game
   langsung (offset persis per build). Setelah update game, profil baru wajib dibuat
   (ada template di versi lama: salin JSON, isi offset+signature, taruh di `profiles/`).
2. **Risiko:** peringatan ban eksplisit (patch anti-deteksi device & platform berisiko
   terdeteksi server-side), risiko crash bila build game tak cocok — memang diproteksi
   ketat dengan SHA + signature supaya gagal dengan aman, bukan menulis sembarangan.
3. **Mutu kode tinggi untuk skrip shell** — lock, atomic write, retry, state machine
   restore/apply, validasi berlapis; konsisten dengan hasil generate AI (author `OpenAI`).
4. **Keanehan kecil:** v1.4.0 punya versionCode **142**, v1.4.1 versionCode **141**
   (terbalik); delta 1.4.0→1.4.1 terutama UI (bungkus `<form>`, versi) + penyempurnaan
   engine/service/uninstall.
5. **Changelogs** di share adalah **Proton Doc** (bisa dilihat hanya via web Proton Drive
   dengan link tersebut) — tidak bisa diunduh sebagai file.
6. Untuk memakai: pasang ZIP via KernelSU Manager di MuMu 15 → reboot → buka WebUI →
   pilih game/build → Save (atau Repair bila binary anomali).

---

## 9. Lampiran: file yang diunduh ke workspace

Karena link Proton Drive ter-encrypt di sisi klien, saya menulis pengunduh yang
mereplikasi alur kripto Proton (SRP-6a v4 + bcrypt + OpenPGP) → semua 12 ZIP berhasil
diunduh & lolos `unzip -t`:

```
proton_probe/downloads/
├── MHO_MuMu_Patcher_v1.4.1.zip      ← yang dianalisis di atas
├── MHO_MuMu_Patcher_v1.4.0.zip
├── Old/MHO_MuMu_Patcher_v1.0.0.zip … v1.3.0.zip (10 file)
└── extract_1.4.1/                   ← hasil ekstraksi (untuk dibaca langsung)
```

---

## 10. Pembaruan v1.4.2 (implementasi rekomendasi anti-stutter)

ZIP baru: `proton_probe/downloads/MHO_MuMu_Patcher_v1.4.2.zip`
(module.prop `version=1.4.2` / `versionCode=143`, layout identik v1.4.1,
payload libhp15 tidak berubah — SHA `f6f7ea74…abdbb` lolos cek customize.sh).

| # | Fitur | Detail |
|---|-------|--------|
| 1 | `IgnoreGLError 1` otomatis | Disisipkan di blok `Name` game pada `renderer.config` MuMu. Wajib untuk GPM Device Level 7 (tanpa ini renderer MuMu crash setelah logo). Baris milik modul dicatat di `shared/renderer/<pkg>/gler.conf` — baris yang ditambahkan manual user tidak pernah dihapus. Default: aktif; toggle "Enable IgnoreGLError Compatibility" di bagian MuMu Compatibility. |
| 2 | Peringatan GPM7 | WebUI menampilkan peringatan bila GPM Device Level terpasang tapi IgnoreGLError belum ada. |
| 3 | Reset GPU cache game | Mode baru `gpu-cache-reset <pkg>` + tombol "Reset Game GPU Cache" — menghapus `shared_prefs/apm_cfg.xml` (backup disimpan di state modul, symlink ditolak). Untuk dipakai setelah mengganti model GPU di MuMu. |
| 4 | Streaming fix UE (eksperimental) | Mode baru `ueini <pkg> on\|off` + kartu "Streaming Fix (UE Engine.ini)" — menambah blok ber-marker `[/SystemSettings]` (`r.Streaming.PoolSize=1024`, `r.DynamicRes.OperationMode=0`) ke `files/UnrealGame/*/Saved/Config/Android/Engine.ini`. Off = blok dihapus presisi; file yang dibuat modul dihapus bila kosong; backup `Engine.ini.orig` disimpan. |
| 5 | Default WebUI lebih aman | Resolution Scale default 100 → **80**; hint FPS: kunci ke nilai stabil selama combat. |

Detail teknis: gler direkonsiliasi SETELAH transform spoof agar snapshot
before/after tetap bebas-gler (restore byte-presisi tetap berfungsi);
`renderer_cleanup_override` kini menghapus override yang identik dengan basis
system walau tanpa `created.conf`; status baru `gler_state`, `ueini_state`,
`mandatory_gler_saved_disabled` di `status` & `shared-status`; `shared-save`
menerima argumen ke-5 (kompatibel WebUI lama 4 argumen).

Pengujian: `tests/test_gler_awk.sh` (30), `tests/test_v142_integration.sh` (56),
`tests/test_v142_main_dispatch.sh` (26) — semuanya lulus juga terhadap artefak
zip hasil ekstraksi segar; `sh -n` semua script + `node --check` app.js bersih.

---

## 11. Pembaruan v1.4.3 — Performance Optimizer maksimal

ZIP: `proton_probe/downloads/MHO_MuMu_Patcher_v1.4.3.zip`
(`version=1.4.3` / `versionCode=144`; SHA-256 `ccc6ad8b…223eb`).

| # | Fitur | Detail |
|---|-------|--------|
| 1 | **Tombol "Apply Performance Max"** (WebUI) | Sekali klik: Resolution75 + FPS lock60 + PixelFlow off + IgnoreGLError on + UE streaming fix preset **Max FPS** — semua masuk lewat jalur Save normal (profile-aware, verifikasi byte). |
| 2 | **Preset streaming fix: Balanced / Max FPS** | `ueini <pkg> on [balanced\|maxfps]`; pilihan preset di kartu Streaming Fix. |
| 3 | **Blok Engine.ini diperkaya** | *Balanced*: `r.Streaming.PoolSize=1024`, `r.DynamicRes.OperationMode=0`, `r.ParticleLODBias=1`, `r.MotionBlurQuality=0`, `r.DepthOfFieldQuality=0`. *Max FPS*: + `sg.EffectsQuality=0`, `sg.ShadowQuality=0`, `sg.PostProcessQuality=0`, `sg.TextureQuality=1`, `sg.ViewDistanceQuality=1`, `r.AntiAliasingMethod=0`, `r.ParticleLODBias=2`. Cvar tak dikenal diabaikan game (aman). |
| 4 | Kunci preset | `on` tanpa argumen mempertahankan preset sebelumnya; status baru `ueini_preset=` di `status` & `shared-status`. |

Catatan diagnosis (konteks): stutter terbukti **bukan** beban GPU/CPU
(GPU20-30%, semua core <70%, ulangan battle identik, cap30 pun jatuh) —
optimizer ini menekan **kedalaman drop**; stall menunggu disk/jaringan
di luar jangkauan patcher.

Pengujian: suite bertambah →30 awk +70 integrasi +26 dispatch =126 assert,
lulus juga terhadap artefak zip segar; `sh -n` + `node --check` bersih.
