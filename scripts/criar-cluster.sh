#!/usr/bin/env bash
set -euo pipefail

CLUSTER=autocenter
CTX="kind-${CLUSTER}"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INGRESS_URL="https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/kind/deploy.yaml"
K="kubectl --context ${CTX}"

export KIND_EXPERIMENTAL_DOCKER_NETWORK="${KIND_EXPERIMENTAL_DOCKER_NETWORK:-autocenter}"

CTX_ANTERIOR="$(kubectl config current-context 2>/dev/null || true)"

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER}"; then
  echo "Cluster ${CLUSTER} ja existe."
else
  for p in 80 443 9094; do
    if ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${p}$"; then
      echo "ERRO: porta ${p} do host em uso. Libere-a (ex.: o cluster kind antigo) e rode de novo." >&2
      exit 1
    fi
  done
  restaurar_contexto() {
    if [ -n "${CTX_ANTERIOR}" ] && [ "${CTX_ANTERIOR}" != "${CTX}" ]; then
      kubectl config use-context "${CTX_ANTERIOR}" >/dev/null 2>&1 || true
    fi
  }
  trap restaurar_contexto EXIT INT TERM
  kind create cluster --config "${RAIZ}/kind/cluster.yaml"
  restaurar_contexto
fi

echo "Aplicando Ingress NGINX (controller-v1.11.2)..."
${K} apply -f "${INGRESS_URL}"
${K} -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=180s
${K} -n ingress-nginx wait --for=condition=complete job/ingress-nginx-admission-create --timeout=120s || true

echo "Aplicando k8s/..."
${K} -n autocenter delete job kafka-topicos --ignore-not-found
${K} apply -k "${RAIZ}/k8s"

${K} -n autocenter rollout status statefulset/kafka --timeout=240s
echo "Pronto. Aguarde o job: kubectl --context ${CTX} -n autocenter wait --for=condition=complete job/kafka-topicos --timeout=180s"
