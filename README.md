# nagoya-nkp

## DifyをNKPアプリケーションカタログに登録する手順

このドキュメントでは、`dify`配下のHelmチャートをNKPアプリケーションカタログに登録する手順を説明します。

参考: [ログほいほいを NKPアプリケーションカタログしてみる](https://konchangakita.hatenablog.com/entry/2025/12/11/100000)

### 前提知識

NKPアプリケーションカタログの詳細な手順については、以下の公式ドキュメントを参照してください。
- [NTNX＞日記様のブログ](https://blog.ntnx.jp)

### 準備

#### 1. Helmパッケージの作成

`dify`ディレクトリ配下のHelmチャートをパッケージ化します。

```bash
helm package ./dify
```

Chart.yamlのVersionに合わせて、`dify-0.1.0.tgz`のようなファイルが作成されます。

#### 2. OCIレジストリ（GHCR）へpush

HelmパッケージをGitHub Container Registry（GHCR）にプッシュします。

```bash
export HELM_EXPERIMENTAL_OCI=1
helm push dify-0.1.0.tgz oci://ghcr.io/konchangakita/
```

**注意**: GHCRへのpushには、GitHubのPersonal Access Token（PAT）が必要です。事前に作成しておいてください。

**認証設定例**:
```bash
export GHCR_USER=konchangakita
export GHCR_PAT='<your-github-pat>'
echo "$GHCR_PAT" | docker login ghcr.io -u "$GHCR_USER" --password-stdin
```

**GitHub上でのパッケージ確認**:
- GitHubのパッケージ設定から、パッケージをPublicにして、認証無しでダウンロードできるようにしておきます。

### NKPカタログ用のファイル作成

#### 3. Catalog Repository（Git）の準備

NKPカタログにはGit管理されたカタログリポジトリが必要です。
NKPカタログ用のディレクトリを作成し、`nkp`コマンドでテンプレート一式を作成します。

```bash
nkp generate catalog-repository --apps dify=1.11.4 --repo-dir ./
```

このコマンドで以下のような構造のファイル一式が作成されます：

```
.
├── .bloodhound.yml
└── applications
    └── dify
        └── 1.11.4
            ├── helmrelease
            │   ├── cm.yaml
            │   ├── helmrelease.yaml
            │   └── kustomization.yaml
            ├── helmrelease.yaml
            ├── kustomization.yaml
            └── metadata.yaml
```

#### 4. 設定ファイルの編集

##### metadata.yaml

`metadata.yaml`では、NKPアプリカタログで表示される項目を設定できます。

```yaml
schema: catalog.nkp.nutanix.com/v1/application-metadata
allowMultipleInstances: true
category:
- general
description: "Dify Community Edition - オープンソースのLLMアプリケーション開発プラットフォーム"
displayName: dify
icon: ""
licensing:
- Pro
- Ultimate
overview: ""
scope:
- project
supportLink: "https://github.com/langgenius/dify"
```

**注意**: 
- `description`や`icon`はなくても実装可能ですが、`supportLink`は何か入れておかないとエラーが出る場合があります。
- アイコンを設定する場合は、SVG形式のファイルをbase64でエンコードして設定します。

##### helmrelease.yaml

`helmrelease.yaml`では、OCIレジストリにプッシュしたOCIアーティファクトのURLを指定します。

`applications/dify/1.11.4/helmrelease/helmrelease.yaml`を編集：

```yaml
apiVersion: source.toolkit.fluxcd.io/v1
kind: OCIRepository
metadata:
  name: ${releaseName}-chart-source
  namespace: ${releaseNamespace}
spec:
  interval: 6h0m0s
  ref:
    tag: 0.1.0  # Helmチャートのバージョン
  url: oci://ghcr.io/konchangakita/dify  # OCIレジストリのURL
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata:
  name: dify
  namespace: ${releaseNamespace}
spec:
  chartRef:
    kind: OCIRepository
    name: ${releaseName}-chart-source
    namespace: ${releaseNamespace}
  install:
    crds: CreateReplace
    createNamespace: true
    remediation:
      retries: 30
  interval: 15s
  targetNamespace: ${releaseNamespace}
  upgrade:
    crds: CreateReplace
    remediation:
      retries: 30
  valuesFrom:
  - kind: ConfigMap
    name: ${releaseName}-config-defaults
```

**重要**: 
- `ref.tag`にはHelmチャートのバージョン（Chart.yamlの`version`フィールド）を指定します。
- `url`には実際のOCIレジストリのURLを指定します。

### NKPアプリカタログの実装

#### 5. Catalog Bundleの生成

カタログバンドルを作成します。

```bash
nkp create catalog-bundle --repo-dir .
```

実行例：
```bash
$ nkp create catalog-bundle --repo-dir .
Bundling 1 application(s) (airgapped : false)
 ✓ Validating metadata.yaml for dify/1.11.4
 ✓ Building OCI artifact nkp-catalog/dify:1.11.4
Processing application dify/1.11.4
 ✓ K8s v1.33.0: parsing resources 
 ✓ K8s v1.33.0: validating 
 ✓ Pulling requested images [====================================>1/1] (time elapsed 00s) 
 ✓ Saving application bundle to /path/to/dify-1.11.4.tar
```

#### 6. BundleをGHCRへPush

作成したバンドルをGHCRにプッシュします。

```bash
nkp push bundle \
  --bundle dify-1.11.4.tar \
  --to-registry oci://ghcr.io/konchangakita
```

実行例：
```bash
$ nkp push bundle \
  --bundle dify-1.11.4.tar \
  --to-registry oci://ghcr.io/konchangakita

 ✓ Creating temporary directory
 ✓ Extracting bundle configs from "dify-1.11.4.tar"
 ✓ Parsing image bundle config
 ✓ Starting temporary Docker registry
 ✓ Pushing bundled images [====================================>1/1] (time elapsed 02s) 
```

**GitHub上でのパッケージ確認**:
- パッケージをPublicにして、認証無しでダウンロード可能にしておきます。
- GitHub上のパッケージ名を確認します（自動的にディレクトリ名の`nkp-catalog`が付与されます）。

### NKP WorkspaceのApplicationsにカタログを登録

#### 7. NKPのWorkspace Nameを確認

NKP Managementクラスタに対して、ワークスペース一覧を取得します。

```bash
nkp get ws
```

実行例：
```bash
$ nkp get ws
NAME                    NAMESPACE                    
default-workspace       kommander-default-workspace 
kom-workspace-4m9zt     kon-workspace-4m9zt-nthlf
kommander-workspace     kommander                   
```

#### 8. カタログ登録

先程プッシュしたCatalog Bundleを指定し、カタログ登録したいworkspace nameを指定します。

```bash
nkp create catalog-application \
  --url oci://ghcr.io/konchangakita/nkp-catalog/dify \
  --tag 1.11.4 \
  --workspace <workspace-name> \
  --skip-oci-registry-patches
```

実行例：
```bash
$ nkp create catalog-application \
  --url oci://ghcr.io/konchangakita/nkp-catalog/dify \
  --tag 1.11.4 \
  --workspace kon-workspace-4m9zt \
  --skip-oci-registry-patches

Catalog application nkp-catalog-dify created. Use 'nkp edit ocirepository -n <namespace> nkp-catalog-dify' to change its configuration if needed.
Note that the OCIRepository is not patched by NKP with credentials due to custom configuration. Make sure to configure the url and credentials according to your cluster networking capabilities.
```

**プロジェクト指定の場合**:
プロジェクトを指定する場合は、`--project`オプションを追加します。

```bash
nkp create catalog-application \
  --url oci://ghcr.io/konchangakita/nkp-catalog/dify \
  --tag 1.11.4 \
  --workspace <workspace-name> \
  --project <project-name> \
  --skip-oci-registry-patches
```

NKP上でWorkspaceを選択して、Applicationを確認すると追加されているはずです。

### カタログからDifyを実装

NKPのWeb UIから、ApplicationsカタログでDifyを選択し、Enableします。

実装後、ネームスペースが自動的に作成され、アプリケーションがデプロイされます。

```bash
kubectl get all -n <namespace>
```

### カタログから削除するには

カタログからアプリケーションを削除する場合は、以下のコマンドを実行します。

```bash
# アプリケーション一覧を確認
kubectl get apps.apps.kommander.d2iq.io -n <workspace-namespace>

# アプリケーションを削除
kubectl delete apps.apps.kommander.d2iq.io -n <workspace-namespace> <app-name>
```

実行例：
```bash
$ kubectl get apps.apps.kommander.d2iq.io -n kon-workspace-4m9zt-nthlf
NAME               APP ID       APP VERSION   SOURCE                  AGE
dify-1.11.4        dify        1.11.4        nkp-catalog-dify        10m

$ kubectl delete apps.apps.kommander.d2iq.io -n kon-workspace-4m9zt-nthlf dify-1.11.4
app.apps.kommander.d2iq.io "dify-1.11.4" deleted
```

### トラブルシューティング

#### エラー: "the server doesn't have a resource type 'appdeployments'"

このエラーが発生する場合は、正しいリソースタイプを使用しているか確認してください。
NKPでは`apps.apps.kommander.d2iq.io`リソースを使用します。

```bash
# 正しいコマンド
kubectl get apps.apps.kommander.d2iq.io -n <namespace>

# 間違ったコマンド（存在しないリソースタイプ）
kubectl get appdeployments -n <namespace>  # ❌
```

### 参考リンク

- [ログほいほいを NKPアプリケーションカタログしてみる](https://konchangakita.hatenablog.com/entry/2025/12/11/100000)
- [NTNX＞日記様のブログ](https://blog.ntnx.jp)
