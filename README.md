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

## Topicos (todos com 3 particoes, replicacao 1)
`os.eventos`, `billing.comandos`, `execucao.comandos`, `billing.eventos`,
`execucao.eventos`, `billing.eventos.dlt`, `execucao.eventos.dlt`.

`auto.create.topics.enable=false` (decisao explicita): topicos e DLTs sao criados
so pelo Job `kafka-topicos` (`--if-not-exists`, reexecutavel). Publicar em topico
inexistente falha em vez de criar um topico errado. Para um topico novo, inclua-o
no Job e reaplique (`kubectl delete job kafka-topicos -n autocenter` antes, pois
o spec do Job e imutavel).

## Como conectar
**Servico dentro do cluster (namespace `autocenter`):**
`SPRING_KAFKA_BOOTSTRAP_SERVERS=kafka:9092` (de outro namespace:
`kafka.autocenter.svc.cluster.local:9092`). Nos Deployments do servico use
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

## Datadog (opcional, fora do apply padrao)
`k8s/datadog.yaml` nao entra no `k8s/kustomization.yaml`: sem o Secret o pod
ficaria travado. Para usar:
```bash
kubectl --context kind-autocenter -n autocenter create secret generic datadog-secret \
  --from-literal=api-key='<SUA_DD_API_KEY>'
kubectl --context kind-autocenter apply -f k8s/datadog.yaml
```
Nunca versione a chave. Baseado em `autocenter/terraform/datadog.tf` (agent 7.83.1),
adaptado ao containerd do kind (socket `/run/containerd/containerd.sock`).
Validado apenas que o pod sobe e detecta containerd/kubelet; a **entrega real ao
Datadog nao foi validada** (ainda nao ha chave real; com chave falsa o agent
recebe 403).

## Remover
`kind delete cluster --name autocenter` (apenas este; nao afeta outros clusters).
