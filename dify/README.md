# Dify Kubernetes Installation

DifyをKubernetesクラスタにインストールするためのリポジトリです。

## 📋 前提条件

- Kubernetesクラスタへのアクセス権限
- `kubectl`コマンドが利用可能
- `helm`コマンドが利用可能（v3以上）
- kubeconfigファイル（デフォルト: `/home/nutanix/nkp/kon-hoihoi.conf`）

## 📁 ファイル構成

```
dify/
├── install.sh       # インストールスクリプト
├── values.yaml      # Helm values設定ファイル
├── ingress.yaml     # Ingress設定（Traefik対応）
└── README.md        # このファイル
```

## 🚀 インストール手順

### 1. 事前準備

```bash
# 作業ディレクトリに移動
cd /home/nutanix/konchangakita/nagoya-nkp/dify

# kubeconfigの確認
ls -l /home/nutanix/nkp/kon-hoihoi.conf
```

### 2. インストール実行

#### デフォルト設定（nutanix-volume）でインストール

```bash
./install.sh
```

#### カスタムStorageClassを指定してインストール

```bash
STORAGE_CLASS=nutanix-nfs ./install.sh
```

#### カスタムkubeconfigを指定

```bash
KUBECONFIG=/path/to/your/kubeconfig.conf ./install.sh
```

### 3. インストール後の確認

```bash
# Podの状態を確認
kubectl --kubeconfig=/home/nutanix/nkp/kon-hoihoi.conf get pods -n dify

# Serviceの確認
kubectl --kubeconfig=/home/nutanix/nkp/kon-hoihoi.conf get svc -n dify

# Ingressの確認
kubectl --kubeconfig=/home/nutanix/nkp/kon-hoihoi.conf get ingress -n dify

# PersistentVolumeClaimの確認
kubectl --kubeconfig=/home/nutanix/nkp/kon-hoihoi.conf get pvc -n dify
```

## ⚙️ 設定

### StorageClass

デフォルトでは`nutanix-volume`（ReadWriteOnce）を使用します。

- **nutanix-volume**: Nutanix標準ボリューム（ReadWriteOnce）
- **nutanix-nfs**: NFSストレージ（ReadWriteMany）

⚠️ **重要**: Difyの`dify-backend-pvc`（API/Worker用）には`ReadWriteMany`アクセスモードが必要なため、**`nutanix-nfs` StorageClassが必要です**。クラスタに`nutanix-nfs` StorageClassが存在しない場合は、インストール前に作成してください。

#### StorageClassの確認

```bash
# 既存のStorageClassを確認
kubectl --kubeconfig=/home/nutanix/nkp/kon-hoihoi.conf get storageclass

# nutanix-nfsが存在するか確認
kubectl --kubeconfig=/home/nutanix/nkp/kon-hoihoi.conf get storageclass nutanix-nfs
```

#### nutanix-nfs StorageClassの作成（必要な場合）

`nutanix-nfs` StorageClassが存在しない場合は、以下の手順で作成してください。

##### 1. CSI認証情報のSecretを作成

```bash
kubectl --kubeconfig=/home/nutanix/nkp/kon-hoihoi.conf apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: nutanix-csi-credentials-files
  namespace: ntnx-system
stringData:
  key: "<PrismElement_IP>:<Port>:<Username>:<Password>"
  files-key: "<NFS_External_IP>:<FilesAPIUsername>:<Password>"
EOF
```

**注意**: Secretの値は環境に応じて変更してください。

##### 2. StorageClassを作成

```bash
kubectl --kubeconfig=/home/nutanix/nkp/kon-hoihoi.conf apply -f - <<EOF
allowVolumeExpansion: true
kind: StorageClass
apiVersion: storage.k8s.io/v1
metadata:
    name: nutanix-nfs
provisioner: csi.nutanix.com
parameters:
    nfsServerName: <NFS_Server_Name>
    nfsServer: <NFS_Server_IP>
    dynamicProv: ENABLED
    storageType: NutanixFiles
    squashType: root-squash
    csi.storage.k8s.io/node-publish-secret-name: nutanix-csi-credentials-files
    csi.storage.k8s.io/node-publish-secret-namespace: ntnx-system
    csi.storage.k8s.io/controller-expand-secret-name: nutanix-csi-credentials-files
    csi.storage.k8s.io/controller-expand-secret-namespace: ntnx-system
    csi.storage.k8s.io/provisioner-secret-name: nutanix-csi-credentials-files
    csi.storage.k8s.io/provisioner-secret-namespace: ntnx-system
reclaimPolicy: Delete
volumeBindingMode: Immediate
EOF
```

**パラメータの説明**:
- `nfsServerName`: NFSサーバーの名前（例: `labFS`）
- `nfsServer`: NFSサーバーのIPアドレス（例: `10.55.1.39`）
- `storageType`: `NutanixFiles`を指定
- `squashType`: `root-squash`を推奨
- `reclaimPolicy`: `Delete`（削除時にボリュームも削除）

**注意**: 上記のパラメータは環境に応じて調整が必要です。NutanixクラスタのNFSプロビジョナーの設定を確認してください。

StorageClassは環境変数で指定できます：

```bash
STORAGE_CLASS=nutanix-nfs ./install.sh
```

または、`values.yaml`の`storageClass`を直接編集してください。

### Namespace

デフォルトでは`dify`名前空間を使用します。スクリプト内で自動的に作成されます。

### Ingress

`ingress.yaml`でTraefik Ingressを設定しています。以下のパスが利用可能です：

- `/` - Dify Web UI（フロントエンド）
- `/api` - Dify API

Ingressは自動的に適用されますが、必要に応じて手動で適用・更新できます：

```bash
kubectl --kubeconfig=/home/nutanix/nkp/kon-hoihoi.conf apply -f ingress.yaml
```

## 📦 インストールされるコンポーネント

- **Dify Web**: フロントエンドUI
- **Dify API**: バックエンドAPI
- **Dify Worker**: ワーカーサービス
- **PostgreSQL**: データベース（内蔵）
- **Redis**: キャッシュ・キュー（内蔵）
- **Weaviate**: ベクトルデータベース（内蔵）

## 🔧 アップグレード

既存のリリースをアップグレードする場合：

```bash
./install.sh
```

既存リリースが検出された場合、アップグレードを確認されます。

手動でアップグレードする場合：

```bash
helm upgrade dify dify/dify \
  --namespace dify \
  --kubeconfig=/home/nutanix/nkp/kon-hoihoi.conf \
  --values values.yaml
```

## 🗑️ アンインストール

```bash
# Helmリリースの削除
helm uninstall dify \
  --namespace dify \
  --kubeconfig=/home/nutanix/nkp/kon-hoihoi.conf

# Namespaceの削除（データも削除されます）
kubectl --kubeconfig=/home/nutanix/nkp/kon-hoihoi.conf delete namespace dify
```

⚠️ **注意**: Namespaceを削除すると、すべてのデータ（PVC含む）も削除されます。

## 📝 values.yamlの主な設定

- `global.image.tag`: イメージタグ（デフォルト: `latest`）
- `storageClass`: ストレージクラス（デフォルト: `nutanix-volume`）
- `postgresql.primary.persistence.size`: PostgreSQLストレージサイズ（デフォルト: `20Gi`）
- `redis.master.persistence.size`: Redisストレージサイズ（デフォルト: `5Gi`）
- `weaviate.persistence.size`: Weaviateストレージサイズ（デフォルト: `20Gi`）
- `web.replicaCount`: Webレプリカ数（デフォルト: `1`）
- `api.replicaCount`: APIレプリカ数（デフォルト: `1`）
- `worker.replicaCount`: Workerレプリカ数（デフォルト: `1`）

詳細は`values.yaml`を参照してください。

## 🔗 参考リンク

- [Dify Helm Chart 公式ドキュメント](https://langgenius.github.io/dify-helm/#/)
- [Dify 公式サイト](https://dify.ai/)

## ❓ トラブルシューティング

### Podが起動しない

```bash
# Podの詳細を確認
kubectl --kubeconfig=/home/nutanix/nkp/kon-hoihoi.conf describe pod -n dify <pod-name>

# Podのログを確認
kubectl --kubeconfig=/home/nutanix/nkp/kon-hoihoi.conf logs -n dify <pod-name>
```

### PVCがBoundにならない

```bash
# PVCの詳細を確認
kubectl --kubeconfig=/home/nutanix/nkp/kon-hoihoi.conf describe pvc -n dify <pvc-name>

# StorageClassの確認
kubectl --kubeconfig=/home/nutanix/nkp/kon-hoihoi.conf get storageclass
```

### Ingressにアクセスできない

```bash
# Ingressの詳細を確認
kubectl --kubeconfig=/home/nutanix/nkp/kon-hoihoi.conf describe ingress -n dify dify-ingress

# TraefikのIngressRouteを確認
kubectl --kubeconfig=/home/nutanix/nkp/kon-hoihoi.conf get ingressroute -A
```
