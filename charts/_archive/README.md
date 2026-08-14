# charts/_archive/

Chart yang **tidak dihapus tapi bukan lagi jalur utama** setelah lab direvisi ke
simulasi serving layer (lihat "Kenapa direvisi" di README root).

Isi folder ini masih ikut `helm lint` di `make test-lint` dan di CI — diarsipkan
bukan berarti boleh membusuk. Yang berubah cuma statusnya: tidak dipakai sprint
berikutnya, tidak jadi dependency apa pun.

| Chart | Kenapa diarsipkan | Masih berguna sebagai |
|---|---|---|
| `tenant-bootstrap/` | Scope produksi ternyata satu client, bukan multi-tenant | Contoh jadi untuk ResourceQuota/LimitRange/RBAC/NetworkPolicy dalam satu chart, plus pola test `helm-unittest` |

Kalau nanti multi-tenancy kembali relevan, pindahkan kembali ke `charts/` —
jangan menyalin isinya ke chart baru.
