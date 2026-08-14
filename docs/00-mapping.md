# Pemetaan: fitur platform produksi → substrat open source → objek Kubernetes

Artifact Fase 0. Dokumen rujukan utama selama empat bulan ke depan.

Kolom 3 adalah alasan dokumen ini ada. Kolom 1 dan 2 bisa ditebak siapa saja yang googling; kolom 3 hanya bisa diisi orang yang tahu objek apa yang benar-benar lahir di cluster saat sebuah tombol diklik. Itu yang bikin kamu bisa menjawab "kenapa job saya pending" dalam 30 detik, bukan 30 menit.

**Kolom Sumber:** `deck` = disebut eksplisit di materi yang kamu pegang. `inferensi` = tebakan terdidik dari stack upstream standar — **verifikasi saat kamu baca deck**, dan koreksi baris ini. Jangan biarkan kolom itu tetap `inferensi` setelah kamu punya buktinya.

---

## Lapisan serving

| Yang disebut deck | Sebenarnya | Objek yang benar-benar dibuat di cluster | Sumber |
|---|---|---|---|
| MLIS, 1-click model deployment | KServe di atas Knative Serving | `InferenceService` (serving.kserve.io/v1beta1) → controller melahirkan `Service`/`Configuration`/`Revision`/`Route` (serving.knative.dev/v1) → `Deployment` → Pod berisi initContainer `storage-initializer` + `kserve-container` + sidecar `queue-proxy` | deck |
| Pilihan runtime saat deploy model | KServe ServingRuntime | `ClusterServingRuntime` / `ServingRuntime` (serving.kserve.io/v1alpha1). Isinya image, args, `supportedModelFormats`. Dropdown di GUI itu daftar objek ini | inferensi |
| Autoscaling by concurrent requests | Knative KPA (bukan HPA) | Annotation `autoscaling.knative.dev/target` → `PodAutoscaler` (autoscaling.internal.knative.dev/v1alpha1). Metriknya concurrency yang dihitung `queue-proxy`, bukan CPU | deck |
| Endpoint mati saat tidak dipakai | Knative activator + scale-to-zero | `PodAutoscaler` dengan `minScale: 0`. Saat 0 replica, `Route` mengarah ke activator di namespace `knative-serving`, bukan ke pod aplikasi. Inilah sumber cold start 10–30 detik | inferensi |
| Endpoint kompatibel OpenAI | Runtime yang menyediakan `/v1/chat/completions` | Tidak ada objek khusus — kontraknya ada di `containers[].args` milik ServingRuntime. Artinya bisa ditukar tanpa menyentuh `InferenceService` | deck |

## Lapisan tenancy dan penjadwalan

| Yang disebut deck | Sebenarnya | Objek yang benar-benar dibuat di cluster | Sumber |
|---|---|---|---|
| Workspace / project per tim | Namespace + RBAC bundle | `Namespace`, `ServiceAccount`, `Role`, `RoleBinding`. Persis isi chart `tenant-bootstrap` kamu | inferensi |
| GPU quota per team | ResourceQuota per namespace | `ResourceQuota` dengan key `requests.nvidia.com/gpu`. Catatan penting: extended resource **wajib** `requests == limits`, jadi tidak ada overcommit GPU — beda total dari CPU | deck |
| Batas default per container | LimitRange | `LimitRange` (default, defaultRequest, max). Ini yang menyelamatkan kamu dari pod tanpa request yang menelan node | deck |
| Idle reclaim, priority 8000 vs 10000 | PriorityClass + preemption scheduler | `PriorityClass` (scheduling.k8s.io/v1) — objek global, bukan per namespace. Pod merujuk lewat `spec.priorityClassName`. Saat preemption: scheduler menulis event `Preempted` di korban dan mengisi `status.nominatedNodeName` di pemenang | deck |
| Template GPU Tiny / Small / Medium | Request extended resource | `resources.limits."nvidia.com/gpu"` di pod template. `GPU Tiny` = 1x H200 utuh; tanpa MIG berarti **tidak ada sharing sama sekali** — satu pod memegang 141 GB HBM meski cuma butuh 20 | deck |
| Worker GPU terpisah dari control node | Taint + toleration + affinity | `Node.spec.taints`, lalu `tolerations` + `nodeSelector`/`nodeAffinity` di pod. Kalau kamu lupa toleration, pod Pending selamanya tanpa pesan yang jelas | inferensi |
| Isolasi antar tenant | NetworkPolicy | `NetworkPolicy` (networking.k8s.io/v1) default-deny + allow DNS dan model store. Kalau ada Istio, ditambah `AuthorizationPolicy` untuk L7 | inferensi |

## Lapisan platform dan governance

| Yang disebut deck | Sebenarnya | Objek yang benar-benar dibuat di cluster | Sumber |
|---|---|---|---|
| Import Framework | Helm chart + Istio + Kyverno | Helm release disimpan sebagai `Secret` type `helm.sh/release.v1`; `VirtualService` (networking.istio.io/v1beta1) untuk routing; `ClusterPolicy` (kyverno.io/v1) untuk label wajib | deck |
| Aplikasi muncul di UI dengan nama sendiri | Label + VirtualService host | Label `nativeAppName` pada Deployment, dicocokkan dengan host di `VirtualService`. Ini yang harus kamu samakan di dashboard Grafana nanti | deck |
| Login SSO ke seluruh UI | Keycloak + Istio ext authz | `RequestAuthentication` + `AuthorizationPolicy` (security.istio.io/v1), `Secret` berisi OIDC client credentials | inferensi |
| Instalasi air-gapped | Registry mirror + chart bundling | `/etc/rancher/k3s/registries.yaml` atau containerd `hosts.toml` di setiap node; `Secret` type `kubernetes.io/dockerconfigjson`; `imagePullPolicy: IfNotPresent` | deck |
| Upgrade cluster tanpa matiin layanan | Cordon, drain, eviction | `PodDisruptionBudget` + Eviction API. PDB yang salah setel membuat drain menggantung tanpa batas — dan itu terjadi jam 2 pagi | inferensi |

## Lapisan data dan jaringan

| Yang disebut deck | Sebenarnya | Objek yang benar-benar dibuat di cluster | Sumber |
|---|---|---|---|
| Data Lakehouse Gateway | Apache Iceberg + REST catalog | Tidak ada CRD khusus: `Deployment` + `Service` untuk catalog, `Secret` kredensial S3, `ConfigMap` warehouse path | deck |
| RAG Essentials | Weaviate + model embedding + LLM | `StatefulSet` + `PVC` untuk Weaviate, **dua** `InferenceService` (embedding dan generation), `Service` internal. Dua model itu memakan slot GPU yang sama dengan model produksi — hitung di dokumen kapasitas | deck |
| Storage untuk notebook dan model | CSI driver | `StorageClass`, `PVC`, `VolumeSnapshotClass`. Access mode menentukan apakah dua pod bisa berbagi satu model — `ReadWriteMany` atau tidak sama sekali | inferensi |
| Pod int 0–3 ke NIC 400GbE | SR-IOV Virtual Function + Multus | `NetworkAttachmentDefinition` (k8s.cni.cncf.io/v1), annotation pod `k8s.v1.cni.cncf.io/networks`, dan extended resource `<vendor>.com/sriov_netdevice` di `resources.limits` — VF dijatah persis seperti GPU | deck |
| bond0, mgt vlan 101, prod vlan 800 | Linux bonding + VLAN tagging | **Tidak ada objek Kubernetes.** Ini konfigurasi host (netplan / nmcli) yang selesai sebelum kubelet hidup. Terlihat di K8s hanya sebagai `Node.status.addresses` dan label topologi | deck |

## Lapisan observability

| Yang disebut deck | Sebenarnya | Objek yang benar-benar dibuat di cluster | Sumber |
|---|---|---|---|
| OpsRamp | Prometheus + Alertmanager di lapisan bawahnya | `ServiceMonitor` / `PodMonitor` (monitoring.coreos.com/v1), `PrometheusRule`. OpsRamp sendiri agen di luar cluster yang fokus ke hardware — pembagian kerjanya harus kamu petakan sendiri | deck |
| Monitoring kesehatan GPU | DCGM exporter | `DaemonSet` di node GPU + `ServiceMonitor`. Metrik kunci: `DCGM_FI_DEV_GPU_UTIL`, `DCGM_FI_DEV_FB_USED`, `DCGM_FI_PROF_SM_ACTIVE`. Dua yang terakhir yang membedakan "sibuk" dari "menunggu memori" | deck |

---

## Cara memakai dokumen ini

**Saat baca deck:** setiap kali ketemu istilah vendor baru, tambahkan baris. Jangan tunda — kamu tidak akan kembali.

**Saat rapat:** kolom 1 adalah kosakata yang dipakai orang lain. Kolom 3 adalah yang kamu cek di terminal. Kemampuan menerjemahkan bolak-balik antara keduanya, di tempat, adalah keseluruhan nilai posisi kamu.

**Saat on-hand:** buka GUI, klik satu fitur, lalu `kubectl get <objek di kolom 3> -A` sebelum dan sesudah. Selisihnya adalah jawaban yang sebenarnya. Kalau tidak cocok dengan tabel ini, tabel ini yang salah — perbaiki.

## Tiga hal yang belum terpetakan dan perlu kamu cari di deck

1. **Scheduler apa yang dipakai.** Kubernetes default, atau Volcano / Kueue untuk gang scheduling? Ini menentukan apakah job multi-GPU bisa deadlock saat cluster penuh. Cari kata "gang", "queue", atau "batch scheduler".
2. **Apakah MIG diaktifkan.** Deck menyebut template `GPU Tiny` = 1x H200, yang mengisyaratkan tidak. Kalau benar, utilisasi rendah adalah masalah bisnis yang akan muncul di bulan kedua, dan kamu sudah punya jawabannya lewat dokumen kapasitas.
3. **Siapa yang memegang model registry.** MinIO internal, S3 eksternal, atau registry bawaan platform? Ini menentukan seluruh prosedur air-gap kamu.
