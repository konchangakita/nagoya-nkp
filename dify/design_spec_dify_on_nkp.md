## Dify Community Edition on NKP  
### 設計方針仕様書 v1

---

### 1. 目的（Why）

- Dify Community Edition (CE) を Nutanix Kubernetes Platform (NKP) 上にデプロイする。  
- Helm チャートとしてパッケージ化し、**どの環境でも再利用可能**にする。  
- GitHub に公開する YAML / `values.yaml` には、**IP・URL・Secret 等の固定値を一切書かない**。  
- 環境依存値は、**デプロイ時に自動特定**または **オプション指定（`--set` / スクリプト引数）**で注入する。  
- 実装は **最小・単純・保守しやすいことを最優先**する。  

---

### 2. 前提条件（Environment）

- **Kubernetes**: Nutanix Kubernetes Platform (NKP)  
- **Ingress Controller**: Kommander Traefik  
- **IngressClass**: `kommander-traefik`  
- **LoadBalancer**: MetalLB（Traefik Service が LoadBalancer タイプ）  
- **StorageClass**: `nutanix-volume`（デフォルト, RWO）  
- **Namespace**: `dify`  
- **公開対象**: prod 相当環境のみ（dev / stg は対象外）  
- **Dify Edition**: Community Edition（Enterprise 専用機能は対象外）  

---

### 3. 公開方式

- Dify は **Ingress 経由で公開**する。  
- Ingress は **IP を一切参照しない**（`host` 未指定、`path` ベース）。  
- 公開用 IP は **Traefik（kommander-traefik）の Service: LoadBalancer** が持つ。  
- Dify の公開パスは **`/dify`** とする。  
- 外部アクセス例（内部利用前提）：  
  - `https://<Traefik_LB_IP>/dify`  
  - TLS は Traefik が提供する **自己署名証明書**を使用し、**ブラウザ警告は許容**する。  
  - DNS / 正式証明書管理は本仕様の対象外。  

---

### 4. 全体アーキテクチャ

- Browser  
  - ↓ `https://<LB_IP>/dify`  
- Traefik (kommander-traefik, Service: LoadBalancer)  
  - ↓ Ingress (PathPrefix `/dify`)  
- Dify Web Service (`dify-web`)  
  - ↓  
- Dify API / Worker (`dify-api`, `dify-worker`)  
  - ↓  
- PostgreSQL / Redis / Weaviate（StatefulSet + PVC）  

---

### 5. Helm チャート構成（1チャート・全部入り）

`dify/`（チャートルート）は以下の構成とする：

- `Chart.yaml`  
- `values.yaml`（固定値ゼロ。GitHub 公開可）  
- `templates/`  
  - `secret.yaml`  
  - `dify-web.yaml`  
  - `dify-api.yaml`  
  - `dify-worker.yaml`  
  - `ingress.yaml`  
  - `postgresql.yaml`      # 公式イメージ postgres:16 を利用  
  - `redis.yaml`           # 公式イメージ redis:7 を利用  
  - `_helpers.tpl`  
- `charts/`（サブチャート）  
  - `weaviate/`            # Weaviate のみサブチャート利用  
- `deploy.sh`（環境依存値を自動注入するスクリプト）  

---

### 6. values.yaml 設計方針

#### 6.1 原則

- `values.yaml` に **固定値は一切書かない**。  
- 必須値は Helm の `required` 関数でチェックし、指定漏れ時にはインストールを失敗させる。  
- 環境依存値はすべて `helm install` / `helm upgrade` の `--set` または `deploy.sh` から注入する。  

#### 6.2 主要キー構造（例）

```yaml
expose:
  ingressClassName: ""  # 例: kommander-traefik
  path: ""              # 例: /dify

external:
  scheme: ""            # 例: https
  host: ""              # 例: <LB_IP> または dify.example.com

images:
  dify:
    repository: ""      # 例: langgenius/dify
    tag: ""             # 例: 1.11.4

secrets:
  difySecretKey: ""     # DIFY_SECRET_KEY
  openaiApiKey: ""      # 任意（LLM API Key）

storage:
  storageClassName: ""  # 例: nutanix-volume

postgresql:
  enabled: true
  persistence:
    size: ""            # 例: 20Gi
  auth:
    username: ""        # 例: dify
    password: ""        # 例: ランダム生成 or 任意指定
    database: ""        # 例: dify

redis:
  enabled: true
  persistence:
    size: ""            # 例: 8Gi
  auth:
    password: ""        # 任意（空ならパスワードなし）

weaviate:
  enabled: true
  persistence:
    enabled: true
    size: ""            # 例: 50Gi
    storageClass: ""    # 省略時は storage.storageClassName を利用

dify:
  fileStorage:
    enabled: true
    size: ""            # 例: 20Gi
```

- 実際の容量値・リソース値は `values.yaml` には書かず、`--set` または `deploy.sh` から指定する。  
- 重要パラメータには `required` を適用する（例：`expose.ingressClassName`, `expose.path`, `external.scheme`, `external.host`, `secrets.difySecretKey` など）。  

---

### 7. Ingress 定義（IP 非依存）

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: dify
  namespace: {{ .Release.Namespace }}
spec:
  ingressClassName: {{ required "expose.ingressClassName is required" .Values.expose.ingressClassName }}
  rules:
    - http:
        paths:
          - path: {{ required "expose.path is required" .Values.expose.path }}
            pathType: Prefix
            backend:
              service:
                name: dify-web
                port:
                  number: 80
```

- IP アドレスは Ingress には一切記載しない。  
- TLS 設定は本チャートでは扱わない（Traefik 既定の自己署名証明書を利用）。  

---

### 8. Dify 外部 URL の扱い（Community Edition 対応）

- `_helpers.tpl` に外部 URL を組み立てるテンプレートを定義する：

```tpl
{{- define "dify.externalURL" -}}
{{ required "external.scheme is required" .Values.external.scheme }}://{{ required "external.host is required" .Values.external.host }}{{ .Values.expose.path }}
{{- end -}}
```

- Dify の Deployment 環境変数例：

```yaml
env:
  - name: SERVER_URL
    value: "{{ include "dify.externalURL" . }}"
  - name: CONSOLE_URL
    value: "{{ include "dify.externalURL" . }}"
```

- Community Edition でも `SERVER_URL` / `CONSOLE_URL` の指定は必須とみなす。  

---

### 9. データ永続化

- コンポーネントごとの永続化方式：
  - **PostgreSQL**: StatefulSet + PVC（`postgresql.persistence`）  
  - **Redis**: StatefulSet + PVC（`redis.persistence`）  
  - **Weaviate**: StatefulSet + PVC（`weaviate.persistence`）  
  - **Dify ファイル**（アップロードデータ等）: PVC（`dify.fileStorage`）  
- StorageClass：  
  - デフォルトは `nutanix-volume`（RWO）。  
  - RWX/NFS が必要な場合、`nutanix-nfs`（Nutanix Files, sample に定義）を追加実装してもよい。  
- バックアップ / DR は本仕様の対象外。  

---

### 10. Secret 管理

- 方針：
  - Kubernetes Secret に直接格納。  
  - GitHub に固定値は一切置かない。  
  - 値は `deploy.sh` / 環境変数 / `--set` で注入する。  
- 対象：
  - `DIFY_SECRET_KEY`（必須、`secrets.difySecretKey`）  
    - 環境変数 `DIFY_SECRET_KEY` が未設定の場合、`deploy.sh` が自動生成する（`openssl rand -hex 32`）。  
    - 既に設定されている場合はその値を使用する。  
  - LLM API Key（任意、`secrets.openaiApiKey`）  
  - 必要であれば DB 接続パスワード等。  
    - PostgreSQL のパスワードは、環境変数 `POSTGRES_PASSWORD` が未設定の場合、`deploy.sh` が自動生成し `postgresql.auth.password` に注入する。  

---

### 11. deploy.sh（環境依存値の自動特定）

#### 11.1 目的

- Traefik の LoadBalancer IP を自動取得し、Helm に `--set` で注入する。  
- `DIFY_SECRET_KEY` が未設定の場合は自動生成する。  
- YAML / `values.yaml` に固定値を残さない。  
- `KUBECONFIG=/home/ubuntu/nkp/kube.conf` を前提として実行する。  

#### 11.2 kubeconfig の扱い

- 本手順では、`deploy.sh` は以下の前提で実行される：

```bash
KUBECONFIG=/home/ubuntu/nkp/kube.conf ./deploy.sh ...
```

- 別の kubeconfig を利用したい場合は、利用者が事前に `KUBECONFIG` 環境変数を変更してから `deploy.sh` を実行する。  
- スクリプト内では `kubectl` / `helm` は `KUBECONFIG` に依存して動作し、パスはハードコードしない。  

#### 11.3 Traefik Service 検出の仕様

- デフォルト動作（自動検出）：
  - ラベルセレクタ `app.kubernetes.io/name=kommander-traefik` で Traefik Service を自動検出する。  
  - コマンド例：  
    - `kubectl get svc -A -l app.kubernetes.io/name=kommander-traefik`  
  - 取得した `namespace` / `name` をもとに、Traefik Service の LoadBalancer IP を `jsonpath: {.status.loadBalancer.ingress[0].ip}` で取得する。  
- オーバーライド機能：
  - `--traefik-namespace` / `--traefik-service-name` オプションをサポートし、指定された場合は **自動検出結果よりこれを優先**する。  
  - ラベル構成が異なるクラスタ、将来的な構成変更に対応するための逃げ道とする。  

#### 11.4 挙動

1. `Namespace dify` が存在しなければ作成する。  
2. Traefik Service を検出し、LoadBalancer IP を取得する（IP が付与されるまで待機）。  
3. 必要に応じて `--external-host` オプションを解釈し、`external.host` の値を決定する。  
4. `DIFY_SECRET_KEY` が未設定であればランダム生成し、`secrets.difySecretKey` に注入する。  
5. PostgreSQL / Redis / Weaviate / Dify ファイルストレージに関する値を、環境変数またはデフォルトから決定し、`--set` で注入する。  
   - `postgresql.auth.username` / `postgresql.auth.database` はデフォルト `dify`。  
   - `postgresql.auth.password` は `POSTGRES_PASSWORD` が未設定の場合、ランダム生成。  
   - 各永続ボリュームサイズ（`POSTGRES_SIZE` / `REDIS_SIZE` / `WEAVIATE_SIZE` / `DIFY_FILES_SIZE`）は環境変数未設定時にデフォルト値（例：20Gi 等）を用いる。  
6. `helm upgrade --install` を実行し、環境依存値を `--set` で注入する。  

---

### 12. `--external-host` オプション

- 目的：  
  - デフォルトでは Traefik LB IP を取得して `external.host` とするが、DNS 名や別の IP を指定したい場合もある。  
- 仕様：
  - `--external-host` が指定された場合：  
    - `external.host` には **`--external-host` の値をセット**する。  
    - Traefik LB IP は `SERVER_URL` 等に直接は使わない。  
  - `--external-host` が指定されない場合：  
    - 自動取得した Traefik LB IP を `external.host` にセットする。  

---

### 13. Helm 実行イメージ（完成形）

```bash
KUBECONFIG=/home/ubuntu/nkp/kube.conf \
  ./deploy.sh \
    --image-tag 1.11.4 \
    --openai-api-key sk-xxxxxx
```

- 注意：`DIFY_SECRET_KEY` 環境変数が未設定の場合、`deploy.sh` が自動生成します。  
- 既存の `DIFY_SECRET_KEY` を保持したい場合は、事前に `export DIFY_SECRET_KEY=...` を実行してください。

- 内部的に `deploy.sh` が実行する `helm` コマンド例：

```bash
helm upgrade --install dify ./dify -n dify \
  --set expose.ingressClassName=kommander-traefik \
  --set expose.path=/dify \
  --set external.scheme=https \
  --set external.host=<AUTO_DETECTED_LB_IP or --external-host> \
  --set secrets.difySecretKey=$DIFY_SECRET_KEY \
  --set secrets.openaiApiKey=sk-xxxxxx \
  --set images.dify.repository=langgenius/dify \
  --set images.dify.tag=1.11.4 \
  --set storage.storageClassName=nutanix-volume
```

---

### 14. Community Edition 明示

- 使用 image：Dify Community Edition。  
- Enterprise 専用コンポーネントは含めない。  
- SSO / 監査 / 組織管理など Enterprise 機能は非対象。  
- CE 標準 API のみを使用する。  

---

### 15. 非対象（割り切り）

- dev / stg 環境構築。  
- DNS / 正式証明書管理（例：Let’s Encrypt, 公式証明書の自動更新等）。  
- バックアップ / DR（災害対策）。  
- SSO / IdP 連携。  

---

### 16. 実装優先順位

1. Helm チャート骨格作成（`Chart.yaml`, `values.yaml`, `templates/*` の最低限）  
2. Dify Web / API / Worker Deployment 実装  
3. PostgreSQL / Redis / Weaviate サブチャート組み込み  
4. Ingress（`/dify`）実装  
5. `deploy.sh` 実装（Traefik LB IP 自動検出、`--external-host` / Traefik Service オーバーライド対応）  
6. `values.yaml` の `required` チェック実装とサンプルコマンド整備  

---

### 17. インストール手順

#### 17.1 前提条件

- Kubernetes クラスタ（NKP）にアクセス可能
- `kubectl` / `helm` コマンドがインストール済み
- `KUBECONFIG` 環境変数が設定済み（例：`/home/ubuntu/nkp/kube.conf`）
- Traefik Ingress Controller（kommander-traefik）がデプロイ済み

#### 17.2 サブチャートの取得

```bash
cd /home/ubuntu/nkp/konchangakita/nagoya-nkp/dify
helm dependency build
```

#### 17.3 デプロイ実行

**基本コマンド（最小構成）**：

```bash
export KUBECONFIG=/home/ubuntu/nkp/kube.conf
cd /home/ubuntu/nkp/konchangakita/nagoya-nkp/dify

# DIFY_SECRET_KEY が未設定の場合は自動生成されます
./deploy.sh --image-tag 1.11.4
```

**OpenAI API Key を指定する場合**：

```bash
./deploy.sh --image-tag 1.11.4 --openai-api-key sk-xxxxxx
```

**PostgreSQL 認証情報をカスタマイズする場合**：

```bash
export POSTGRES_USERNAME=myuser
export POSTGRES_DATABASE=mydb
export POSTGRES_PASSWORD=mypassword  # 未設定なら自動生成
./deploy.sh --image-tag 1.11.4
```

**ストレージサイズをカスタマイズする場合**：

```bash
export POSTGRES_SIZE=50Gi
export REDIS_SIZE=16Gi
export WEAVIATE_SIZE=100Gi
export DIFY_FILES_SIZE=50Gi
./deploy.sh --image-tag 1.11.4
```

**外部ホスト（DNS名）を指定する場合**：

```bash
./deploy.sh --image-tag 1.11.4 --external-host dify.example.com
```

**Traefik Service を手動指定する場合**：

```bash
./deploy.sh --image-tag 1.11.4 \
  --traefik-namespace my-namespace \
  --traefik-service-name my-traefik
```

#### 17.4 デプロイ確認

**Pod の状態確認**：

```bash
kubectl get pods -n dify
```

**Service の確認**：

```bash
kubectl get svc -n dify
```

**Ingress の確認**：

```bash
kubectl get ingress -n dify
```

**Traefik LoadBalancer IP の確認**：

```bash
kubectl get svc -A -l app.kubernetes.io/name=kommander-traefik -o jsonpath='{range .items[0]}{.status.loadBalancer.ingress[0].ip}{end}'
```

**ブラウザでアクセス**：

```
https://<Traefik_LB_IP>/dify
```

**注意**: ブラウザで自己署名証明書の警告が表示されますが、これは正常です。警告を無視してアクセスしてください。

**動作確認**：

すべてのPodが `Running` 状態で、`dify-web` が `1/1 Ready` になっていれば、Dify UIが表示されるはずです。

```bash
# 全Podの状態確認
kubectl get pods -n dify

# 期待される状態：
# - dify-api: 1/1 Running
# - dify-web: 1/1 Running
# - dify-worker: 1/1 Running
# - dify-postgresql-0: 1/1 Running
# - dify-redis-master-*: 1/1 Running
# - weaviate-0: 1/1 Running
```

---

### 18. アンインストール手順

**Helm リリースの削除**：

```bash
export KUBECONFIG=/home/ubuntu/nkp/kube.conf
helm uninstall dify -n dify
```

**Namespace ごと削除する場合**（**注意：永続データも削除されます**）：

```bash
kubectl delete namespace dify
```

**永続データを保持したまま削除する場合**：

```bash
# Helm リリースのみ削除（PVC は残る）
helm uninstall dify -n dify

# 必要に応じて PVC を個別に削除
kubectl get pvc -n dify
kubectl delete pvc <pvc-name> -n dify
```

---

### 19. 確認コマンド（トラブルシューティング用）

**Pod のログ確認**：

```bash
# Dify Web
kubectl logs -n dify -l app=dify-web --tail=100

# Dify API
kubectl logs -n dify -l app=dify-api --tail=100

# Dify Worker
kubectl logs -n dify -l app=dify-worker --tail=100
```

**PostgreSQL への接続確認**：

```bash
kubectl exec -it -n dify <postgresql-pod-name> -- psql -U dify -d dify
```

**Redis への接続確認**：

```bash
kubectl exec -it -n dify <redis-pod-name> -- redis-cli
```

**Weaviate のヘルスチェック**：

```bash
kubectl port-forward -n dify svc/dify-weaviate 8080:8080
curl http://localhost:8080/v1/.well-known/ready
```

**Helm リリースの状態確認**：

```bash
helm status dify -n dify
helm get values dify -n dify
```

**環境変数の確認**：

```bash
kubectl exec -n dify <dify-api-pod-name> -- env | grep -E "DB_|REDIS_|WEAVIATE_|SERVER_URL|CONSOLE_URL"
```

