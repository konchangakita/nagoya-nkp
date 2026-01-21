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

# Migration Job の状態確認
kubectl get jobs -n dify

# Migration Job のログ確認
kubectl logs -n dify job/dify-db-migration

# データベースのテーブル確認
kubectl exec -n dify dify-postgresql-0 -- psql -U dify -d dify -c "SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename;"
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

## 参考資料

- [MIGRATION_ROOT_CAUSE.md](./MIGRATION_ROOT_CAUSE.md) - マイグレーション問題の根本原因分析
- [MIGRATION_ANALYSIS.md](./MIGRATION_ANALYSIS.md) - マイグレーション問題の詳細分析
