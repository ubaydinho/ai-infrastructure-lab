# Substrate Lab v2 — Simulasi Serving Layer

## Kenapa direvisi

Lab awal (Sprint 0-1) dirancang di sekitar multi-tenancy: chart `tenant-bootstrap` dengan tier small/medium/dedicated, ResourceQuota per tim. Setelah melihat gambaran platform produksi yang sebenarnya — lewat satu meeting dan dua workbook monitoring resmi — scope kerja ternyata jauh lebih sempit:

- Satu client, dua model (Llama + DeepSeek), pod tetap tanpa autoscaling
- Serving-only: RAG dan data ada sepenuhnya di sisi client
- Dua site active-active, masing-masing satu unit platform ukuran Medium
- Monitoring resmi menyebut tool spesifik: KServe/Triton untuk endpoint inferensi, Prometheus + Grafana + Alertmanager untuk observability, Harbor untuk registry

Lab v2 mengganti fokus dari "platform multi-tenant" ke "serving layer yang bisa gagal dan pulih", supaya artifact yang dihasilkan (angka kapasitas, perilaku failover, model lifecycle) langsung relevan ke pekerjaan asli.

Sprint 0 dan chart `tenant-bootstrap` dari Sprint 1 **tidak dihapus** — tetap valid sebagai contoh RBAC/NetworkPolicy/Helm testing, hanya bukan lagi jalur utama. Lihat "Yang tetap dipakai" di bawah.

## Keputusan: RAG dikesampingkan

RAG itu milik client, bukan milik kita, dan kita tidak punya gambaran arsitekturnya sama sekali — framework apa, vector DB apa, chunking strategy apa. Mensimulasikannya berarti menebak, bukan belajar sesuatu yang bisa diverifikasi. Lab ini berhenti di titik yang sama dengan tanggung jawab kerja sebenarnya: menerima HTTP request di endpoint model, mengembalikan token. Apa pun yang terjadi sebelum request itu sampai (retrieval, prompt construction) ada di luar boundary lab maupun boundary pekerjaan.

## Prinsip untuk bagian yang belum diketahui

Beberapa detail produksi belum bisa diverifikasi (load balancer persis apa, apakah InferenceService CRD atau Deployment polos, Istio penuh atau ingress controller lain). Untuk tiap bagian yang tidak pasti, lab memakai default yang **paling dekat dengan yang tersirat dari checklist resmi** (nama tool yang disebut eksplisit di dokumen monitoring) — bukan arsitektur berbeda. Setiap asumsi ditandai eksplisit di bagian "Asumsi & cara verifikasi" supaya gampang dikoreksi begitu ada akses hands-on.

## Arsitektur yang disimulasikan

```
RAG milik client (DI LUAR SCOPE — tidak disimulasikan)
        |  HTTPS, format OpenAI-compatible
        v
+-------------------------------------------------------+
|   namespace: site-a          namespace: site-b         |
|   +------------------+       +------------------+      |
|   | Ingress (Traefik) |       | Ingress (Traefik) |      |
|   +--------+---------+       +--------+---------+      |
|            v                          v                |
|   +------------------+       +------------------+      |
|   | InferenceService  |       | InferenceService  |      |
|   |  llama-sim (Raw)  |       |  llama-sim (Raw)  |      |
|   |  deepseek-sim(Raw)|       |  deepseek-sim(Raw)|      |
|   +--------+---------+       +--------+---------+      |
|            v                          v                |
|      predictor pods              predictor pods        |
|      (llama.cpp, model 135M beneran jalan)              |
+-------------------------------------------------------+
        |
        v
  KWOK plane (simulasi 8x H200 lintas 2 site, fake node)
  dipakai untuk skenario kapasitas & preemption tanpa
  GPU sungguhan
```

Dua plane dari Sprint 0 tetap dipertahankan: plane nyata (k3d asli, model kecil beneran jalan) untuk uji fungsional, dan plane KWOK (fake node besar) untuk uji skenario kapasitas/preemption yang butuh skala GPU besar tanpa GPU sungguhan.

## Pemetaan komponen

| Lapisan | Production (dari checklist resmi) | Lab v2 | Status |
|---|---|---|---|
| Model serving | KServe / Triton dashboard (item checklist 27) | KServe InferenceService, RawDeployment mode | Sesuai — nama tool sama persis |
| Ingress / load balancer | Belum dikonfirmasi; kemungkinan Istio (default KServe) | Traefik (bawaan k3d) | **ASUMSI** — lihat di bawah |
| Serving engine | vLLM (dikonfirmasi langsung) | llama.cpp, endpoint OpenAI-compatible | **Simplifikasi karena RAM** — image vLLM 4 GB + butuh GPU; permukaan API (`/v1/chat/completions`, `/v1/models`) identik. Alasan lengkap di `serving/runtimes/llamacpp-openai.yaml` |
| Monitoring | Grafana + Prometheus + Alertmanager (item 30-32) | kube-prometheus-stack | Sesuai |
| Registry | Harbor + Trivy (item 28-29) | Registry bawaan k3d, tanpa Harbor penuh | Simplifikasi karena constraint RAM |
| RBAC / tenant | tenant-bootstrap chart (Sprint 1) | Diarsipkan sebagai referensi, bukan jalur utama | Dipertahankan, tidak dihapus |
| RAG | Milik client, di luar checklist EOS | Tidak disimulasikan | Di luar scope |
| Notebook / MLflow / Kubeflow | Ada di checklist tapi bukan tanggung jawab EOS | Tidak disimulasikan | Di luar scope (sesuai split fokus 80/20) |

## Kenapa RawDeployment, bukan Serverless (Knative)

KServe defaultnya jalan pakai Knative Serverless — itu yang paling sering muncul di tutorial. Tapi dokumentasi KServe sendiri menyarankan Standard/RawDeployment mode untuk generative inference (LLM), karena beban kerjanya panjang dan GPU-nya mahal — scale-to-zero justru kontraproduktif untuk pola ini. RawDeployment jalan di atas Deployment/Service/HPA biasa, tanpa Knative sama sekali.

Ini cocok ganda:

1. Match dengan kenyataan produksi — pod fixed, tanpa autoscaling, persis profil yang direkomendasikan RawDeployment untuk beban generative.
2. Jauh lebih ringan di laptop 8GB, karena tidak perlu install Knative + Istio penuh.

Ini bukan mengganti arsitektur. API `InferenceService` tetap sama persis, hanya execution mode yang beda. Kalau nanti dikonfirmasi produksi pakai Istio, tinggal ganti `ingressClassName` dari `traefik` ke `istio` di values — tidak perlu re-design.

## Asumsi & cara verifikasi

Wajib dicek ulang begitu ada akses hands-on. Jangan biarkan lab jadi sumber kebenaran palsu.

1. **Ingress**: lab pakai Traefik. Verifikasi produksi: `kubectl get ingressclass` dan `kubectl get pods -n istio-system` (kalau ada isinya, berarti Istio).
2. **Deployment mode KServe**: lab set RawDeployment eksplisit. Verifikasi: `kubectl get inferenceservice -A -o yaml | grep -i deploymentMode`, atau cek `kubectl get pods -A | grep knative` (kalau kosong, kemungkinan besar RawDeployment juga di produksi).
3. **Load balancing antar site**: sengaja tidak disimulasikan karena belum diketahui mekanismenya (DNS-based, LB terpusat, atau client pilih manual). **Ini tidak menghalangi lab berjalan** — testing di Sprint 2-4 mengakses site-a dan site-b langsung lewat endpoint masing-masing (header `Host`, tanpa DNS), bukan lewat satu LB gabungan. Skenario "site mati" di Sprint 4 dimatikan manual lewat anotasi `serving.kserve.io/stop`, bukan menunggu mekanisme failover otomatis yang belum diketahui bentuknya. Isi bagian ini begitu tahu mekanisme aslinya — nanti tinggal menambah satu layer di depan, bukan mengubah yang sudah dibangun.
4. **Registry**: lab skip Harbor penuh. Kalau nanti perlu simulasi vulnerability scanning, tambahkan Trivy standalone (ringan) daripada Harbor penuh (butuh Postgres + Redis).

## Yang tetap dipakai dari Sprint 0-1

- Scaffold k3d, Makefile dengan memory profile, preflight script — dipakai apa adanya
- Fake GPU nodes (KWOK plane) — dipakai apa adanya, jadi plane simulasi kapasitas
- Hasil eksperimen preemption (10 putaran, korban selalu 2 pod terbaru per node) — tetap relevan sebagai baseline pembanding skenario failover baru
- Chart `tenant-bootstrap` — dipindah ke `charts/_archive/tenant-bootstrap/`, tetap ada, bukan lagi dependency sprint berikutnya

## Rencana sprint (revisi)

**Sprint 2 — Serving plane dasar — SELESAI (2026-08-14)**
- Install KServe (RawDeployment mode) + Traefik IngressClass di plane nyata
- Deploy 2 InferenceService kecil mewakili "llama-sim" dan "deepseek-sim" — cukup untuk uji jalur request end-to-end, bukan benchmark performa model
- Duplikasi ke 2 namespace (`site-a`, `site-b`) dengan config identik
- Validasi: request OpenAI-compatible sampai ke kedua site dan dapat respons

  Bukti jalan, penyimpangan dari rencana, dan tiga temuan yang mengubah Sprint 3-4: **`docs/20-serving-plane.md`**. Reproduksi: `make up-serving && make smoke`.

**Sprint 3 — Observability — SELESAI (2026-08-14)**
- Install kube-prometheus-stack, resource request di-scope biar muat di 8GB
- Dashboard Grafana minimal: request rate, latency p95, status pod — per site
- Alert rule dasar: endpoint down, pod restart looping. Catatan dari Sprint 2: **jangan bangun alert "endpoint down" di atas condition `Ready` milik InferenceService** — condition itu jadi `False` selama rolling update normal padahal trafik tidak pernah putus. Ukur dengan request sungguhan, seperti `scripts/smoke-serving.sh`
- Ini jadi dasar pembanding waktu kamu lihat Grafana kantor beneran

  Bukti jalan + tiga temuan (yang terpenting: `up == 0` buta terhadap target yang hilang): **`docs/30-observability.md`**. Reproduksi: `make up-obs && make smoke`, lalu `make grafana`.

**Sprint 4 — Skenario kapasitas & failover**
- Load test terkontrol ke plane nyata (k6 atau locust), cari titik antrean mulai numpuk
- Simulasi "site mati": `kubectl annotate isvc <nama> -n site-a serving.kserve.io/stop=true`, ukur berapa lama site-b menyerap beban. **Jangan pakai `kubectl scale --replicas=0`** — controller KServe mengembalikannya dari `minReplicas` dalam ~8 detik (dibuktikan di Sprint 2, lihat `docs/20-serving-plane.md`)
- Pakai plane KWOK untuk skenario skala besar (8x H200 penuh) yang tidak muat di laptop
- Catatan dari Sprint 3: yang mendeteksi site mati adalah `SiteEndpointsAbsent` (berbasis `absent()`), **bukan** `up == 0` — waktu site dimatikan, target scrape-nya hilang dari service discovery dan `up` berhenti ada, bukan menjadi 0. Ukur durasi failover dari alert itu, atau langsung dari `traefik_service_requests_total` per site
- Output: draft angka kapasitas + runbook failover — bentuk yang sama dipakai di kerjaan asli

**Sprint 5 — Model lifecycle**
- Simulasi rollout versi model baru tanpa downtime (rolling update biasa; RawDeployment tidak dukung canary bawaan Knative)
- Dokumentasi prosedur rollback

## Instruksi untuk Claude Code

1. Baca struktur repo yang ada (`charts/`, `Makefile`, mapping doc Sprint 0) sebelum mengubah apa pun
2. Pindahkan `charts/tenant-bootstrap` ke `charts/_archive/tenant-bootstrap/` — jangan dihapus, update referensi CI kalau ada
3. Konfirmasi Traefik aktif bawaan k3d: `kubectl get pods -n kube-system | grep traefik`
4. Install KServe di mode RawDeployment (`kserve.controller.deploymentMode=RawDeployment` di Helm values) — jangan install Knative
5. Buat namespace `site-a` dan `site-b`, masing-masing 2 InferenceService (`llama-sim`, `deepseek-sim`) pakai model HF kecil
6. Validasi end-to-end: `curl` ke endpoint tiap site, pastikan dapat respons token
7. Baru lanjut ke Sprint 3 setelah Sprint 2 tervalidasi hijau — tiap sprint butuh bukti jalan (output command atau test lulus) sebelum lanjut ke sprint berikutnya
