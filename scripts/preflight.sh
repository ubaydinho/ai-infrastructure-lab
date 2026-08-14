#!/usr/bin/env bash
# Cek apakah host siap menjalankan lab ini. Aman dijalankan berkali-kali.
set -uo pipefail

PASS=0; WARN=0; FAIL=0
ok()   { echo -e "  [ ok ] $1";        PASS=$((PASS+1)); }
warn() { echo -e "  [warn] $1";        WARN=$((WARN+1)); }
bad()  { echo -e "  [FAIL] $1";        FAIL=$((FAIL+1)); }

echo ""
echo "== Host =="
if grep -qi microsoft /proc/version 2>/dev/null; then
  ok "WSL2 terdeteksi"
  WSL=1
else
  ok "Linux native — kamu hemat sekitar 1.5 GB dibanding WSL2"
  WSL=0
fi

echo ""
echo "== Memori =="
MEM_MB=$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)
SWAP_MB=$(awk '/SwapTotal/{printf "%d", $2/1024}' /proc/meminfo)
AVAIL_MB=$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)
echo "  total=${MEM_MB}MB  tersedia=${AVAIL_MB}MB  swap=${SWAP_MB}MB"

if [ "$MEM_MB" -lt 4200 ]; then
  bad "RAM total di bawah 4.2 GB — up-core pun akan sesak"
elif [ "$MEM_MB" -gt 6200 ] && [ "$WSL" -eq 1 ]; then
  warn "WSL2 mengambil lebih dari 6.2 GB; Windows bisa mulai tersedak. Turunkan di .wslconfig"
else
  ok "RAM total ${MEM_MB}MB"
fi

# MemAvailable adalah angka yang benar-benar menentukan lab ini muat atau tidak.
# MemTotal cuma memberi tahu apa yang kamu beli; MemAvailable memberi tahu apa yang tersisa.
if [ "$AVAIL_MB" -lt 2200 ]; then
  bad "tersedia hanya ${AVAIL_MB}MB — up-core (~1.6 GB) pun akan langsung menyentuh swap"
elif [ "$AVAIL_MB" -lt 4200 ]; then
  warn "tersedia ${AVAIL_MB}MB — cukup untuk up-core, TIDAK cukup untuk up-serving (~3.3 GB) tanpa thrashing"
  echo "         Tutup browser, atau jalankan lab dari TTY tanpa sesi desktop."
  echo "         Tiga pemakan memori terbesar sekarang:"
  ps -eo rss,comm --sort=-rss --no-headers 2>/dev/null | head -3 | \
    awk '{printf "           %-24s %6.0f MB\n", $2, $1/1024}'
else
  ok "tersedia ${AVAIL_MB}MB — muat untuk profil up-serving"
fi

if [ "$SWAP_MB" -lt 4000 ]; then
  warn "swap di bawah 4 GB — tambahkan, itu jaring pengaman kamu"
else
  ok "swap ${SWAP_MB}MB"
  if [ "$AVAIL_MB" -lt 4200 ]; then
    echo "         Ingat: swap menyelamatkan dari OOM, bukan dari lambat. Kalau nanti pod"
    echo "         restart sendiri tanpa sebab jelas, itu probe timeout karena thrashing,"
    echo "         bukan bug konfigurasi. Catat di runbook saat kamu ketemu pertama kali."
  fi
fi

echo ""
echo "== Disk =="
FREE_GB=$(df -BG --output=avail "$HOME" 2>/dev/null | tail -1 | tr -dc '0-9')
echo "  bebas di \$HOME: ${FREE_GB}GB"
if [ "${FREE_GB:-0}" -lt 25 ]; then
  bad "sisa disk di bawah 25 GB — image KServe + runtime model saja sudah beberapa GB"
elif [ "${FREE_GB:-0}" -lt 45 ]; then
  warn "sisa disk pas-pasan; jalankan 'make clean' rutin"
else
  ok "ruang disk cukup"
fi

echo ""
echo "== Tooling wajib =="
for t in docker k3d kubectl helm; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t"; else bad "$t belum terpasang"; fi
done

echo ""
echo "== Tooling test (dipakai CI, bagus kalau ada lokal) =="
for t in kubeconform promtool crane k9s yq; do
  if command -v "$t" >/dev/null 2>&1; then ok "$t"; else warn "$t belum ada"; fi
done

echo ""
echo "== Docker daemon =="
if docker info >/dev/null 2>&1; then
  ok "daemon merespons"
  DRIVER=$(docker info --format '{{.CgroupVersion}}' 2>/dev/null || echo "?")
  echo "  cgroup version: ${DRIVER}"
  [ "$DRIVER" = "1" ] && warn "cgroup v1 — akuntansi memori kurang akurat, 'make mem' jadi kurang bisa dipercaya"
else
  bad "docker tidak merespons (coba: sudo service docker start)"
fi

echo ""
echo "-- ringkasan: ${PASS} ok, ${WARN} warn, ${FAIL} gagal --"
if [ "$FAIL" -gt 0 ]; then
  echo "   Beresin yang FAIL dulu sebelum 'make up-core'."
  exit 1
fi
echo "   Siap. Lanjut: make up-core"
