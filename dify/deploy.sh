#!/usr/bin/env bash
set -euo pipefail

CHART_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TRAefik_namespace=""
traefik_service_name=""
external_host=""
image_tag=""
openai_api_key=""

usage() {
  cat <<EOF
Usage: $0 [options]

Options:
  --image-tag TAG             Dify image tag (e.g. 1.11.4) (required)
  --openai-api-key KEY        OpenAI API key (optional)
  --external-host HOST        External host (DNS or IP). If omitted, Traefik LB IP is used.
  --traefik-namespace NS      Traefik Service namespace (override auto-detect)
  --traefik-service-name NAME Traefik Service name (override auto-detect)
  -h, --help                  Show this help

Notes:
  - KUBECONFIG 環境変数で対象クラスタを指定してください
  - Namespace dify が存在しない場合は自動作成します
  - DIFY_SECRET_KEY 環境変数が未設定の場合は自動生成します
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
    --traefik-namespace)
      TRAefik_namespace="$2"
      shift 2
      ;;
    --traefik-service-name)
      traefik_service_name="$2"
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

kubectl get ns dify >/dev/null 2>&1 || kubectl create ns dify

detect_traefik_svc() {
  local ns name

  if [[ -n "${TRAefik_namespace}" ]] && [[ -n "${traefik_service_name}" ]]; then
    echo "${TRAefik_namespace} ${traefik_service_name}"
    return 0
  fi

  local line
  line="$(kubectl get svc -A -l app.kubernetes.io/name=kommander-traefik -o jsonpath='{range .items[0]}{.metadata.namespace} {.metadata.name}{end}' 2>/dev/null || true)"
  if [[ -z "${line}" ]]; then
    echo "Failed to auto-detect Traefik service. Please specify --traefik-namespace and --traefik-service-name." >&2
    exit 1
  fi
  echo "${line}"
}

traefik_info=($(detect_traefik_svc))
traefik_ns="${traefik_info[0]}"
traefik_svc="${traefik_info[1]}"

echo "Using Traefik service: ${traefik_ns}/${traefik_svc}"

get_lb_ip() {
  local ip=""
  echo "Waiting for Traefik LoadBalancer IP..."
  for _ in {1..60}; do
    ip="$(kubectl get svc "${traefik_svc}" -n "${traefik_ns}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [[ -n "${ip}" ]]; then
      echo "${ip}"
      return 0
    fi
    sleep 5
  done
  echo "Timeout waiting for Traefik LoadBalancer IP" >&2
  exit 1
}

if [[ -z "${external_host}" ]]; then
  external_host="$(get_lb_ip)"
fi

echo "Using external host: ${external_host}"

# Generate PostgreSQL password if not set
if [[ -z "${POSTGRES_PASSWORD:-}" ]]; then
  export POSTGRES_PASSWORD="$(openssl rand -base64 16 | tr -d "=+/" | cut -c1-16)"
fi

# Set defaults for PostgreSQL/Redis/Weaviate
POSTGRES_USERNAME="${POSTGRES_USERNAME:-dify}"
POSTGRES_DATABASE="${POSTGRES_DATABASE:-dify}"
REDIS_PASSWORD="${REDIS_PASSWORD:-}"
POSTGRES_SIZE="${POSTGRES_SIZE:-20Gi}"
REDIS_SIZE="${REDIS_SIZE:-8Gi}"
WEAVIATE_SIZE="${WEAVIATE_SIZE:-50Gi}"
DIFY_FILES_SIZE="${DIFY_FILES_SIZE:-20Gi}"

helm upgrade --install dify "${CHART_DIR}" -n dify \
  --set expose.ingressClassName=kommander-traefik \
  --set expose.path=/dify \
  --set external.scheme=https \
  --set external.host="${external_host}" \
  --set secrets.difySecretKey="${DIFY_SECRET_KEY}" \
  --set secrets.openaiApiKey="${openai_api_key}" \
  --set images.dify.repository=langgenius/dify \
  --set images.dify.tag="${image_tag}" \
  --set storage.storageClassName=nutanix-volume \
  --set postgresql.auth.username="${POSTGRES_USERNAME}" \
  --set postgresql.auth.password="${POSTGRES_PASSWORD}" \
  --set postgresql.auth.database="${POSTGRES_DATABASE}" \
  --set postgresql.persistence.size="${POSTGRES_SIZE}" \
  --set redis.auth.password="${REDIS_PASSWORD}" \
  --set redis.persistence.size="${REDIS_SIZE}" \
  --set weaviate.persistence.size="${WEAVIATE_SIZE}" \
  --set weaviate.persistence.storageClass=nutanix-volume \
  --set dify.fileStorage.size="${DIFY_FILES_SIZE}"

echo "Dify deployment completed."
echo ""
echo "PostgreSQL credentials stored in Kubernetes Secret: dify-postgresql (namespace: dify)"
echo "  Username: ${POSTGRES_USERNAME}"
echo "  Database: ${POSTGRES_DATABASE}"

