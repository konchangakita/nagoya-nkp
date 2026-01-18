#!/bin/bash
set -e

# カラー出力
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 設定
KUBECONFIG_PATH="${KUBECONFIG:-/home/nutanix/nkp/kon-hoihoi.conf}"
NAMESPACE="dify"
RELEASE_NAME="dify"
HELM_REPO_NAME="dify"
HELM_REPO_URL="https://langgenius.github.io/dify-helm"
STORAGE_CLASS="${STORAGE_CLASS:-nutanix-volume}"  # デフォルトは nutanix-volume

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}   Dify Kubernetes Installation     ${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo -e "Kubeconfig: ${YELLOW}${KUBECONFIG_PATH}${NC}"
echo -e "Namespace: ${YELLOW}${NAMESPACE}${NC}"
echo -e "Release Name: ${YELLOW}${RELEASE_NAME}${NC}"
echo -e "StorageClass: ${YELLOW}${STORAGE_CLASS}${NC}"
echo ""

# スクリプトのディレクトリを取得
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VALUES_FILE="${SCRIPT_DIR}/values.yaml"
INGRESS_FILE="${SCRIPT_DIR}/ingress.yaml"
PVC_FILE="${SCRIPT_DIR}/dify-backend-pvc.yaml"

# kubeconfigの確認
if [ ! -f "${KUBECONFIG_PATH}" ]; then
    echo -e "${RED}Error: Kubeconfig not found at ${KUBECONFIG_PATH}${NC}"
    exit 1
fi

# values.yamlの確認
if [ ! -f "${VALUES_FILE}" ]; then
    echo -e "${RED}Error: values.yaml not found at ${VALUES_FILE}${NC}"
    exit 1
fi

# kubectlのエイリアス
K="kubectl --kubeconfig=${KUBECONFIG_PATH}"

# クラスタ接続確認
echo -e "${BLUE}Checking cluster connection...${NC}"
${K} cluster-info || {
    echo -e "${RED}Failed to connect to cluster${NC}"
    exit 1
}
echo -e "${GREEN}✓ Cluster connection OK${NC}"
echo ""

# Namespace確認
echo -e "${BLUE}Checking namespace...${NC}"
if ${K} get namespace ${NAMESPACE} &>/dev/null; then
    echo -e "${GREEN}✓ Namespace '${NAMESPACE}' exists${NC}"
else
    echo -e "${YELLOW}Creating namespace '${NAMESPACE}'...${NC}"
    ${K} create namespace ${NAMESPACE}
    echo -e "${GREEN}✓ Namespace created${NC}"
fi
echo ""

# Helmリポジトリ確認
echo -e "${BLUE}Checking Helm repository...${NC}"
if helm repo list | grep -q "^${HELM_REPO_NAME}"; then
    echo -e "${GREEN}✓ Helm repository '${HELM_REPO_NAME}' already added${NC}"
    echo -e "${BLUE}Updating Helm repository...${NC}"
    helm repo update ${HELM_REPO_NAME}
else
    echo -e "${YELLOW}Adding Helm repository '${HELM_REPO_NAME}'...${NC}"
    helm repo add ${HELM_REPO_NAME} ${HELM_REPO_URL}
    helm repo update ${HELM_REPO_NAME}
    echo -e "${GREEN}✓ Helm repository added${NC}"
fi
echo ""

# StorageClass確認
echo -e "${BLUE}Checking StorageClass...${NC}"
if ${K} get storageclass ${STORAGE_CLASS} &>/dev/null; then
    echo -e "${GREEN}✓ StorageClass '${STORAGE_CLASS}' exists${NC}"
else
    echo -e "${YELLOW}⚠️  Warning: StorageClass '${STORAGE_CLASS}' not found${NC}"
    echo -e "${YELLOW}Available StorageClasses:${NC}"
    ${K} get storageclass
    echo ""
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo ""
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${YELLOW}Installation cancelled${NC}"
        exit 1
    fi
fi
echo ""

# values.yamlのstorageClassを更新
echo -e "${BLUE}Updating values.yaml with StorageClass...${NC}"
if grep -q "^storageClass:" "${VALUES_FILE}"; then
    # storageClassを更新（sed -i は環境によって動作が異なるため、一時ファイルを使用）
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS
        sed -i '' "s|^storageClass:.*|storageClass: ${STORAGE_CLASS}|" "${VALUES_FILE}"
    else
        # Linux
        sed -i "s|^storageClass:.*|storageClass: ${STORAGE_CLASS}|" "${VALUES_FILE}"
    fi
    echo -e "${GREEN}✓ values.yaml updated with StorageClass: ${STORAGE_CLASS}${NC}"
else
    echo -e "${YELLOW}⚠️  Warning: storageClass not found in values.yaml${NC}"
fi
echo ""

# 既存のリリース確認
echo -e "${BLUE}Checking existing Helm release...${NC}"
if helm list --kubeconfig=${KUBECONFIG_PATH} -n ${NAMESPACE} | grep -q "^${RELEASE_NAME}"; then
    echo -e "${YELLOW}⚠️  Warning: Helm release '${RELEASE_NAME}' already exists${NC}"
    echo ""
    read -p "Do you want to upgrade? (y/N): " -n 1 -r
    echo ""
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}Upgrading Helm release...${NC}"
        # --wait でタイムアウトしても続行するため、一時的に set -e を無効化
        set +e
        helm upgrade ${RELEASE_NAME} ${HELM_REPO_NAME}/dify \
            --namespace ${NAMESPACE} \
            --kubeconfig=${KUBECONFIG_PATH} \
            --values ${VALUES_FILE} \
            --timeout 10m \
            --wait 2>&1
        HELM_EXIT_CODE=$?
        set -e
        
        if [ $HELM_EXIT_CODE -eq 0 ]; then
            echo -e "${GREEN}✓ Helm release upgraded${NC}"
        else
            echo -e "${YELLOW}⚠️  Warning: Helm upgrade completed with warnings/timeout${NC}"
            echo -e "${YELLOW}   Continuing with PVC and Ingress setup...${NC}"
        fi
    else
        echo -e "${YELLOW}Installation cancelled${NC}"
        exit 0
    fi
else
    # Helmインストール
    echo -e "${BLUE}Installing Dify with Helm...${NC}"
    # --wait でタイムアウトしても続行するため、一時的に set -e を無効化
    set +e
    helm install ${RELEASE_NAME} ${HELM_REPO_NAME}/dify \
        --namespace ${NAMESPACE} \
        --kubeconfig=${KUBECONFIG_PATH} \
        --values ${VALUES_FILE} \
        --timeout 10m \
        --wait 2>&1
    HELM_EXIT_CODE=$?
    set -e
    
    if [ $HELM_EXIT_CODE -eq 0 ]; then
        echo -e "${GREEN}✓ Helm installation completed${NC}"
    else
        echo -e "${YELLOW}⚠️  Warning: Helm installation completed with warnings/timeout${NC}"
        echo -e "${YELLOW}   Continuing with PVC and Ingress setup...${NC}"
    fi
fi
echo ""

# dify-backend-pvcの確認と作成
echo -e "${BLUE}Checking dify-backend-pvc...${NC}"
if ${K} get pvc -n ${NAMESPACE} dify-backend-pvc &>/dev/null; then
    echo -e "${GREEN}✓ PVC 'dify-backend-pvc' already exists${NC}"
else
    echo -e "${YELLOW}Creating dify-backend-pvc...${NC}"
    if [ -f "${PVC_FILE}" ]; then
        ${K} apply -f ${PVC_FILE}
        echo -e "${GREEN}✓ PVC created from ${PVC_FILE}${NC}"
    else
        # PVCファイルが存在しない場合は動的に作成
        ${K} apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: dify-backend-pvc
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteMany
  resources:
    requests:
      storage: 5Gi
  storageClassName: nutanix-nfs
EOF
        echo -e "${GREEN}✓ PVC created dynamically${NC}"
    fi
    
    # PVCがBoundになるまで待機
    echo -e "${BLUE}Waiting for PVC to be bound...${NC}"
    timeout=60
    count=0
    while [ $count -lt $timeout ]; do
        if ${K} get pvc -n ${NAMESPACE} dify-backend-pvc -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Bound"; then
            echo -e "${GREEN}✓ PVC is bound${NC}"
            break
        fi
        sleep 2
        count=$((count + 2))
        echo -n "."
    done
    echo ""
    
    if [ $count -ge $timeout ]; then
        echo -e "${YELLOW}⚠️  Warning: PVC is not bound yet. Continuing...${NC}"
    fi
fi
echo ""

# Ingress適用
echo -e "${BLUE}Applying Ingress...${NC}"
if [ -f "${INGRESS_FILE}" ]; then
    ${K} apply -f ${INGRESS_FILE}
    echo -e "${GREEN}✓ Ingress applied${NC}"
else
    echo -e "${YELLOW}⚠️  Warning: ingress.yaml not found at ${INGRESS_FILE}${NC}"
fi
echo ""

# インストール状況確認
echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}   Installation Status                ${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""

echo -e "${BLUE}Pods:${NC}"
${K} get pods -n ${NAMESPACE}
echo ""

echo -e "${BLUE}Services:${NC}"
${K} get svc -n ${NAMESPACE}
echo ""

echo -e "${BLUE}PersistentVolumeClaims:${NC}"
${K} get pvc -n ${NAMESPACE}
echo ""

echo -e "${BLUE}Ingress:${NC}"
${K} get ingress -n ${NAMESPACE}
echo ""

echo -e "${GREEN}======================================${NC}"
echo -e "${GREEN}   Installation Completed!            ${NC}"
echo -e "${GREEN}======================================${NC}"
echo ""
echo -e "${BLUE}Next steps:${NC}"
echo -e "  1. Check pod status: ${YELLOW}kubectl get pods -n ${NAMESPACE}${NC}"
echo -e "  2. Check ingress: ${YELLOW}kubectl get ingress -n ${NAMESPACE}${NC}"
echo -e "  3. Access Dify UI via Ingress${NC}"
echo ""
