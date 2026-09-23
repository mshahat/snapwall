#!/usr/bin/env bash
#
# nkp-snapshot-dr.sh
#
# Creates an NDK application snapshot on a source NKP cluster, replicates it
# to a target cluster, then performs a restore on the target.
#
# Tested target OS: Rocky Linux 8/9 (uses bash, no distro-specific syscalls,
# but the dependency check below assumes dnf as the package manager).
#
# Usage:
#   ./nkp-snapshot-dr.sh [options]
#
# Options:
#   -s, --source-context NAME       Source kubeconfig context (default: nkp-onprem-jeddah-admin@nkp-onprem-jeddah)
#   -t, --target-context NAME       Target kubeconfig context (default: nkp-nc2-azure-admin@nkp-nc2-azure)
#   -n, --namespace NAME            Namespace (default: snapwall)
#   -a, --application NAME          Application name (default: snapwall)
#   -S, --snapshot-name NAME        Snapshot name (default: snapwall-snapshot-1)
#   -R, --restore-name NAME         Restore name (default: snapwall-restore-1)
#   -T, --replication-target NAME   Replication target name (default: nkp-nc2-azure)
#   -w, --wait-timeout SECONDS      Max seconds to wait on each async step (default: 600)
#       --snapshot-status-jsonpath  jsonpath expr for snapshot readiness (default: {.status.readyToUse})
#       --replication-status-jsonpath  jsonpath expr for replication status (default: conditions[type==Available].status)
#       --snapshot-resource-type    Resource type for snapshot status polling (default: applicationsnapshot.dataservices.nutanix.com)
#       --replication-resource-type Resource type for replication status polling (default: applicationsnapshotreplication.dataservices.nutanix.com)
#       --replication-resource-name Resource name for replication status polling (default: same as --snapshot-name)
#       --restore-status-jsonpath   jsonpath expr for restore readiness (default: {.status.completed})
#       --restore-resource-type     Resource type for restore status polling (default: applicationsnapshotrestore.dataservices.nutanix.com)
#       --ready-values LIST         Comma-separated values that count as "ready" (default: true,True,Ready,Completed,Available,Synced,Succeeded)
#       --skip-wait                 Don't poll for snapshot/replication completion, just fire and continue
#       --dry-run                   Print the commands that would run, don't execute them
#   -h, --help                      Show this help
#
# Requires: bash 4+, kubectl, the kubectl "ndk" plugin, and "kubectx"
# on PATH with the named contexts already configured.

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Defaults (override via flags or environment variables of the same name)
# ---------------------------------------------------------------------------
SOURCE_CONTEXT="${SOURCE_CONTEXT:-nkp-onprem-jeddah-admin@nkp-onprem-jeddah}"
TARGET_CONTEXT="${TARGET_CONTEXT:-nkp-nc2-azure-admin@nkp-nc2-azure}"
NAMESPACE="${NAMESPACE:-snapwall}"
APPLICATION="${APPLICATION:-snapwall}"
SNAPSHOT_NAME="${SNAPSHOT_NAME:-snapwall-snapshot-1}"
RESTORE_NAME="${RESTORE_NAME:-snapwall-restore-1}"
REPLICATION_TARGET="${REPLICATION_TARGET:-nkp-nc2-azure}"
WAIT_TIMEOUT="${WAIT_TIMEOUT:-600}"
SKIP_WAIT=0
DRY_RUN=0
# Field paths used to poll readiness. Defaults are a best guess — if your
# NDK CRD uses different field names, override with --snapshot-status-jsonpath
# / --replication-status-jsonpath, or check the diagnostic dump the script
# prints on the first poll of each wait loop.
SNAPSHOT_STATUS_JSONPATH="${SNAPSHOT_STATUS_JSONPATH:-{.status.readyToUse}}"
# Replication status lives in a conditions array, not a flat field, e.g.:
#   status.conditions[] where type=="Available" and status=="True"
# (reason on that same condition is "ReplicationComplete"). The jsonpath
# below pulls just the "status" value of the Available condition.
REPLICATION_STATUS_JSONPATH="${REPLICATION_STATUS_JSONPATH:-{.status.conditions[?(@.type==\"Available\")].status}}"
READY_VALUES="${READY_VALUES:-true,True,Ready,Completed,Available,Synced,Succeeded}"
# Status polling uses plain "kubectl get" against this resource type rather
# than "kubectl ndk get", because the ndk plugin's own get subcommand does
# not reliably support -o jsonpath. This is the type kubectl printed after
# "create snapshot" (e.g. "applicationsnapshot.dataservices.nutanix.com/NAME created").
SNAPSHOT_RESOURCE_TYPE="${SNAPSHOT_RESOURCE_TYPE:-applicationsnapshot.dataservices.nutanix.com}"
# The replicate step creates a separate resource kind for tracking
# replication progress. Override if your cluster's actual kind/name differs
# (check with: kubectl get applicationsnapshotreplication.dataservices.nutanix.com -n <ns>).
REPLICATION_RESOURCE_TYPE="${REPLICATION_RESOURCE_TYPE:-applicationsnapshotreplication.dataservices.nutanix.com}"
REPLICATION_RESOURCE_NAME="${REPLICATION_RESOURCE_NAME:-${SNAPSHOT_NAME}}"
# "kubectl ndk perform restore" creates its resource with exactly the given
# --restore-name (unlike replicate, it does not append a generated suffix),
# so no name auto-detection is needed here — just the type and status field.
# Confirmed field: status.completed = true when the restore is done.
RESTORE_RESOURCE_TYPE="${RESTORE_RESOURCE_TYPE:-applicationsnapshotrestore.dataservices.nutanix.com}"
RESTORE_STATUS_JSONPATH="${RESTORE_STATUS_JSONPATH:-{.status.completed}}"

SCRIPT_NAME="$(basename "$0")"
LOG_FILE="${LOG_FILE:-/var/log/${SCRIPT_NAME%.sh}.log}"

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
    # Fall back gracefully if LOG_FILE's directory isn't writable
    # (e.g. running as a non-root user without /var/log access).
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
    log_error "Script failed at line ${line_no} (exit code ${exit_code})."
    exit "${exit_code}"
}
trap 'on_error $LINENO' ERR

run() {
    # Wrapper so --dry-run can short-circuit any command we execute.
    # Global IFS is set to $'\n\t' below, so "$*" here must locally
    # override IFS to a plain space or every argument prints on its own line.
    local IFS=' '
    log_info "+ $*"
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        return 0
    fi
    "$@"
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
usage() {
    sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -s|--source-context)      SOURCE_CONTEXT="$2"; shift 2 ;;
        -t|--target-context)      TARGET_CONTEXT="$2"; shift 2 ;;
        -n|--namespace)           NAMESPACE="$2"; shift 2 ;;
        -a|--application)         APPLICATION="$2"; shift 2 ;;
        -S|--snapshot-name)       SNAPSHOT_NAME="$2"; shift 2 ;;
        -R|--restore-name)        RESTORE_NAME="$2"; shift 2 ;;
        -T|--replication-target)  REPLICATION_TARGET="$2"; shift 2 ;;
        -w|--wait-timeout)        WAIT_TIMEOUT="$2"; shift 2 ;;
        --snapshot-status-jsonpath)     SNAPSHOT_STATUS_JSONPATH="$2"; shift 2 ;;
        --replication-status-jsonpath)  REPLICATION_STATUS_JSONPATH="$2"; shift 2 ;;
        --snapshot-resource-type)       SNAPSHOT_RESOURCE_TYPE="$2"; shift 2 ;;
        --replication-resource-type)    REPLICATION_RESOURCE_TYPE="$2"; shift 2 ;;
        --replication-resource-name)    REPLICATION_RESOURCE_NAME="$2"; REPLICATION_RESOURCE_NAME_SET=1; shift 2 ;;
        --restore-status-jsonpath)      RESTORE_STATUS_JSONPATH="$2"; shift 2 ;;
        --restore-resource-type)        RESTORE_RESOURCE_TYPE="$2"; shift 2 ;;
        --ready-values)                 READY_VALUES="$2"; shift 2 ;;
        --skip-wait)              SKIP_WAIT=1; shift ;;
        --dry-run)                DRY_RUN=1; shift ;;
        -h|--help)                usage; exit 0 ;;
        *) die "Unknown option: $1 (use -h for help)" ;;
    esac
done

# If --snapshot-name was overridden but --replication-resource-name was not,
# keep the replication lookup name in sync with the (new) snapshot name.
if [[ "${REPLICATION_RESOURCE_NAME_SET:-0}" -eq 0 ]]; then
    REPLICATION_RESOURCE_NAME="${SNAPSHOT_NAME}"
fi

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

    require_bin kubectl "Install with: sudo dnf install -y kubectl (or via the vendor repo you use for kubectl on Rocky)."
    require_bin kubectx "Install with: sudo dnf install -y kubectx (or download the kubectx binary and put it on PATH)."

    if ! kubectl ndk --help >/dev/null 2>&1; then
        die "The 'kubectl ndk' plugin does not appear to be installed/on PATH. Install the NDK kubectl plugin before running this script."
    fi

    log_info "Preflight checks passed."
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------
switch_context() {
    local ctx="$1"
    log_info "Switching context to ${ctx}"
    run kubectx "${ctx}"
}

create_snapshot() {
    log_info "Creating snapshot '${SNAPSHOT_NAME}' for application '${APPLICATION}' in namespace '${NAMESPACE}'"
    run kubectl ndk create snapshot "${SNAPSHOT_NAME}" -n "${NAMESPACE}" --application="${APPLICATION}"
}

is_ready_value() {
    local value="$1"
    local IFS=','
    local candidate
    for candidate in ${READY_VALUES}; do
        [[ "${value}" == "${candidate}" ]] && return 0
    done
    return 1
}

# Overwrites the current terminal line in place (for polling loops), and
# still appends a normal newline-terminated entry to the log file so the
# file keeps a full history even though the terminal only shows the latest.
_progress_in_progress=0
progress_update() {
    local msg="$1"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S%z')"
    local line="[${ts}] [INFO] ${msg}"
    printf '\r%-160s' "${line}"
    if [[ -w "$(dirname "${LOG_FILE}")" || -w "${LOG_FILE}" ]] 2>/dev/null; then
        echo "${line}" >> "${LOG_FILE}" 2>/dev/null || true
    fi
    _progress_in_progress=1
}

end_progress() {
    if [[ "${_progress_in_progress}" -eq 1 ]]; then
        printf '\n'
        _progress_in_progress=0
    fi
}

wait_for_snapshot() {
    if [[ "${SKIP_WAIT}" -eq 1 || "${DRY_RUN}" -eq 1 ]]; then
        log_info "Skipping wait for snapshot readiness."
        return 0
    fi
    log_info "Waiting up to ${WAIT_TIMEOUT}s for snapshot '${SNAPSHOT_NAME}' to become ready (${SNAPSHOT_RESOURCE_TYPE}, jsonpath: ${SNAPSHOT_STATUS_JSONPATH})..."
    local elapsed=0
    local interval=5
    local status=""
    local dumped_diagnostics=0
    while (( elapsed < WAIT_TIMEOUT )); do
        status="$(kubectl get "${SNAPSHOT_RESOURCE_TYPE}" "${SNAPSHOT_NAME}" -n "${NAMESPACE}" -o jsonpath="${SNAPSHOT_STATUS_JSONPATH}" 2>/dev/null || true)"
        if [[ -n "${status}" ]] && is_ready_value "${status}"; then
            end_progress
            log_info "Snapshot is ready (status: ${status})."
            return 0
        fi
        if [[ -z "${status}" && "${dumped_diagnostics}" -eq 0 ]]; then
            end_progress
            log_warn "Status field at '${SNAPSHOT_STATUS_JSONPATH}' is empty. Dumping full .status for diagnosis:"
            kubectl get "${SNAPSHOT_RESOURCE_TYPE}" "${SNAPSHOT_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status}{"\n"}' 2>/dev/null | tee -a "${LOG_FILE}" 2>/dev/null || true
            log_warn "If a field above looks like the real readiness indicator, re-run with --snapshot-status-jsonpath '{.status.<field>}'."
            dumped_diagnostics=1
        fi
        sleep "${interval}"
        elapsed=$(( elapsed + interval ))
        progress_update "  ...still waiting (status: ${status:-empty}, ${elapsed}s elapsed)"
    done
    end_progress
    die "Timed out after ${WAIT_TIMEOUT}s waiting for snapshot '${SNAPSHOT_NAME}' to become ready. Check --snapshot-status-jsonpath against the diagnostic dump above."
}

replicate_snapshot() {
    log_info "Replicating snapshot '${SNAPSHOT_NAME}' to target '${REPLICATION_TARGET}'"

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_info "+ kubectl ndk replicate snapshot ${SNAPSHOT_NAME} -n ${NAMESPACE} --replication-target=${REPLICATION_TARGET}"
        return 0
    fi

    # "kubectl ndk replicate" generates its own resource name for the
    # replication object (observed format: asrepln-<snapshot-name>-<suffix>),
    # it does not reuse the snapshot's name. That name only exists in this
    # command's own "<type>/<name> created" output, so capture it here
    # (while still streaming it to the terminal) rather than guessing.
    local IFS=' '
    log_info "+ kubectl ndk replicate snapshot ${SNAPSHOT_NAME} -n ${NAMESPACE} --replication-target=${REPLICATION_TARGET}"
    local output_file
    output_file="$(mktemp)"
    kubectl ndk replicate snapshot "${SNAPSHOT_NAME}" -n "${NAMESPACE}" --replication-target="${REPLICATION_TARGET}" | tee "${output_file}"

    local created_line
    created_line="$(grep -F "${REPLICATION_RESOURCE_TYPE}/" "${output_file}" | grep -F " created" | head -n1)"
    rm -f "${output_file}"

    if [[ "${REPLICATION_RESOURCE_NAME_SET:-0}" -eq 1 ]]; then
        log_info "Using explicitly-set replication resource name: ${REPLICATION_RESOURCE_NAME}"
    elif [[ -n "${created_line}" ]]; then
        local detected_name="${created_line#*/}"
        detected_name="${detected_name% created}"
        REPLICATION_RESOURCE_NAME="${detected_name}"
        log_info "Detected replication resource name: ${REPLICATION_RESOURCE_NAME}"
    else
        log_warn "Could not auto-detect the replication resource name from command output; falling back to '${REPLICATION_RESOURCE_NAME}'. If waiting stalls, pass the real name with --replication-resource-name (see it via: kubectl get ${REPLICATION_RESOURCE_TYPE} -n ${NAMESPACE})."
    fi
}

wait_for_replication() {
    if [[ "${SKIP_WAIT}" -eq 1 || "${DRY_RUN}" -eq 1 ]]; then
        log_info "Skipping wait for replication completion."
        return 0
    fi
    log_info "Waiting up to ${WAIT_TIMEOUT}s for replication of '${SNAPSHOT_NAME}' to complete (${REPLICATION_RESOURCE_TYPE}/${REPLICATION_RESOURCE_NAME}, jsonpath: ${REPLICATION_STATUS_JSONPATH})..."
    local elapsed=0
    local interval=5
    local status=""
    local dumped_diagnostics=0
    while (( elapsed < WAIT_TIMEOUT )); do
        status="$(kubectl get "${REPLICATION_RESOURCE_TYPE}" "${REPLICATION_RESOURCE_NAME}" -n "${NAMESPACE}" -o jsonpath="${REPLICATION_STATUS_JSONPATH}" 2>/dev/null || true)"
        if [[ -n "${status}" ]] && is_ready_value "${status}"; then
            end_progress
            log_info "Replication complete (status: ${status})."
            return 0
        fi
        if [[ -z "${status}" && "${dumped_diagnostics}" -eq 0 ]]; then
            end_progress
            log_warn "Status field at '${REPLICATION_STATUS_JSONPATH}' is empty on ${REPLICATION_RESOURCE_TYPE}/${REPLICATION_RESOURCE_NAME}. Dumping full .status for diagnosis:"
            kubectl get "${REPLICATION_RESOURCE_TYPE}" "${REPLICATION_RESOURCE_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status}{"\n"}' 2>/dev/null | tee -a "${LOG_FILE}" 2>/dev/null || true
            log_warn "If the resource itself wasn't found, check the real kind/name with: kubectl get applicationsnapshotreplication.dataservices.nutanix.com -n ${NAMESPACE}"
            log_warn "Then override with --replication-resource-type / --replication-resource-name / --replication-status-jsonpath as needed."
            dumped_diagnostics=1
        fi
        sleep "${interval}"
        elapsed=$(( elapsed + interval ))
        progress_update "  ...still waiting (status: ${status:-empty}, ${elapsed}s elapsed)"
    done
    end_progress
    die "Timed out after ${WAIT_TIMEOUT}s waiting for replication of '${SNAPSHOT_NAME}' to complete. Check --replication-status-jsonpath against the diagnostic dump above."
}

perform_restore() {
    log_info "Performing restore '${RESTORE_NAME}' from snapshot '${SNAPSHOT_NAME}' in namespace '${NAMESPACE}'"
    run kubectl ndk perform restore "${RESTORE_NAME}" --application-snapshot-name="${SNAPSHOT_NAME}" -n "${NAMESPACE}"
}

wait_for_restore() {
    if [[ "${SKIP_WAIT}" -eq 1 || "${DRY_RUN}" -eq 1 ]]; then
        log_info "Skipping wait for restore completion."
        return 0
    fi
    log_info "Waiting up to ${WAIT_TIMEOUT}s for restore '${RESTORE_NAME}' to complete (${RESTORE_RESOURCE_TYPE}, jsonpath: ${RESTORE_STATUS_JSONPATH})..."
    local elapsed=0
    local interval=5
    local status=""
    local dumped_diagnostics=0
    while (( elapsed < WAIT_TIMEOUT )); do
        status="$(kubectl get "${RESTORE_RESOURCE_TYPE}" "${RESTORE_NAME}" -n "${NAMESPACE}" -o jsonpath="${RESTORE_STATUS_JSONPATH}" 2>/dev/null || true)"
        if [[ -n "${status}" ]] && is_ready_value "${status}"; then
            end_progress
            log_info "Restore complete (status: ${status})."
            return 0
        fi
        if [[ -z "${status}" && "${dumped_diagnostics}" -eq 0 ]]; then
            end_progress
            log_warn "Status field at '${RESTORE_STATUS_JSONPATH}' is empty on ${RESTORE_RESOURCE_TYPE}/${RESTORE_NAME}. Dumping full .status for diagnosis:"
            kubectl get "${RESTORE_RESOURCE_TYPE}" "${RESTORE_NAME}" -n "${NAMESPACE}" -o jsonpath='{.status}{"\n"}' 2>/dev/null | tee -a "${LOG_FILE}" 2>/dev/null || true
            log_warn "If a field above looks like the real readiness indicator, re-run with --restore-status-jsonpath '{.status.<field>}'."
            dumped_diagnostics=1
        fi
        sleep "${interval}"
        elapsed=$(( elapsed + interval ))
        progress_update "  ...still waiting (status: ${status:-empty}, ${elapsed}s elapsed)"
    done
    end_progress
    die "Timed out after ${WAIT_TIMEOUT}s waiting for restore '${RESTORE_NAME}' to complete. Check --restore-status-jsonpath against the diagnostic dump above."
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    log_info "=== NKP snapshot DR run starting (dry-run: ${DRY_RUN}) ==="
    log_info "Source context: ${SOURCE_CONTEXT}"
    log_info "Target context: ${TARGET_CONTEXT}"
    log_info "Namespace: ${NAMESPACE}, Application: ${APPLICATION}"
    log_info "Snapshot: ${SNAPSHOT_NAME}, Replication target: ${REPLICATION_TARGET}, Restore: ${RESTORE_NAME}"
    log_info "Snapshot status jsonpath: ${SNAPSHOT_STATUS_JSONPATH}, Replication status jsonpath: ${REPLICATION_STATUS_JSONPATH}, Ready values: ${READY_VALUES}"
    log_info "Status polling resource type: ${SNAPSHOT_RESOURCE_TYPE}"
    log_info "Replication status polling: ${REPLICATION_RESOURCE_TYPE}/${REPLICATION_RESOURCE_NAME}"
    log_info "Restore status polling: ${RESTORE_RESOURCE_TYPE}/${RESTORE_NAME}, jsonpath: ${RESTORE_STATUS_JSONPATH}"

    preflight

    switch_context "${SOURCE_CONTEXT}"
    create_snapshot
    wait_for_snapshot
    replicate_snapshot
    wait_for_replication

    switch_context "${TARGET_CONTEXT}"
    perform_restore
    wait_for_restore

    log_info "=== NKP snapshot DR run completed successfully ==="
}

main "$@"