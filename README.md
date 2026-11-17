# autocenter-k8s-infra

Infraestrutura comum dos microsservicos AutoCenter (OS, Billing, Execucao) em um
cluster **kind** local: namespace `autocenter`, Kafka (KRaft, 1 broker) e
Ingress NGINX. Nao e AWS; roda na maquina de cada desenvolvedor.

## Requisitos
Docker, `kind` (>= 0.22) e `kubectl`.

## Subir
```bash
./scripts/criar-cluster.sh
kubectl --context kind-autocenter -n autocenter wait --for=condition=complete job/kafka-topicos --timeout=180s
```
O script e idempotente (pode rodar de novo). Ele so age no cluster `autocenter`
(todos os `kubectl` usam `--context kind-autocenter`) e devolve o contexto
kubectl que voce tinha antes. Cria uma rede docker propria `autocenter`.

**Portas do host:** 80, 443 (Ingress) e 9094 (Kafka para dev local). Se estiverem
ocupadas o script aborta sem matar nada. Um cluster kind antigo que mapeie 80/443
(ex.: `auto-center`) nao pode rodar junto com este: pare um deles antes.
Na maquina de cada um, o cluster e independente (nao ha compartilhamento entre
maquinas): cada pessoa roda o script e tem seu proprio Kafka.

## Homologacao (cluster `autocenter-qa`)
Um segundo cluster kind, `autocenter-qa` (contexto `kind-autocenter-qa`), representa o ambiente de
homologacao. Ele roda junto com o `autocenter`, na mesma maquina, com portas e rede docker proprias:

| | Dev (`autocenter`) | Homologacao (`autocenter-qa`) |
|---|---|---|
| Subir | `./scripts/criar-cluster.sh` | `./scripts/criar-cluster.sh qa` |
| Contexto | `kind-autocenter` | `kind-autocenter-qa` |
| Ingress (host) | `http://localhost/` | `http://localhost:18080/` |
| Kafka do host | `localhost:9094` | `localhost:19094` |
| Kafka UI | `http://kafka-ui.localhost/` | `http://kafka-ui.localhost:18080/` |
| Rede docker | `autocenter` | `autocenter-qa` (`172.31.0.0/16`) |
| Manifestos | `k8s/` | `overlays/qa/` (base `k8s/` + endereco externo do Kafka) |

Os microsservicos fazem deploy no `autocenter-qa` a cada push (merge) na branch `homologacao` e no
`autocenter` a cada push na `main`, pelo runner self-hosted desta maquina.

Remover so a homologacao: `kind delete cluster --name autocenter-qa && docker network rm autocenter-qa`.

## Topicos (todos com 3 particoes, replicacao 1)
`os.eventos`, `billing.comandos`, `execucao.comandos`, `billing.eventos`,
`execucao.eventos`, `billing.eventos.dlt`, `execucao.eventos.dlt`.

`auto.create.topics.enable=false` (decisao explicita): topicos e DLTs sao criados
so pelo Job `kafka-topicos` (`--if-not-exists`, reexecutavel). Publicar em topico
inexistente falha em vez de criar um topico errado. Para um topico novo, inclua-o
no Job e reaplique (`kubectl delete job kafka-topicos -n autocenter` antes, pois
o spec do Job e imutavel).

## Como conectar
**Servico dentro do cluster:**
`kafka.autocenter.svc.cluster.local:9092` (no namespace `autocenter` tambem vale `kafka:9092`). O broker se
anuncia com o nome completo, entao clientes de outros namespaces (Billing, Execucao) conseguem conectar. Nos Deployments do servico use
`enableServiceLinks: false` se o pod usar imagem que le variaveis `KAFKA_*`.

**Carregar sua imagem no kind (sem registry):**
```bash
docker build -t meu-servico:dev .
kind load docker-image meu-servico:dev --name autocenter
```
use `imagePullPolicy: IfNotPresent` e `namespace: autocenter` nos manifests, e
`kubectl --context kind-autocenter apply -f ...`.

**Do host (desenvolvimento local, fora do cluster):** bootstrap `localhost:9094`
(listener EXTERNO, anunciado como `localhost:9094`). Validado com cliente real
no host (`docker run --rm --network host apache/kafka:3.8.0`): criou topico
temporario, produziu e consumiu 1 mensagem e removeu o topico.

**Ingress:** controller `ingress-nginx` v1.11.2, `ingressClassName: nginx`;
`http://localhost/` responde 404 do nginx ate existir um Ingress.

Checar topicos:
```bash
kubectl --context kind-autocenter -n autocenter exec kafka-0 -- \
  /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list
```
(aparece tambem `__consumer_offsets`, interno.) Os dados ficam em PVC de 5Gi e
sobrevivem a reinicio do pod; o cluster id KRaft e fixo.

## Kafka UI (visualizar o Kafka)
`k8s/kafka-ui.yaml` sobe o [Kafka UI](https://github.com/kafbat/kafka-ui) (kafbat,
Apache 2.0, `kafbat/kafka-ui:v1.5.0`) junto com o resto do `criar-cluster.sh`.
Abra **http://kafka-ui.localhost/** (Ingress com host proprio; `*.localhost`
resolve para 127.0.0.1). Mostra broker, topicos/particoes, mensagens (com filtro),
consumer groups com lag, e permite publicar mensagens para testar a Saga.

Sem login e com escrita liberada (apagar/criar topico, publicar): uso so em dev
local. Se um topico for apagado por engano, recrie com o Job `kafka-topicos`
(`./scripts/criar-cluster.sh`). Logo apos subir o pod, o Ingress pode responder
503 por alguns segundos ate registrar o endpoint.

Num cluster ja existente, basta: `kubectl --context kind-autocenter apply -f k8s/kafka-ui.yaml`.

## Datadog (uma conta por ambiente)
Cada cluster envia para a sua propria conta do Datadog: `autocenter` (producao) usa a chave da conta de
producao e `autocenter-qa` (homologacao) a da conta de QA. Os dados dos ambientes nunca se misturam.

| | Producao (`autocenter`) | Homologacao (`autocenter-qa`) |
|---|---|---|
| Variaveis | `DD_API_KEY_PROD`, `DD_SITE_PROD` | `DD_API_KEY_QA`, `DD_SITE_QA` |
| Manifestos | `k8s/datadog/` | `overlays/qa/datadog/` |
| `DD_CLUSTER_NAME` / `DD_ENV` do agent | `kind-autocenter` / `prod` | `kind-autocenter-qa` / `qa` |

As chaves ficam num arquivo local, nunca no git:
```bash
cat > ~/.autocenter-datadog.env <<'FIM'
export DD_API_KEY_PROD=<chave da conta de producao>
export DD_API_KEY_QA=<chave da conta de QA>
export DD_SITE_PROD=datadoghq.com
export DD_SITE_QA=datadoghq.com
FIM
chmod 600 ~/.autocenter-datadog.env
```
`DD_SITE` depende da regiao da conta (URL do navegador): `app.datadoghq.com` = `datadoghq.com`,
`us3.datadoghq.com`, `us5.datadoghq.com`, `app.datadoghq.eu` = `datadoghq.eu`. Sem a variavel, vale `datadoghq.com`.

Subir ou atualizar o agent (so mexe no Datadog do cluster escolhido):
```bash
source ~/.autocenter-datadog.env
./scripts/datadog.sh qa
./scripts/datadog.sh dev
```
O `criar-cluster.sh` tambem chama o `datadog.sh` no final. Sem a chave do ambiente, o agent nao e instalado
e o script so avisa. Antes de aplicar, a chave e validada na API do Datadog; chaves iguais nos dois ambientes
sao recusadas. Trocar a chave e rodar de novo reinicia o agent com a chave nova.

O agent (7.83.1, adaptado ao containerd do kind) coleta metricas, logs de todos os containers e traces (APM).
Os servicos enviam traces para `status.hostIP:8126`, por isso o agent expoe `hostPort: 8126`.

O agent tambem expoe `hostPort: 8125/UDP` (DogStatsD), por onde o tracer envia as metricas de JVM, e
ignora os checks de etcd, scheduler e controller-manager, que no kind so escutam em localhost.

Conferir: `kubectl --context kind-autocenter-qa -n autocenter exec ds/datadog -- agent status`.

### Dashboards
Os dashboards ficam versionados em `datadog/dashboards/` e sao publicados pela API:

| Dashboard | Conteudo |
|---|---|
| `visao-geral.json` | Saude agora (req/s, % erro, p95, erros em log), tabela por servico, trafego, fluxo da Saga, pods e ultimos erros |
| `analise-de-erros.json` | 2xx/4xx/5xx, endpoints com mais erros e mais lentos, erros de Kafka, HTTP de saida, banco e tarefas agendadas, logs e pods |
| `infra-e-jvm.json` | CPU e memoria dos pods x limite, restarts, heap, GC, threads, Kafka e bancos, no do cluster |

Todos tem os filtros `env` e `service` no topo. Para publicar e preciso uma **Application Key** da
mesma conta da API key (Organization Settings > Application Keys), no arquivo de chaves:
```bash
export DD_APP_KEY_QA=<application key da conta de QA>
export DD_APP_KEY_PROD=<application key da conta de producao>
```
```bash
source ~/.autocenter-datadog.env
./scripts/datadog-dashboards.sh qa
./scripts/datadog-dashboards.sh dev
```
O script cria ou atualiza pelo titulo, entao pode rodar de novo. Alteracoes feitas na tela do Datadog sao
sobrescritas na proxima execucao: edite o JSON (ou exporte pela tela e substitua o arquivo).
Remover de um cluster: `kubectl --context kind-autocenter-qa delete -k overlays/qa/datadog` e
`kubectl --context kind-autocenter-qa -n autocenter delete secret datadog-secret`.

## Remover
`kind delete cluster --name autocenter` (apenas este; nao afeta outros clusters).
