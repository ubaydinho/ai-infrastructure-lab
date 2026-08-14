#!/usr/bin/env bash
# Uji jalur request end-to-end ke tiap endpoint model di tiap site.
# Lewat ingress Traefik, BUKAN port-forward — supaya yang diuji jalur yang sama
# dengan yang dipakai client sungguhan: DNS/Host → traefik → Service → pod.
# Aman dijalankan berkali-kali.
set -uo pipefail

# Port 8080 host dipetakan ke port 80 loadbalancer k3d (lihat cluster/k3d.yaml).
LB="${LB:-http://localhost:8080}"
# Domain ini datang dari kserve.controller.gateway.domain di
# serving/kserve/values-rawdeployment.yaml. Sengaja domain palsu: kita kirim
# lewat header Host, jadi tidak ada ketergantungan DNS sama sekali.
DOMAIN="${DOMAIN:-example.com}"
SITES="${SITES:-site-a site-b}"
MODELS="${MODELS:-llama-sim deepseek-sim}"

PASS=0; FAIL=0
ok()  { echo "  [ ok ] $1"; PASS=$((PASS+1)); }
bad() { echo "  [FAIL] $1"; FAIL=$((FAIL+1)); }

echo ""
echo "== Endpoint lewat $LB =="

for site in $SITES; do
  for model in $MODELS; do
    host="${model}-${site}.${DOMAIN}"

    # 1. Identitas: endpoint harus mengaku sebagai model yang benar. Ini yang
    #    membedakan "ingress nyasar ke pod tetangga" dari "ingress benar".
    got=$(curl -s --max-time 15 "$LB/v1/models" -H "Host: $host" \
          | jq -r '.data[0].id // "?"' 2>/dev/null)
    if [ "$got" = "$model" ]; then
      ok "$host → /v1/models = $got"
    else
      bad "$host → /v1/models = '$got', harusnya '$model'"
      continue
    fi

    # 2. Token: respons harus benar-benar berisi token hasil generate, bukan
    #    sekadar HTTP 200. Endpoint yang hidup tapi menghasilkan 0 token adalah
    #    kegagalan yang paling gampang lolos dari monitoring.
    body=$(curl -s --max-time 90 -w '\n%{time_total}' \
           -X POST "$LB/v1/chat/completions" \
           -H "Host: $host" -H "Content-Type: application/json" \
           -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"Name one color.\"}],\"max_tokens\":16}")
    secs=$(echo "$body" | tail -1)
    json=$(echo "$body" | sed '$d')

    toks=$(echo "$json" | jq -r '.usage.completion_tokens // 0' 2>/dev/null)
    text=$(echo "$json" | jq -r '.choices[0].message.content // ""' 2>/dev/null | tr '\n' ' ' | cut -c1-48)

    if [ "${toks:-0}" -gt 0 ] 2>/dev/null; then
      ok "$host → ${toks} token dalam ${secs}s — \"${text}\""
    else
      bad "$host → tidak ada token. Respons mentah: $(echo "$json" | head -c 160)"
    fi
  done
done

echo ""
echo "-- ringkasan: ${PASS} ok, ${FAIL} gagal --"
if [ "$FAIL" -gt 0 ]; then
  echo "   Cek dulu: kubectl get isvc -A ; kubectl get ingress -A"
  echo "   Kalau isvc READY tapi curl gagal, masalahnya di ingress, bukan di model."
  exit 1
fi
echo "   Jalur request kedua site hidup."
