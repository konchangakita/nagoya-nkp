# Dify Community Edition on Kubernetes

Dify Community Edition を Kubernetes (Nutanix Kubernetes Platform) 上にデプロイするための Helm Chart です。

## 重要な注意事項

### データベースマイグレーション

**Migration は専用の Job で実行されます。**

- **`upgrade_db()` 関数は使用しません**
  - `upgrade_db()` は exit code を返さず危険です
  - Redis ロック取得失敗時に migration を skip し、exit code 0 で終了します
  - 例外発生時も例外を握りつぶし、exit code 0 で終了します
  - そのため、migration が失敗しても Kubernetes 的には成功として扱われます

- **実装方法**
  - Helm hook (post-install, post-upgrade) で Job を実行
  - `flask db upgrade` を直接実行（Redis ロックに依存しない）
  - 失敗時は Job が失敗として記録される（Kubernetes 的に検出可能）
  - `ttlSecondsAfterFinished: 86400` で競合防止

- **MIGRATION_ENABLED について**
  - `MIGRATION_ENABLED=false` に設定されています（Job で migration を実行するため）
  - API コンテナ起動時の自動 migration は無効化されています

### Secret 自動生成

**Secret は自動生成されます（lookup で既存値を優先）**

- Dify Secrets (`dify-secrets`): DIFY_SECRET_KEY, PLUGIN_DAEMON_KEY, DIFY_INNER_API_KEY
- PostgreSQL Secrets (`dify-postgresql`): postgres-username, postgres-password, postgres-database
- Redis Secrets (`dify-redis`): password

**重要**: PostgreSQL/Redis のパスワードは PVC が残る限り同じ値が必要です。upgrade 時は既存 Secret を lookup で維持します。

## インストール

### 前提条件

- Kubernetes クラスタ（Nutanix Kubernetes Platform）
- Helm 3.x
- Traefik Ingress Controller（dify namespace内の dify-traefik）
- Nutanix CSI（ストレージ用）

### デプロイ

```bash
# Namespace を作成（存在しない場合）
kubectl create namespace dify

# Helm Chart をデプロイ（デフォルト値を使用、最小限の指定のみ）
helm upgrade --install dify ./dify -n dify --create-namespace

# OpenAI APIを使用する場合のみ追加
# helm upgrade --install dify ./dify -n dify --create-namespace \
#   --set secrets.openaiApiKey=sk-xxx

# イメージタグを変更する場合（web/api/workerは一括指定可能）
# helm upgrade --install dify ./dify -n dify --create-namespace \
#   --set images.tag=1.12.0 \
#   --set images.pluginDaemon.tag=0.6.0

# 個別にバージョンを指定する場合（通常は不要）
# helm upgrade --install dify ./dify -n dify --create-namespace \
#   --set images.web.tag=1.12.0 \
#   --set images.api.tag=1.12.0 \
#   --set images.worker.tag=1.12.0 \
#   --set images.pluginDaemon.tag=0.6.0

# Ingress Class名を変更する場合（通常は不要、デフォルト: dify-traefik）
# helm upgrade --install dify ./dify -n dify --create-namespace \
#   --set expose.ingressClassName=kommander-traefik
```

**重要**: `external.host` の指定は不要です。相対パスまたはHostヘッダー由来で動作します。

### 主要パラメータ（通常はデフォルト値でOK）

- `expose.ingressClassName`: Ingress Class 名（デフォルト: `dify-traefik`、通常は変更不要）
- `images.tag`: 共通イメージタグ（web/api/worker用、デフォルト: `1.11.4`）
  - web/api/workerは通常同じバージョンを使用するため、このパラメータで一括指定可能
  - 個別指定も可能（`images.web.tag`, `images.api.tag`, `images.worker.tag`）
- `images.pluginDaemon.tag`: Plugin Daemon イメージタグ（デフォルト: `0.5.3-local`）
- `secrets.openaiApiKey`: OpenAI API Key（オプション、OpenAIを使用する場合のみ）
- `external.host`: 外部URLのホスト名（オプション、未指定でOK）
  - 未指定の場合は相対パスで動作（Ingress経由でアクセス可能なURLは自動判定）
  - 固定IP依存を避けるため、通常は指定不要
- `external.scheme`: 外部URLのスキーム（デフォルト: `https`、オプション）
- `images.web.tag`: Dify Web イメージタグ（必須）
- `images.api.tag`: Dify API イメージタグ（必須）
- `images.worker.tag`: Dify Worker イメージタグ（必須）
- `images.pluginDaemon.tag`: Plugin Daemon イメージタグ（必須）
- `secrets.openaiApiKey`: OpenAI API Key（オプション）
- `storage.storageClassName`: Storage Class 名（デフォルト: `nutanix-volume`）
- `postgresql.persistence.size`: PostgreSQL PVC サイズ（デフォルト: `20Gi`）
- `redis.persistence.size`: Redis PVC サイズ（デフォルト: `8Gi`）
- `weaviate.persistence.size`: Weaviate PVC サイズ（デフォルト: `50Gi`）
- `dify.fileStorage.size`: File Storage PVC サイズ（デフォルト: `20Gi`）

詳細は `values.yaml` を参照してください。

## アンインストール

```bash
# Helm release を削除
helm uninstall dify -n dify

# Namespace を削除（すべてのリソースを含む）
kubectl delete namespace dify

# 完全削除（PVC も含む）
helm uninstall dify -n dify
kubectl delete pvc --all -n dify
kubectl delete namespace dify
```

## 動作確認

### 外部アクセス確認

```bash
# LoadBalancer の IP を確認（helm install では使わない、確認のみ）
kubectl get svc -n dify dify-traefik -o wide

# LB IP を取得
LB=$(kubectl -n dify get svc dify-traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

# アクセステスト
curl -k -sS -o /dev/null -w "/:%{http_code}\n" https://$LB/
curl -k -sS -o /dev/null -w "/apps:%{http_code}\n" https://$LB/apps
curl -k -sS -o /dev/null -w "/plugins:%{http_code}\n" https://$LB/plugins
curl -k -sS -o /dev/null -w "/console:%{http_code}\n" https://$LB/console
curl -k -sS -o /dev/null -w "/api:%{http_code}\n" https://$LB/api
curl -k -sS -o /dev/null -w "/plugin/health/check:%{http_code}\n" https://$LB/plugin/health/check
```

**期待結果**:
- `/`, `/apps`, `/plugins`: 200（Next.js）
- `/console`: 200 or 307（実装により遷移OK）
- `/plugin/health/check`: 200（plugin-daemon）

### 内部疎通確認

```bash
# Plugin Daemon のヘルスチェック
kubectl exec -n dify $(kubectl get pods -n dify -l app=dify-plugin-daemon -o jsonpath='{.items[0].metadata.name}') -- curl -s http://localhost:5002/health/check

# API から Plugin Daemon への接続確認
kubectl exec -n dify $(kubectl get pods -n dify -l app=dify-api -o jsonpath='{.items[0].metadata.name}') -- curl -s http://dify-plugin-daemon:5002/health/check
```

## 確認コマンド

```bash
# Pod の状態確認
kubectl get pods -n dify

# Deployment/Service の状態確認
kubectl get deploy,svc -n dify

# Migration Job の状態確認
kubectl get jobs -n dify

# Migration Job のログ確認
kubectl logs -n dify job/dify-db-migration

# データベースのテーブル確認
kubectl exec -n dify dify-postgresql-0 -- psql -U dify -d dify -c "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;"

# Plugin Daemon のログ確認
kubectl logs -n dify -l app=dify-plugin-daemon

# Ingress の状態確認
kubectl get ingress -n dify
kubectl describe ingress -n dify dify
```

## トラブルシューティング

### Migration Job が失敗する場合

1. Job のログを確認
   ```bash
   kubectl logs -n dify job/dify-db-migration
   ```

2. Job を再実行
   ```bash
   kubectl delete job -n dify dify-db-migration
   helm upgrade dify ./dify -n dify --reuse-values
   ```

### データベース接続エラー

- PostgreSQL Pod が起動しているか確認
  ```bash
  kubectl get pods -n dify -l app=dify-postgresql
  kubectl logs -n dify -l app=dify-postgresql
  ```

- PostgreSQL の接続確認
  ```bash
  kubectl exec -n dify dify-postgresql-0 -- pg_isready -U dify -d dify
  ```

- ネットワークポリシーを確認

### Plugin Daemon 関連エラー

- Plugin Daemon Pod が起動しているか確認
  ```bash
  kubectl get pods -n dify -l app=dify-plugin-daemon
  ```

- Plugin Daemon のログを確認
  ```bash
  kubectl logs -n dify -l app=dify-plugin-daemon
  ```

- Plugin Daemon のヘルスチェックを確認
  ```bash
  kubectl exec -n dify $(kubectl get pods -n dify -l app=dify-plugin-daemon -o jsonpath='{.items[0].metadata.name}') -- curl -s http://localhost:5002/health/check
  ```

- Ingress で /plugin パスが正しくルーティングされているか確認
  ```bash
  kubectl describe ingress -n dify dify | grep -A 10 "/plugin"
  ```

**重要: Plugin Daemon は Redis が必須です**

- Plugin Daemon は Redis に接続する必要があります
- Redis Service 名: `dify-redis`（デフォルト）
- Redis パスワードは Secret (`dify-redis`) から自動的に読み込まれます

### ImagePullBackOff エラー

Docker Hub のレート制限が原因の可能性があります。

- 一時的な回避策: しばらく待ってから再試行
- 根本的な解決策: プライベートレジストリを使用、または Docker Hub の認証情報を使用

## アーキテクチャ

### コンポーネント

- **dify-web**: Web UI（Next.js）
- **dify-api**: API サーバー（Flask）
- **dify-worker**: バックグラウンドワーカー（Celery）
- **dify-plugin-daemon**: Plugin Daemon（内部アクセスのみ）
- **dify-postgresql**: PostgreSQL データベース（StatefulSet）
- **dify-redis**: Redis キャッシュ（Deployment）
- **dify-weaviate**: Weaviate ベクトルストア（Deployment）

### ネットワーク

- **Ingress**: Traefik（dify-traefik、dify namespace内）を使用
- **Service**: すべて ClusterIP（内部アクセスのみ）
- **Plugin Daemon**: 外部アクセス不要、内部 URL (`http://dify-plugin-daemon:5002`) で完結
- **外部URL**: `external.host` 指定不要、相対パスまたはHostヘッダー由来で動作

### ストレージ

- **PostgreSQL**: RWO（ReadWriteOnce）、nutanix-volume
- **Redis**: RWO、nutanix-volume
- **Weaviate**: RWO、nutanix-volume
- **File Storage**: RWO、nutanix-volume

## 参考資料

- [MIGRATION_ROOT_CAUSE.md](./MIGRATION_ROOT_CAUSE.md) - マイグレーション問題の根本原因分析
