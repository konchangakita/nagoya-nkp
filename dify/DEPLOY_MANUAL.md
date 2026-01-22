# Dify Helm Chart 手動デプロイガイド

## 前提条件

- Kubernetes クラスタ（Nutanix Kubernetes Platform）
- Helm 3.x
- `KUBECONFIG` 環境変数が設定されていること

## デプロイ手順

### 1. 環境変数の設定

```bash
export KUBECONFIG=/home/ubuntu/nkp/kube.conf
export POSTGRES_PASSWORD='your-fixed-password'  # 必須: 固定パスワードを設定
export POSTGRES_USERNAME="${POSTGRES_USERNAME:-dify}"
export POSTGRES_DATABASE="${POSTGRES_DATABASE:-dify}"
export REDIS_PASSWORD="${REDIS_PASSWORD:-}"  # オプション
export IMAGE_TAG="1.11.4"  # Dify のバージョン
export OPENAI_API_KEY="${OPENAI_API_KEY:-}"  # オプション
```

### 2. Namespace の作成

```bash
kubectl create namespace dify
```

### 3. Helm dependencies のビルド

```bash
cd /home/ubuntu/nkp/konchangakita/nagoya-nkp/dify
helm dependency build .
```

### 4. ステップ1: Traefik をインストール（LB IP を取得するため）

```bash
helm upgrade --install dify . -n dify \
  --skip-crds \
  --set traefik.enabled=true \
  --set traefik.service.type=LoadBalancer \
  --set traefik.ingressClass.enabled=true \
  --set traefik.ingressClass.name=dify-traefik \
  --set traefik.ingressClass.isDefaultClass=false \
  --set traefik.dashboard.enabled=false \
  --set traefik.gateway.enabled=false \
  --set traefik.gatewayClass.enabled=false \
  --set expose.traefik.enabled=true \
  --set expose.ingressClassName=dify-traefik \
  --set expose.path=/ \
  --set external.scheme=https \
  --set external.host=placeholder \
  --set secrets.openaiApiKey="${OPENAI_API_KEY}" \
  --set images.web.repository=langgenius/dify-web \
  --set images.web.tag="${IMAGE_TAG}" \
  --set images.api.repository=langgenius/dify-api \
  --set images.api.tag="${IMAGE_TAG}" \
  --set images.worker.repository=langgenius/dify-api \
  --set images.worker.tag="${IMAGE_TAG}" \
  --set images.pluginDaemon.repository=langgenius/dify-plugin-daemon \
  --set images.pluginDaemon.tag="${IMAGE_TAG}" \
  --set dify.marketplace.enabled=true \
  --set dify.marketplace.apiUrl=https://marketplace.dify.ai \
  --set storage.storageClassName=nutanix-volume \
  --set postgresql.auth.username="${POSTGRES_USERNAME}" \
  --set postgresql.auth.password="${POSTGRES_PASSWORD}" \
  --set postgresql.auth.database="${POSTGRES_DATABASE}" \
  --set postgresql.persistence.size=20Gi \
  --set postgresql.image.tag=16 \
  --set redis.auth.password="${REDIS_PASSWORD}" \
  --set redis.persistence.size=8Gi \
  --set redis.image.tag=7.2 \
  --set weaviate.service.type=ClusterIP \
  --set weaviate.grpcService.type=ClusterIP \
  --set weaviate.persistence.size=50Gi \
  --set weaviate.persistence.storageClass=nutanix-volume \
  --set dify.fileStorage.size=20Gi \
  --wait --timeout=10m
```

### 5. Traefik LoadBalancer IP を取得

```bash
echo "Traefik LoadBalancer IP を取得中..."
EXTERNAL_HOST=$(kubectl get svc dify-traefik -n dify -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
while [[ -z "${EXTERNAL_HOST}" ]]; do
  echo "  Waiting for LoadBalancer IP..."
  sleep 5
  EXTERNAL_HOST=$(kubectl get svc dify-traefik -n dify -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
done
echo "  LoadBalancer IP: ${EXTERNAL_HOST}"
```

### 6. ステップ2: Dify を正しい external.host でアップグレード

```bash
helm upgrade dify . -n dify \
  --skip-crds \
  --set traefik.enabled=true \
  --set traefik.service.type=LoadBalancer \
  --set traefik.ingressClass.enabled=true \
  --set traefik.ingressClass.name=dify-traefik \
  --set traefik.ingressClass.isDefaultClass=false \
  --set traefik.dashboard.enabled=false \
  --set traefik.gateway.enabled=false \
  --set traefik.gatewayClass.enabled=false \
  --set expose.traefik.enabled=true \
  --set expose.ingressClassName=dify-traefik \
  --set expose.path=/ \
  --set external.scheme=https \
  --set external.host="${EXTERNAL_HOST}" \
  --set secrets.openaiApiKey="${OPENAI_API_KEY}" \
  --set images.web.repository=langgenius/dify-web \
  --set images.web.tag="${IMAGE_TAG}" \
  --set images.api.repository=langgenius/dify-api \
  --set images.api.tag="${IMAGE_TAG}" \
  --set images.worker.repository=langgenius/dify-api \
  --set images.worker.tag="${IMAGE_TAG}" \
  --set images.pluginDaemon.repository=langgenius/dify-plugin-daemon \
  --set images.pluginDaemon.tag="${IMAGE_TAG}" \
  --set dify.marketplace.enabled=true \
  --set dify.marketplace.apiUrl=https://marketplace.dify.ai \
  --set storage.storageClassName=nutanix-volume \
  --set postgresql.auth.username="${POSTGRES_USERNAME}" \
  --set postgresql.auth.password="${POSTGRES_PASSWORD}" \
  --set postgresql.auth.database="${POSTGRES_DATABASE}" \
  --set postgresql.persistence.size=20Gi \
  --set postgresql.image.tag=16 \
  --set redis.auth.password="${REDIS_PASSWORD}" \
  --set redis.persistence.size=8Gi \
  --set redis.image.tag=7.2 \
  --set weaviate.service.type=ClusterIP \
  --set weaviate.grpcService.type=ClusterIP \
  --set weaviate.persistence.size=50Gi \
  --set weaviate.persistence.storageClass=nutanix-volume \
  --set dify.fileStorage.size=20Gi
```

## 確認コマンド

```bash
# Pod の状態確認
kubectl get pods -n dify

# Service の状態確認
kubectl get svc -n dify

# LoadBalancer IP の確認
kubectl get svc dify-traefik -n dify

# Migration Job の確認
kubectl get jobs -n dify

# Migration Job のログ確認
kubectl logs -n dify job/dify-db-migration
```

## アンインストール

```bash
helm uninstall dify -n dify
kubectl delete namespace dify
```

## 注意事項

- `POSTGRES_PASSWORD` は**固定パスワード**である必要があります
- PVC が残っている場合、PostgreSQL のパスワード変更は反映されません
- パスワードを変更する場合は、必ず PVC を削除してから再デプロイしてください
