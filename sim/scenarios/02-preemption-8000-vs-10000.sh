#!/usr/bin/env bash
# Uji hipotesis tiebreak dari docs/10-quota-rationale.md bagian 2.
# Pertanyaan: pemilihan node korban deterministik, atau hasil tiebreak?
#
# Pakai:  bash sim/scenarios/02-preemption-8000-vs-10000.sh [jumlah_putaran]
set -uo pipefail
cd "$(dirname "$0")/../.." || exit 1

RUNS="${1:-10}"
BATCH=sim/workloads/batch-1gpu.yaml
INTER=sim/workloads/interactive-2gpu.yaml
declare -A node_count

printf '%-5s %-16s %s\n' "RUN" "NODE PEMENANG" "KORBAN"
printf '%-5s %-16s %s\n' "---" "-------------" "------"

for run in $(seq 1 "$RUNS"); do
  # --- kondisi awal bersih ---
  kubectl delete pod -l sim=true --ignore-not-found >/dev/null 2>&1
  while [ "$(kubectl get pods -l sim=true --no-headers 2>/dev/null | wc -l)" -gt 0 ]; do
    sleep 1
  done

  # --- isi 8 GPU dengan pod batch prioritas 8000 ---
  for i in $(seq 1 8); do
    sed "s/^  name: batch-1$/  name: batch-$i/" "$BATCH" | kubectl apply -f - >/dev/null
  done

  # tunggu kedelapan pod dapat node
  for _ in $(seq 30); do
    n=$(kubectl get pods -l tier=batch -o jsonpath='{.items[*].spec.nodeName}' 2>/dev/null | wc -w)
    [ "$n" -eq 8 ] && break
    sleep 1
  done

  # --- picu preemption: minta 2 GPU saat cluster penuh ---
  kubectl apply -f "$INTER" >/dev/null
  for _ in $(seq 20); do
    NODE=$(kubectl get pod interactive-1 -o jsonpath='{.spec.nodeName}' 2>/dev/null)
    [ -n "$NODE" ] && break
    sleep 1
  done
  NODE=${NODE:-PENDING}

  # --- korban = pod batch yang tidak lagi ada ---
  alive=" $(kubectl get pods -l tier=batch -o jsonpath='{.items[*].metadata.name}' 2>/dev/null) "
  victims=""
  for i in $(seq 1 8); do
    case "$alive" in
      *" batch-$i "*) ;;
      *) victims="$victims batch-$i" ;;
    esac
  done

  node_count["$NODE"]=$(( ${node_count["$NODE"]:-0} + 1 ))
  printf '%-5s %-16s %s\n' "$run" "$NODE" "${victims# }"
done

echo ""
echo "Ringkasan pilihan node:"
for k in "${!node_count[@]}"; do
  printf '  %-16s %d/%s putaran\n' "$k" "${node_count[$k]}" "$RUNS"
done
echo ""
echo "Baca hasilnya:"
echo "  Node berganti-ganti  -> tiebreak, tidak deterministik. Hipotesis benar."
echo "  Selalu node yang sama -> ada sebab sistematis. Hipotesis SALAH, cari lagi."
echo ""
kubectl delete pod -l sim=true --ignore-not-found >/dev/null 2>&1
