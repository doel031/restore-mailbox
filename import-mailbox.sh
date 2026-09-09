#!/bin/bash

# Ensure running as root
if [ "$EUID" -ne 0 ]; then
    echo "Error: Please run this script as root!"
    exit 1
fi

INPUT_FILE="$1"
if [ -z "$INPUT_FILE" ] || [ ! -f "$INPUT_FILE" ]; then
    echo "Error: Input file not found or not specified!"
    echo "Usage: $0 /path/to/input_file.csv"
    exit 1
fi

# Detect mail server platform: Carbonio (user: zextras) or Zimbra (user: zimbra)
if [ -n "$MAIL_USER" ]; then
    if [ "$MAIL_USER" = "zextras" ]; then
        MAIL_PLATFORM="Carbonio"
    else
        MAIL_PLATFORM="Zimbra"
    fi
elif id "zextras" &>/dev/null && [ -d "/opt/zextras" ]; then
    MAIL_PLATFORM="Carbonio"
    MAIL_USER="zextras"
elif id "zimbra" &>/dev/null && [ -d "/opt/zimbra" ]; then
    MAIL_PLATFORM="Zimbra"
    MAIL_USER="zimbra"
elif id "zextras" &>/dev/null; then
    MAIL_PLATFORM="Carbonio"
    MAIL_USER="zextras"
elif id "zimbra" &>/dev/null; then
    MAIL_PLATFORM="Zimbra"
    MAIL_USER="zimbra"
elif [ -d "/opt/zextras" ]; then
    MAIL_PLATFORM="Carbonio"
    MAIL_USER="zextras"
elif [ -d "/opt/zimbra" ]; then
    MAIL_PLATFORM="Zimbra"
    MAIL_USER="zimbra"
else
    echo "Error: Unable to detect mail server (Zimbra or Carbonio not found)!"
    echo "Please ensure 'zimbra' or 'zextras' user exists on the system."
    exit 1
fi

BASE_LOG_DIR="/var/log/restore-mailbox"
mkdir -p "$BASE_LOG_DIR"

# Find highest existing batch number to create the next batch directory
max_batch=0
for dir in "$BASE_LOG_DIR"/batch-*; do
    if [ -d "$dir" ]; then
        bname=$(basename "$dir")
        num="${bname#batch-}"
        if [[ "$num" =~ ^[0-9]+$ ]]; then
            if [ "$num" -gt "$max_batch" ]; then
                max_batch="$num"
            fi
        fi
    fi
done

next_batch=$((max_batch + 1))
LOG_DIR="$BASE_LOG_DIR/batch-$next_batch"
mkdir -p "$LOG_DIR"

SUMMARY_LOG="$LOG_DIR/summary_report.txt"
> "$SUMMARY_LOG" # Reset summary file

PROGRESS_DIR="$LOG_DIR/progress"
mkdir -p "$PROGRESS_DIR"
chmod 777 "$PROGRESS_DIR" # Allow write access for mail user (zimbra/zextras)
rm -f "$PROGRESS_DIR"/* 2>/dev/null

RESTORE_TEMP_BASE="/tmp/restore"
mkdir -p "$RESTORE_TEMP_BASE"
chmod 777 "$RESTORE_TEMP_BASE"

MAX_PARALLEL=10

print_status() {
    clear
    echo "=================================================="
    echo "      ACTIVE RESTORE STATUS [$(basename "$LOG_DIR")]"
    echo "      Platform: $MAIL_PLATFORM (User: $MAIL_USER)"
    echo "=================================================="
    local active_jobs=0
    for pfile in "$PROGRESS_DIR"/*; do
        if [ -f "$pfile" ]; then
            acc=$(basename "$pfile")
            case "$acc" in
                *.stat|*.tmp) continue ;;
            esac
            status=$(cat "$pfile" 2>/dev/null)
            echo "$acc : $status"
            active_jobs=$((active_jobs + 1))
        fi
    done
    if [ "$active_jobs" -eq 0 ]; then
        echo "Starting processes..."
    fi
    echo "=================================================="
}


# Handle SIGINT (Ctrl+C) and SIGTERM to kill all child processes and clean up cache
cleanup() {
    echo ""
    echo "[!] Process interrupted by user (Ctrl+C). Terminating background jobs..."
    # Kill all child/background processes spawned by this script
    pkill -P $$ 2>/dev/null
    wait 2>/dev/null

    echo "[!] Cleaning up cache and temporary files..."
    rm -rf "$RESTORE_TEMP_BASE"/* 2>/dev/null
    rm -f "$PROGRESS_DIR"/* 2>/dev/null

    echo "[!] All processes stopped and temporary files cleaned up."
    exit 1
}

# Trap SIGINT (Ctrl+C) and SIGTERM
trap cleanup SIGINT SIGTERM

process_account() {
    local TARGET_ACCOUNT="$1"
    local TGZ_FILE="$2"
    local TEMP_EXTRACT_DIR="$RESTORE_TEMP_BASE/$TARGET_ACCOUNT"
    local ACCOUNT_LOG="$LOG_DIR/${TARGET_ACCOUNT}.log"
    local start_time_epoch=$(date +%s)
    local start_time_str=$(date '+%Y-%m-%d %H:%M:%S')

    {
        echo "=================================================="
        echo "[$start_time_str] Starting restore for account: $TARGET_ACCOUNT"
        echo "=================================================="

        if [ ! -f "$TGZ_FILE" ]; then
            echo "[ERROR] Backup file .tgz not found at: $TGZ_FILE"
            echo "❌ FAILED: $TARGET_ACCOUNT (.tgz file not found)" >> "$SUMMARY_LOG"
            return
        fi

        # Pre-check: Verify target account existence on mail server before extracting archive
        echo "Checking account on $MAIL_PLATFORM..." > "$PROGRESS_DIR/$TARGET_ACCOUNT"
        chmod 666 "$PROGRESS_DIR/$TARGET_ACCOUNT" 2>/dev/null

        local acc_check
        if [ "$MAIL_USER" = "zextras" ]; then
            acc_check=$(su - "$MAIL_USER" -c "export PATH=/opt/zextras/bin:\$PATH; zmprov ga '$TARGET_ACCOUNT' zimbraAccountStatus" 2>&1)
        else
            acc_check=$(su - "$MAIL_USER" -c "export PATH=/opt/zimbra/bin:\$PATH; zmprov ga '$TARGET_ACCOUNT' zimbraAccountStatus" 2>&1)
        fi
        local acc_check_status=$?

        if [ $acc_check_status -ne 0 ] || echo "$acc_check" | grep -qiE "no_such_account|no such account"; then
            echo "[$start_time_str] [SKIP] ⚠️ Account '$TARGET_ACCOUNT' does not exist on $MAIL_PLATFORM! Skipping restore."
            echo "⏭️ SKIPPED: $TARGET_ACCOUNT (Account does not exist on mail server)" >> "$SUMMARY_LOG"
            rm -f "$PROGRESS_DIR/$TARGET_ACCOUNT"
            return
        fi

        local acc_status=$(echo "$acc_check" | awk '/^zimbraAccountStatus:/ {print $2}')
        if [ "$acc_status" = "closed" ]; then
            echo "[$start_time_str] [SKIP] ⚠️ Account '$TARGET_ACCOUNT' status is CLOSED! Skipping restore."
            echo "⏭️ SKIPPED: $TARGET_ACCOUNT (Account status is CLOSED)" >> "$SUMMARY_LOG"
            rm -f "$PROGRESS_DIR/$TARGET_ACCOUNT"
            return
        fi

        echo "Extracting backup archive..." > "$PROGRESS_DIR/$TARGET_ACCOUNT"
        chmod 666 "$PROGRESS_DIR/$TARGET_ACCOUNT"

        echo "Extracting backup archive to $TEMP_EXTRACT_DIR ..."
        mkdir -p "$TEMP_EXTRACT_DIR"
        chmod 777 "$TEMP_EXTRACT_DIR"
        tar -xzf "$TGZ_FILE" -C "$TEMP_EXTRACT_DIR"

        # Count total files (messages) and calculate extracted backup size
        local total_msgs=$(find "$TEMP_EXTRACT_DIR" -type f -not -name "*.meta" 2>/dev/null | wc -l | tr -d ' ')
        local backup_kb=$(du -sk "$TEMP_EXTRACT_DIR" 2>/dev/null | awk '{print $1}')
        local backup_bytes=$((backup_kb * 1024))
        find "$TEMP_EXTRACT_DIR" -mindepth 1 -type d | sort > "$TEMP_EXTRACT_DIR/.dirlist"
        chmod 666 "$TEMP_EXTRACT_DIR/.dirlist"
        echo "0/$total_msgs Starting..." > "$PROGRESS_DIR/$TARGET_ACCOUNT"

        echo "Starting message import to mailbox ($MAIL_PLATFORM via user $MAIL_USER)..."
        su - "$MAIL_USER" <<EOF
        if [ "$MAIL_USER" = "zextras" ]; then
            export PATH="/opt/zextras/bin:\$PATH"
        else
            export PATH="/opt/zimbra/bin:\$PATH"
        fi
        TEMP_ROOT="$TEMP_EXTRACT_DIR"
        total_msgs="$total_msgs"
        backup_bytes="$backup_bytes"
        count=0
        imported=0
        duplicate=0
        failed=0
        quota_hit=0
        rm -f "\$TEMP_ROOT/.folder_records"

        # Query mailbox quota limit and current mailbox usage
        quota_bytes=\$(zmprov ga "$TARGET_ACCOUNT" zimbraMailQuota 2>/dev/null | awk '/^zimbraMailQuota:/ {print \$2}')
        [ -z "\$quota_bytes" ] && quota_bytes=0

        used_bytes=\$(zmprov gmi "$TARGET_ACCOUNT" 2>/dev/null | awk '/^quotaUsed:/ {print \$2}')
        if [ -z "\$used_bytes" ]; then
            used_bytes=\$(zmmailbox -z -m "$TARGET_ACCOUNT" gms 2>/dev/null | grep -oE '[0-9]+' | tail -n 1)
            [ -z "\$used_bytes" ] && used_bytes=0
        fi

        fmt_bytes() {
            local b=\$1
            if [ -z "\$b" ] || [ "\$b" -le 0 ] 2>/dev/null; then
                echo "0 B"
            elif [ "\$b" -ge 1073741824 ]; then
                awk -v b="\$b" 'BEGIN { printf "%.2f GB", b / 1073741824 }'
            elif [ "\$b" -ge 1048576 ]; then
                awk -v b="\$b" 'BEGIN { printf "%.2f MB", b / 1048576 }'
            elif [ "\$b" -ge 1024 ]; then
                awk -v b="\$b" 'BEGIN { printf "%.2f KB", b / 1024 }'
            else
                echo "\${b} B"
            fi
        }

        get_current_usage() {
            local cur_u=\$(zmprov gmi "$TARGET_ACCOUNT" 2>/dev/null | awk '/^quotaUsed:/ {print \$2}')
            if [ -z "\$cur_u" ]; then
                cur_u=\$(zmmailbox -z -m "$TARGET_ACCOUNT" gms 2>/dev/null | grep -oE '[0-9]+' | tail -n 1)
            fi
            if [ -n "\$cur_u" ]; then
                used_bytes="\$cur_u"
            fi
        }

        log_quota_details() {
            get_current_usage
            local ts_q=\$(date '+%H:%M:%S')
            local cur_used_f=\$(fmt_bytes "\$used_bytes")
            local backup_f=\$(fmt_bytes "\$backup_bytes")
            local total_needed=\$((used_bytes + backup_bytes))
            local total_needed_f=\$(fmt_bytes "\$total_needed")

            if [ "\$quota_bytes" -gt 0 ]; then
                local quota_f=\$(fmt_bytes "\$quota_bytes")
                local deficit=\$((total_needed - quota_bytes))
                if [ "\$deficit" -gt 0 ]; then
                    local deficit_f=\$(fmt_bytes "\$deficit")
                    local rec_bytes=\$(awk -v tn="\$total_needed" 'BEGIN { printf "%.0f", tn * 1.10 }')
                    local rec_f=\$(fmt_bytes "\$rec_bytes")

                    printf "[%s] [QUOTA] ── Quota & Storage Details (%s) ──\n" "\$ts_q" "$TARGET_ACCOUNT"
                    printf "[%s] [QUOTA]   • Mailbox Quota Limit : %s (%s bytes)\n" "\$ts_q" "\$quota_f" "\$quota_bytes"
                    printf "[%s] [QUOTA]   • Current Mailbox Used: %s\n" "\$ts_q" "\$cur_used_f"
                    printf "[%s] [QUOTA]   • Backup Data to Add  : %s\n" "\$ts_q" "\$backup_f"
                    printf "[%s] [QUOTA]   • Est. Total Required : %s (Used + Backup)\n" "\$ts_q" "\$total_needed_f"
                    printf "[%s] [QUOTA]   • Deficit / Kekurangan: ⚠️ KURANG %s (Mailbox Full!)\n" "\$ts_q" "\$deficit_f"
                    printf "[%s] [QUOTA]   • Recommended Quota   : Minimum %s (+10%% buffer)\n" "\$ts_q" "\$rec_f"
                    printf "[%s] [QUOTA]   • Increase Quota Cmd  : zmprov ma %s zimbraMailQuota %s\n" "\$ts_q" "$TARGET_ACCOUNT" "\$rec_bytes"
                else
                    local rec_bytes=\$(awk -v tn="\$total_needed" -v q="\$quota_bytes" 'BEGIN { base = (tn > q) ? tn : q; printf "%.0f", base * 1.25 }')
                    local rec_f=\$(fmt_bytes "\$rec_bytes")

                    printf "[%s] [QUOTA] ── Quota & Storage Details (%s) ──\n" "\$ts_q" "$TARGET_ACCOUNT"
                    printf "[%s] [QUOTA]   • Mailbox Quota Limit : %s (%s bytes)\n" "\$ts_q" "\$quota_f" "\$quota_bytes"
                    printf "[%s] [QUOTA]   • Current Mailbox Used: %s\n" "\$ts_q" "\$cur_used_f"
                    printf "[%s] [QUOTA]   • Backup Data to Add  : %s\n" "\$ts_q" "\$backup_f"
                    printf "[%s] [QUOTA]   • Est. Total Required : %s (Used + Backup)\n" "\$ts_q" "\$total_needed_f"
                    printf "[%s] [QUOTA]   • Status              : ⚠️ Batas kuota server tercapai saat import pesan!\n" "\$ts_q"
                    printf "[%s] [QUOTA]   • Recommended Quota   : Naikkan kuota ke %s atau 0 (Unlimited)\n" "\$ts_q" "\$rec_f"
                    printf "[%s] [QUOTA]   • Increase Quota Cmd  : zmprov ma %s zimbraMailQuota %s\n" "\$ts_q" "$TARGET_ACCOUNT" "\$rec_bytes"
                fi
            else
                printf "[%s] [QUOTA] ── Quota & Storage Details (%s) ──\n" "\$ts_q" "$TARGET_ACCOUNT"
                printf "[%s] [QUOTA]   • Mailbox Quota Limit : Unlimited (0)\n" "\$ts_q"
                printf "[%s] [QUOTA]   • Current Mailbox Used: %s\n" "\$ts_q" "\$cur_used_f"
                printf "[%s] [QUOTA]   • Backup Data to Add  : %s\n" "\$ts_q" "\$backup_f"
                printf "[%s] [QUOTA]   • Est. Total Required : %s (Used + Backup)\n" "\$ts_q" "\$total_needed_f"
                printf "[%s] [QUOTA]   • Note: Mailbox quota is unlimited, check server disk/domain limits.\n" "\$ts_q"
            fi
        }

        # Default folders list to prevent redundant createFolder calls
        created_folders="
/Inbox
/Sent
/Drafts
/Trash
/Junk
/Contacts
/Calendar
/Tasks
/Briefcase"

        # Ensure parent and nested folders exist hierarchically (like mkdir -p)
        ensure_folder() {
            local target="\$1"
            local clean="\${target#/}"
            local current=""
            local old_ifs="\$IFS"
            IFS="/"
            local -a parts=(\$clean)
            IFS="\$old_ifs"

            for part in "\${parts[@]}"; do
                current="\$current/\$part"
                if ! echo "\$created_folders" | grep -qx "\$current"; then
                    if [ "$MAIL_PLATFORM" = "Carbonio" ]; then
                        cf_out=\$(zmmailbox -z -m "$TARGET_ACCOUNT" cf -V message "\$current" 2>&1)
                    else
                        cf_out=\$(zmmailbox -z -m "$TARGET_ACCOUNT" createFolder "\$current" 2>&1)
                    fi
                    cf_status=\$?
                    ts_f=\$(date '+%H:%M:%S')

                    if [ \$cf_status -eq 0 ]; then
                        printf "[%s] [FOLDER] Created: %s\n" "\$ts_f" "\$current"
                    elif echo "\$cf_out" | grep -qiE "QUOTA_EXCEEDED|quota exceeded|mailbox is full"; then
                        quota_hit=1
                        printf "[%s] [QUOTA] ⚠️ Mailbox quota exceeded while creating folder: %s!\n" "\$ts_f" "\$current"
                        log_quota_details
                        return 1
                    elif echo "\$cf_out" | grep -qi "already_exists"; then
                        if [ "$MAIL_PLATFORM" = "Carbonio" ]; then
                            # If folder already exists in Carbonio, ensure its view is set to message (in case it was created as unknown)
                            gf_res=\$(zmmailbox -z -m "$TARGET_ACCOUNT" getFolder "\$current" 2>/dev/null)
                            gf_view=\$(echo "\$gf_res" | grep -m 1 '"view"' | sed -E 's/.*"view":[[:space:]]*"([^"]+)".*/\1/')
                            if [ -n "\$gf_view" ] && [ "\$gf_view" != "message" ]; then
                                gf_id=\$(echo "\$gf_res" | grep -m 1 '"id"' | sed -E 's/.*"id":[[:space:]]*"([^"]+)".*/\1/')
                                if [ -n "\$gf_id" ]; then
                                    zmsoap -z -m "$TARGET_ACCOUNT" FolderActionRequest/action @id="\$gf_id" @op="update" @view="message" >/dev/null 2>&1
                                    printf "[%s] [FOLDER] Repaired view: %s\n" "\$ts_f" "\$current"
                                fi
                            fi
                        fi
                    else
                        cf_err=\$(echo "\$cf_out" | grep -v 'INFO' | grep -v 'DEBUG' | head -n 1 | tr -d '\r\n')
                        [ -z "\$cf_err" ] && cf_err=\$(echo "\$cf_out" | head -n 1 | tr -d '\r\n')
                        printf "[%s] [FOLDER] Failed to create: %s (Error: %s)\n" "\$ts_f" "\$current" "\$cf_err"
                    fi

                    created_folders="\$created_folders
\$current"
                fi
            done
        }

        # Ensure /Archive exists
        ensure_folder "/Archive"

        # Pre-scan and move any existing custom root-level folders to /Archive so they are visible in Webmail
        gaf_out=\$(zmmailbox -z -m "$TARGET_ACCOUNT" gaf 2>/dev/null)
        echo "\$gaf_out" | awk '\$1 ~ /^[0-9]+\$/ {
            id = \$1;
            path = \$5;
            for (i = 6; i <= NF; i++) path = path " " \$i;
            print id "\t" path;
        }' | while IFS=$'\t' read -r fid fpath; do
            case "\$fpath" in
                /|/Inbox|/Inbox/*|/Sent|/Sent/*|/Drafts|/Drafts/*|/Trash|/Trash/*|/Junk|/Junk/*|/Archive|/Archive/*|/Contacts|/Contacts/*|/Calendar|/Calendar/*|/Tasks|/Tasks/*|/Briefcase|/Briefcase/*|/Chats*|/Emailed\ Contacts*)
                    # Standard system / default folders, keep as is
                    ;;
                /*)
                    # Non-standard custom folder at root level (e.g. /Cosco)
                    top_f=\$(echo "\${fpath#/}" | cut -d/ -f1)
                    sub_f=\$(echo "\${fpath#/}" | cut -s -d/ -f2-)
                    if [ -z "\$sub_f" ]; then
                        # Move /Cosco to /Archive/Cosco
                        zmmailbox -z -m "$TARGET_ACCOUNT" renameFolder "\$fpath" "/Archive/\$top_f" >/dev/null 2>&1
                        if [ \$? -eq 0 ]; then
                            printf "[%s] [FOLDER] Moved custom folder: %s -> /Archive/%s\n" "\$(date '+%H:%M:%S')" "\$fpath" "\$top_f"
                        fi
                    fi
                    ;;
            esac
        done

        # Pre-scan and merge any existing sharded folders (e.g. "Notifikasi BCA!2" -> "Notifikasi BCA")
        echo "\$gaf_out" | awk '\$1 ~ /^[0-9]+\$/ {
            id = \$1;
            path = \$5;
            for (i = 6; i <= NF; i++) path = path " " \$i;
            if (path ~ /![0-9]+/) print id "\t" path;
        }' | while IFS=$'\t' read -r fid fpath; do
            clean_dest=\$(echo "\$fpath" | sed -E 's/![0-9]+(\/|$)/\1/g')
            ensure_folder "\$clean_dest"
            
            # Move all messages from sharded folder to clean folder
            s_res=\$(zmmailbox -z -m "$TARGET_ACCOUNT" search -l 1000 -t message "in:\"\$fpath\"" 2>/dev/null)
            echo "\$s_res" | awk '\$1 ~ /^[0-9]+\$/ && \$2 == "mess" {print \$1}' | while read -r mid; do
                if [ -n "\$mid" ]; then
                    zmmailbox -z -m "$TARGET_ACCOUNT" moveMessage "\$mid" "\$clean_dest" >/dev/null 2>&1
                fi
            done
            
            # Delete the empty sharded folder
            zmmailbox -z -m "$TARGET_ACCOUNT" deleteFolder "\$fpath" >/dev/null 2>&1
            printf "[%s] [FOLDER] Merged sharded folder: %s -> %s\n" "\$(date '+%H:%M:%S')" "\$fpath" "\$clean_dest"
        done

        # Pre-scan and repair any existing custom folders with 'unkn' view (Carbonio specific)
        if [ "$MAIL_PLATFORM" = "Carbonio" ]; then
            echo "\$gaf_out" | awk '\$2 == "unkn" && \$5 != "/" && \$5 != "/Trash" && \$1 ~ /^[0-9]+\$/ {
                id = \$1;
                path = \$5;
                for (i = 6; i <= NF; i++) path = path " " \$i;
                print id "\t" path;
            }' | while IFS=$'\t' read -r fid fpath; do
                if [ -n "\$fid" ] && [ -n "\$fpath" ]; then
                    zmsoap -z -m "$TARGET_ACCOUNT" FolderActionRequest/action @id="\$fid" @op="update" @view="message" >/dev/null 2>&1
                    printf "[%s] [FOLDER] Repaired view: %s\n" "\$(date '+%H:%M:%S')" "\$fpath"
                fi
            done
        fi

        while read -r dir; do
            # Get relative path to extraction folder
            rel_path=\${dir#\$TEMP_ROOT/}
            
            # Clean Zimbra shard suffixes (!1, !2, !4, etc.) from all path segments
            clean_path=\$(echo "\$rel_path" | sed -E 's/![0-9]+(\/|$)/\1/g')

            # Separate top-level folder name and subpath
            top_level=\$(echo "\$clean_path" | cut -d/ -f1)
            sub_path=\$(echo "\$clean_path" | cut -s -d/ -f2-)
            
            # Normalize top-level folder: map standard folders, place all other custom folders under Archive
            case "\$top_level" in
                Inbox|[iI]nbox) target_base="Inbox" ;;
                Sent|[sS]ent|[sS]end) target_base="Sent" ;;
                Drafts|[dD]rafts) target_base="Drafts" ;;
                Trash|[tT]rash) target_base="Trash" ;;
                Junk|[jJ]unk|[sS]pam) target_base="Junk" ;;
                Archive|[aA]rchive|[aA]rchieve) target_base="Archive" ;;
                Contacts|[cC]ontacts) target_base="Contacts" ;;
                Calendar|[cC]alendar) target_base="Calendar" ;;
                Tasks|[tT]asks) target_base="Tasks" ;;
                Briefcase|[bB]riefcase) target_base="Briefcase" ;;
                *) target_base="Archive/\$top_level" ;; # Put all other custom folders inside Archive
            esac
            
            # Recombine with subpath if present
            if [ -n "\$sub_path" ]; then
                target_folder="/\$target_base/\$sub_path"
            else
                target_folder="/\$target_base"
            fi

            folder_display="\${target_folder#/}"
            f_new=0
            f_dup=0
            f_fail=0
            f_recorded=0

            echo "[\$(date '+%H:%M:%S')] -> Processing folder: \$target_folder"
            echo "\$count/\$total_msgs Import \$folder_display" > "$PROGRESS_DIR/$TARGET_ACCOUNT"
            ensure_folder "\$target_folder"
            if [ "\$quota_hit" -eq 1 ]; then
                break
            fi

            for f in "\$dir"/*; do
                if [ ! -f "\$f" ] || [[ "\$f" == *.meta ]]; then
                    continue
                fi

                fname=\$(basename "\$f")
                ts=\$(date '+%H:%M:%S')

                # Extract email Subject
                subject=\$(grep -i -m 1 "^Subject:" "\$f" | sed -E 's/^Subject:[[:space:]]*//I' | tr -d '\r')
                [ -z "\$subject" ] && subject="(No Subject)"
                if [ \${#subject} -gt 50 ]; then
                    subject="\${subject:0:47}..."
                fi

                # Extract Message-ID to prevent duplicates
                msg_id=\$(grep -i -m 1 "^Message-ID:" "\$f" | sed -E 's/^Message-ID:[[:space:]]*//I' | tr -d '<>\r')
                
                if [ -n "\$msg_id" ]; then
                    # Check if message with same Message-ID already exists in target folder
                    search_res=\$(zmmailbox -z -m "$TARGET_ACCOUNT" search -l 1 "in:\"\$target_folder\" msgid:\$msg_id" 2>/dev/null)
                    found_count=\$(echo "\$search_res" | grep -i "^num:" | awk '{print \$2}' | tr -d ',')
                    
                    if [ -n "\$found_count" ] && [ "\$found_count" -gt 0 ]; then
                        printf "[%s] [SKIP] %s/%s - \"%s\" (Duplicate)\n" "\$ts" "\$folder_display" "\$fname" "\$subject"
                        count=\$((count + 1))
                        duplicate=\$((duplicate + 1))
                        f_dup=\$((f_dup + 1))
                        echo "\$count/\$total_msgs Import \$folder_display" > "$PROGRESS_DIR/$TARGET_ACCOUNT"
                        continue
                    fi
                fi

                add_res=\$(zmmailbox -z -m "$TARGET_ACCOUNT" addMessage "\$target_folder" "\$f" 2>&1)
                add_status=\$?

                if [ \$add_status -eq 0 ]; then
                    printf "[%s] [OK]   %s/%s - \"%s\"\n" "\$ts" "\$folder_display" "\$fname" "\$subject"
                    imported=\$((imported + 1))
                    f_new=\$((f_new + 1))
                else
                    err_msg=\$(echo "\$add_res" | grep -v 'INFO' | grep -v 'DEBUG' | head -n 1 | tr -d '\r\n')
                    [ -z "\$err_msg" ] && err_msg=\$(echo "\$add_res" | head -n 1 | tr -d '\r\n')
                    failed=\$((failed + 1))
                    f_fail=\$((f_fail + 1))

                    if echo "\$add_res" | grep -qiE "QUOTA_EXCEEDED|quota exceeded|mailbox is full"; then
                        quota_hit=1
                        printf "[%s] [FAIL] %s/%s - \"%s\" (Error: %s)\n" "\$ts" "\$folder_display" "\$fname" "\$subject" "\$err_msg"
                        printf "[%s] [QUOTA] ⚠️ Mailbox quota exceeded for %s! Halting import for this account.\n" "\$ts" "$TARGET_ACCOUNT"
                        log_quota_details
                        count=\$((count + 1))
                        f_recorded=1
                        echo "\$folder_display|\$f_new|\$f_dup|\$f_fail" >> "\$TEMP_ROOT/.folder_records"
                        break 2
                    elif echo "\$add_res" | grep -qiE "no_such_account|no such account"; then
                        printf "[%s] [FAIL] %s/%s - \"%s\" (Error: %s)\n" "\$ts" "\$folder_display" "\$fname" "\$subject" "\$err_msg"
                        printf "[%s] [SKIP] ⚠️ Account %s does not exist on mail server! Halting import.\n" "\$ts" "$TARGET_ACCOUNT"
                        break 2
                    else
                        printf "[%s] [FAIL] %s/%s - \"%s\" (Error: %s)\n" "\$ts" "\$folder_display" "\$fname" "\$subject" "\$err_msg"
                    fi
                fi

                count=\$((count + 1))
                echo "\$count/\$total_msgs Import \$folder_display" > "$PROGRESS_DIR/$TARGET_ACCOUNT"
            done
            if [ "\$f_recorded" -ne 1 ]; then
                echo "\$folder_display|\$f_new|\$f_dup|\$f_fail" >> "\$TEMP_ROOT/.folder_records"
            fi
        done < "\$TEMP_ROOT/.dirlist"
        get_current_usage
        if [ "\$quota_hit" -eq 1 ]; then
            failed=\$((total_msgs - imported - duplicate))
            [ "\$failed" -lt 0 ] && failed=0
            echo "\$count/\$total_msgs Stopped (Quota Exceeded)" > "$PROGRESS_DIR/$TARGET_ACCOUNT"
        else
            echo "\$count/\$total_msgs Completed" > "$PROGRESS_DIR/$TARGET_ACCOUNT"
        fi
        echo "\$total_msgs:\$imported:\$duplicate:\$failed:\$quota_hit:\$used_bytes:\$quota_bytes:\$backup_bytes" > "\$TEMP_ROOT/.stat"
EOF

        local total="$total_msgs" imported=0 duplicate=0 failed=0 quota_hit=0
        local used_bytes=0 quota_bytes=0 backup_bytes_stat="$backup_bytes"
        if [ -f "$TEMP_EXTRACT_DIR/.stat" ]; then
            IFS=':' read -r total imported duplicate failed quota_hit used_bytes quota_bytes backup_bytes_stat < "$TEMP_EXTRACT_DIR/.stat"
        fi
        [ -z "$backup_bytes_stat" ] && backup_bytes_stat="$backup_bytes"
        [ -z "$used_bytes" ] && used_bytes=0
        [ -z "$quota_bytes" ] && quota_bytes=0

        rm -f "$PROGRESS_DIR/$TARGET_ACCOUNT"

        local end_time_epoch=$(date +%s)
        local end_time_str=$(date '+%Y-%m-%d %H:%M:%S')
        local duration_sec=$((end_time_epoch - start_time_epoch))
        local dur_min=$((duration_sec / 60))
        local dur_sec=$((duration_sec % 60))
        local duration_str=""
        if [ $dur_min -gt 0 ]; then
            duration_str="${dur_min}m ${dur_sec}s"
        else
            duration_str="${dur_sec}s"
        fi

        local used_gb=$(awk -v b="$used_bytes" 'BEGIN { if (b >= 1073741824) printf "%.2f GB", b / 1073741824; else if (b >= 1048576) printf "%.2f MB", b / 1048576; else printf "%.2f KB", b / 1024 }')
        local backup_gb=$(awk -v b="$backup_bytes_stat" 'BEGIN { if (b >= 1073741824) printf "%.2f GB", b / 1073741824; else if (b >= 1048576) printf "%.2f MB", b / 1048576; else printf "%.2f KB", b / 1024 }')
        local total_req_gb=$(awk -v u="$used_bytes" -v b="$backup_bytes_stat" 'BEGIN { tot = u + b; if (tot >= 1073741824) printf "%.2f GB", tot / 1073741824; else if (tot >= 1048576) printf "%.2f MB", tot / 1048576; else printf "%.2f KB", tot / 1024 }')
        local quota_desc="Unlimited"
        local deficit_desc=""
        if [ "$quota_bytes" -gt 0 ]; then
            quota_desc=$(awk -v q="$quota_bytes" 'BEGIN { if (q >= 1073741824) printf "%.2f GB", q / 1073741824; else printf "%.2f MB", q / 1048576 }')
            local def_b=$((used_bytes + backup_bytes_stat - quota_bytes))
            if [ "$def_b" -gt 0 ]; then
                local def_gb=$(awk -v d="$def_b" 'BEGIN { if (d >= 1073741824) printf "%.2f GB", d / 1073741824; else printf "%.2f MB", d / 1048576 }')
                deficit_desc=" [Deficit: $def_gb]"
            fi
        fi

        if [ "$quota_hit" -eq 1 ]; then
            echo "[$end_time_str] Stopped for account: $TARGET_ACCOUNT (QUOTA EXCEEDED)"
            echo "⚠️ QUOTA EXCEEDED: $TARGET_ACCOUNT (Total: $total, Imported: $imported, Duplicate: $duplicate, Failed/Unimported: $failed - Mailbox Full | Used: $used_gb / $quota_desc, Backup: $backup_gb, Est. Needed: $total_req_gb$deficit_desc)" >> "$SUMMARY_LOG"
        elif [ "$failed" -gt 0 ]; then
            echo "[$end_time_str] Completed for account: $TARGET_ACCOUNT (WITH ERRORS)"
            echo "⚠️ WITH ERRORS: $TARGET_ACCOUNT (Total: $total, Imported: $imported, Duplicate: $duplicate, Failed: $failed)" >> "$SUMMARY_LOG"
        else
            echo "[$end_time_str] Completed for account: $TARGET_ACCOUNT"
            echo "✅ SUCCESS: $TARGET_ACCOUNT (Total: $total, Imported: $imported, Duplicate: $duplicate)" >> "$SUMMARY_LOG"
        fi
        echo ""

        local record_file="$TEMP_EXTRACT_DIR/.folder_records"
        if [ ! -f "$record_file" ]; then
            record_file="/dev/null"
        fi

        awk -F'|' \
            -v start="$start_time_str" \
            -v end="$end_time_str" \
            -v dur="$duration_str" \
            -v acc="$TARGET_ACCOUNT" \
            -v tot="$total" \
            -v imp="$imported" \
            -v dup="$duplicate" \
            -v fail="$failed" \
            -v quota="$quota_hit" \
            -v used="$used_bytes" \
            -v quota_limit="$quota_bytes" \
            -v backup="$backup_bytes_stat" '
        function fmt_size(b) {
            if (b <= 0) return "0 B";
            if (b >= 1073741824) return sprintf("%.2f GB", b / 1073741824);
            if (b >= 1048576) return sprintf("%.2f MB", b / 1048576);
            if (b >= 1024) return sprintf("%.2f KB", b / 1024);
            return sprintf("%d B", b);
        }
        BEGIN {
            order["Inbox"] = 1; names[1] = "Inbox"
            order["Sent"] = 2; names[2] = "Sent"
            order["Drafts"] = 3; names[3] = "Drafts"
            count = 3
        }
        {
            f = $1
            f_new[f] += $2
            f_dup[f] += $3
            f_fail[f] += $4
            if (!(f in order)) {
                order[f] = ++count
                names[count] = f
            }
        }
        END {
            imp_pct = (tot > 0) ? sprintf("(%.1f%%)", (imp * 100.0) / tot) : "(0.0%)"
            dup_pct = (tot > 0) ? sprintf("(%.1f%%)", (dup * 100.0) / tot) : "(0.0%)"
            fail_pct = (tot > 0) ? sprintf("(%.1f%%)", (fail * 100.0) / tot) : "(0.0%)"

            if (quota == 1) {
                status_str = "⚠️ QUOTA EXCEEDED (Mailbox Full)"
            } else if (fail > 0) {
                status_str = "⚠️ COMPLETED WITH ERRORS"
            } else {
                status_str = "✅ COMPLETED"
            }

            printf "===============================================================================\n"
            title = "MAILBOX RESTORE REPORT: " acc
            pad = int((79 - length(title)) / 2)
            if (pad < 0) pad = 0
            printf "%*s%s\n", pad, "", title
            printf "===============================================================================\n"
            printf " Start Time    : %-22s  Status       : %s\n", start, status_str
            printf " End Time      : %-22s  Duration     : %s\n", end, dur
            printf "-------------------------------------------------------------------------------\n"
            printf " SUMMARY:\n"
            printf "   • Total Messages : %d messages\n", tot
            printf "   • New Messages   : %d messages %s\n", imp, imp_pct
            printf "   • Duplicates     : %d messages %s\n", dup, dup_pct
            if (fail > 0) {
                if (quota == 1) {
                    printf "   • Failed (Quota) : %d messages %s (Mailbox Full)\n", fail, fail_pct
                } else {
                    printf "   • Failed         : %d messages %s\n", fail, fail_pct
                }
            }
            printf "-------------------------------------------------------------------------------\n"
            printf " STORAGE & QUOTA ANALYSIS:\n"
            used_f = fmt_size(used)
            backup_f = fmt_size(backup)
            tot_req = used + backup
            tot_req_f = fmt_size(tot_req)

            if (quota_limit > 0) {
                quota_f = fmt_size(quota_limit)
                used_pct = sprintf("(%.1f%%)", (used * 100.0) / quota_limit)
                printf "   • Mailbox Quota Limit : %-12s (%.0f bytes)\n", quota_f, quota_limit
                printf "   • Current Mailbox Used: %-12s %s\n", used_f, used_pct
                printf "   • Backup Data Size    : %-12s (Ekstraksi dari .tgz)\n", backup_f
                printf "   • Est. Space Needed   : %-12s (Pemakaian saat ini + Data backup)\n", tot_req_f
                
                deficit = tot_req - quota_limit
                if (deficit > 0) {
                    deficit_f = fmt_size(deficit)
                    rec_bytes = sprintf("%.0f", tot_req * 1.10)
                    rec_f = fmt_size(rec_bytes)
                    printf "   • Status / Deficit    : ⚠️ KURANG %s (Mailbox tidak muat!)\n", deficit_f
                    printf "   • Rekomendasi Quota   : Minimum %s (Disarankan +10%% buffer)\n", rec_f
                    printf "   • Perintah Update     : zmprov ma %s zimbraMailQuota %.0f\n", acc, rec_bytes
                } else if (quota == 1) {
                    base_bytes = (tot_req > quota_limit) ? tot_req : quota_limit
                    rec_bytes = sprintf("%.0f", base_bytes * 1.25)
                    rec_f = fmt_size(rec_bytes)
                    printf "   • Status / Deficit    : ⚠️ KUOTA TERCAPAI (Server menolak penambahan pesan)\n"
                    printf "   • Rekomendasi Quota   : Naikkan ke %s atau 0 (Unlimited)\n", rec_f
                    printf "   • Perintah Update     : zmprov ma %s zimbraMailQuota %.0f\n", acc, rec_bytes
                } else {
                    remaining = quota_limit - tot_req
                    rem_f = fmt_size(remaining)
                    printf "   • Sisa Kuota Aman     : %-12s (Setelah semua pesan direstore)\n", rem_f
                    printf "   • Status              : ✅ Kuota mailbox mencukupi\n"
                }
            } else {
                printf "   • Mailbox Quota Limit : Unlimited (0)\n"
                printf "   • Current Mailbox Used: %s\n", used_f
                printf "   • Backup Data Size    : %s (Ekstraksi dari .tgz)\n", backup_f
                printf "   • Est. Space Needed   : %s (Pemakaian saat ini + Data backup)\n", tot_req_f
                printf "   • Status              : ✅ Kuota akun Unlimited (Cek kapasitas disk server)\n"
            }
            printf "-------------------------------------------------------------------------------\n"
            printf " FOLDER BREAKDOWN:\n"
            printf "┌────────────────────────────────┬──────────┬────────────────┬────────────────┐\n"
            printf "│ Folder                         │    Total │        New (+) │  Duplicate (≈) │\n"
            printf "├────────────────────────────────┼──────────┼────────────────┼────────────────┤\n"
            for (i = 1; i <= count; i++) {
                f = names[i]
                n = f_new[f] + 0
                d = f_dup[f] + 0
                t = n + d
                disp_f = f
                if (length(disp_f) > 30) disp_f = substr(disp_f, 1, 27) "..."
                printf "│ %-30s │ %8d │ %14d │ %14d │\n", disp_f, t, n, d
            }
            printf "└────────────────────────────────┴──────────┴────────────────┴────────────────┘\n"
            printf "===============================================================================\n"
        }' "$record_file"
        echo ""

        echo "Removing temporary files in $TEMP_EXTRACT_DIR ..."
        rm -rf "$TEMP_EXTRACT_DIR"

    } > "$ACCOUNT_LOG" 2>&1
}

while IFS=',' read -r TARGET_ACCOUNT TGZ_FILE; do
    TARGET_ACCOUNT=$(echo "$TARGET_ACCOUNT" | xargs)
    TGZ_FILE=$(echo "$TGZ_FILE" | xargs)
    
    [ -z "$TARGET_ACCOUNT" ] || [ -z "$TGZ_FILE" ] && continue

    process_account "$TARGET_ACCOUNT" "$TGZ_FILE" &

    while [ $(jobs -r | wc -l) -ge $MAX_PARALLEL ]; do
        print_status
        sleep 2
    done

done < "$INPUT_FILE"

while [ $(jobs -r | wc -l) -gt 0 ]; do
    print_status
    sleep 2
done
wait
print_status
echo ""
echo "=================================================="
echo "              IMPORT RESULTS SUMMARY"
echo "=================================================="
if [ -f "$SUMMARY_LOG" ]; then
    cat "$SUMMARY_LOG" | sort
    
    success_count=$(grep "✅ SUCCESS" "$SUMMARY_LOG" 2>/dev/null | wc -l | tr -d ' ')
    quota_count=$(grep "⚠️ QUOTA EXCEEDED" "$SUMMARY_LOG" 2>/dev/null | wc -l | tr -d ' ')
    error_count=$(grep "⚠️ WITH ERRORS" "$SUMMARY_LOG" 2>/dev/null | wc -l | tr -d ' ')
    skipped_count=$(grep "⏭️ SKIPPED" "$SUMMARY_LOG" 2>/dev/null | wc -l | tr -d ' ')
    fail_count=$(grep "❌ FAILED" "$SUMMARY_LOG" 2>/dev/null | wc -l | tr -d ' ')
    total_accounts=$((success_count + quota_count + error_count + skipped_count + fail_count))

    tot_msgs=$(awk -F'Total: ' '{print $2}' "$SUMMARY_LOG" | awk -F'[,)]' '{sum += $1} END {print sum+0}')
    tot_imported=$(awk -F'Imported: ' '{print $2}' "$SUMMARY_LOG" | awk -F'[,)]' '{sum += $1} END {print sum+0}')
    tot_duplicate=$(awk -F'Duplicate: ' '{print $2}' "$SUMMARY_LOG" | awk -F'[,)]' '{sum += $1} END {print sum+0}')
    tot_failed=$(awk -F'Failed[^:]*: ' '{print $2}' "$SUMMARY_LOG" | awk -F'[, -)]' '{sum += $1} END {print sum+0}')

    echo "--------------------------------------------------"
    echo "Mail Server Platform : $MAIL_PLATFORM (User: $MAIL_USER)"
    echo "Total Accounts       : $total_accounts (Success: $success_count, Quota Exceeded: $quota_count, Errors: $error_count, Skipped: $skipped_count, Failed: $fail_count)"
    echo "Total Messages       : $tot_msgs"
    echo "Total Imported       : $tot_imported"
    echo "Total Duplicates     : $tot_duplicate"
    if [ "$tot_failed" -gt 0 ]; then
        echo "Total Failed/Unsaved : $tot_failed"
    fi
else
    echo "No summary data available."
fi
echo "=================================================="
rmdir "$RESTORE_TEMP_BASE" 2>/dev/null
echo "All bulk restore processes completed! Check detailed logs in $LOG_DIR/"
