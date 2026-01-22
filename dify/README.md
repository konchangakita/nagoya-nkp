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

## インストール

### 前提条件

- Kubernetes クラスタ（Nutanix Kubernetes Platform）
- Helm 3.x
- MetalLB（LoadBalancer 用）
- Nutanix CSI（ストレージ用）

### デプロイ

```bash
export KUBECONFIG=/home/ubuntu/nkp/kube.conf
export DIFY_SECRET_KEY=$(openssl rand -hex 32)
./deploy.sh --image-tag 1.11.4 --openai-api-key sk-xxx
```

### パラメータ

主要なパラメータは `deploy.sh` で設定されます。詳細は `values.yaml` を参照してください。

## アンインストール

```bash
export KUBECONFIG=/home/ubuntu/nkp/kube.conf
helm uninstall dify -n dify
kubectl delete namespace dify
```

## 確認コマンド

```bash
# Pod の状態確認
kubectl get pods -n dify

# Deployment/Service の状態確認（plugin-daemon を含む）
kubectl get deploy,po,svc -n dify | grep -iE "plugin|daemon|dify"

# Migration Job の状態確認
kubectl get jobs -n dify

# Migration Job のログ確認
kubectl logs -n dify job/dify-db-migration

# データベースのテーブル確認
kubectl exec -n dify dify-postgresql-0 -- psql -U dify -d dify -c "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;"

# Plugin Daemon のログ確認
kubectl logs -n dify -l app=dify-plugin-daemon

# Plugin Daemon のヘルスチェック確認
kubectl exec -n dify $(kubectl get pods -n dify -l app=dify-plugin-daemon -o jsonpath='{.items[0].metadata.name}') -- curl -s http://localhost:5002/health
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
   helm upgrade dify . -n dify --reuse-values
   ```

### データベース接続エラー

- PostgreSQL Pod が起動しているか確認
- パスワードが正しいか確認
- ネットワークポリシーを確認

**重要: PostgreSQL パスワードの固定化について**

### パスワード固定化の理由

PostgreSQL のパスワードは **固定化** されています。これは以下の理由からです：

1. **PVC の永続化**: PostgreSQL は初回起動時に PVC にパスワードを保存します
2. **再現性の担保**: 同じパスワードを使用することで、再デプロイ時も認証が成功します
3. **Secret との整合性**: `dify-postgresql` Secret と PostgreSQL の実パスワードが常に一致します

### パスワードの設定方法

`deploy.sh` 実行時に `POSTGRES_PASSWORD` 環境変数を設定してください：

```bash
export POSTGRES_PASSWORD='your-fixed-password'
./deploy.sh --image-tag 1.11.4
```

**注意**: `POSTGRES_PASSWORD` が未設定の場合、`deploy.sh` はエラーで終了します（ランダム生成は行いません）。

### パスワードの参照元

- **PostgreSQL Secret**: `dify-postgresql` (namespace: `dify`)
  - キー名: `postgres-password` (または `password` で互換性あり)
  - 生成元: `values.yaml` の `postgresql.auth.password`
- **dify-api / plugin-daemon**: `DB_PASSWORD` 環境変数は `dify-postgresql` Secret から `secretKeyRef` で読み込まれます

### パスワード変更時の注意事項

**PVC が残っている場合、PostgreSQL のパスワード変更は反映されません**

- PostgreSQL は初回起動時に PVC にパスワードを保存します
- PVC が存在する場合、`POSTGRES_PASSWORD` 環境変数の変更は無視されます
- パスワードを変更する場合は、**必ず PVC を削除してから**再デプロイしてください

```bash
# 注意: データが失われます
kubectl delete pvc -n dify data-dify-postgresql-0
export POSTGRES_PASSWORD='new-password'
./deploy.sh --image-tag 1.11.4
```

### 運用ルール

1. **`postgresql.auth.password` は固定にすること**
   - ランダム生成は禁止
   - 環境変数 `POSTGRES_PASSWORD` で指定

2. **Secret 名/キー名**
   - Secret 名: `dify-postgresql` (デフォルト、`values.yaml` で変更可能)
   - キー名:
     - `postgres-password`: パスワード（推奨）
     - `postgres-username`: ユーザー名
     - `postgres-database`: データベース名
     - `password`: 互換性のためのキー（`postgres-password` と同じ値）

3. **再デプロイ時の動作**
   - `deploy.sh` は PVC の存在をチェックし、警告を表示します
   - パスワードが一致しない場合は認証エラーが発生します
   - パスワードを変更する場合は、明示的に PVC を削除してください

### Plugin Daemon の DB 接続エラー (28P01) を解消する場合

PostgreSQL のパスワード認証エラーが発生した場合、以下の手順で復帰確認を行います:

1. Helm upgrade で Secret を再生成
   ```bash
   export KUBECONFIG=/home/ubuntu/nkp/kube.conf
   export DIFY_SECRET_KEY=$(openssl rand -hex 32)
   helm upgrade dify . -n dify --set secrets.difySecretKey="${DIFY_SECRET_KEY}" --reuse-values
   ```

2. plugin-daemon を再起動
   ```bash
   kubectl rollout restart deploy/dify-plugin-daemon -n dify
   ```

3. plugin-daemon の状態を確認
   ```bash
   kubectl get pods -n dify -l app=dify-plugin-daemon
   kubectl logs -n dify -l app=dify-plugin-daemon --tail=50
   ```

4. dify-api から plugin-daemon への接続確認
   ```bash
   kubectl exec -n dify $(kubectl get pods -n dify -l app=dify-api -o jsonpath='{.items[0].metadata.name}') -- curl -sv http://dify-plugin-daemon:5002/health
   ```

5. plugin-daemon の /management/models エンドポイント確認
   ```bash
   kubectl exec -n dify $(kubectl get pods -n dify -l app=dify-api -o jsonpath='{.items[0].metadata.name}') -- curl -sv http://dify-plugin-daemon:5002/management/models
   ```

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
  kubectl exec -n dify $(kubectl get pods -n dify -l app=dify-plugin-daemon -o jsonpath='{.items[0].metadata.name}') -- curl -s http://localhost:5002/health
  ```

- Ingress で /plugin パスが正しくルーティングされているか確認
  ```bash
  kubectl describe ingress -n dify dify | grep -A 10 "/plugin"
  ```

- ブラウザ DevTools で以下を確認
  - `/console/api/workspaces/current/models/model-types/llm` が 200 になること
  - `/plugin/*` 経由のリクエストが 4xx にならないこと
  - "Failed to request plugin daemon" エラーが消えること

**重要: Plugin Daemon は Redis が必須です**

- Plugin Daemon は Redis に接続する必要があります
- 必要な環境変数:
  - `REDIS_HOST`: Redis Service 名（デフォルト: `dify-redis-master`）
  - `REDIS_PORT`: Redis ポート（デフォルト: `6379`）
  - `REDIS_PASSWORD`: Redis パスワード（認証が有効な場合のみ）
- Redis Service 名とポートは `values.yaml` の `pluginDaemon.redis` セクションで設定可能
- Redis 認証が有効な場合は `pluginDaemon.redis.authEnabled=true` を設定し、Secret を指定

## 参考資料

- [MIGRATION_ROOT_CAUSE.md](./MIGRATION_ROOT_CAUSE.md) - マイグレーション問題の根本原因分析
- [MIGRATION_ANALYSIS.md](./MIGRATION_ANALYSIS.md) - マイグレーション問題の詳細分析
