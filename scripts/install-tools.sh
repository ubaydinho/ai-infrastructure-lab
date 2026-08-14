#!/usr/bin/env bash
# Pasang tooling yang dibutuhkan lab ini. Linux amd64. Aman diulang.
# URL diverifikasi 2026-07-28. Semua binary mendarat di /usr/local/bin.
set -euo pipefail

BIN=/usr/local/bin
# /tmp sering tmpfs (berbasis RAM). Tarball prometheus ~110 MB — taruh di disk.
TMP=$(mktemp -d -p "${TMPDIR:-/var/tmp}"); trap 'rm -rf "$TMP"' EXIT

# Tooling test bisa dilewati: SKIP_OPTIONAL=1 bash scripts/install-tools.sh
SKIP_OPTIONAL="${SKIP_OPTIONAL:-0}"
have() { command -v "$1" >/dev/null 2>&1; }
say()  { echo ">> $*"; }

# ---------- wajib ----------

if ! docker info >/dev/null 2>&1; then
  say "menyalakan docker daemon"
  sudo systemctl enable --now docker
  if ! id -nG "$USER" | grep -qw docker; then
    sudo usermod -aG docker "$USER"
    echo "   Kamu ditambahkan ke grup docker. Logout-login, atau: newgrp docker"
  fi
fi

if ! have kubectl; then
  say "kubectl"
  KVER=$(curl -Ls https://dl.k8s.io/release/stable.txt)
  curl -sSLo "$TMP/kubectl" "https://dl.k8s.io/release/${KVER}/bin/linux/amd64/kubectl"
  sudo install -m 0755 "$TMP/kubectl" "$BIN/kubectl"
fi

if ! have k3d; then
  say "k3d"
  curl -sS https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash
fi

if ! have helm; then
  say "helm"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

# ---------- tooling test: dipakai CI, enak kalau ada lokal ----------

if [ "$SKIP_OPTIONAL" = "1" ]; then
  echo ""
  say "tooling test dilewati (SKIP_OPTIONAL=1). Yang wajib sudah siap."
  exit 0
fi

if ! have kubeconform; then
  say "kubeconform"
  curl -fsSL -o "$TMP/kc.tgz" \
    https://github.com/yannh/kubeconform/releases/latest/download/kubeconform-linux-amd64.tar.gz
  tar -xzf "$TMP/kc.tgz" -C "$TMP" kubeconform
  sudo install -m 0755 "$TMP/kubeconform" "$BIN/kubeconform"
fi

if ! have promtool; then
  say "promtool (dari rilis prometheus)"
  # '|| true' wajib: tanpa itu, pipefail + set -e membunuh skrip saat API
  # kena rate limit, dan baris fallback di bawah tidak pernah tereksekusi.
  PVER=$(curl -fsS https://api.github.com/repos/prometheus/prometheus/releases/latest 2>/dev/null \
         | grep -m1 '"tag_name"' | sed 's/.*: "v//; s/".*//' || true)
  PVER=${PVER:-3.13.1}
  say "  versi ${PVER}, tarball ~110 MB — ini bagian paling lama"
  curl -fsSL -o "$TMP/prom.tgz" \
    "https://github.com/prometheus/prometheus/releases/download/v${PVER}/prometheus-${PVER}.linux-amd64.tar.gz"
  tar -xzf "$TMP/prom.tgz" -C "$TMP" --strip-components=1 "prometheus-${PVER}.linux-amd64/promtool"
  sudo install -m 0755 "$TMP/promtool" "$BIN/promtool"
fi

if ! have crane; then
  say "crane (mirroring image untuk air-gap)"
  curl -fsSL -o "$TMP/cr.tgz" \
    https://github.com/google/go-containerregistry/releases/latest/download/go-containerregistry_Linux_x86_64.tar.gz
  tar -xzf "$TMP/cr.tgz" -C "$TMP" crane
  sudo install -m 0755 "$TMP/crane" "$BIN/crane"
fi

if ! have k9s; then
  say "k9s (bukan kemewahan di 8 GB — kamu butuh lihat siapa makan memori)"
  curl -fsSL -o "$TMP/k9s.tgz" \
    https://github.com/derailed/k9s/releases/latest/download/k9s_Linux_amd64.tar.gz
  tar -xzf "$TMP/k9s.tgz" -C "$TMP" k9s
  sudo install -m 0755 "$TMP/k9s" "$BIN/k9s"
fi

if ! have yq; then
  say "yq"
  curl -fsSL -o "$TMP/yq" https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
  sudo install -m 0755 "$TMP/yq" "$BIN/yq"
fi

echo ""
say "selesai. Verifikasi: bash scripts/preflight.sh"
