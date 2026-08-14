#!/usr/bin/env bash
# Unit test alert rule dengan promtool.
#
# Kenapa perlu skrip dan bukan 'promtool test rules' langsung: promtool tidak
# mengerti PrometheusRule — itu objek Kubernetes dengan rule-nya terkubur di
# .spec. promtool mau file rules Prometheus polos (top-level 'groups:').
# Skrip ini mengekstrak .spec tiap PrometheusRule ke direktori sementara,
# menaruh file test di sebelahnya, lalu menjalankan promtool di sana.
#
# Konsekuensinya: 'rule_files:' di file test merujuk NAMA FILE yang sama dengan
# manifest-nya. observability/rules/serving.yaml -> rule_files: [serving.yaml]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT

python3 - "$ROOT" "$TMP" <<'PY'
import sys, pathlib, yaml
root, tmp = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
n = 0
for f in sorted((root / "observability" / "rules").glob("*.yaml")):
    doc = yaml.safe_load(f.read_text(encoding="utf-8"))
    if not doc or doc.get("kind") != "PrometheusRule":
        continue
    (tmp / f.name).write_text(yaml.safe_dump(doc["spec"], sort_keys=False, allow_unicode=True),
                              encoding="utf-8")
    n += 1
if n == 0:
    sys.exit("tidak ada PrometheusRule di observability/rules/")
print(f">> {n} PrometheusRule diekstrak jadi rules Prometheus polos")
PY

cp "$ROOT"/observability/tests/*_test.yaml "$TMP"/
cd "$TMP"
promtool test rules ./*_test.yaml
