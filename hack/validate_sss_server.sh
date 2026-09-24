#!/bin/bash
# Server-side dry-run validation for SelectorSyncSet templates
# against a Hive shard via backplane.
#
# Expects to run inside a Prow multi-step job with:
#   - CLUSTER_PROFILE_DIR: path to OCM cluster profile credentials
#   - BACKPLANE_CLUSTER_ID: Hive cluster ID
#   - BACKPLANE_ELEVATE_REASON: Jira ticket for elevated access
#   - SHARED_DIR: shared directory between steps

set -o nounset
set -o errexit
set -o pipefail

log() { echo -e "\033[1m$(date "+%H:%M:%S") $*\033[0m" >&2; }

# ---- Install CLI tools (each step is a separate pod) ----
BIN="${HOME}/bin"
mkdir -p "${BIN}"
export PATH="${BIN}:${PATH}"

if ! command -v ocm &>/dev/null; then
    log "Installing ocm CLI"
    curl -sfSL "https://github.com/openshift-online/ocm-cli/releases/latest/download/ocm-linux-amd64" -o "${BIN}/ocm"
    chmod +x "${BIN}/ocm"
fi

if ! command -v ocm-backplane &>/dev/null; then
    log "Installing ocm-backplane v0.11.0"
    curl -sfSL "https://github.com/openshift/backplane-cli/releases/download/v0.11.0/ocm-backplane_0.11.0_Linux_x86_64.tar.gz" \
        | tar xzf - --no-same-owner -C "${BIN}" ocm-backplane
    chmod +x "${BIN}/ocm-backplane"
fi

log "ocm: $(ocm version 2>&1 | head -1), backplane: $(ocm-backplane version 2>&1 | head -1)"

# ---- Configure backplane proxy ----
mkdir -p "${HOME}/.config/backplane"
BACKPLANE_PROXY_URL="${BACKPLANE_PROXY_URL:-http://squid.corp.redhat.com:3128}"
printf '{"proxy-url":"%s"}\n' "${BACKPLANE_PROXY_URL}" > "${HOME}/.config/backplane/config.json"

# ---- OCM login using cluster profile credentials ----
set +x
SSO_CLIENT_ID=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-id" 2>/dev/null || true)
SSO_CLIENT_SECRET=$(cat "${CLUSTER_PROFILE_DIR}/sso-client-secret" 2>/dev/null || true)
OCM_TOKEN=$(cat "${CLUSTER_PROFILE_DIR}/ocm-token" 2>/dev/null || true)
OCM_LOGIN_ENV="${OCM_LOGIN_ENV:-production}"

if [[ -n "${SSO_CLIENT_ID}" && -n "${SSO_CLIENT_SECRET}" ]]; then
    log "Logging into OCM (${OCM_LOGIN_ENV}) with SSO credentials"
    ocm login --url "${OCM_LOGIN_ENV}" --client-id "${SSO_CLIENT_ID}" --client-secret "${SSO_CLIENT_SECRET}"
elif [[ -n "${OCM_TOKEN}" ]]; then
    log "Logging into OCM (${OCM_LOGIN_ENV}) with offline token"
    ocm login --url "${OCM_LOGIN_ENV}" --token "${OCM_TOKEN}"
else
    log "ERROR: No OCM credentials found in cluster profile dir ${CLUSTER_PROFILE_DIR}"
    exit 1
fi
set -x

# ---- Backplane login ----
export KUBECONFIG="${SHARED_DIR}/kubeconfig"
log "Backplane login to ${BACKPLANE_CLUSTER_ID}"
ocm-backplane login "${BACKPLANE_CLUSTER_ID}"
log "Connected to $(oc whoami --show-server) via backplane"

# ---- Generate SSS templates ----
log "Generating SSS templates via make"
make

# ---- Server-side dry-run validation ----
# The Makefile generates SSS template files in hack/
FAIL_COUNT=0
PASS_COUNT=0
TOTAL=0

for template in hack/00-osd-managed-cluster-config-*.yaml.tmpl; do
    [[ -f "${template}" ]] || continue
    TOTAL=$((TOTAL + 1))
    log "Validating ${template}"
    if ocm-backplane elevate "${BACKPLANE_ELEVATE_REASON}" -- oc apply --dry-run=server -f "${template}" 2>&1; then
        PASS_COUNT=$((PASS_COUNT + 1))
        log "  ✓ PASS: ${template}"
    else
        FAIL_COUNT=$((FAIL_COUNT + 1))
        log "  ✗ FAIL: ${template}"
    fi
done

log "Results: ${PASS_COUNT}/${TOTAL} passed, ${FAIL_COUNT} failed"

if [[ ${TOTAL} -eq 0 ]]; then
    log "ERROR: No SSS template files found in hack/"
    exit 1
fi

if [[ ${FAIL_COUNT} -gt 0 ]]; then
    log "ERROR: ${FAIL_COUNT} template(s) failed server-side dry-run validation"
    exit 1
fi

log "All ${TOTAL} SSS templates passed server-side dry-run validation"
