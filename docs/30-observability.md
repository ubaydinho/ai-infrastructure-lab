# Observability: melihat serving plane dua site

Artifact Sprint 3. Ditulis dari lab yang benar-benar jalan.

Reproduksi: `make up-obs && make smoke`, lalu `make grafana` (admin / lab).

---

## 1. Dari mana angkanya datang

Ada dua sumber metrik, dan pembagiannya bukan selera — masing-masing tahu hal yang
tidak diketahui yang lain.

| Butuh | Sumber | Kenapa |
|---|---|---|
| Request rate, latency p95 | **Traefik** | Diukur di titik masuk — tempat client merasakannya. Latency yang diukur di dalam pod selalu terlihat lebih bagus daripada kenyataan |
| Kedalaman antrean, token/detik | **llama.cpp** (`--metrics`) | Cuma server model yang tahu berapa request sedang menunggu slot |
| Restart pod, inventaris objek | **kube-state-metrics** | Membaca API server, bukan proses aplikasi |
| Endpoint hidup atau tidak | **`up` dari scrape** | Scrape adalah request HTTP sungguhan. Lihat bagian 3 — ada jebakannya |

Yang penting dicatat: **llama.cpp tidak punya counter request maupun histogram
latency.** Dua angka yang justru diminta rencana sprint harus datang dari Traefik.
Kalau nanti runtime diganti vLLM (yang punya histogram sendiri), pembagian ini
berubah — dan dashboard-nya ikut berubah.

Traefik bawaan k3s ternyata **sudah** mengekspos 126 metrik di container port 9100
tanpa dikonfigurasi apa pun. Service-nya cuma membuka 80/443, jadi dipakai
**PodMonitor** yang menembak pod langsung — nol perubahan pada Traefik.

## 2. Yang berdiri

```
$ kubectl get pods -n monitoring
alertmanager-...-0                2/2 Running
kps-grafana-...                   3/3 Running
kps-...-operator-...              1/1 Running
kps-kube-state-metrics-...        1/1 Running
prometheus-...-0                  2/2 Running

$ Prometheus /api/v1/targets
llama-sim-predictor      up   site-a  llama-sim
llama-sim-predictor      up   site-b  llama-sim
deepseek-sim-predictor   up   site-a  deepseek-sim
deepseek-sim-predictor   up   site-b  deepseek-sim
kube-system/traefik      up
kube-state-metrics / prometheus / alertmanager / grafana / coredns / apiserver: up
```

Dashboard `Serving — dua site` (uid `serving-2site`), 8 panel, ditulis sebagai
ConfigMap di `observability/grafana/dashboards/` — jadi ikut divalidasi
`make test-schema` dan diff-nya terbaca di git.

Angka nyata dari dashboard, diambil setelah `make smoke`:

```
Request rate per endpoint     site-a/llama-sim 0.007 req/s   (4 endpoint, seimbang)
Latency p95 per endpoint      site-a 0.283 s   site-b 1.110 s
```

Lima alert rule, semuanya `health=ok`, semuanya `inactive` saat cluster sehat.

## 3. Tiga temuan, dan yang ketiga mengubah Sprint 4

### 3.1 Komponen control plane k3s harus dimatikan di chart

`kubeControllerManager`, `kubeScheduler`, `kubeEtcd`, `kubeProxy` — di k3s keempatnya
digabung jadi satu proses (etcd diganti sqlite). Kalau dibiarkan `enabled: true`,
ServiceMonitor-nya tidak akan pernah punya target dan alert `*Down`-nya menyala
permanen. Gejala yang sama muncul di cluster terkelola mana pun.

### 3.2 Unit test membuktikan logika, bukan keberadaan series

Rule `NodeKubeletDown` versi pertama mengecualikan fake node lewat
`kube_node_labels{label_type="kwok"}`. Unit test promtool-nya **lulus**. Di cluster,
rule-nya langsung `pending` — karena `kube_node_labels` **kosong**: kube-state-metrics
v2 tidak mengekspos label node kecuali dijalankan dengan `--metric-labels-allowlist`.

Test lulus karena test yang memberi makan series buatannya sendiri. Yang membuktikan
sebuah rule benar bukan unit test-nya, tapi melihat rule itu di cluster sungguhan.

Perbaikannya: `kube_node_spec_taint{key="kwok.x-k8s.io/node"}` — ada secara default,
dan taint itu justru mekanisme yang sama yang menahan pod model supaya tidak mendarat
di node palsu.

### 3.3 `up == 0` BUTA terhadap target yang hilang

Ini yang paling mahal, dan ketahuan hanya karena alert-nya diuji melawan gangguan
sungguhan, bukan cuma dibaca ulang.

Seluruh site-b dimatikan dengan anotasi `serving.kserve.io/stop` (mekanisme yang
ditemukan di Sprint 2). Ditunggu lewat dari `for: 2m`. **Tidak ada satu pun alert
yang menyala.**

Sebabnya: KServe menghapus Deployment, Service, Endpoints, dan Pod sekaligus. Target
hilang dari service discovery, dan series `up` bukan menjadi 0 — dia **berhenti ada**.
`up == 0` tidak punya apa pun untuk dicocokkan.

```
$ kubectl get deploy,svc,endpoints,pod -n site-b
(kosong)

$ query: up{job=~".+-predictor"}
site-a/llama-sim = 1
site-a/deepseek-sim = 1        ← site-b tidak muncul sebagai 0; dia tidak muncul sama sekali
```

Ini persis skenario failover Sprint 4. Alerting yang dibangun hanya di atas `up == 0`
akan **bisu tepat pada kejadian yang paling penting**.

Perbaikannya `absent()`, yang justru menghasilkan series ketika input kosong.
Konsekuensinya daftar site harus ditulis eksplisit satu per satu — disengaja, sama
seperti di ServiceMonitor: menambah site-c harus menyentuh file rule, supaya tidak
ada site yang diam-diam tidak terpantau.

Diverifikasi ulang melawan gangguan yang sama:

```
site-b dimatikan  → SiteEndpointsAbsent  state=firing  site=site-b   (hanya site-b)
site-b dipulihkan → (tidak ada alert — menutup sendiri)
make smoke        → 8 ok, 0 gagal
```

Dua alert sekarang menutupi dua mode kegagalan yang berbeda:
**`ModelEndpointDown`** = pod ada tapi tidak menjawab HTTP.
**`SiteEndpointsAbsent`** = target hilang sama sekali.

## 4. Enam target kubelet permanen `down`, dan itu jujur

3 endpoint × 2 fake node KWOK. Node itu memang tidak punya kubelet. Karena itu di
lab ini **tidak ada** alert `TargetDown` borongan — alert borongan akan menyala
selamanya dan mengajari orang mengabaikan alert. Yang ada `NodeKubeletDown` yang
mengecualikan node ber-taint kwok secara eksplisit.

## 5. Anggaran memori

| Kondisi | Container k3d | `MemAvailable` |
|---|---|---|
| Akhir Sprint 2 (serving saja) | ~1.6 GB | 2.4 Gi |
| + kube-prometheus-stack + 4 pod model | **1.48 GB** | **1.9 Gi** |

Muat, dengan catatan: `node-exporter` dimatikan (di k3d ketiga "node" berbagi satu
kernel — angkanya sama tiga kali), dashboard bawaan (~20) dimatikan, dan rule bawaan
dimatikan. Prometheus tanpa PVC, retensi 12 jam.

## 6. Batas yang diketahui

1. **Scrape memukul `/metrics`, bukan `/v1/chat/completions`.** `up=1` berarti proses
   server hidup dan menjawab HTTP — bukan bahwa inferensi masih benar. Untuk itu
   butuh probe sungguhan ke endpoint chat (blackbox exporter). Pekerjaan Sprint 4.
2. **Bucket histogram Traefik kasar** (0.1 / 0.3 / 1.2 / 5 / +Inf). p95 di dashboard
   adalah interpolasi — cukup untuk melihat tren dan menangkap "jelas rusak", tidak
   cukup untuk menyetel SLO. Atur bucket Traefik dulu kalau butuh presisi.
3. **Metrik GPU belum ada.** Fake DCGM exporter masih kosong; plane KWOK tidak
   menghasilkan metrik GPU apa pun.
