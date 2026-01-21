# Dify DB マイグレーション問題：根本原因の断定と解決策

## ① 事実確認（仮説を排除する）

### 1. flask upgrade-db の exit code を確定させる

#### エントリーポイントスクリプトの実装確認

```bash
# /entrypoint.sh の該当部分
if [[ "${MIGRATION_ENABLED}" == "true" ]]; then
  echo "Running migrations"
  flask upgrade-db
  # Pure migration mode
  if [[ "${MODE}" == "migration" ]]; then
    echo "Migration completed, exiting normally"
    exit 0
  fi
fi
```

**問題点**：
- `flask upgrade-db` の exit code をチェックしていない
- `flask upgrade-db` が失敗しても、`exit 0` で終了する
- `MODE=migration` の場合、常に `exit 0` で終了する

#### upgrade_db() 関数の実装確認

```python
def upgrade_db():
    click.echo("Preparing database migration...")
    lock = redis_client.lock(name="db_upgrade_lock", timeout=60)
    if lock.acquire(blocking=False):
        try:
            click.echo(click.style("Starting database migration.", fg="green"))
            import flask_migrate
            flask_migrate.upgrade()
            click.echo(click.style("Database migration successful!", fg="green"))
        except Exception:
            logger.exception("Failed to execute database migration")
        finally:
            lock.release()
    else:
        click.echo("Database migration skipped")
```

**問題点**：
- Redis ロック取得失敗時：`"Database migration skipped"` と表示されるが、**例外は発生しない**（exit code 0）
- `flask_migrate.upgrade()` の例外発生時：`except Exception:` でキャッチされ、**例外は再発生しない**（exit code 0）
- **すべての経路で exit code は 0 になる**

### 2. upgrade_db() の実行経路を整理

#### 実行経路の分岐条件

| 条件 | 挙動 | exit code | テーブル作成 |
|------|------|-----------|--------------|
| Redis 接続失敗（`redis_client.lock()` で例外） | 例外が発生し、`upgrade_db()` が例外を発生させる可能性 | 非0（可能性） | ❌ |
| Redis ロック取得失敗（`lock.acquire(blocking=False)` が False） | `"Database migration skipped"` と表示、例外なし | **0** | ❌ |
| `flask_migrate.upgrade()` で例外発生 | `except Exception:` でキャッチ、例外再発生なし | **0** | ❌ |
| 正常実行 | `"Database migration successful!"` と表示 | **0** | ✅ |

#### 「migration が実行されないのに成功扱いになる経路」

**経路1：Redis ロック取得失敗**
```python
if lock.acquire(blocking=False):  # False を返す
    # このブロックは実行されない
else:
    click.echo("Database migration skipped")  # これだけ実行される
    # 例外は発生しない → exit code 0
```

**経路2：flask_migrate.upgrade() で例外発生**
```python
try:
    flask_migrate.upgrade()  # 例外発生
except Exception:
    logger.exception("Failed to execute database migration")  # ログのみ
    # 例外は再発生しない → exit code 0
```

**経路3：Redis 接続失敗（redis_client.lock() で例外）**
```python
lock = redis_client.lock(name="db_upgrade_lock", timeout=60)  # 例外発生
# この時点で例外が発生する可能性があるが、
# Click コマンドの例外処理により exit code が 0 になる可能性
```

## ② 現状実装の問題点を断定

### 問題点1：Redis ロック取得失敗時に migration が skip される設計

**断定**：`upgrade_db()` 関数は、Redis ロック取得を前提とした設計である。

- `lock.acquire(blocking=False)` が `False` を返した場合、マイグレーションは実行されない
- 例外は発生せず、`"Database migration skipped"` と表示されるだけ
- exit code は 0 のまま

### 問題点2：例外が except Exception で握りつぶされ、exit code が 0 になる設計

**断定**：`upgrade_db()` 関数内で発生した例外は、すべて `except Exception:` でキャッチされ、再発生しない。

- `flask_migrate.upgrade()` で例外が発生しても、`logger.exception()` でログが記録されるだけ
- 例外は再発生しないため、exit code は 0 のまま
- エントリーポイントスクリプトは exit code をチェックしていないため、失敗を検出できない

### 問題点3：entrypoint が migration の成否を見ずに exit 0 している

**断定**：エントリーポイントスクリプトは、`flask upgrade-db` の exit code をチェックせず、常に `exit 0` で終了する。

- `MODE=migration` の場合、`flask upgrade-db` の成否に関わらず `exit 0` で終了する
- `flask upgrade-db` が失敗しても、Kubernetes 的には成功として扱われる

### 「なぜ Kubernetes 的には成功に見えるのか」

**断定**：以下の3つの要因により、マイグレーションが失敗しても Kubernetes 的には成功として扱われる。

1. **`upgrade_db()` 関数の設計**：Redis ロック取得失敗時や例外発生時でも、例外を発生させない（exit code 0）
2. **エントリーポイントスクリプトの設計**：`flask upgrade-db` の exit code をチェックせず、常に `exit 0` で終了する
3. **Kubernetes の initContainer の挙動**：initContainer の exit code が 0 の場合、Pod は正常起動として扱われる

## ③ upgrade_db() に依存しない「確実な実装」

### コンテナ内で使用可能な migration コマンド

| コマンド | 説明 | Redis 依存 | 推奨 |
|----------|------|------------|------|
| `flask upgrade-db` | `upgrade_db()` 関数を呼び出す（Redis ロック依存） | ✅ | ❌ |
| `flask db upgrade` | `flask_migrate.upgrade()` を直接実行 | ❌ | ✅ |
| `python -m flask db upgrade` | `flask db upgrade` と同等 | ❌ | ✅ |

**推奨**：`flask db upgrade` または `python -m flask db upgrade` を使用する。

### 実装要件

1. **Redis ロックやアプリ内部条件に依存しない**
   - `flask db upgrade` を直接実行する
2. **migration 成否が exit code で明確**
   - `set -euo pipefail` を使用する
   - 失敗時は exit code が非0になる
3. **Kubernetes / Helm で再現性が高い**
   - 環境変数の設定を明確にする
   - ログ出力を充実させる
4. **実行前後でログを出す**
   - 各ステップでログを出力する
5. **migration 後に DB検証を行う**
   - `alembic_version` テーブルの存在確認
   - 可能なら主要テーブル1つも確認

## ④ 正解構成（2案）

### A. 推奨：Migration 専用 Job（安定運用）

```yaml
# templates/db-migration-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: dify-db-migration
  namespace: {{ .Release.Namespace }}
  labels:
    app: dify
    component: db-migration
  annotations:
    "helm.sh/hook": post-install,post-upgrade
    "helm.sh/hook-weight": "-5"
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  backoffLimit: 3
  template:
    metadata:
      labels:
        app: dify
        component: db-migration
    spec:
      restartPolicy: OnFailure
      containers:
        - name: migrate
          image: "{{ required "images.api.repository is required" .Values.images.api.repository }}:{{ required "images.api.tag is required" .Values.images.api.tag }}"
          imagePullPolicy: IfNotPresent
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -euo pipefail
              echo "=== [$(date +%Y-%m-%d\ %H:%M:%S)] Starting database migration (Job) ==="
              echo "DB_HOST=${DB_HOST}"
              echo "DB_PORT=${DB_PORT}"
              echo "DB_USERNAME=${DB_USERNAME}"
              echo "DB_DATABASE=${DB_DATABASE}"
              echo "DB_PASSWORD length: ${#DB_PASSWORD}"
              
              cd /app/api
              export FLASK_APP=app.py
              
              echo "=== [$(date +%Y-%m-%d\ %H:%M:%S)] Running flask db upgrade (direct, bypassing upgrade_db) ==="
              python -m flask db upgrade
              FLASK_EXIT_CODE=$?
              
              if [ $FLASK_EXIT_CODE -ne 0 ]; then
                echo "❌ [$(date +%Y-%m-%d\ %H:%M:%S)] flask db upgrade failed with exit code $FLASK_EXIT_CODE"
                exit $FLASK_EXIT_CODE
              fi
              
              echo "=== [$(date +%Y-%m-%d\ %H:%M:%S)] Verifying migration ==="
              python -c "
              import os
              import sys
              import psycopg2
              
              try:
                  conn = psycopg2.connect(
                      host=os.getenv('DB_HOST'),
                      port=os.getenv('DB_PORT'),
                      user=os.getenv('DB_USERNAME'),
                      password=os.getenv('DB_PASSWORD'),
                      database=os.getenv('DB_DATABASE')
                  )
                  cur = conn.cursor()
                  
                  # Check alembic_version table
                  cur.execute(\"SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename = 'alembic_version';\")
                  result = cur.fetchone()
                  if not result:
                      print('❌ Migration failed: alembic_version table not found')
                      sys.exit(1)
                  
                  print('✅ Migration verified: alembic_version table exists')
                  
                  # Check migration version
                  cur.execute(\"SELECT version_num FROM alembic_version;\")
                  version = cur.fetchone()
                  if version:
                      print(f'✅ Current migration version: {version[0]}')
                  
                  # Check total tables
                  cur.execute(\"SELECT COUNT(*) FROM pg_tables WHERE schemaname = 'public';\")
                  table_count = cur.fetchone()[0]
                  print(f'✅ Total tables created: {table_count}')
                  
                  # Check a major table (e.g., accounts)
                  cur.execute(\"SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename = 'accounts';\")
                  accounts_table = cur.fetchone()
                  if accounts_table:
                      print('✅ Major table verified: accounts table exists')
                  else:
                      print('⚠️  Warning: accounts table not found (may be normal if migration is incomplete)')
                  
                  cur.close()
                  conn.close()
                  
              except Exception as e:
                  print(f'❌ Verification failed: {e}')
                  import traceback
                  traceback.print_exc()
                  sys.exit(1)
              "
              VERIFY_EXIT_CODE=$?
              
              if [ $VERIFY_EXIT_CODE -ne 0 ]; then
                echo "❌ [$(date +%Y-%m-%d\ %H:%M:%S)] Migration verification failed with exit code $VERIFY_EXIT_CODE"
                exit $VERIFY_EXIT_CODE
              fi
              
              echo "✅ [$(date +%Y-%m-%d\ %H:%M:%S)] Database migration completed successfully! ==="
          env:
            - name: DB_HOST
              value: "dify-postgresql"
            - name: DB_PORT
              value: "5432"
            - name: DB_USERNAME
              value: "{{ required "postgresql.auth.username is required" .Values.postgresql.auth.username }}"
            - name: DB_PASSWORD
              value: "{{ required "postgresql.auth.password is required" .Values.postgresql.auth.password }}"
            - name: DB_DATABASE
              value: "{{ required "postgresql.auth.database is required" .Values.postgresql.auth.database }}"
            - name: STORAGE_TYPE
              value: "opendal"
            - name: OPENDAL_SCHEME
              value: "fs"
            - name: OPENDAL_FS_ROOT
              value: "/tmp"
```

**メリット**：
- Helm install/upgrade 時に一度だけ実行される
- 本体コンテナとは独立
- 失敗時の再試行が可能（`backoffLimit: 3`）
- 実行履歴が残る（Job として記録される）
- 失敗時は Job が失敗として記録される

**デメリット**：
- Helm hook の管理が必要
- Job の削除タイミングを考慮する必要がある

### B. 簡易：initContainer 直実行

```yaml
# templates/dify-api.yaml の initContainers セクション
initContainers:
  - name: db-migration
    image: "{{ required "images.api.repository is required" .Values.images.api.repository }}:{{ required "images.api.tag is required" .Values.images.api.tag }}"
    imagePullPolicy: IfNotPresent
    env:
      - name: DB_HOST
        value: "dify-postgresql"
      - name: DB_PORT
        value: "5432"
      - name: DB_USERNAME
        value: "{{ required "postgresql.auth.username is required" .Values.postgresql.auth.username }}"
      - name: DB_PASSWORD
        value: "{{ required "postgresql.auth.password is required" .Values.postgresql.auth.password }}"
      - name: DB_DATABASE
        value: "{{ required "postgresql.auth.database is required" .Values.postgresql.auth.database }}"
      - name: STORAGE_TYPE
        value: "opendal"
      - name: OPENDAL_SCHEME
        value: "fs"
      - name: OPENDAL_FS_ROOT
        value: "/tmp"
    command: ["/bin/bash", "-c"]
    args:
      - |
        set -euo pipefail
        echo "=== [$(date +%Y-%m-%d\ %H:%M:%S)] Starting database migration (initContainer) ==="
        echo "DB_HOST=${DB_HOST}"
        echo "DB_PORT=${DB_PORT}"
        echo "DB_USERNAME=${DB_USERNAME}"
        echo "DB_DATABASE=${DB_DATABASE}"
        echo "DB_PASSWORD length: ${#DB_PASSWORD}"
        
        cd /app/api
        export FLASK_APP=app.py
        
        echo "=== [$(date +%Y-%m-%d\ %H:%M:%S)] Running flask db upgrade (direct, bypassing upgrade_db) ==="
        python -m flask db upgrade
        FLASK_EXIT_CODE=$?
        
        if [ $FLASK_EXIT_CODE -ne 0 ]; then
          echo "❌ [$(date +%Y-%m-%d\ %H:%M:%S)] flask db upgrade failed with exit code $FLASK_EXIT_CODE"
          exit $FLASK_EXIT_CODE
        fi
        
        echo "=== [$(date +%Y-%m-%d\ %H:%M:%S)] Verifying migration ==="
        python -c "
        import os
        import sys
        import psycopg2
        
        try:
            conn = psycopg2.connect(
                host=os.getenv('DB_HOST'),
                port=os.getenv('DB_PORT'),
                user=os.getenv('DB_USERNAME'),
                password=os.getenv('DB_PASSWORD'),
                database=os.getenv('DB_DATABASE')
            )
            cur = conn.cursor()
            
            # Check alembic_version table
            cur.execute(\"SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename = 'alembic_version';\")
            result = cur.fetchone()
            if not result:
                print('❌ Migration failed: alembic_version table not found')
                sys.exit(1)
            
            print('✅ Migration verified: alembic_version table exists')
            
            # Check migration version
            cur.execute(\"SELECT version_num FROM alembic_version;\")
            version = cur.fetchone()
            if version:
                print(f'✅ Current migration version: {version[0]}')
            
            # Check total tables
            cur.execute(\"SELECT COUNT(*) FROM pg_tables WHERE schemaname = 'public';\")
            table_count = cur.fetchone()[0]
            print(f'✅ Total tables created: {table_count}')
            
            # Check a major table (e.g., accounts)
            cur.execute(\"SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename = 'accounts';\")
            accounts_table = cur.fetchone()
            if accounts_table:
                print('✅ Major table verified: accounts table exists')
            else:
                print('⚠️  Warning: accounts table not found (may be normal if migration is incomplete)')
            
            cur.close()
            conn.close()
            
        except Exception as e:
            print(f'❌ Verification failed: {e}')
            import traceback
            traceback.print_exc()
            sys.exit(1)
        "
        VERIFY_EXIT_CODE=$?
        
        if [ $VERIFY_EXIT_CODE -ne 0 ]; then
          echo "❌ [$(date +%Y-%m-%d\ %H:%M:%S)] Migration verification failed with exit code $VERIFY_EXIT_CODE"
          exit $VERIFY_EXIT_CODE
        fi
        
        echo "✅ [$(date +%Y-%m-%d\ %H:%M:%S)] Database migration completed successfully! ==="
```

**メリット**：
- シンプルな実装
- Pod 起動時に自動実行される
- Redis ロックに依存しない
- 失敗時は Pod 起動を止める（`set -euo pipefail`）

**デメリット**：
- 複数の Pod が同時に起動した場合、競合する可能性がある（通常は問題ないが、レプリカ数 > 1 の場合は注意）
- 失敗時の再試行は Pod の再起動に依存

**同時実行時のリスク**：
- 複数の Pod が同時に起動した場合、複数の initContainer が同時にマイグレーションを実行する可能性がある
- Alembic は通常、同時実行を防ぐ仕組みがあるが、完全ではない
- **推奨**：レプリカ数は 1 に設定するか、Job 方式を採用する

## ⑤ 結論

### 今回テーブルが作成されなかった「直接原因」

**断定**：以下の3つの要因が組み合わさり、マイグレーションが実行されなかった。

1. **Redis ロック取得失敗**：`upgrade_db()` 関数が Redis ロック取得を前提としており、ロック取得に失敗した場合、マイグレーションは実行されない
2. **例外の握りつぶし**：`upgrade_db()` 関数内で発生した例外は、すべて `except Exception:` でキャッチされ、再発生しない（exit code 0）
3. **エントリーポイントスクリプトの設計**：エントリーポイントスクリプトは、`flask upgrade-db` の exit code をチェックせず、常に `exit 0` で終了する

### なぜログ上は成功に見えたのか

**断定**：以下の理由により、ログ上は成功に見えた。

1. **`upgrade_db()` 関数の設計**：Redis ロック取得失敗時や例外発生時でも、例外を発生させない（exit code 0）。`"Database migration skipped"` や `"Failed to execute database migration"` のログは出力されるが、exit code は 0 のまま
2. **エントリーポイントスクリプトの設計**：`MODE=migration` の場合、`flask upgrade-db` の成否に関わらず `"Migration completed, exiting normally"` と表示され、`exit 0` で終了する
3. **Kubernetes の initContainer の挙動**：initContainer の exit code が 0 の場合、Pod は正常起動として扱われる

### upgrade_db() に依存する設計を採用すべきか否か

**断定**：**採用すべきではない**

**理由**：
1. Redis ロックに依存しているため、Redis 接続に失敗した場合、マイグレーションが実行されない
2. 例外処理により、失敗が検出されにくい
3. exit code が 0 のままになるため、失敗を検出できない
4. Kubernetes 環境では、Redis の可用性に依存する設計は適切ではない

**推奨**：
- `flask db upgrade` を直接実行する方法を採用する
- マイグレーション実行後に検証を行う
- exit code で成功/失敗を明確に判断する

### Kubernetes 環境での DB migration の正しい設計指針

**断定**：以下の設計指針に従うべきである。

1. **アプリ内部ロジックに依存しない**
   - `flask db upgrade` を直接実行する
   - Redis ロックやアプリ内部条件に依存しない

2. **成功/失敗を明確に検証する**
   - マイグレーション実行後に `alembic_version` テーブルの存在を確認する
   - 可能なら主要テーブル1つも確認する
   - exit code で成功/失敗を判断する

3. **Kubernetes 的に失敗として検出可能にする**
   - `set -euo pipefail` を使用する
   - 失敗時は exit code を非0にする
   - Job 方式を採用する場合は、`backoffLimit` を設定する

4. **ログ出力を充実させる**
   - 各ステップでログを出力し、問題の切り分けを容易にする
   - タイムスタンプを付与する

5. **再現性を確保する**
   - 環境変数の設定を明確にする
   - 実行順序を保証する（initContainer または Job）

## 推奨アプローチ

**推奨**：**A. Migration 専用 Job（安定運用）**

**理由**：
1. Helm install/upgrade 時に一度だけ実行される（重複実行を防げる）
2. 本体コンテナとは独立（API コンテナの起動に影響しない）
3. 失敗時の再試行が可能（`backoffLimit: 3`）
4. 実行履歴が残る（Job として記録される）
5. 失敗時は Job が失敗として記録される（Kubernetes 的に検出可能）

**実装**：`templates/db-migration-job.yaml` を参照
