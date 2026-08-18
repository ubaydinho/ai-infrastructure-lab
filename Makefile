SHELL := /bin/bash
.DEFAULT_GOAL := help

# Aturan main lab ini:
#
# 1. Setiap perubahan butuh bukti jalan — output command atau test lulus — sebelum
#    dianggap selesai. 'make test' jalan tanpa cluster dan sama persis dengan CI.
# 2. Naikkan per profil (up-core → up-sim → up-serving → up-obs), jangan sekaligus,
#    dan lihat 'make mem' di antaranya. Di 8 GB urutan ini yang bikin muat.
# 3. Untuk uji failover, matikan endpoint dengan anotasi:
#      kubectl annotate isvc <nama> -n site-a serving.kserve.io/stop=true
#    JANGAN 'kubectl scale --replicas=0' — controller KServe mengembalikannya dari
#    spec.predictor.minReplicas dalam ~8 detik. Bukti: docs/20-serving-plane.md 3.2

CLUSTER      ?= lab
KUBECTL      ?= kubectl

# Versi diverifikasi lewat API GitHub pada 2026-07-28. Cek lagi sebelum bump,
# dan naikkan satu per satu — bukan sekaligus.
KWOK_VER     ?= v0.8.0
CERTMGR_VER  ?= v1.21.0
KSERVE_VER   ?= v0.18.1

# Knative sengaja tidak ada di daftar ini. KServe jalan mode RawDeployment —
# lihat serving/kserve/values-rawdeployment.yaml untuk alasannya.
#
# Kalau kamu bump KSERVE_VER: nama chart controller pernah berubah. Sampai
# v0.17.0-rc0 namanya 'kserve', sejak v0.18 yang dirilis ke OCI cuma
# 'kserve-resources'. Cek dulu sebelum percaya perintah helm di bawah:
#   curl -s "https://api.github.com/repos/kserve/kserve/contents/charts?ref=$(KSERVE_VER)" | jq -r '.[].name'

# Kyverno: yang dipin di helm adalah versi CHART, bukan versi aplikasi (app v1.18.2).
# Resolve sekali lalu isi di sini:  helm search repo kyverno/kyverno --versions | head -3
# Dikosongkan = ambil terbaru. Isi begitu kamu tahu angkanya, biar reproducible.
KYVERNO_CHART ?=

# kube-prometheus-stack: versi CHART (app = prometheus-operator v0.93.0).
# Resolve ulang sebelum bump:  helm search repo prometheus-community/kube-prometheus-stack --versions | head -3
KPS_CHART    ?= 88.3.0

# k3s v1.36.2+k3s1 adalah stable terbaru, tapi JANGAN otomatis pakai yang terbaru:
# KServe punya matriks dukungan yang tertinggal 1-2 minor di belakang
# Kubernetes. Cluster yang terlalu baru gagal dengan cara yang membingungkan.
# Pilih patch terbaru dari minor yang aman (biasanya N-2), lalu pin di cluster/k3d.yaml:
#   curl -s https://api.github.com/repos/k3s-io/k3s/releases?per_page=100 \
#     | grep tag_name | grep -m1 'v1.34'
# Format tag image memakai '-k3s1', bukan '+k3s1'.

##@ Bantuan

help: ## Tampilkan daftar target
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z_0-9-]+:.*?##/ { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 } /^##@/ { printf "\n%s\n", substr($$0, 5) }' $(MAKEFILE_LIST)
	@echo ""

##@ Sprint 0 — fondasi

preflight: ## Cek host siap atau belum (RAM, docker, tooling)
	@bash scripts/preflight.sh

cluster: ## Buat cluster k3d kalau belum ada, lalu beri label seperti platform produksi
	@if k3d cluster list $(CLUSTER) >/dev/null 2>&1; then \
		echo ">> cluster '$(CLUSTER)' sudah ada, dilewati"; \
	else \
		k3d cluster create --config cluster/k3d.yaml; \
	fi
	@$(KUBECTL) wait --for=condition=Ready nodes --all --timeout=120s
	@$(KUBECTL) label node k3d-$(CLUSTER)-agent-0 node-role.lab.internal/worker=true --overwrite
	@$(KUBECTL) label node k3d-$(CLUSTER)-agent-1 node-role.lab.internal/worker=true --overwrite
	@$(KUBECTL) get nodes -o wide

##@ Profil — jangan jalankan semua sekaligus di 8 GB

# Kyverno dikeluarkan dari profil core di lab v2: tidak dipakai satu pun skenario
# serving/failover, dan 400 MB itu langsung mengurangi ruang untuk pod model.
# Targetnya masih ada — 'make kyverno' kalau butuh latihan admission policy.
up-core: cluster cert-manager kwok ## ~1.0 GB — cluster + traefik + cert-manager + kwok
	@echo ">> core siap. Jalankan 'make mem' untuk cek anggaran memori."

up-sim: kwok ## Pasang 2 worker H200 palsu + PriorityClass (butuh up-core)
	@$(KUBECTL) apply -f sim/nodes/
	@$(KUBECTL) apply -f sim/priorityclasses.yaml
	@$(KUBECTL) get nodes -L nvidia.com/gpu.product

up-serving: kserve sites ## ~1.6 GB (terukur) — KServe RawDeployment + 4 InferenceService di 2 site
	@echo ">> serving plane siap. Uji jalur request: make smoke"

up-obs: obs obs-config ## Prometheus + Grafana + Alertmanager + monitor/rule/dashboard lab
	@echo ">> observability siap. Buka Grafana: make grafana"

##@ Komponen

cert-manager: ## Prasyarat KServe
	@$(KUBECTL) get ns cert-manager >/dev/null 2>&1 || \
		$(KUBECTL) apply -f https://github.com/cert-manager/cert-manager/releases/download/$(CERTMGR_VER)/cert-manager.yaml
	@$(KUBECTL) -n cert-manager rollout status deploy/cert-manager-webhook --timeout=180s

kyverno: ## Admission policy engine, dipangkas jadi seringan mungkin
	@helm repo add kyverno https://kyverno.github.io/kyverno/ 2>/dev/null || true
	@helm upgrade --install kyverno kyverno/kyverno -n kyverno --create-namespace \
		$(if $(KYVERNO_CHART),--version $(KYVERNO_CHART)) \
		--set admissionController.replicas=1 \
		--set backgroundController.replicas=1 \
		--set cleanupController.enabled=false \
		--set reportsController.enabled=false \
		--wait --timeout 5m

kwok: ## Controller node palsu — ini yang bikin 8x H200 muat di 8 GB
	@$(KUBECTL) get deploy -n kube-system kwok-controller >/dev/null 2>&1 || { \
		$(KUBECTL) apply -f https://github.com/kubernetes-sigs/kwok/releases/download/$(KWOK_VER)/kwok.yaml; \
		$(KUBECTL) apply -f https://github.com/kubernetes-sigs/kwok/releases/download/$(KWOK_VER)/stage-fast.yaml; \
	}
	@$(KUBECTL) -n kube-system rollout status deploy/kwok-controller --timeout=120s

kserve: cert-manager ## KServe RawDeployment — TANPA Knative, itu yang bikin muat di 8 GB
	@helm upgrade --install kserve-crd oci://ghcr.io/kserve/charts/kserve-crd \
		--version $(KSERVE_VER) -n kserve --create-namespace --wait --timeout 6m
	@helm upgrade --install kserve oci://ghcr.io/kserve/charts/kserve-resources \
		--version $(KSERVE_VER) -n kserve -f serving/kserve/values-rawdeployment.yaml \
		--wait --timeout 10m
	@$(KUBECTL) -n kserve rollout status deploy/kserve-controller-manager --timeout=300s
	@echo -n ">> deploymentMode yang benar-benar aktif: "
	@$(KUBECTL) -n kserve get cm inferenceservice-config -o jsonpath='{.data.deploy}' | tr -d '\n {}"'
	@echo ""

sites: kserve ## site-a & site-b, masing-masing llama-sim + deepseek-sim
	@$(KUBECTL) apply -f serving/runtimes/
	@$(KUBECTL) apply -f serving/sites/
	@for ns in site-a site-b; do \
		$(KUBECTL) wait --for=condition=Ready inferenceservice --all -n $$ns --timeout=600s; \
	done
	@$(KUBECTL) get inferenceservice -A

obs: ## kube-prometheus-stack, di-scope untuk 8 GB (lihat observability/values-*.yaml)
	@helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
	@helm repo update prometheus-community >/dev/null
	@helm upgrade --install kps prometheus-community/kube-prometheus-stack \
		--version $(KPS_CHART) -n monitoring --create-namespace \
		-f observability/values-kube-prometheus-stack.yaml \
		--wait --timeout 12m
	@$(KUBECTL) -n monitoring get pods

obs-config: ## PodMonitor/ServiceMonitor + PrometheusRule + dashboard Grafana
	@$(KUBECTL) apply -f observability/monitors/
	@$(KUBECTL) apply -f observability/rules/
	@$(KUBECTL) apply -f observability/grafana/dashboards/

##@ Operasi

status: ## Ringkasan cluster
	@echo "--- nodes ---"
	@$(KUBECTL) get nodes -o wide
	@echo "--- gpu allocatable ---"
	@$(KUBECTL) get nodes -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'
	@echo "--- pod tidak Running ---"
	@$(KUBECTL) get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded

smoke: ## Uji jalur request ke 4 endpoint lewat ingress (butuh up-serving)
	@bash scripts/smoke-serving.sh

grafana: ## Port-forward Grafana ke localhost:3000 (user admin, password lab)
	@echo ">> http://localhost:3000  — admin / lab   (Ctrl-C untuk berhenti)"
	@$(KUBECTL) -n monitoring port-forward svc/kps-grafana 3000:80

mem: ## Anggaran memori sekarang — sering-sering lihat ini
	@docker stats --no-stream --format "table {{.Name}}\t{{.MemUsage}}\t{{.CPUPerc}}" | head -12
	@echo ""
	@free -h | head -2

down: ## Hapus cluster
	@k3d cluster delete $(CLUSTER)

clean: ## Rapikan image lama (150 GB tidak selega kelihatannya)
	@docker system prune -af --filter "until=168h"

##@ Test — semua tanpa cluster, sama persis dengan yang jalan di CI

test: test-lint test-schema test-rules ## Jalankan semua test lokal

test-lint: ## helm lint semua chart, termasuk yang diarsipkan
	@for c in charts/*/ charts/_archive/*/; do if [ -f "$$c/Chart.yaml" ]; then helm lint "$$c"; fi; done

# Pola yang dikecualikan adalah file YANG MEMANG BUKAN manifest Kubernetes:
# values Helm (input chart), registries.yaml (config containerd), dan *_test.yaml
# (kasus uji promtool). Node KWOK palsu SENGAJA tidak dikecualikan — field wajibnya
# diisi di sim/nodes/ supaya validasi tetap -strict. Setiap pengecualian baru di sini
# adalah tempat bug bersembunyi; tambahkan hanya kalau file itu benar-benar bukan manifest.
test-schema: ## Validasi manifest terhadap skema Kubernetes dan CRD
	@kubeconform -strict -summary -ignore-missing-schemas \
		-ignore-filename-pattern 'values.*\.yaml' \
		-ignore-filename-pattern 'registries\.yaml' \
		-ignore-filename-pattern '_test\.yaml' \
		-schema-location default \
		-schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
		cluster/ sim/ serving/ observability/

test-rules: ## Unit test alert rule (promtool) — sama dengan yang jalan di CI
	@bash scripts/test-rules.sh

.PHONY: help preflight cluster up-core up-sim up-serving up-obs cert-manager kyverno kwok kserve sites obs obs-config status smoke grafana mem down clean test test-lint test-schema test-rules
