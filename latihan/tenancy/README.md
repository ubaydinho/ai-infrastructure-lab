# Latihan: lima objek yang membentuk satu tenant

YAML biasa, bukan Helm. Sengaja. Helm adalah lapisan template **di atas** objek-objek ini — kalau dipelajari bersamaan, saat error kamu tidak akan tahu itu salah YAML atau salah template. Kuasai objeknya dulu, konversi ke chart belakangan.

Lima sesi, masing-masing 20–40 menit. Satu sesi per malam sudah bagus. Setiap sesi punya langkah **rusakkan sengaja** — di situ letak pelajarannya, bukan di `apply` yang sukses.

Prasyarat: `make up-core && make up-sim` sudah jalan.

---

## Sesi 1 — Namespace

```bash
kubectl apply -f 01-namespace.yaml
kubectl get ns tenant-a --show-labels
```

**Rusakkan:** bikin pod bernama `batch-1` di `tenant-a`, padahal nama itu sudah dipakai di `default`.

```bash
kubectl apply -f test-pods/gpu-1.yaml
kubectl get pods -A | grep -E 'gpu-1|batch-1'
```

Tidak bentrok. **Nama objek unik per namespace, bukan per cluster.** Ini fondasi multi-tenancy: tiap tim bebas menamai apa pun tanpa berkoordinasi.

**Catat:** apa yang terjadi kalau kamu `kubectl get pods` tanpa `-n tenant-a`?

---

## Sesi 2 — ResourceQuota

```bash
kubectl apply -f 02-resourcequota.yaml
kubectl describe quota -n tenant-a
```

Kolom `Used` versus `Hard`. `gpu-1` dari sesi 1 sudah memakai 1 dari 1 GPU.

**Rusakkan — minta GPU kedua padahal quota cuma 1:**

```bash
kubectl apply -f test-pods/gpu-2.yaml
```

Ditolak. Baca pesannya pelan-pelan — dia menyebut resource mana, dipakai berapa, batasnya berapa.

**Ini bedanya dari preemption**, dan penting: pod ditolak **saat apply**, tidak pernah masuk database, tidak pernah jadi Pending. Preemption terjadi setelah pod diterima; quota menolak sebelum itu. Dua mekanisme berbeda di dua tahap berbeda.

**Rusakkan lagi — pod tanpa blok resources sama sekali:**

```bash
kubectl apply -f test-pods/tanpa-resources.yaml
```

Juga ditolak, tapi dengan alasan berbeda: begitu sebuah namespace punya quota untuk cpu/memory, setiap pod **wajib** menyatakan requests-nya. Ingat pesan ini — sesi berikutnya memperbaikinya.

---

## Sesi 3 — LimitRange

```bash
kubectl apply -f 03-limitrange.yaml
kubectl apply -f test-pods/tanpa-resources.yaml    # pod yang tadi ditolak
```

Sekarang **diterima**. Lihat apa yang berubah:

```bash
kubectl get pod tanpa-resources -n tenant-a -o yaml | grep -A6 resources:
```

Blok `resources` terisi, padahal file YAML-mu kosong. LimitRange mengisinya lewat `defaultRequest`, lalu pod itu lolos ResourceQuota.

**Ini interaksi arsitektural yang paling sering tidak dipahami orang:** LimitRange dan ResourceQuota bekerja berpasangan. Quota menuntut setiap pod menyatakan kebutuhannya; LimitRange yang menyediakan jawabannya untuk pod yang tidak menyatakan. Tanpa LimitRange, satu tenant baru akan mengeluh "semua pod saya ditolak" dan kamu akan lama mencarinya.

**Rusakkan:** ubah `max.memory` di `03-limitrange.yaml` jadi `16Gi`, apply ulang, lalu coba `test-pods/gpu-1.yaml` yang minta 32Gi.

---

## Sesi 4 — RBAC

```bash
kubectl apply -f 04-rbac.yaml
```

Uji izinnya tanpa perlu login sebagai siapa pun — `--as` membuat kamu berpura-pura jadi identitas lain:

```bash
SA=system:serviceaccount:tenant-a:tenant-a-user

kubectl auth can-i get pods    -n tenant-a --as=$SA     # yes
kubectl auth can-i delete pods -n tenant-a --as=$SA     # no
kubectl auth can-i get pods    -n default  --as=$SA     # no
kubectl auth can-i get nodes               --as=$SA     # no
kubectl auth can-i --list      -n tenant-a --as=$SA     # daftar lengkap
```

Empat baris itu adalah seluruh model RBAC: **izin bersifat aditif** (tidak ada aturan "deny"), dan **Role hanya berlaku di namespace-nya sendiri**.

**Rusakkan:** tambahkan `delete` ke `verbs` di Role, apply ulang, jalankan lagi baris kedua. Lalu kembalikan.

**Pertanyaan untuk dokumenmu:** tenant boleh `get` pod tapi tidak boleh `delete`. Apakah itu masuk akal untuk tim data science yang harus membatalkan job sendiri? Ini keputusan platform, bukan teknis.

---

## Sesi 5 — NetworkPolicy

Butuh pod **sungguhan** — pod KWOK tidak punya jaringan nyata.

```bash
kubectl apply -f test-pods/real-busybox.yaml
kubectl get pod real-busybox -n tenant-a -o wide      # mendarat di node k3d asli
```

Uji koneksi keluar sebelum policy dipasang:

```bash
kubectl exec -n tenant-a real-busybox -- nslookup kubernetes.default
kubectl exec -n tenant-a real-busybox -- wget -qO- --timeout=5 http://kyverno-svc.kyverno:443 2>&1 | head -2
```

Sekarang pasang default-deny **tanpa** aturan DNS. Edit `05-networkpolicy.yaml`, buang dokumen kedua (`allow-dns`), lalu:

```bash
kubectl apply -f 05-networkpolicy.yaml
kubectl exec -n tenant-a real-busybox -- nslookup kubernetes.default
```

DNS mati. Inilah kesalahan nomor satu saat pertama memakai NetworkPolicy, dan gejalanya menyesatkan — aplikasi melapor "host tidak ditemukan", bukan "jaringan diblokir".

Kembalikan `allow-dns`, apply ulang, uji lagi. Hidup.

**Rusakkan:** ubah `podSelector: {}` jadi `podSelector: { matchLabels: { app: tidak-ada } }`. Policy jadi tidak menyeleksi pod mana pun, dan semuanya terbuka lagi. `podSelector` menentukan **siapa yang diatur**, bukan siapa yang diizinkan.

---

## Penutup

```bash
kubectl get all,quota,limitrange,networkpolicy,sa,role,rolebinding -n tenant-a
```

Itu satu tenant lengkap. Tujuh jenis objek, dan kamu sudah tahu apa yang terjadi kalau masing-masing salah.

Bersihkan — hapus namespace-nya, semua isinya ikut terhapus:

```bash
kubectl delete ns tenant-a
```

**Selanjutnya:** ubah kelima file ini jadi satu chart Helm — hasilnya ada di
`charts/_archive/tenant-bootstrap/` (diarsipkan saat lab beralih ke serving layer, tetap bisa dibaca) — dengan `tier` (small/medium/dedicated) sebagai nilai yang bisa diganti. Sekarang kamu sudah tahu objek apa yang dihasilkan chart itu — jadi kalau template-nya salah, kamu bisa membedakannya dari YAML yang salah.

**Yang wajib ditulis ke `docs/10-quota-rationale.md` setelah sesi 5:** urutan penolakan. Quota menolak saat apply. LimitRange mengisi yang kosong. RBAC menolak berdasarkan identitas. NetworkPolicy menolak setelah pod jalan. Empat lapis penolakan di empat tahap berbeda — dan tenant yang mengeluh "kenapa tidak jalan" bisa tersangkut di mana saja.
