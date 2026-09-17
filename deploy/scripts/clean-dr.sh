#!/usr/bin/env bash
#
# nkp-snapshot-cleanup.sh
#
# Tears down everything created by an nkp-snapshot-dr.sh run:
#   Target cluster:  the restored app (deployment, service, pvc)
#   Target cluster:  the restore + replicated snapshot objects (asr, as)
#   Source cluster:  the original snapshot + its replication object
#
# Tested target OS: Rocky Linux 8/9 (plain bash, dnf-based dependency hint).
#
# Usage:
#   ./nkp-snapshot-cleanup.sh [options]
#
# Options:
#   -s, --source-context NAME       Source kubeconfig context (default: nkp-onprem-joburg-admin@nkp-onprem-joburg)
#   -t, --target-context NAME       Target kubeconfig context (default: nkp-nc2-azure-admin@nkp-nc2-azure)
#   -n, --namespace NAME            Namespace (default: snapwall)
#       --app-name NAME             Deployment/Service name to delete (default: snapwall)
#       --pvc-name NAME             PVC name to delete (default: snapwall-data)
#   -R, --restore-name NAME         ApplicationSnapshotRestore (asr) name (default: snapwall-restore-1)
#   -S, --snapshot-name NAME        ApplicationSnapshot (as) name, used on both clusters (default: snapwall-snapshot-1)
#       --replication-name NAME     ApplicationSnapshotReplication name on the source cluster.
#                                    If omitted, the script auto-discovers any replication object
#                                    named "asrepln-<snapshot-name>-*" on the source cluster.
#       --skip-app                  Don't delete the deploy/svc/pvc, only the snapshot/restore/replication objects
#       --skip-snapshots            Don't delete the asr/as/applicationsnapshot(replication) objects, only the app
#   -y, --yes                       Skip the confirmation prompt (needed for non-interactive/automated runs)
#       --dry-run                   Print what would be deleted, don't delete anything
#   -h, --help                      Show this help
#
# Deletions are tolerant of "already gone": a NotFound result is logged and
# treated as success, so the script is safe to re-run. A summary of what was
# deleted / skipped / failed is printed at the end, and the script exits
# non-zero only if a real (non-NotFound) deletion failure occurred.
#
# Requires: bash 4+, kubectl, and "kubectx" on PATH with the named contexts
# already configured.

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Defaults (override via flags or environment variables of the same name)
# ---------------------------------------------------------------------------
SOURCE_CONTEXT="${SOURCE_CONTEXT:-nkp-onprem-joburg-admin@nkp-onprem-joburg}"
TARGET_CONTEXT="${TARGET_CONTEXT:-nkp-nc2-azure-admin@nkp-nc2-azure}"
NAMESPACE="${NAMESPACE:-snapwall}"
APP_NAME="${APP_NAME:-snapwall}"
PVC_NAME="${PVC_NAME:-snapwall-data}"
RESTORE_NAME="${RESTORE_NAME:-snapwall-restore-1}"
SNAPSHOT_NAME="${SNAPSHOT_NAME:-snapwall-snapshot-1}"
REPLICATION_NAME="${REPLICATION_NAME:-}"
SKIP_APP=0
SKIP_SNAPSHOTS=0
ASSUME_YES=0
DRY_RUN=0

SCRIPT_NAME="$(basename "$0")"
LOG_FILE="${LOG_FILE:-/var/log/${SCRIPT_NAME%.sh}.log}"

# Tallies for the end-of-run summary.
DELETED=()
SKIPPED_NOTFOUND=()
FAILED=()

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
_log() {
    local level="$1"; shift
    local msg="$*"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S%z')"
    local line="[${ts}] [${level}] ${msg}"
    echo "${line}"
    if [[ -w "$(dirname "${LOG_FILE}")" || -w "${LOG_FILE}" ]] 2>/dev/null; then
        echo "${line}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
}
log_info()  { _log "INFO"  "$@"; }
log_warn()  { _log "WARN"  "$@"; }
log_error() { _log "ERROR" "$@" >&2; }

die() {
    log_error "$*"
    exit 1
}

on_error() {
    local exit_code=$?
    local line_no=$1
    log_error "Script failed unexpectedly at line ${line_no} (exit code ${exit_code})."
    exit "${exit_code}"
}
trap 'on_error $LINENO' ERR

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
    sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--source-context)   SOURCE_CONTEXT="$2"; shift 2 ;;
        -t|--target-context)   TARGET_CONTEXT="$2"; shift 2 ;;
        -n|--namespace)        NAMESPACE="$2"; shift 2 ;;
        --app-name)             APP_NAME="$2"; shift 2 ;;
        --pvc-name)              PVC_NAME="$2"; shift 2 ;;
        -R|--restore-name)     RESTORE_NAME="$2"; shift 2 ;;
        -S|--snapshot-name)    SNAPSHOT_NAME="$2"; shift 2 ;;
        --replication-name)     REPLICATION_NAME="$2"; shift 2 ;;
        --skip-app)              SKIP_APP=1; shift ;;
        --skip-snapshots)        SKIP_SNAPSHOTS=1; shift ;;
        -y|--yes)               ASSUME_YES=1; shift ;;
        --dry-run)               DRY_RUN=1; shift ;;
        -h|--help)              usage; exit 0 ;;
        *) die "Unknown option: $1 (use -h for help)" ;;
    esac
done

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
require_bin() {
    local bin="$1"
    local hint="${2:-}"
    if ! command -v "${bin}" >/dev/null 2>&1; then
        if [[ -n "${hint}" ]]; then
            die "Required command '${bin}' not found on PATH. ${hint}"
        else
            die "Required command '${bin}' not found on PATH."
        fi
    fi
}

preflight() {
    log_info "Running preflight checks..."
    require_bin kubectl "Install with: sudo dnf install -y kubectl."
    require_bin kubectx "Install with: sudo dnf install -y kubectx (or download the kubectx binary and put it on PATH)."
    log_info "Preflight checks passed."
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
switch_context() {
    local ctx="$1"
    log_info "Switching context to ${ctx}"
    local IFS=' '
    log_info "+ kubectx ${ctx}"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        return 0
    fi
    kubectx "${ctx}"
}

# Deletes one resource. Tolerant of NotFound. Records the outcome for the
# end-of-run summary. Never aborts the script on failure.
attempt_delete() {
    local resource_type="$1"
    local resource_name="$2"
    local label="${resource_type}/${resource_name}"

    log_info "Deleting ${label} in namespace '${NAMESPACE}'"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_info "+ kubectl -n ${NAMESPACE} delete ${resource_type} ${resource_name}"
        return 0
    fi

    local output
    if output="$(kubectl -n "${NAMESPACE}" delete "${resource_type}" "${resource_name}" 2>&1)"; then
        log_info "  ${output}"
        DELETED+=("${label}")
    else
        if grep -qiE "notfound|not found" <<< "${output}"; then
            log_warn "  ${label} not found (already deleted?) — treating as OK"
            SKIPPED_NOTFOUND+=("${label}")
        else
            log_error "  Failed to delete ${label}: ${output}"
            FAILED+=("${label}")
        fi
    fi
}

# Finds the ApplicationSnapshotReplication object for SNAPSHOT_NAME when the
# caller didn't pass --replication-name explicitly. The replicate step names
# it "asrepln-<snapshot-name>-<random-suffix>", so we match on that prefix.
discover_replication_name() {
    local prefix="asrepln-${SNAPSHOT_NAME}-"
    local matches
    matches="$(kubectl -n "${NAMESPACE}" get applicationsnapshotreplication.dataservices.nutanix.com \
        -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null \
        | grep -F "${prefix}" || true)"

    local count
    count="$(grep -c . <<< "${matches}" 2>/dev/null || echo 0)"
    if [[ -z "${matches}" ]]; then
        log_warn "No applicationsnapshotreplication found matching '${prefix}*' in namespace '${NAMESPACE}'. Nothing to delete for replication."
        REPLICATION_NAME=""
    elif [[ "${count}" -gt 1 ]]; then
        log_warn "Multiple applicationsnapshotreplication objects match '${prefix}*':"
        log_warn "${matches}"
        log_warn "Deleting all of them. Pass --replication-name to target just one instead."
        REPLICATION_NAME="${matches}"
    else
        REPLICATION_NAME="${matches}"
        log_info "Discovered replication object: ${REPLICATION_NAME}"
    fi
}

confirm() {
    if [[ "${ASSUME_YES}" -eq 1 || "${DRY_RUN}" -eq 1 ]]; then
        return 0
    fi
    echo
    echo "About to delete, in namespace '${NAMESPACE}':"
    [[ "${SKIP_APP}" -eq 0 ]] && echo "  Target (${TARGET_CONTEXT}): deployment/${APP_NAME}, service/${APP_NAME}, pvc/${PVC_NAME}"
    [[ "${SKIP_SNAPSHOTS}" -eq 0 ]] && {
        echo "  Target (${TARGET_CONTEXT}): asr/${RESTORE_NAME}, as/${SNAPSHOT_NAME}"
        echo "  Source (${SOURCE_CONTEXT}): applicationsnapshot/${SNAPSHOT_NAME}, applicationsnapshotreplication (auto-discovered unless --replication-name is set)"
    }
    read -r -p "Proceed? [y/N] " reply
    case "${reply}" in
        [yY]|[yY][eE][sS]) return 0 ;;
        *) die "Aborted by user." ;;
    esac
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log_info "=== NKP snapshot cleanup starting (dry-run: ${DRY_RUN}) ==="
    log_info "Source context: ${SOURCE_CONTEXT}, Target context: ${TARGET_CONTEXT}"
    log_info "Namespace: ${NAMESPACE}, App: ${APP_NAME}, PVC: ${PVC_NAME}"
    log_info "Restore: ${RESTORE_NAME}, Snapshot: ${SNAPSHOT_NAME}, Replication: ${REPLICATION_NAME:-<auto-discover>}"

    preflight
    confirm

    if [[ "${SKIP_APP}" -eq 0 ]]; then
        switch_context "${TARGET_CONTEXT}"
        attempt_delete "deploy" "${APP_NAME}"
        attempt_delete "svc" "${APP_NAME}"
        attempt_delete "pvc" "${PVC_NAME}"
    else
        log_info "Skipping app deletion (--skip-app)."
    fi

    if [[ "${SKIP_SNAPSHOTS}" -eq 0 ]]; then
        switch_context "${TARGET_CONTEXT}"
        attempt_delete "asr" "${RESTORE_NAME}"
        attempt_delete "as" "${SNAPSHOT_NAME}"

        switch_context "${SOURCE_CONTEXT}"
        attempt_delete "applicationsnapshot" "${SNAPSHOT_NAME}"

        if [[ -z "${REPLICATION_NAME}" && "${DRY_RUN}" -eq 0 ]]; then
            discover_replication_name
        fi
        if [[ -n "${REPLICATION_NAME}" ]]; then
            while IFS= read -r repl_name; do
                [[ -n "${repl_name}" ]] && attempt_delete "applicationsnapshotreplication" "${repl_name}"
            done <<< "${REPLICATION_NAME}"
        elif [[ "${DRY_RUN}" -eq 1 ]]; then
            log_info "+ (dry-run) would auto-discover and delete applicationsnapshotreplication matching asrepln-${SNAPSHOT_NAME}-*"
        fi
    else
        log_info "Skipping snapshot/restore/replication cleanup (--skip-snapshots)."
    fi

    echo
    log_info "=== Cleanup summary ==="
    log_info "Deleted (${#DELETED[@]}): ${DELETED[*]:-none}"
    log_info "Already gone (${#SKIPPED_NOTFOUND[@]}): ${SKIPPED_NOTFOUND[*]:-none}"
    log_info "Failed (${#FAILED[@]}): ${FAILED[*]:-none}"

    if [[ "${#FAILED[@]}" -gt 0 ]]; then
        die "=== NKP snapshot cleanup completed with failures ==="
    fi
    log_info "=== NKP snapshot cleanup completed successfully ==="
}

main "$@"