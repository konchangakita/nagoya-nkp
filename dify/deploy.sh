#!/usr/bin/env bash
set -euo pipefail

CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

external_host=""
image_tag=""
openai_api_key=""

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --image-tag TAG             Dify image tag (e.g. 1.11.4) (required)
  --openai-api-key KEY        OpenAI API key (optional)
  --external-host HOST        External host (DNS or IP). If omitted, dify-traefik LB IP is used.
  -h, --help                  Show this help

Notes:
  - KUBECONFIG 環境変数で対象クラスタを指定してください
  - Namespace dify が存在しない場合は自動作成します
  - Secret は自動生成されます（lookup で既存値を優先）
  - This script will install Traefik Ingress Controller in dify namespace first,
    then install Dify with the Traefik's LoadBalancer IP.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-tag)
      image_tag="$2"
      shift 2
      ;;
    --openai-api-key)
      openai_api_key="$2"
      shift 2
      ;;
    --external-host)
      external_host="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${image_tag}" ]]; then
  echo "--image-tag is required" >&2
  exit 1
fi

if [[ -z "${DIFY_SECRET_KEY:-}" ]]; then
  echo "DIFY_SECRET_KEY is not set. Generating automatically..."
  export DIFY_SECRET_KEY="$(openssl rand -hex 32)"
fi

# Ensure namespace exists
kubectl get ns dify >/dev/null 2>&1 || kubectl create ns dify

# Add required Helm repositories
echo "Adding required Helm repositories..."
if ! helm repo list | grep -q "traefik"; then
  echo "  Adding traefik repository..."
  helm repo add traefik https://traefik.github.io/charts
fi
if ! helm repo list | grep -q "weaviate"; then
  echo "  Adding weaviate repository..."
  helm repo add weaviate https://weaviate.github.io/weaviate-helm
fi

# Update Helm repositories
echo "Updating Helm repositories..."
helm repo update

# Build Helm dependencies (including Traefik)
echo "Building Helm dependencies..."
helm dependency build "${CHART_DIR}"

# Get Traefik LB IP
get_dify_traefik_lb_ip() {
  local ip=""
  local svc_name="dify-traefik"
  
  echo "Waiting for dify-traefik LoadBalancer IP..." >&2
  for _ in {1..60}; do
    ip="$(kubectl get svc "${svc_name}" -n dify -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [[ -n "${ip}" ]]; then
      echo "${ip}"
      return 0
    fi
    sleep 5
  done
  echo "Timeout waiting for dify-traefik LoadBalancer IP" >&2
  exit 1
}

# PostgreSQL password must be fixed (not randomly generated)
# This ensures consistency across deployments, even when PVCs persist
# If you need to change the password, you must delete the PVC first
# TODO: 一時的に強制指定。本番環境では環境変数から取得するように戻すこと
if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
  export POSTGRES_PASSWORD='nutanix/4u'
  echo "WARNING: POSTGRES_PASSWORD not set, using default: nutanix/4u" >&2
fi

# Check if PVC exists and warn if password might be different
check_postgresql_pvc() {
  local pvc_name="data-dify-postgresql-0"
  if kubectl get pvc "${pvc_name}" -n dify >/dev/null 2>&1; then
    echo "WARNING: PostgreSQL PVC (${pvc_name}) already exists." >&2
    echo "If the password in the PVC differs from POSTGRES_PASSWORD, authentication will fail." >&2
    echo "To change the password, delete the PVC first:" >&2
    echo "  kubectl delete pvc -n dify ${pvc_name}" >&2
    echo "" >&2
    echo "Continuing with deployment (assuming password matches)..." >&2
  fi
}

# Set defaults for PostgreSQL/Redis/Weaviate
POSTGRES_USERNAME="${POSTGRES_USERNAME:-dify}"
POSTGRES_DATABASE="${POSTGRES_DATABASE:-dify}"

# Check PVC before deployment
check_postgresql_pvc
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
POSTGRES_SIZE="${POSTGRES_SIZE:-20Gi}"
REDIS_SIZE="${REDIS_SIZE:-8Gi}"
WEAVIATE_SIZE="${WEAVIATE_SIZE:-50Gi}"
DIFY_FILES_SIZE="${DIFY_FILES_SIZE:-20Gi}"

# Step 1: Install Traefik first (as subchart)
echo "Installing Traefik Ingress Controller..."
helm upgrade --install dify "${CHART_DIR}" -n dify \
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
  --set secrets.openaiApiKey="${openai_api_key}" \
        --set images.web.repository=langgenius/dify-web \
        --set images.web.tag="${image_tag}" \
        --set images.api.repository=langgenius/dify-api \
        --set images.api.tag="${image_tag}" \
        --set images.worker.repository=langgenius/dify-api \
        --set images.worker.tag="${image_tag}" \
        --set images.pluginDaemon.repository=langgenius/dify-plugin-daemon \
        --set images.pluginDaemon.tag="0.5.3-local" \
  --set storage.storageClassName=nutanix-volume \
  --set postgresql.auth.username="${POSTGRES_USERNAME}" \
  --set postgresql.auth.password="${POSTGRES_PASSWORD}" \
  --set postgresql.auth.database="${POSTGRES_DATABASE}" \
  --set postgresql.persistence.size="${POSTGRES_SIZE}" \
  --set postgresql.image.tag=16 \
  --set redis.auth.password="${REDIS_PASSWORD}" \
  --set redis.persistence.size="${REDIS_SIZE}" \
  --set redis.image.tag=7.2 \
  --set weaviate.service.type=ClusterIP \
  --set weaviate.grpcService.type=ClusterIP \
  --set weaviate.persistence.size="${WEAVIATE_SIZE}" \
  --set weaviate.persistence.storageClass=nutanix-volume \
  --set dify.fileStorage.size="${DIFY_FILES_SIZE}" \
  --wait --timeout=10m || {
    echo "Failed to install Traefik. Please check the logs." >&2
    exit 1
  }

# Step 2: Get Traefik LB IP
if [[ -z "${external_host}" ]]; then
  external_host="$(get_dify_traefik_lb_ip)"
fi

echo "Using external host: ${external_host}"

# Step 3: Upgrade with correct external.host
echo "Updating Dify configuration with Traefik LB IP..."
helm upgrade dify "${CHART_DIR}" -n dify \
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
  --set external.host="${external_host}" \
  --set secrets.openaiApiKey="${openai_api_key}" \
        --set images.web.repository=langgenius/dify-web \
        --set images.web.tag="${image_tag}" \
        --set images.api.repository=langgenius/dify-api \
        --set images.api.tag="${image_tag}" \
        --set images.worker.repository=langgenius/dify-api \
        --set images.worker.tag="${image_tag}" \
        --set images.pluginDaemon.repository=langgenius/dify-plugin-daemon \
        --set images.pluginDaemon.tag="0.5.3-local" \
  --set storage.storageClassName=nutanix-volume \
  --set postgresql.auth.username="${POSTGRES_USERNAME}" \
  --set postgresql.auth.password="${POSTGRES_PASSWORD}" \
  --set postgresql.auth.database="${POSTGRES_DATABASE}" \
  --set postgresql.persistence.size="${POSTGRES_SIZE}" \
  --set postgresql.image.tag=16 \
  --set redis.auth.password="${REDIS_PASSWORD}" \
  --set redis.persistence.size="${REDIS_SIZE}" \
  --set redis.image.tag=7.2 \
  --set weaviate.service.type=ClusterIP \
  --set weaviate.grpcService.type=ClusterIP \
  --set weaviate.persistence.size="${WEAVIATE_SIZE}" \
  --set weaviate.persistence.storageClass=nutanix-volume \
  --set dify.fileStorage.size="${DIFY_FILES_SIZE}"

echo ""
echo "Dify deployment completed."
echo ""
echo "Access Dify at: https://${external_host}/"
echo ""
echo "PostgreSQL credentials stored in Kubernetes Secret: dify-postgresql (namespace: dify)"
echo "  Username: ${POSTGRES_USERNAME}"
echo "  Database: ${POSTGRES_DATABASE}"
