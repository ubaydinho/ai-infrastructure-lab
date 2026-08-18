# Substrate Lab — Simulasi Serving Layer LLM

Lab lokal yang meniru serving layer inferensi LLM: dua site active-active, dua model per
site, pod fixed tanpa autoscaling, plus observability lengkap. Semuanya jalan di laptop
8 GB tanpa GPU.

Batas scope: lab berhenti di titik yang sama dengan tanggung jawab kerja aslinya — menerima
HTTP request di endpoint model, mengembalikan token. RAG, notebook, dan pipeline training
milik pihak lain dan tidak disimulasikan.

## Arsitektur

```
Client (RAG, prompt construction — DI LUAR SCOPE)
        |  HTTPS, format OpenAI-compatible
        v
+-------------------------------------------------------+
|   namespace: site-a          namespace: site-b         |
|   +------------------+       +------------------+      |
|   | Ingress (Traefik)|       | Ingress (Traefik)|      |
|   +--------+---------+       +--------+---------+      |
|            v                          v                |
|   +-------------------+      +-------------------+     |
|   | InferenceService  |      | InferenceService  |     |
|   |  llama-sim (Raw)  |      |  llama-sim (Raw)  |     |
|   |  deepseek-sim(Raw)|      |  deepseek-sim(Raw)|     |
|   +--------+----------+      +--------+----------+     |
|            v                          v                |
|      predictor pods              predictor pods        |
|      (llama.cpp, model 135M beneran jalan)             |
+-------------------------------------------------------+
        |  scrape
        v
  monitoring: Prometheus + Grafana + Alertmanager
```

### Dua plane

| Plane | Isi | Dipakai untuk |
|---|---|---|
| Plane nyata | k3d (1 control + 2 worker), model 135M yang benar-benar generate token | Uji jalur request end-to-end, failover, observability |
| Plane KWOK | Node palsu 8x H200 lintas 2 site | Skenario kapasitas & preemption yang butuh skala GPU besar tanpa GPU sungguhan |

### Pemetaan ke produksi

| Lapisan | Produksi | Lab | Catatan |
|---|---|---|---|
| Model serving | KServe / Triton | KServe InferenceService, RawDeployment mode | Nama tool sama persis |
| Ingress | Belum dikonfirmasi, kemungkinan Istio | Traefik (bawaan k3d) | Asumsi — cukup ganti `ingressClassName` kalau ternyata Istio |
| Serving engine | vLLM | llama.cpp, endpoint OpenAI-compatible | Permukaan API (`/v1/chat/completions`, `/v1/models`) identik; alasan lengkap di `serving/runtimes/llamacpp-openai.yaml` |
| Monitoring | Grafana + Prometheus + Alertmanager | kube-prometheus-stack | Sesuai |
| Registry | Harbor + Trivy | Registry bawaan k3d | Disederhanakan karena RAM |
| RBAC / tenancy | — | `charts/_archive/tenant-bootstrap` | Referensi, bukan jalur utama |

## Struktur repo

```
cluster/          config k3d + registry (mode air-gap opsional)
serving/
  kserve/         Helm values KServe (RawDeployment)
  runtimes/       ServingRuntime llama.cpp OpenAI-compatible
  sites/          InferenceService per site (site-a, site-b)
observability/
  values-*.yaml   Helm values kube-prometheus-stack, di-scope untuk 8 GB
  monitors/       PodMonitor / ServiceMonitor (predictor, Traefik)
  rules/          PrometheusRule
  tests/          kasus uji promtool untuk rule di atas
  grafana/        dashboard sebagai ConfigMap
sim/              plane KWOK: fake node H200, PriorityClass, skenario preemption
scripts/          install-tools, preflight, smoke test, unit test rule
charts/_archive/  chart tenant-bootstrap (referensi RBAC/NetworkPolicy/Helm test)
latihan/          manifest latihan tenancy mentah
docs/             catatan hasil dan temuan per topik
airgap/ capacity/ tempat artifact mirroring image & angka kapasitas
```

## Workflow

### 1. Siapkan host

```bash
bash scripts/install-tools.sh     # SKIP_OPTIONAL=1 untuk lewati tooling test
make preflight                    # cek RAM, docker, tooling
```

### 2. Naikkan lab bertahap

Jangan jalankan semua sekaligus di 8 GB. Naikkan per profil dan cek anggaran memori di
antaranya dengan `make mem`.

```bash
make up-core       # ~1.0 GB — cluster k3d + Traefik + cert-manager + KWOK
make up-sim        # 2 worker H200 palsu + PriorityClass  (butuh up-core)
make up-serving    # ~1.6 GB — KServe + 4 InferenceService di 2 site
make up-obs        # Prometheus + Grafana + Alertmanager + monitor/rule/dashboard
```

### 3. Validasi

```bash
make smoke         # request OpenAI-compatible ke 4 endpoint lewat ingress
make status        # node, GPU allocatable, pod yang tidak Running
make grafana       # port-forward Grafana ke localhost:3000 (admin / lab)
```

`make smoke` sengaja lewat ingress Traefik dan bukan port-forward, supaya yang diuji jalur
yang sama dengan yang dipakai client: Host header → Traefik → Service → pod. Dua hal yang
dicek per endpoint: identitas model dari `/v1/models`, dan token hasil generate yang benar-benar
keluar — bukan sekadar HTTP 200.

### 4. Test tanpa cluster

Sama persis dengan yang jalan di CI (`.github/workflows/ci.yml`), jadi bisa dijalankan
sebelum push.

```bash
make test          # semuanya sekaligus
make test-lint     # helm lint semua chart, termasuk yang diarsipkan
make test-schema   # kubeconform -strict terhadap skema Kubernetes + CRD
make test-rules    # unit test alert rule via promtool
```

`test-rules` tidak memanggil `promtool test rules` langsung: rule disimpan sebagai objek
`PrometheusRule` yang tidak dimengerti promtool, jadi skripnya mengekstrak `.spec` dulu.

### 5. Bongkar

```bash
make down          # hapus cluster
make clean         # rapikan image docker lama
```

## Tools yang dipakai

### Runtime

| Tool | Peran |
|---|---|
| k3d + k3s | Cluster Kubernetes lokal, 1 control + 2 worker |
| Traefik | IngressClass, bawaan k3d, dipakai InferenceService |
| cert-manager | Prasyarat webhook KServe |
| KServe | `InferenceService` mode RawDeployment (tanpa Knative) |
| llama.cpp | Serving engine, endpoint OpenAI-compatible |
| KWOK | Node palsu untuk simulasi 8x H200 tanpa GPU |
| kube-prometheus-stack | Prometheus + Grafana + Alertmanager + operator |
| Kyverno | Opsional (`make kyverno`), di luar profil default — tidak dipakai skenario serving |

### CLI

| Tool | Peran |
|---|---|
| kubectl | Operasi cluster |
| helm | Install KServe, kube-prometheus-stack, lint chart lokal |
| docker | Runtime k3d, sekaligus sumber angka `make mem` |
| kubeconform | Validasi manifest terhadap skema Kubernetes dan CRD |
| promtool | Unit test alert rule |
| crane | Mirroring image untuk skenario air-gap |
| k9s | Melihat siapa yang makan memori — bukan kemewahan di 8 GB |
| yq / jq | Baca YAML dan respons JSON di skrip |

## Dokumentasi

| Dokumen | Isi |
|---|---|
| `docs/00-mapping.md` | Pemetaan komponen lab ke platform produksi |
| `docs/10-quota-rationale.md` | Dasar angka quota dan hasil eksperimen preemption |
| `docs/20-serving-plane.md` | Bukti jalan serving plane + temuan perilaku KServe |
| `docs/30-observability.md` | Bukti jalan observability + temuan soal alert |
| `docs/runbooks/` | Prosedur operasional |
| `90-panduan-konsep.md` | Panduan konsep di balik keputusan lab |
