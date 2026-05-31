#!/bin/sh
#
# ============================================================================
# VBox Live Snapshot Backup Script
# ============================================================================
#
# FreeBSD 15 / VirtualBox 7.2
#
# Werking:
#
#   1. Live snapshot maken
#   2. VBox schrijft nieuwe wijzigingen naar delta disk
#   3. Alleen BASE disks + VM config backuppen
#   4. Snapshot directory uitsluiten
#   5. tar -> pigz -> openssl encryptie
#   6. Oude backup vervangen
#   7. Snapshot verwijderen / mergen
#
# Belangrijk:
#
#   - Draaien ALS de VBox gebruiker
#   - NIET als root
#
# Voorbeeld:
#
#   su - DC03 -c /usr/local/sbin/vbox-backup.sh
#
# ============================================================================
# REQUIREMENTS
# ============================================================================
#
# pkg install pigz
#
# ============================================================================
# PASSWORD STORAGE
# ============================================================================
#
# Wachtwoord binary opslaan:
#
#   mkdir -p ~/.config/vbox-backup
#
#   printf 'MijnSuperSecretPassword123!' \
#       | openssl enc -aes-256-cbc -pbkdf2 -salt \
#       -out ~/.config/vbox-backup/pass.bin
#
# Rechten:
#
#   chmod 700 ~/.config/vbox-backup
#   chmod 600 ~/.config/vbox-backup/pass.bin
#
# ============================================================================
# RESTORE
# ============================================================================
#
# openssl enc -d -aes-256-cbc -pbkdf2 \
#   -in DC03.tar.gz.enc \
#   -pass file:/tmp/pass.txt | pigz -d | tar xpf -
#
# ============================================================================
#

BACKUP_MODE="live"
ORIGINAL_VM_STATE=""
NEEDS_VM_RESTART="0"

##############################################################################
# CONFIG
##############################################################################

VM_NAME="$(whoami)"

VM_PATH="/tank/vm/${VM_NAME}"

BACKUP_DIR="/mnt/65tb/vbox-backups"

TMP_BACKUP="${BACKUP_DIR}/${VM_NAME}.tar.gz.enc.tmp"
FINAL_BACKUP="${BACKUP_DIR}/${VM_NAME}.tar.gz.enc"

LOG_DIR="/home/${VM_NAME}/logs"
LOG_FILE="${LOG_DIR}/vbox-backup.log"

PASS_STORE="/home/${VM_NAME}/.config/vbox-backup/pass.bin"

SNAPSHOT_NAME="backup-running"

PIGZ_THREADS="8"

MAX_LOG_SIZE_MB="10"
MAX_LOG_FILES="5"

MIN_BACKUP_SIZE_MB="100"

##############################################################################
# FUNCTIONS
##############################################################################

usage()
{
    cat << EOF
Usage: $0 [live|savestate|poweroff]

live       Live snapshot backup (default)
savestate  Save VM state before backup and restart afterwards
poweroff   Shutdown VM before backup and restart afterwards
EOF
}

log()
{
    NOW="$(date '+%Y-%m-%d %H:%M:%S')"

    mkdir -p "${LOG_DIR}"

    echo "[${NOW}] $1" | tee -a "${LOG_FILE}"
}

rotate_logs()
{
    mkdir -p "${LOG_DIR}"

    [ ! -f "${LOG_FILE}" ] && return

    LOG_SIZE_MB=$(du -m "${LOG_FILE}" | awk '{print $1}')

    [ "${LOG_SIZE_MB}" -lt "${MAX_LOG_SIZE_MB}" ] && return

    i="${MAX_LOG_FILES}"

    while [ "${i}" -gt 1 ]
    do
        PREV=$((i - 1))

        if [ -f "${LOG_FILE}.${PREV}.gz" ]; then
            mv \
                "${LOG_FILE}.${PREV}.gz" \
                "${LOG_FILE}.${i}.gz"
        fi

        i="${PREV}"
    done

    gzip -c "${LOG_FILE}" > "${LOG_FILE}.1.gz"

    : > "${LOG_FILE}"
}

cleanup_temp()
{
    rm -f "${TMP_BACKUP}"
}

cleanup_error()
{
    cleanup_temp

    if snapshot_exists; then
        remove_snapshot
    fi

    restore_vm_state

    exit 1
}

require_non_root()
{
    if [ "$(id -u)" -eq 0 ]; then
        log "ERROR: Script may not run as root"
        cleanup_error
    else
        log "Pass: Non-Root User detected: $(id -u)"
    fi
}

check_paths()
{
    log "Checking if VM Path exists ...."
    if [ -d "${VM_PATH}" ]; then
        log "PASS: VM path correct: ${VM_PATH}"
    else
        log "ERROR: VM path missing: ${VM_PATH}"
        cleanup_error
    fi

    log "Check if Backup Directory exists ... (When this takes to long, the path is not reachable)"
    if [ -d "${BACKUP_DIR}" ]; then
        log "PASS: Backup dir correct: ${BACKUP_DIR}"
    else
        log "ERROR: Backup dir missing: ${BACKUP_DIR}"
        cleanup_error
    fi

    log "Check if the password store exists ..."
    if [ -f "${PASS_STORE}" ]; then
        log "PASS: Password store found: ${PASS_STORE}"
    else
        log "ERROR: Password store missing: ${PASS_STORE}"
        cleanup_error
    fi
}

prepare_vm_for_backup()
{
    ORIGINAL_VM_STATE=$(
        VBoxManage showvminfo "${VM_NAME}" --machinereadable | \
        grep '^VMState=' | cut -d'"' -f2
    )

    log "Current VM state: ${ORIGINAL_VM_STATE}"

    case "${BACKUP_MODE}" in

        live)

            log "Backup mode: LIVE"

            ;;

        savestate)

            if [ "${ORIGINAL_VM_STATE}" = "running" ]; then

                log "Saving VM state"

                VBoxManage controlvm "${VM_NAME}" savestate \
                    >> "${LOG_FILE}" 2>&1

                if [ $? -ne 0 ]; then
                    log "ERROR: Failed to save VM state"
                    cleanup_error
                fi

                NEEDS_VM_RESTART="1"
            fi

            ;;

        poweroff)

            if [ "${ORIGINAL_VM_STATE}" = "running" ]; then

                log "Powering off VM using ACPI"

                VBoxManage controlvm "${VM_NAME}" acpipowerbutton \
                    >> "${LOG_FILE}" 2>&1

                while :
                do
                    VM_STATE=$(
                        VBoxManage showvminfo "${VM_NAME}" --machinereadable |
                        grep '^VMState=' | cut -d'"' -f2
                    )

                    [ "${VM_STATE}" = "poweroff" ] && break

                    sleep 5
                done

                sleep 120

                NEEDS_VM_RESTART="1"
            fi

            ;;

        *)

            log "ERROR: Invalid BACKUP_MODE: ${BACKUP_MODE}"
            cleanup_error
            ;;
    esac
}

restore_vm_state()
{
    if [ "${NEEDS_VM_RESTART}" != "1" ]; then
        log "No VM restart required"
        return
    fi

    log "Starting VM"

    VBoxManage startvm "${VM_NAME}" --type headless \
        >> "${LOG_FILE}" 2>&1

    if [ $? -ne 0 ]; then
        log "ERROR: Failed to start VM"
        cleanup_error
    fi

    log "VM started successfully"
}

check_vbox_access()
{
    VBoxManage list vms >/dev/null 2>&1

    if [ $? -ne 0 ]; then
        log "ERROR: VBoxManage failed"
        cleanup_error
    fi
}

snapshot_exists()
{
    VBoxManage snapshot "${VM_NAME}" list \
        | grep -q "${SNAPSHOT_NAME}"

    return $?
}

remove_snapshot()
{
    log "Removing snapshot: ${SNAPSHOT_NAME}"

    VBoxManage snapshot "${VM_NAME}" delete "${SNAPSHOT_NAME}" \
        >> "${LOG_FILE}" 2>&1

    if [ $? -ne 0 ]; then
        log "ERROR: Snapshot merge failed"
        cleanup_error
    fi

    log "Snapshot merge completed"
}

remove_stale_snapshot()
{
    snapshot_exists

    if [ $? -eq 0 ]; then

        log "Detected stale backup snapshot"

        remove_snapshot
    fi
}

create_live_snapshot()
{
    VM_STATE=$(
        VBoxManage showvminfo "${VM_NAME}" --machinereadable | \
        grep '^VMState=' | cut -d'"' -f2
    )

    log "Detected VM state: ${VM_STATE}"

    if [ "${VM_STATE}" = "running" ]; then

        log "VM is running, creating LIVE snapshot"

        VBoxManage snapshot "${VM_NAME}" \
            take "${SNAPSHOT_NAME}" \
            --live \
            >> "${LOG_FILE}" 2>&1

    else

        log "VM is powered off, creating OFFLINE snapshot"

        VBoxManage snapshot "${VM_NAME}" \
            take "${SNAPSHOT_NAME}" \
            >> "${LOG_FILE}" 2>&1
    fi

    if [ $? -ne 0 ]; then
        log "ERROR: Snapshot creation failed"
        cleanup_error
    fi

    log "Snapshot created successfully"
}
decrypt_password()
{
    openssl enc -d -aes-256-cbc -pbkdf2 \
        -in "${PASS_STORE}" \
        -pass pass:"${VM_NAME}"
}

create_backup()
{
    cleanup_temp

    log "Creating encrypted backup"

    PASSFILE="$(mktemp)"

    decrypt_password > "${PASSFILE}"

    chmod 600 "${PASSFILE}"

    tar \
        --exclude="Snapshots" \
        --exclude="Snapshots/*" \
        -b 256 \
        -cpf - "${VM_PATH}" 2>> "${LOG_FILE}" | \
    openssl enc -aes-256-cbc -pbkdf2 -salt \
        -pass file:"${PASSFILE}" \
        -out "${TMP_BACKUP}"

    RESULT=$?

    rm -f "${PASSFILE}"

    if [ ${RESULT} -ne 0 ]; then

        log "ERROR: Backup creation failed"

        cleanup_temp

        remove_snapshot

        cleanup_error
    fi
}

verify_backup()
{
    BACKUP_SIZE=$(du -m "${TMP_BACKUP}" | awk '{print $1}')

    if [ "${BACKUP_SIZE}" -lt "${MIN_BACKUP_SIZE_MB}" ]; then

        log "ERROR: Backup too small (${BACKUP_SIZE} MB)"

        cleanup_temp

        remove_snapshot

        cleanup_error
    fi

    log "Backup verified (${BACKUP_SIZE} MB)"
}

replace_old_backup()
{
    log "Replacing old backup"

    rm -f "${FINAL_BACKUP}"

    mv "${TMP_BACKUP}" "${FINAL_BACKUP}"

    if [ $? -ne 0 ]; then

        log "ERROR: Failed replacing old backup"

        cleanup_temp

        remove_snapshot

        cleanup_error
    fi
}

##############################################################################
# PARAMETERS
##############################################################################

case "${1:-live}" in
    live|savestate|poweroff)
        BACKUP_MODE="${1:-live}"
        ;;
    -h|--help)
        usage
        exit 0
        ;;
    *)
        usage
        cleanup_error
        ;;
esac

##############################################################################
# MAIN
##############################################################################

rotate_logs

log "============================================================"
log "Starting VBox live snapshot backup"
log "VM/User: ${VM_NAME}"

require_non_root

check_paths

check_vbox_access

remove_stale_snapshot

prepare_vm_for_backup

create_live_snapshot

create_backup

verify_backup

replace_old_backup

remove_snapshot

restore_vm_state

log "Backup completed successfully"
log "Backup file: ${FINAL_BACKUP}"

log "============================================================"

exit 0
