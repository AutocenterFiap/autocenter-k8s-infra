#!/usr/bin/env bash
set -euo pipefail

AMBIENTE="${1:-dev}"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE=autocenter

case "${AMBIENTE}" in
  dev)
    CLUSTER=autocenter
    MANIFESTOS="${RAIZ}/k8s/datadog"
    VAR_CHAVE=DD_API_KEY_PROD
    CHAVE="${DD_API_KEY_PROD:-}"
    SITE="${DD_SITE_PROD:-datadoghq.com}"
    ;;
  qa)
    CLUSTER=autocenter-qa
    MANIFESTOS="${RAIZ}/overlays/qa/datadog"
    VAR_CHAVE=DD_API_KEY_QA
    CHAVE="${DD_API_KEY_QA:-}"
    SITE="${DD_SITE_QA:-datadoghq.com}"
    ;;
  *)
    echo "Uso: $0 [dev|qa]" >&2
    exit 1
    ;;
esac

CTX="kind-${CLUSTER}"
K="kubectl --context ${CTX}"

if [ -z "${CHAVE}" ]; then
  echo "Datadog nao configurado em ${CLUSTER}: defina ${VAR_CHAVE} para subir o agent (veja o README)."
  exit 0
fi

if [ -n "${DD_API_KEY_PROD:-}" ] && [ "${DD_API_KEY_PROD:-}" = "${DD_API_KEY_QA:-}" ]; then
  echo "ERRO: DD_API_KEY_PROD e DD_API_KEY_QA sao iguais; cada ambiente usa a chave da sua conta." >&2
  exit 1
fi

if ! kubectl config get-contexts -o name | grep -qx "${CTX}"; then
  echo "ERRO: contexto ${CTX} nao existe. Crie o cluster antes: ./scripts/criar-cluster.sh ${AMBIENTE}" >&2
  exit 1
fi

STATUS_CHAVE="$(curl -s -o /dev/null -w '%{http_code}' -H @<(printf 'DD-API-KEY: %s' "${CHAVE}") \
  "https://api.${SITE}/api/v1/validate" || true)"
if [ "${STATUS_CHAVE}" != "200" ]; then
  echo "ERRO: ${VAR_CHAVE} recusada pelo site ${SITE} (HTTP ${STATUS_CHAVE}). Confira a chave e a regiao da conta." >&2
  exit 1
fi

echo "Aplicando Datadog em ${CLUSTER} (site ${SITE})..."
RESULTADO_SECRET="$(${K} -n "${NAMESPACE}" create secret generic datadog-secret \
  --from-file=api-key=<(printf '%s' "${CHAVE}") \
  --from-literal=site="${SITE}" \
  --dry-run=client -o yaml | ${K} apply -f -)"
echo "${RESULTADO_SECRET}"

${K} apply -k "${MANIFESTOS}"

if [[ "${RESULTADO_SECRET}" == *configured* ]]; then
  ${K} -n "${NAMESPACE}" rollout restart daemonset/datadog
fi

${K} -n "${NAMESPACE}" rollout status daemonset/datadog --timeout=180s
echo "Datadog pronto em ${CLUSTER}. Status: ${K} -n ${NAMESPACE} exec ds/datadog -- agent status"
