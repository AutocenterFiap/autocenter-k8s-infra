#!/usr/bin/env bash
set -euo pipefail

AMBIENTE="${1:-qa}"
RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PASTA="${RAIZ}/datadog/dashboards"

case "${AMBIENTE}" in
  dev)
    SUFIXO=PROD
    ;;
  qa)
    SUFIXO=QA
    ;;
  *)
    echo "Uso: $0 [dev|qa]" >&2
    exit 1
    ;;
esac

VAR_API="DD_API_KEY_${SUFIXO}"
VAR_APP="DD_APP_KEY_${SUFIXO}"
VAR_SITE="DD_SITE_${SUFIXO}"
CHAVE_API="${!VAR_API:-}"
CHAVE_APP="${!VAR_APP:-}"
SITE="${!VAR_SITE:-datadoghq.com}"

if [ -z "${CHAVE_API}" ] || [ -z "${CHAVE_APP}" ]; then
  echo "ERRO: defina ${VAR_API} e ${VAR_APP} (veja o README)." >&2
  exit 1
fi

CABECALHOS="$(mktemp)"
RESPOSTA="$(mktemp)"
trap 'rm -f "${CABECALHOS}" "${RESPOSTA}"' EXIT
chmod 600 "${CABECALHOS}"
printf 'DD-API-KEY: %s\nDD-APPLICATION-KEY: %s\nContent-Type: application/json\n' "${CHAVE_API}" "${CHAVE_APP}" > "${CABECALHOS}"
API="https://api.${SITE}/api/v1/dashboard"
case "${SITE}" in
  datadoghq.com|datadoghq.eu) PAINEL="https://app.${SITE}" ;;
  *) PAINEL="https://${SITE}" ;;
esac

chamar() {
  curl -s -o "${RESPOSTA}" -w '%{http_code}' -H @"${CABECALHOS}" "$@"
}

STATUS="$(chamar "${API}")"
if [ "${STATUS}" != "200" ]; then
  echo "ERRO: nao foi possivel listar os dashboards (HTTP ${STATUS}). Confira ${VAR_APP}." >&2
  exit 1
fi
EXISTENTES="$(cat "${RESPOSTA}")"

for arquivo in "${PASTA}"/*.json; do
  titulo="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["title"])' "${arquivo}")"
  id="$(printf '%s' "${EXISTENTES}" | python3 -c '
import json, sys
alvo = sys.argv[1]
for d in json.load(sys.stdin).get("dashboards", []):
    if d["title"] == alvo:
        print(d["id"])
        break
' "${titulo}")"
  if [ -n "${id}" ]; then
    STATUS="$(chamar -X PUT --data-binary @"${arquivo}" "${API}/${id}")"
    acao="atualizado"
  else
    STATUS="$(chamar -X POST --data-binary @"${arquivo}" "${API}")"
    acao="criado"
  fi
  if [ "${STATUS}" != "200" ]; then
    echo "ERRO em ${titulo} (HTTP ${STATUS}):" >&2
    cat "${RESPOSTA}" >&2
    echo >&2
    exit 1
  fi
  url="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("url",""))' "${RESPOSTA}")"
  echo "${acao}: ${titulo} -> ${PAINEL}${url}"
done
