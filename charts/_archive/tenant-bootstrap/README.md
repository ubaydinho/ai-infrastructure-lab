# tenant-bootstrap

Satu `helm install` menghasilkan tenant lengkap: Namespace, ResourceQuota,
LimitRange, RBAC (ServiceAccount + Role + RoleBinding), dan NetworkPolicy.

Ini versi Helm dari lima YAML latihan di `latihan/tenancy/` — objeknya identik,
angkanya sekarang datang dari `values.yaml` lewat tier, bukan diketik ulang di
setiap file.

## Pakai

```bash
# lihat dulu YAML yang AKAN dikirim, tanpa menyentuh cluster
helm template tenant-a . --set tenant.name=tenant-a --set tenant.tier=small

# baru install sungguhan
helm install tenant-a . --set tenant.name=tenant-a --set tenant.tier=medium -n tenant-a --create-namespace

# uji sebelum kirim
helm lint .
helm unittest .   # butuh: helm plugin install https://github.com/helm-unittest/helm-unittest
```

## Tier

| Tier | GPU | requests.cpu | requests.memory | pods |
|---|---|---|---|---|
| small | 1 | 16 | 64Gi | 30 |
| medium | 2 | 64 | 256Gi | 60 |
| dedicated | 4 | 224 | 2Ti | 110 |

Angka `dedicated` sengaja sama dengan kapasitas satu node KWOK penuh
(`sim/nodes/gpu-worker-0*.yaml`) — tenant tier ini secara efektif memonopoli
satu worker.

## Yang belum diisi di sini, sengaja

Angka-angka di atas belum melewati proses yang dijelaskan di
`docs/10-quota-rationale.md` — dokumen itu yang menentukan berapa GPU
sebenarnya pantas untuk tiap tier, bukan chart ini. Chart ini cuma mekanisme;
`10-quota-rationale.md` yang isi kebijakannya.

## Belum ditest secara live

Test di `tests/tenant_test.yaml` ditulis mengikuti sintaks plugin
`helm-unittest`, tapi belum pernah dijalankan — pasang plugin-nya dan jalankan
`helm unittest .` sebelum memercayainya. Begitu juga `helm lint` dan
`helm template`: jalankan dulu di laptopmu, tempel hasilnya di sini kalau ada
yang aneh.
