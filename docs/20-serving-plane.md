# Serving plane: KServe RawDeployment di dua site

Artifact Sprint 2. Ditulis dari lab yang benar-benar jalan, bukan dari dokumentasi.

Reproduksi seluruh isi dokumen ini: `make up-serving && make smoke`.

---

## 1. Yang berdiri sekarang

Dua namespace (`site-a`, `site-b`), masing-masing dua endpoint model, semua di atas KServe
mode RawDeployment tanpa Knative sama sekali.

```
$ kubectl get isvc -A
NAMESPACE   NAME           URL                                      READY
site-a      deepseek-sim   http://deepseek-sim-site-a.example.com   True
site-a      llama-sim      http://llama-sim-site-a.example.com      True
site-b      deepseek-sim   http://deepseek-sim-site-b.example.com   True
site-b      llama-sim      http://llama-sim-site-b.example.com      True
```

**Rantai objek yang benar-benar lahir dari satu `InferenceService`** — ini yang membedakan
RawDeployment dari mode Serverless yang dipetakan di `00-mapping.md`:

```
InferenceService/llama-sim
  └── Deployment/llama-sim-predictor
        └── ReplicaSet → Pod (initContainer storage-initializer + kserve-container)
  └── Service/llama-sim-predictor      (ClusterIP :80)
  └── Ingress/llama-sim                (class traefik, host llama-sim-site-a.example.com)
```

Tidak ada `Configuration`, `Revision`, `Route`, maupun sidecar `queue-proxy`. Baris pertama
tabel serving di `00-mapping.md` menggambarkan mode Knative — **di lab ini mode itu tidak
dipakai**, dan perbedaan objeknya persis seperti di atas.

Bukti empat sudut bahwa Knative tidak ikut terpasang:

```
kubectl get ns | grep -i knative        → kosong
kubectl get pods -A | grep -i knative   → kosong
kubectl api-resources | grep -i knative → kosong
kubectl get crd | grep -i knative       → kosong
```

## 2. Bukti jalur request

Lewat ingress Traefik dari host, bukan port-forward — jalur yang sama dengan client sungguhan:

```
$ make smoke
  [ ok ] llama-sim-site-a.example.com    → /v1/models = llama-sim
  [ ok ] llama-sim-site-a.example.com    → 16 token dalam 0.459s
  [ ok ] deepseek-sim-site-a.example.com → /v1/models = deepseek-sim
  [ ok ] deepseek-sim-site-a.example.com → 16 token dalam 0.366s
  [ ok ] llama-sim-site-b.example.com    → /v1/models = llama-sim
  [ ok ] llama-sim-site-b.example.com    →  9 token dalam 0.251s
  [ ok ] deepseek-sim-site-b.example.com → /v1/models = deepseek-sim
  [ ok ] deepseek-sim-site-b.example.com → 16 token dalam 0.406s
-- ringkasan: 8 ok, 0 gagal --
```

Test ini sudah diuji gagal, dua cara, supaya tahu dia bukan sekadar selalu hijau:
`SITES=site-c` (host tidak ada) → 2 gagal, exit 1. Pod sungguhan di-scale ke 0 → 1 gagal,
exit 1.

**Angka awal yang bisa dipakai membandingkan nanti:** latensi 0.2–0.5 detik untuk 9–16 token
di CPU, model 135M. Bukan angka kapasitas — cuma titik nol supaya perubahan di Sprint 4
kelihatan relatif terhadap sesuatu.

## 3. Tiga temuan yang mengubah rencana sprint berikutnya

### 3.1 `Ready` di InferenceService bukan sinyal ketersediaan

Saat rolling update, keempat isvc menunjukkan `READY=False` dengan alasan
`Predictor ingress not created` dan `ReplicaSet ... is progressing`. **Di saat yang sama
`make smoke` tetap 8/8 hijau** — pod lama melayani sampai pod baru siap, dan objek Ingress
tidak pernah hilang.

Konsekuensi untuk Sprint 3: alert "endpoint down" yang dibangun di atas condition ini akan
berbunyi setiap deploy normal. Yang mengukur ketersediaan nyata adalah request sungguhan.
Ini bukan kekurangan KServe — `Ready` memang menjawab "apakah spec sudah tercapai
sepenuhnya", bukan "apakah trafik masih dilayani". Dua pertanyaan berbeda.

### 3.2 `kubectl scale --replicas=0` tidak mematikan apa pun

Rencana Sprint 4 semula memakai scale manual untuk mensimulasikan site mati. Tidak bisa:

```
$ kubectl scale deploy/llama-sim-predictor -n site-b --replicas=0
$ # 8 detik kemudian
$ kubectl get deploy/llama-sim-predictor -n site-b -o jsonpath='{.spec.replicas}'
1        ← dikembalikan controller dari spec.predictor.minReplicas
```

Yang benar adalah anotasi resmi KServe v0.18.1:

```
$ kubectl annotate isvc llama-sim -n site-b serving.kserve.io/stop=true --overwrite
→ Deployment hilang seluruhnya, dan TIDAK direkonsiliasi balik
$ kubectl annotate isvc llama-sim -n site-b serving.kserve.io/stop-
→ pulih, Ready dalam ~60 detik (dominan waktu unduh model oleh storage-initializer)
```

Efek sampingnya kelihatan di `status.conditions` sebagai condition `Stopped`.

### 3.3 KServe menamai mode yang sama dengan dua nama

Kita menulis `serving.kserve.io/deploymentMode: RawDeployment`; yang muncul di anotasi pod
template adalah `Standard`. Mode yang sama, nama baru. Jangan bingung waktu membaca cluster
produksi — cari dua-duanya.

## 4. Penyimpangan dari rencana, dan alasannya

| Rencana di README | Yang dibangun | Alasan |
|---|---|---|
| vLLM sebagai serving engine | llama.cpp, endpoint OpenAI-compatible | Image `kserve/huggingfaceserver:v0.18.1` = 4 GB terkompresi dan butuh beberapa GB RAM untuk torch. Host punya <2 GB bebas. Permukaan API identik (`/v1/chat/completions`, `/v1/models`), dan yang diuji sprint ini bentuk jalur request — bukan performa mesin inferensi |
| `facebook/opt-125m` | `SmolLM2-135M-Instruct-Q8_0.gguf` (145 MB) | Kelas ukuran sama, tapi sudah instruction-tuned dan punya chat template, jadi respons `/v1/chat/completions` terbaca manusia |
| Traefik "bawaan k3d" | Traefik bawaan k3d, setelah `--disable=traefik` dicabut | `cluster/k3d.yaml` warisan rencana Knative/Kourier mematikannya. Cluster dibuat ulang |
| Kyverno di profil core | Dilepas | Tidak dipakai satu pun skenario serving/failover; 400 MB itu langsung mengurangi ruang pod model |

Penyimpangan pertama yang paling perlu diingat: **begitu ada GPU sungguhan, yang diganti
cuma image dan args di `serving/runtimes/llamacpp-openai.yaml`.** Keempat `InferenceService`
di `serving/sites/` tidak perlu disentuh. Itu memang gunanya ServingRuntime dipisah dari
InferenceService, dan sekarang sudah terbukti bukan cuma teori.

## 5. Anggaran memori terukur

| Kondisi | Container k3d | `MemAvailable` |
|---|---|---|
| Cluster lama + Kyverno (sebelum Sprint 2) | 1.48 GB | 1.7 Gi |
| Cluster baru, tanpa Kyverno, + Traefik | 841 MiB | 2.3 Gi |
| + cert-manager + KServe | 1.20 GB | 1.9 Gi |
| + 4 pod model jalan | ~1.6–2.0 GB | 2.4–2.6 Gi |

Yang bikin ini muat, dan tidak terduga di awal: llama.cpp **mmap** file GGUF, jadi bobot
model masuk page cache (bisa direklaim kernel) bukan anonymous memory. RSS anonymous per pod
cuma **37 MiB**. Kalau nanti pindah ke runtime yang memuat bobot ke heap (vLLM, transformers),
aritmatika ini berubah total — jangan bawa angka di tabel ini ke sana.

## 6. Yang masih asumsi

Tidak berubah dari README, tapi diulang di sini karena dokumen ini yang akan dibuka duluan:

1. **Ingress produksi** belum dikonfirmasi Traefik atau Istio. Lab pakai Traefik.
   Pindahnya satu baris: `className` di `serving/kserve/values-rawdeployment.yaml`.
2. **Mekanisme failover antar site** belum diketahui. Lab mengakses tiap site langsung lewat
   header `Host`, tanpa DNS dan tanpa LB gabungan.
3. **Model dan runtime produksi** jelas berbeda (vLLM, model besar, GPU). Yang dibuktikan lab
   ini bentuk jalur request dan perilaku controller — bukan angka performa.

Begitu ada akses hands-on: jalankan `kubectl get inferenceservice -A -o yaml` di produksi dan
bandingkan dengan `serving/sites/site-a.yaml`. Selisihnya adalah daftar kerja berikutnya.
