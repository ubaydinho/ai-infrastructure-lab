# Rasional quota dan perilaku preemption

Artifact Sprint 1. Ditulis dari satu eksperimen preemption di homelab: 2 worker palsu, 4x H200 masing-masing, 8 pod batch prioritas 8000, lalu satu pod interaktif prioritas 10000 yang minta 2 GPU.

---

## 1. Yang aku amati

**Sebelum.** Delapan pod batch, masing-masing 1 GPU, tersebar rata oleh scheduler tanpa aku atur:

| Node | Pod | GPU terpakai |
|---|---|---|
| `gpu-worker-01` | batch-2, batch-3, batch-5, batch-8 | 4 / 4 |
| `gpu-worker-02` | batch-1, batch-4, batch-6, batch-7 | 4 / 4 |

Cluster penuh. Tidak ada satu slot GPU pun sisa.

**Kejadian.** `interactive-1` masuk, prioritas 10000, minta 2 GPU sekaligus. Urutan event dari `kubectl get events`:

| Waktu | Event | Isi |
|---|---|---|
| 07:07:18Z | `Warning FailedScheduling` | `0/5 nodes are available: 2 Insufficient nvidia.com/gpu, 3 node(s) didn't match Pod's node affinity/selector` |
| 07:07:18Z | `Normal Preempted` | batch-8 direbut oleh pod UID `fd2353d0-…` |
| 07:07:18Z | `Normal Preempted` | batch-5 direbut oleh pod UID yang sama |
| 07:07:20Z | `Normal Scheduled` | `interactive-1` masuk ke `gpu-worker-01` |

**Sesudah.**

| Node | Pod | GPU terpakai |
|---|---|---|
| `gpu-worker-01` | batch-2, batch-3, **interactive-1 (2 GPU)** | 4 / 4 |
| `gpu-worker-02` | batch-1, batch-4, batch-6, batch-7 | 4 / 4 |

Korban: **batch-5 dan batch-8**, keduanya di `gpu-worker-01`.

Detail kecil yang menegaskan slotnya benar-benar didaur ulang: `interactive-1` mendapat IP `10.42.3.3`, alamat yang sebelumnya dipakai batch-5.

### Tiga hal yang aku pelajari dari urutan event itu

1. **Scheduler tidak tahu harus merebut.** Dia mencoba dulu, gagal, baru menjalankan logika preemption, lalu mencoba lagi. `FailedScheduling` bukan error yang perlu diperbaiki — itu langkah normal dalam loop. Yang perlu dikhawatirkan adalah `FailedScheduling` yang **tidak** diikuti `Preempted` dan `Scheduled`.
2. **Seluruh proses selesai dalam 2 detik**, dan tidak ada manusia yang terlibat.
3. **Pesan penolakan adalah neraca per node.** `2 Insufficient nvidia.com/gpu` = dua worker palsu, GPU penuh. `3 node(s) didn't match` = tiga node k3d sungguhan, ditolak karena `nodeSelector: type=kwok` tidak cocok. 2 + 3 = 5 node, masing-masing dengan alasan sendiri.

---

## 2. Kenapa korban itu yang dipilih

Urutan kriteria scheduler saat memilih **node** untuk dikorbankan:

1. Node dengan pelanggaran PodDisruptionBudget paling sedikit
2. Node yang korban prioritas-tertingginya paling rendah
3. Total prioritas korban paling kecil
4. Jumlah korban paling sedikit
5. Waktu start korban — cenderung merebut pod yang paling baru

Sekarang cocokkan dengan kasus ini: semua pod batch prioritasnya **sama** (8000), request-nya **sama** (1 GPU), **tidak ada PDB** sama sekali, dan **kedua node penuh 4/4** dengan 4 kandidat korban masing-masing.

Artinya kriteria 1 sampai 4 **seri semua.** Keputusan turun ke kriteria 5, dan bahkan di sana selisihnya cuma pecahan detik karena batch-2 sampai batch-8 dibuat dalam satu loop.

**Kesimpulan sementara: pemilihan `gpu-worker-01` kemungkinan besar hasil tiebreak, bukan keputusan bermakna.**

> **Ini masih hipotesis, belum terbukti.** Cara mengujinya: ulangi eksperimen 5–10 kali dari kondisi bersih dan catat node mana yang jadi korban setiap kali.
>
> - Kalau node-nya **berganti-ganti** → benar tiebreak, tidak deterministik.
> - Kalau **selalu `gpu-worker-01`** → ada sebab sistematis yang belum aku temukan, dan penjelasan di atas salah.
>
> Belum aku jalankan. Hasilnya masuk ke bagian ini.

Kenapa batch-5 dan batch-8, bukan batch-2 dan batch-3? Di dalam satu node, scheduler mengurutkan kandidat dari yang "paling tidak penting" — prioritas sama, jadi pembedanya waktu start, dan yang lebih baru dianggap kurang penting. batch-5 dan batch-8 dibuat setelah batch-2 dan batch-3. Konsisten dengan yang teramati, tapi perlu dikonfirmasi dengan ulangan di atas.

---

## 3. Artinya bagi tenant

Ini bagian yang paling penting, dan tidak ada di dokumentasi mana pun.

**Quota bukan jaminan.** `ResourceQuota` membatasi berapa banyak yang boleh tenant *minta*. Dia tidak pernah *menyisihkan* apa pun. Tenant dengan quota 4 GPU bisa berjalan dengan 4 GPU selama berjam-jam, lalu tinggal 2 dalam dua detik — tanpa perubahan apa pun di quota mereka, dan tanpa pemberitahuan.

Konsekuensi konkret yang harus aku sampaikan ke tim:

- Job batch **wajib** bisa di-checkpoint dan dilanjutkan. Job 6 jam tanpa checkpoint di prioritas 8000 adalah job yang akan hilang.
- Pod telanjang tidak pernah kembali. batch-5 dan batch-8 mati dan tidak dihidupkan ulang, karena tidak ada Deployment atau Job yang memilikinya. `restartPolicy: Always` **tidak** menolong di sini — field itu mengatur restart container di dalam pod yang masih hidup, bukan menghidupkan objek pod yang sudah dihapus.
- Tenant tidak bisa memprediksi job mana yang jadi korban. Kalau prediktabilitas dibutuhkan, tiebreak tidak bisa diandalkan — butuh PDB, prioritas yang benar-benar berbeda, atau kapasitas yang disisihkan.

### Batas simulasi ini

KWOK mereplikasi **keputusan** preemption dengan setia, tapi tidak **mekanikanya**. Pod palsu hilang begitu saja: tidak ada `terminationGracePeriodSeconds` nyata, tidak ada koneksi yang di-drain, tidak ada PVC yang di-unmount. Jadi pertanyaan "apa yang terjadi pada request HTTP yang sedang jalan saat pod-nya direbut" **tidak terjawab oleh lab ini** dan harus diuji di real plane dengan pod sungguhan di Sprint 2.

---

## 4. Angka quota yang aku usulkan

Kapasitas: 8 GPU, 4 per node. Ketegangan intinya:

- **Sisihkan kapasitas** → produksi terjamin, tapi GPU idle terbuang saat produksi sepi
- **Oversubscribe** → utilisasi maksimal, tapi batch jadi tidak bisa diprediksi

Itu keputusan bisnis, bukan keputusan teknis.

**Opsi A — partisi keras.** Produksi dapat `gpu-worker-01` lewat taint + nodeSelector, batch dapat `gpu-worker-02`. Produksi tidak pernah jadi korban dan tidak pernah perlu merebut. Harganya: kalau produksi cuma pakai 1 GPU, tiga GPU menganggur dan batch tidak boleh menyentuhnya.

**Opsi B — prioritas tanpa partisi.** Semua tenant di kedua node, produksi 10000, batch 8000, quota batch dibuat lebih besar dari kapasitas sisa. Utilisasi tinggi, tapi batch sering mati — dan itu harus jadi ekspektasi yang disepakati, bukan kejutan.

**Opsi C — campuran.** Sisihkan 2 GPU untuk produksi, 6 sisanya diperebutkan dengan prioritas.

`[KEPUTUSANMU]` Pilih satu, tulis angka quota per tier di sini, dan sebutkan alasannya. Ini yang akan ditanyakan atasanmu, dan jawabannya harus bisa kamu pertahankan.

`[KEPUTUSANMU]` Berapa GPU yang kamu tahan dari alokasi tenant sebagai headroom untuk RAG Essentials dan replika autoscaling? Angka ini baru bisa dijawab setelah dokumen perencanaan kapasitas di Sprint 3 — sementara ini tulis dugaanmu supaya nanti bisa dibandingkan.

`[KEPUTUSANMU]` Apakah tenant batch boleh memakai PriorityClass `lab-interactive`? PriorityClass itu objek global, jadi secara default siapa pun bisa memakainya dan menghindari preemption. Kalau tidak boleh, batasi lewat RBAC atau `ResourceQuota` dengan `scopeSelector`. Putuskan dan tulis alasannya.

---

## 5. Yang belum selesai

- [ ] Ulangi eksperimen 5–10 kali, konfirmasi hipotesis tiebreak di bagian 2
- [ ] Uji ulang dengan PDB dipasang, lihat apakah kriteria 1 mengubah pilihan node
- [ ] Uji ulang dengan prioritas batch yang berbeda-beda (8000 vs 9000), lihat kriteria 2 bekerja
- [ ] Isi tiga `[KEPUTUSANMU]` di bagian 4
- [ ] Uji mekanika preemption pada pod sungguhan di Sprint 2
