#!/usr/bin/env bash
# Build NanoClaw golden image containers and tag for the EV Gitea registry.
#
# Builds TWO images:
#   1. nanoclaw (orchestrator) — from container/Dockerfile.golden
#   2. nanoclaw-agent           — from container/Dockerfile (existing agent container)
#
# Usage:
#   ./scripts/build-golden.sh                    # Build both images, tag as :latest
#   ./scripts/build-golden.sh v1.2.10            # Build and tag with version
#   ./scripts/build-golden.sh v1.2.10 --push     # Build, tag, and push to registry
#
# Environment:
#   REGISTRY    - Override registry (default: git.escape-velocity-ventures.org)
#   ORG         - Override org/namespace (default: ev)
#   PLATFORM    - Override build platform (default: linux/amd64)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Configuration
REGISTRY="${REGISTRY:-git.escape-velocity-ventures.org}"
ORG="${ORG:-ev}"
TAG="${1:-latest}"
PUSH="${2:-}"
PLATFORM="${PLATFORM:-linux/amd64}"

# Image names
ORCHESTRATOR_IMAGE="${REGISTRY}/${ORG}/nanoclaw"
AGENT_IMAGE="${REGISTRY}/${ORG}/nanoclaw-agent"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

info() { echo -e "${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Verify we're in the right directory
if [ ! -f "${PROJECT_ROOT}/package.json" ]; then
    error "Cannot find package.json — run this script from the nanoclaw repo"
    exit 1
fi

if [ ! -f "${PROJECT_ROOT}/container/Dockerfile.golden" ]; then
    error "Cannot find container/Dockerfile.golden"
    exit 1
fi

if [ ! -f "${PROJECT_ROOT}/container/Dockerfile" ]; then
    error "Cannot find container/Dockerfile (agent container)"
    exit 1
fi

# Extract version from package.json for auto-tagging
PKG_VERSION=$(node -e "console.log(require('${PROJECT_ROOT}/package.json').version)" 2>/dev/null || echo "unknown")
info "NanoClaw version: ${PKG_VERSION}"

echo ""
echo "============================================"
echo "  NanoClaw Golden Image Build"
echo "============================================"
echo "  Registry:  ${REGISTRY}/${ORG}"
echo "  Tag:       ${TAG}"
echo "  Platform:  ${PLATFORM}"
echo "  Version:   ${PKG_VERSION}"
echo "============================================"
echo ""

# =============================================================================
# Step 1: Build the orchestrator image
# =============================================================================
info "Building orchestrator image..."

docker build \
    --platform "${PLATFORM}" \
    -f "${PROJECT_ROOT}/container/Dockerfile.golden" \
    -t "nanoclaw:${TAG}" \
    -t "nanoclaw:${PKG_VERSION}" \
    -t "${ORCHESTRATOR_IMAGE}:${TAG}" \
    -t "${ORCHESTRATOR_IMAGE}:${PKG_VERSION}" \
    "${PROJECT_ROOT}"

info "Orchestrator image built: ${ORCHESTRATOR_IMAGE}:${TAG}"

# =============================================================================
# Step 2: Build the agent image
# =============================================================================
info "Building agent image..."

docker build \
    --platform "${PLATFORM}" \
    -f "${PROJECT_ROOT}/container/Dockerfile" \
    -t "nanoclaw-agent:${TAG}" \
    -t "nanoclaw-agent:${PKG_VERSION}" \
    -t "${AGENT_IMAGE}:${TAG}" \
    -t "${AGENT_IMAGE}:${PKG_VERSION}" \
    "${PROJECT_ROOT}/container"

info "Agent image built: ${AGENT_IMAGE}:${TAG}"

# =============================================================================
# Step 3: Push if requested
# =============================================================================
if [ "${PUSH}" = "--push" ]; then
    info "Pushing images to ${REGISTRY}..."

    docker push "${ORCHESTRATOR_IMAGE}:${TAG}"
    docker push "${ORCHESTRATOR_IMAGE}:${PKG_VERSION}"
    docker push "${AGENT_IMAGE}:${TAG}"
    docker push "${AGENT_IMAGE}:${PKG_VERSION}"

    info "Images pushed successfully"
else
    echo ""
    info "Images built locally. To push to the registry:"
    echo "  docker push ${ORCHESTRATOR_IMAGE}:${TAG}"
    echo "  docker push ${ORCHESTRATOR_IMAGE}:${PKG_VERSION}"
    echo "  docker push ${AGENT_IMAGE}:${TAG}"
    echo "  docker push ${AGENT_IMAGE}:${PKG_VERSION}"
    echo ""
    info "Or re-run with --push:"
    echo "  ./scripts/build-golden.sh ${TAG} --push"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "============================================"
echo "  Build Complete"
echo "============================================"
echo ""
echo "  Orchestrator:"
echo "    Local:    nanoclaw:${TAG}"
echo "    Registry: ${ORCHESTRATOR_IMAGE}:${TAG}"
echo "    Registry: ${ORCHESTRATOR_IMAGE}:${PKG_VERSION}"
echo ""
echo "  Agent:"
echo "    Local:    nanoclaw-agent:${TAG}"
echo "    Registry: ${AGENT_IMAGE}:${TAG}"
echo "    Registry: ${AGENT_IMAGE}:${PKG_VERSION}"
echo ""
echo "  Deploy to k3s:"
echo "    cp deploy/k3s-manifest.yaml /var/lib/rancher/k3s/server/manifests/"
echo ""
echo "============================================"
