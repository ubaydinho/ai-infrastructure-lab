# Panduan konsep — dari docker-compose ke lab ini

Ditulis untuk dibaca berurutan, tapi tiap bagian berdiri sendiri. Semua contoh diambil dari file yang benar-benar ada di repo ini.

**Urutan baca yang aku sarankan:** bagian 1 dan 2 sekali duduk (30 menit). Bagian 3 dan 4 saat kamu sedang di depan cluster. Bagian 5 tentang Helm baru saat mau bikin chart. Bagian 6 buat rujukan.

---

## 1. Tiga nama yang mirip dan sering tertukar

Ini penyebab kebingungan yang paling murah untuk dibereskan.

| Nama | Apa itu | Perannya di lab kamu |
|---|---|---|
| **Kubernetes** / **k8s** | Softwarenya sendiri. "k8s" = k + 8 huruf + s, cuma singkatan | Konsep yang kamu pelajari |
| **k3s** | Distribusi Kubernetes dari Rancher. API-nya sama persis, tapi dibungkus jadi satu binary kecil | Kubernetes yang benar-benar jalan di laptop kamu |
| **k3d** | Alat untuk menjalankan k3s **di dalam container Docker** | Yang bikin 3 "node" kamu, padahal cuma 1 laptop |
| **k9s** | Tampilan terminal untuk **melihat** cluster Kubernetes apa pun | GUI yang kamu pakai tadi. Tidak menjalankan apa pun |

Analoginya: kalau Kubernetes itu "Linux", maka k3s itu "Ubuntu" — distribusi, bukan barang berbeda. k3d itu semacam alat yang menjalankan Ubuntu di dalam container. Dan k9s itu `htop`: cuma melihat, tidak mengatur.

**Konsekuensi praktis:** semua yang kamu pelajari di k3s berlaku di platform produksi, karena API-nya identik. Yang berbeda cuma cara komponennya dipaket. Satu contoh nyata: di k3s, apiserver dan scheduler digabung jadi satu proses, jadi kamu tidak melihatnya sebagai pod di `kube-system`. Di Kubernetes normal dan di platform produksi, keduanya pod yang kelihatan.

---

## 2. YAML — cuma cara menulis data bersarang

YAML bukan bahasa pemrograman. Tidak ada logika, tidak ada perulangan. Dia cuma format untuk menuliskan data, seperti JSON tapi lebih enak dibaca.

### Lima aturan yang menutupi 95% kebutuhan

**1. `kunci: nilai`**

```yaml
name: batch-1
replicas: 3
```

**2. Indentasi = bersarang.** Spasi, **tidak boleh tab sama sekali**. Ini sumber error paling sering.

```yaml
metadata:
  name: batch-1        # 'name' ada DI DALAM 'metadata'
  namespace: default
```

**3. Tanda `-` = anggota daftar**

```yaml
containers:            # daftar berisi 1 anggota
  - name: trainer
    image: fake-image:latest
tolerations:           # daftar berisi 2 anggota
  - key: a
  - key: b
```

**4. `{ }` dan `[ ]` = bentuk singkat.** Dua penulisan ini identik artinya:

```yaml
labels:
  team: riset
  tier: batch
```
```yaml
labels: { team: riset, tier: batch }
```

File di repo ini pakai bentuk singkat supaya pendek. Kalau bingung, tulis bentuk panjang — hasilnya sama.

**5. `---` = pemisah dokumen.** Satu file bisa memuat beberapa objek. Lihat `sim/priorityclasses.yaml`: dua `PriorityClass` dalam satu file, dipisah `---`.

### Kutip itu bukan hiasan

```yaml
gpu: 4          # angka
gpu: "4"        # teks
sim: true       # boolean
sim: "true"     # teks
```

Kubernetes rewel soal ini. Beberapa field wajib teks meski isinya angka — itu sebabnya di repo ini ada `nvidia.com/gpu: "1"` dan `sim: "true"` yang dikutip. Kalau salah, error-nya bunyi seperti *cannot unmarshal number into string*.

### Pola yang sama di SEMUA manifest Kubernetes

Ini kunci yang membuka segalanya. Setiap objek Kubernetes, apa pun jenisnya, punya empat kunci teratas yang sama:

```yaml
apiVersion: ...   # versi API yang dipakai
kind: ...         # jenis objeknya
metadata: ...     # nama, namespace, label — identitas
spec: ...         # KEINGINAN kamu
status: ...       # diisi SISTEM, bukan kamu
```

`apiVersion`, `kind`, `metadata` selalu sama polanya. Yang berbeda antar jenis objek cuma isi `spec`.

Dan pembagian `spec` versus `status` itu justru inti model Kubernetes: **`spec` kamu yang tulis, `status` sistem yang tulis.** Kamu menyatakan keinginan di `spec`, robot-robot mewujudkannya dan melaporkan hasilnya di `status`.

### Bedah file kamu sendiri

`sim/workloads/batch-1gpu.yaml`, baris per baris:

```yaml
apiVersion: v1                    # Pod ada di API "core", jadi cuma v1 tanpa awalan
kind: Pod                         # jenis objek: Pod
metadata:
  name: batch-1                   # nama objek, unik dalam satu namespace
  labels: { team: riset, tier: batch, sim: "true" }
                                  # label = stiker untuk penyaringan.
                                  # Ini yang bikin 'kubectl delete pod -l sim=true' bisa jalan
spec:                             # ---- mulai bagian keinginan ----
  priorityClassName: lab-batch   # rujuk ke objek PriorityClass bernama itu
  nodeSelector: { type: kwok }    # HANYA mau node yang punya label type=kwok
  tolerations:                    # izin mendarat di node yang di-taint
    - key: kwok.x-k8s.io/node
      operator: Equal
      value: fake
      effect: NoSchedule
  containers:                     # daftar container di dalam pod ini
    - name: trainer
      image: fake-image:latest
      resources:
        requests: { cpu: "8", memory: 64Gi, nvidia.com/gpu: "1" }
        limits:   { cpu: "8", memory: 64Gi, nvidia.com/gpu: "1" }
```

Empat hal yang layak diperhatikan:

- **Tidak ada `status`.** Kamu tidak pernah menulisnya. Coba `kubectl get pod batch-1 -o yaml` — status-nya panjang, dan semuanya ditulis sistem.
- **Tidak ada `nodeName`.** Kamu tidak menentukan node. Scheduler yang menulisnya ke `spec.nodeName`. Ini satu-satunya field `spec` yang diisi robot, dan itulah keanehan yang bikin kamu heran sebelumnya.
- **`requests` versus `limits`.** `requests` dipakai scheduler untuk memutuskan pod muat di mana. `limits` adalah pagar saat berjalan. Untuk resource biasa seperti CPU, keduanya boleh berbeda. Untuk GPU dan resource extended lain, **wajib sama** — jadi tidak ada overcommit GPU.
- **`nodeSelector` + `tolerations` bekerja berpasangan.** Selector = "aku maunya node begini". Toleration = "aku tahan dengan pagar di node itu". Butuh keduanya untuk masuk node ber-taint.

### Alat bantu terpenting untuk belajar YAML

```bash
kubectl explain pod.spec.containers.resources
kubectl explain resourcequota.spec
kubectl api-resources | head -40
```

`kubectl explain` adalah dokumentasi bawaan Kubernetes. Setiap field, setiap jenis objek, langsung dari cluster kamu — jadi versinya selalu cocok. Kalau kamu bingung sebuah field ada atau tidak, tanya ini dulu sebelum googling.

---

## 3. Cara kerja Kubernetes

Satu perbedaan dari compose, dan semua hal lain turun dari sini.

```
docker compose:
  compose.yml  ->  docker compose  ->  container jalan
                   (bikin langsung)

kubernetes:
  pod.yaml  ->  kubectl apply  ->  API server  <-  robot-robot
                (cuma menulis)     (database)      (baca, bandingkan, bertindak)
```

Di compose kamu memberi **perintah**. Di Kubernetes kamu menuliskan **keinginan** ke sebuah database, dan sekumpulan robot terus-menerus membandingkan isi database dengan kenyataan, lalu bertindak untuk menyamakan keduanya. Robot itu jalan selamanya, tidak peduli terminal kamu sudah ditutup.

Namanya **loop rekonsiliasi**, dan itu satu-satunya ide besar di Kubernetes.

### Robot yang sudah kamu lihat bekerja

| Robot | Tugasnya | Kamu lihat waktu |
|---|---|---|
| **scheduler** | Baca pod tanpa `nodeName`, pilih node, tulis keputusannya | Event `Scheduled` dan `Preempted` |
| **kubelet** | Di setiap node: jalankan container yang ditugaskan ke node itu | Pod jadi `Running` |
| **kwok-controller** | Palsukan kubelet untuk node palsu | `gpu-worker-01` jadi `Ready` tanpa mesin |
| **kyverno** | Periksa setiap objek **sebelum** ditulis ke database, tolak yang tidak patuh | Belum — Sprint 1 |

Perhatikan Kyverno: dia duduk **di antara** `kubectl apply` dan database. Itu namanya admission control, dan tidak ada padanannya di compose.

### Kenapa preemption terasa aneh, dan sekarang tidak lagi

Urutan yang kamu lihat di event log: `FailedScheduling` → `Preempted` → `Scheduled`.

Scheduler tidak "tahu" harus merebut slot. Dia mencoba, gagal, mencari korban, mencoba lagi. Itu loop rekonsiliasi dalam bentuk paling mentah. Karena itu `FailedScheduling` bukan error yang perlu diperbaiki — dia langkah normal. Yang perlu dikhawatirkan adalah `FailedScheduling` yang tidak diikuti `Scheduled`.

---

## 4. Objek-objek di repo ini, dan yang akan menyusul

### Yang sudah ada

**`Node`** — `sim/nodes/gpu-worker-0{1,2}.yaml`

Pendaftaran sebuah mesin ke cluster. Normalnya kubelet yang membuatnya otomatis saat sebuah server bergabung. Di sini kamu menulisnya dengan tangan, dan **itulah seluruh trik lab ini** — karena tidak ada satu pun bagian Kubernetes yang memverifikasi bahwa `nvidia.com/gpu: "4"` itu benar. Kubernetes cuma pembukuan.

Catatan penting: `status` pada Node hanya diterima saat objeknya **dibuat**. Kalau kamu ubah jumlah GPU di file itu, `kubectl apply` tidak akan berpengaruh. Harus `kubectl delete node gpu-worker-01` dulu.

**`PriorityClass`** — `sim/priorityclasses.yaml`

Cuma sebuah nama yang dipetakan ke angka. `lab-batch` = 8000, `lab-interactive` = 10000. Pod merujuknya lewat `spec.priorityClassName`.

Objek ini **global**, tidak berada di dalam namespace mana pun. Konsekuensinya: secara default tenant mana pun bisa memakai `lab-interactive` dan menghindari preemption. Itu salah satu `[KEPUTUSANMU]` di dokumen rasional quota.

**`Pod`** — `sim/workloads/*.yaml`

Unit terkecil yang bisa dijalankan Kubernetes. Isinya satu atau lebih container yang **berbagi jaringan dan storage** — di dalam satu pod, container saling memanggil lewat `localhost`.

Beda penting dari compose: satu service di compose ≈ satu pod. Tapi pod bisa memuat beberapa container yang memang harus hidup dan mati bersama. Di Sprint 2 kamu akan melihatnya: pod KServe berisi container model kamu **plus** sidecar `queue-proxy` yang menghitung concurrency untuk autoscaler.

Dan satu hal yang sudah kamu buktikan sendiri: **Pod telanjang tidak pernah dihidupkan ulang.** batch-5 dan batch-8 mati dan tidak pernah balik, karena tidak ada objek pemilik yang mengawasinya. `restartPolicy: Always` tidak menolong — field itu mengatur restart container di dalam pod yang **masih hidup**, bukan menghidupkan objek pod yang sudah dihapus.

### Yang akan kamu bangun di Sprint 1

Lima objek, dan aku sarankan kamu tulis sebagai YAML biasa dulu sebelum jadi chart Helm.

**`Namespace`** — folder logis di dalam cluster. Nama objek harus unik per namespace, bukan per cluster. Tidak ada padanannya di compose. Ini fondasi multi-tenancy: satu tenant = satu namespace.

**`ResourceQuota`** — batas atas total yang boleh **diminta** seluruh pod dalam satu namespace.

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: quota-tenant-a
  namespace: tenant-a
spec:
  hard:
    requests.nvidia.com/gpu: "2"
    requests.cpu: "32"
    requests.memory: 128Gi
    pods: "30"
```

Yang wajib kamu pahami, dan sudah kamu tulis di dokumen sendiri: **quota bukan jaminan.** Dia membatasi berapa yang boleh diminta, tidak menyisihkan apa pun. Tenant berquota 2 GPU bisa jalan dengan 2 GPU lalu tinggal 0 dalam dua detik karena preemption, tanpa quota-nya berubah.

**`LimitRange`** — nilai default dan batas per container di dalam satu namespace. Gunanya: menyelamatkan kamu dari pod tanpa `requests` yang menelan seluruh node. ResourceQuota mengatur totalnya, LimitRange mengatur satuannya.

**`ServiceAccount` + `Role` + `RoleBinding`** — tiga objek untuk satu tujuan: siapa boleh melakukan apa.

- `ServiceAccount` = identitas
- `Role` = daftar izin (verb + resource), **berlaku dalam satu namespace**
- `RoleBinding` = menempelkan Role ke ServiceAccount

Ada versi cluster-wide-nya: `ClusterRole` dan `ClusterRoleBinding`. Aturan praktisnya, pakai `Role` kecuali izinnya memang harus lintas namespace.

**`NetworkPolicy`** — aturan firewall antar pod, berbasis label. Default Kubernetes: semua pod boleh menghubungi semua pod. Setelah ada NetworkPolicy yang menyeleksi sebuah pod, hanya yang diizinkan eksplisit yang boleh.

Jebakan yang akan menggigit kamu: kalau kamu tulis default-deny tanpa mengizinkan port 53, DNS mati dan semuanya rusak dengan cara yang membingungkan. Selalu izinkan DNS ke `kube-system`.

Catatan: NetworkPolicy butuh CNI yang menegakkannya. k3s sudah membawanya, jadi di lab ini berfungsi. Tapi **tidak** berlaku pada pod palsu di node KWOK — tidak ada jaringan nyata di sana. Latihan NetworkPolicy harus di real plane.

---

## 5. Helm — kenapa ada, dan kenapa atasanmu menyebutnya

### Masalah yang dipecahkannya

Sprint 1 menghasilkan 5 objek untuk satu tenant. Tiga tenant = 15 file, yang 90% isinya identik, beda cuma nama namespace dan beberapa angka.

Copy-paste 15 file itu jalan sampai kamu perlu mengubah satu hal di semuanya. Lalu kamu lupa satu file, dan satu tenant punya konfigurasi berbeda tanpa ada yang sadar sampai enam bulan kemudian.

### Apa itu Helm

**Template + nilai.** Kamu tulis manifest sekali dengan bagian yang bisa diisi, taruh nilainya di `values.yaml`, lalu Helm menggabungkan keduanya jadi YAML biasa dan mengirimkannya ke cluster.

```yaml
# templates/quota.yaml
spec:
  hard:
    requests.nvidia.com/gpu: "{{ .Values.tiers.small.gpu }}"
```
```yaml
# values.yaml
tiers:
  small: { gpu: 1 }
```

`helm install tenant-a` mengisi cetakan itu dan mengirim hasilnya.

Tiga hal yang perlu kamu tahu, dan sering disalahpahami:

**1. Helm bukan bagian dari Kubernetes.** Dia alat di laptop kamu yang menghasilkan YAML lalu mengirimnya lewat API yang sama seperti `kubectl`. Cluster tidak tahu apa itu Helm.

**2. Helm mengingat apa yang dia pasang.** Sekumpulan objek yang dipasang bersama disebut **release**, dan catatannya disimpan sebagai Secret di dalam namespace. Karena itu `helm uninstall tenant-a` menghapus kelima objek sekaligus. `kubectl apply` tidak punya ingatan — kalau kamu hapus satu baris dari file lalu apply ulang, objek yang hilang dari file tetap tertinggal di cluster.

**3. `helm template` menampilkan hasilnya tanpa menyentuh cluster.**

```bash
helm template tenant-a charts/_archive/tenant-bootstrap
```

Ini alat belajar terbaik untuk Helm. Kamu lihat persis YAML apa yang akan dikirim. Kalau hasilnya salah, itu salah template. Kalau hasilnya benar tapi cluster menolak, itu salah YAML. **Perintah ini memisahkan dua sumber error yang berbeda** — dan itu alasan aku menyarankan kamu menulis YAML biasa dulu sebelum belajar Helm, supaya kamu tidak mendebug keduanya sekaligus.

### Kenapa ini penting untuk platform produksi

**Import Framework di platform produksi adalah Helm chart.** Itu sebabnya atasanmu menyebutnya. Struktur yang mereka minta — `templates/ezua/virtualService.yaml`, `templates/ezua/kyverno.yaml` — adalah struktur chart Helm. Kalau kamu ingin memasukkan aplikasi ke platform produksi, kamu mengirim Helm chart.

Isi sebuah chart:

```
charts/_archive/tenant-bootstrap/
├── Chart.yaml        # nama, versi, deskripsi chart
├── values.yaml       # nilai default, bisa ditimpa saat install
└── templates/        # manifest dengan bagian yang bisa diisi
    ├── namespace.yaml
    ├── quota.yaml
    └── ...
```

---

## 6. Peta repo

| Path | Isi | Kapan disentuh |
|---|---|---|
| `Makefile` | Kumpulan perintah dengan profil memori. `make help` | Terus |
| `cluster/k3d.yaml` | Resep cluster: 1 server + 2 agent, traefik aktif sebagai ingress | Jarang |
| `cluster/registries.yaml` | Pengalihan pull image ke registry lokal | Sprint 4 |
| `scripts/preflight.sh` | Cek RAM, disk, tooling | Sebelum mulai kerja |
| `scripts/install-tools.sh` | Pasang kubectl, k3d, helm, dll | Sekali |
| `sim/nodes/` | Dua node H200 palsu | Sudah jadi |
| `sim/priorityclasses.yaml` | 8000 dan 10000 | Sudah jadi |
| `sim/workloads/` | Pod palsu untuk eksperimen | Sprint 1 |
| `sim/scenarios/` | Skrip eksperimen yang bisa diulang | Sprint 1 |
| `charts/_archive/tenant-bootstrap/` | Chart multi-tenancy — diarsipkan di v2, tetap dilint | Sprint 1 |
| `charts/ai-app-import/` | Chart bergaya Import Framework | Sprint 2 |
| `serving/` | KServe RawDeployment, InferenceService per site | Sprint 2 |
| `capacity/` | Kalkulator KV cache | Sprint 3 |
| `observability/` | DCGM sintetis, alert, unit test | Sprint 4 |
| `airgap/` | Mirror image, putus egress, verifikasi | Sprint 4 |
| `docs/` | Artifact tulisan — bagian yang paling bernilai | Setiap sprint |

### Arsitektur lab dalam satu gambar

```
  laptop, 7 GB
  ┌──────────────────────────────────────────────────────────┐
  │  container docker (dari k3d) — ini "mesin", bukan aplikasi│
  │                                                          │
  │  ┌────────────────────────┐  ┌────────────────────────┐  │
  │  │ k3d-lab-server-0       │  │ agent-0, agent-1       │  │
  │  │                        │  │                        │  │
  │  │  proses k3s:           │  │  kubelet + containerd  │  │
  │  │   - apiserver (database)│ │  kwok-controller       │  │
  │  │   - scheduler (robot)  │  │  local-path-provisioner│  │
  │  │   - controller-manager │  │  kyverno               │  │
  │  │  coredns, cert-manager │  │                        │  │
  │  └────────────────────────┘  └────────────────────────┘  │
  └──────────────────────────────────────────────────────────┘

  gpu-worker-01, gpu-worker-02   <- NOL container.
  4x nvidia.com/gpu masing-masing   Cuma baris di database,
                                    dipalsukan Ready oleh kwok.
```

Node palsu itu bukan tipuan murahan. Karena Kubernetes memang cuma pembukuan, **keputusan** scheduler di atas node palsu identik dengan keputusan di atas H200 sungguhan. Yang tidak identik adalah **mekanika**-nya: tidak ada container yang benar-benar dimatikan, tidak ada koneksi yang di-drain, tidak ada throughput yang bisa diukur. Itu sebabnya Sprint 2 memakai model kecil sungguhan di real plane, dan Sprint 3 menyewa GPU satu weekend.

---

## 7. Glosarium cepat

| Istilah | Artinya |
|---|---|
| **manifest** | File YAML berisi satu objek Kubernetes |
| **objek** / **resource** | Satu baris di database Kubernetes: Pod, Node, Namespace, dll |
| **CRD** | *Custom Resource Definition* — cara menambah jenis objek baru. `InferenceService` di Sprint 2 adalah CRD |
| **controller** | Robot yang mengawasi satu jenis objek dan bertindak. Sinonim praktis: operator |
| **namespace** | Folder logis. Nama objek unik per namespace |
| **label** | Stiker `kunci=nilai` untuk penyaringan. `-l sim=true` |
| **annotation** | Seperti label tapi untuk metadata, tidak untuk penyaringan |
| **selector** | Penyaring berbasis label. `nodeSelector` memilih node |
| **taint / toleration** | Pagar di node / izin melewatinya |
| **spec vs status** | Keinginan kamu vs laporan sistem |
| **reconciliation loop** | Bandingkan keinginan dengan kenyataan, bertindak, ulangi selamanya |
| **admission control** | Pemeriksaan sebelum objek masuk database. Kyverno bekerja di sini |
| **extended resource** | Resource non-standar seperti `nvidia.com/gpu`. Wajib `requests == limits` |
| **release** (Helm) | Sekumpulan objek yang dipasang bersama oleh Helm |
| **chart** (Helm) | Paket berisi template + values |

---

## 8. Tiga latihan untuk memantapkan bagian 2 dan 3

Semua murah, semua di cluster yang sudah jalan.

**Latihan 1 — lihat apa yang sistem tulis.**

```bash
kubectl apply -f sim/workloads/batch-1gpu.yaml
kubectl get pod batch-1 -o yaml > /tmp/hasil.yaml
diff sim/workloads/batch-1gpu.yaml /tmp/hasil.yaml | head -40
```

Semua yang muncul di `/tmp/hasil.yaml` tapi tidak ada di file aslimu ditulis oleh sistem. Cari `nodeName`, `status`, `uid`, `resourceVersion`.

**Latihan 2 — rusakkan YAML-nya sengaja.** Ganti indentasi satu baris, atau hapus tanda kutip di `nvidia.com/gpu: "1"`, lalu apply. Baca pesan errornya. Pesan error YAML punya bentuk yang khas, dan mengenalinya menghemat berjam-jam nanti.

**Latihan 3 — pakai dokumentasi bawaan.**

```bash
kubectl explain pod.spec
kubectl explain pod.spec.tolerations
kubectl explain resourcequota.spec.hard
```

Biasakan ini sebelum googling. Jawabannya selalu cocok dengan versi cluster kamu, dan itu tidak dijamin oleh blog mana pun.
