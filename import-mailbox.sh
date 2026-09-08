#!/bin/bash

# Pastikan dijalankan sebagai root
if [ "$EUID" -ne 0 ]; then
    echo "Harap jalankan skrip ini sebagai root!"
    exit 1
fi

INPUT_FILE="$1"
if [ -z "$INPUT_FILE" ] || [ ! -f "$INPUT_FILE" ]; then
    echo "Gagal: File input tidak ditemukan atau belum ditentukan!"
    echo "Penggunaan: $0 /path/ke/file_input.txt"
    exit 1
fi

BASE_LOG_DIR="/var/log/restore-mailbox"
mkdir -p "$BASE_LOG_DIR"

# Cari nomor batch tertinggi yang sudah ada untuk membuat batch berikutnya
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
> "$SUMMARY_LOG" # Bersihkan file summary

PROGRESS_DIR="$LOG_DIR/progress"
mkdir -p "$PROGRESS_DIR"
chmod 777 "$PROGRESS_DIR" # Agar bisa ditulis oleh zextras
rm -f "$PROGRESS_DIR"/* 2>/dev/null

RESTORE_TEMP_BASE="/tmp/restore"
mkdir -p "$RESTORE_TEMP_BASE"
chmod 777 "$RESTORE_TEMP_BASE"

MAX_PARALLEL=10

print_status() {
    clear
    echo "=================================================="
    echo "      STATUS RESTORE BERJALAN [$(basename "$LOG_DIR")]"
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
        echo "Memulai proses..."
    fi
    echo "=================================================="
}


# Fungsi untuk menangani Ctrl+C (SIGINT) agar membunuh seluruh child process dan membersihkan cache
cleanup() {
    echo ""
    echo "[!] Proses dihentikan oleh pengguna (Ctrl+C). Membersihkan background jobs..."
    # Mematikan seluruh proses anak/background yang berjalan dari skrip ini
    pkill -P $$ 2>/dev/null
    wait 2>/dev/null

    echo "[!] Membersihkan folder cache dan file sementara..."
    rm -rf "$RESTORE_TEMP_BASE"/* 2>/dev/null
    rm -f "$PROGRESS_DIR"/* 2>/dev/null

    echo "[!] Semua proses dihentikan dan file cache sementara telah dibersihkan."
    exit 1
}

# Tangkap sinyal SIGINT (Ctrl+C) dan SIGTERM
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
        echo "[$start_time_str] Memulai proses untuk akun: $TARGET_ACCOUNT"
        echo "=================================================="

        if [ ! -f "$TGZ_FILE" ]; then
            echo "[ERROR] File backup .tgz tidak ditemukan di: $TGZ_FILE"
            echo "❌ GAGAL: $TARGET_ACCOUNT (File .tgz tidak ditemukan)" >> "$SUMMARY_LOG"
            return
        fi

        echo "Mengekstrak file backup..." > "$PROGRESS_DIR/$TARGET_ACCOUNT"
        chmod 666 "$PROGRESS_DIR/$TARGET_ACCOUNT"

        echo "Mengekstrak file backup ke $TEMP_EXTRACT_DIR ..."
        mkdir -p "$TEMP_EXTRACT_DIR"
        chmod 777 "$TEMP_EXTRACT_DIR"
        tar -xzf "$TGZ_FILE" -C "$TEMP_EXTRACT_DIR"

        # Hitung total file (pesan)
        local total_msgs=$(find "$TEMP_EXTRACT_DIR" -type f -not -name "*.meta" 2>/dev/null | wc -l | tr -d ' ')
        find "$TEMP_EXTRACT_DIR" -mindepth 1 -type d | sort > "$TEMP_EXTRACT_DIR/.dirlist"
        chmod 666 "$TEMP_EXTRACT_DIR/.dirlist"
        echo "0/$total_msgs Mulai..." > "$PROGRESS_DIR/$TARGET_ACCOUNT"

        echo "Memulai import pesan ke mailbox..."
        su - zextras <<EOF
        TEMP_ROOT="$TEMP_EXTRACT_DIR"
        total_msgs="$total_msgs"
        count=0
        imported=0
        duplicate=0
        rm -f "\$TEMP_ROOT/.folder_records"

        # Daftar folder default untuk menghindari pemanggilan createFolder berulang
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

        # Fungsi untuk memastikan folder induk dan folder turunan terbuat secara hierarkis (seperti mkdir -p)
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
                    zmmailbox -z -m "$TARGET_ACCOUNT" createFolder "\$current" >/dev/null 2>&1
                    created_folders="\$created_folders
\$current"
                fi
            done
        }

        while read -r dir; do
            # Dapatkan path relatif terhadap folder ekstrak
            rel_path=\${dir#\$TEMP_ROOT/}
            
            # Pisahkan nama folder utama (top level) dan subfoldernya
            top_level=\$(echo "\$rel_path" | cut -d/ -f1)
            sub_path=\$(echo "\$rel_path" | cut -s -d/ -f2-)
            
            # Normalisasi folder utama dari sharding (misal Inbox!123 menjadi Inbox)
            case "\$top_level" in
                Inbox|Inbox!*) target_base="Inbox" ;;
                Sent|Sent!*) target_base="Sent" ;;
                Drafts|Drafts!*) target_base="Drafts" ;;
                Trash|Trash!*) target_base="Trash" ;;
                Junk|Junk!*) target_base="Junk" ;;
                Contacts|Contacts!*) target_base="Contacts" ;;
                Calendar|Calendar!*) target_base="Calendar" ;;
                Tasks|Tasks!*) target_base="Tasks" ;;
                Briefcase|Briefcase!*) target_base="Briefcase" ;;
                *) target_base="\$top_level" ;; # Biarkan folder kustom tetap apa adanya
            esac
            
            # Gabungkan kembali dengan subfoldernya jika ada
            if [ -n "\$sub_path" ]; then
                target_folder="/\$target_base/\$sub_path"
            else
                target_folder="/\$target_base"
            fi

            folder_display="\${target_folder#/}"
            f_new=0
            f_dup=0

            echo "[\$(date '+%H:%M:%S')] -> Memproses folder: \$target_folder"
            echo "\$count/\$total_msgs Import \$folder_display" > "$PROGRESS_DIR/$TARGET_ACCOUNT"
            ensure_folder "\$target_folder"

            for f in "\$dir"/*; do
                if [ ! -f "\$f" ] || [[ "\$f" == *.meta ]]; then
                    continue
                fi

                fname=\$(basename "\$f")
                ts=\$(date '+%H:%M:%S')

                # Dapatkan Subject email
                subject=\$(grep -i -m 1 "^Subject:" "\$f" | sed -E 's/^Subject:[[:space:]]*//I' | tr -d '\r')
                [ -z "\$subject" ] && subject="(Tanpa Subjek)"
                if [ \${#subject} -gt 50 ]; then
                    subject="\${subject:0:47}..."
                fi

                # Dapatkan Message-ID untuk menghindari duplikat
                msg_id=\$(grep -i -m 1 "^Message-ID:" "\$f" | sed -E 's/^Message-ID:[[:space:]]*//I' | tr -d '<>\r')
                
                if [ -n "\$msg_id" ]; then
                    # Cek apakah pesan dengan Message-ID yang sama sudah ada di mailbox
                    search_res=\$(zmmailbox -z -m "$TARGET_ACCOUNT" search -l 1 "msgid:\$msg_id" 2>/dev/null)
                    found_count=\$(echo "\$search_res" | grep -i "^num:" | awk '{print \$2}' | tr -d ',')
                    
                    if [ -n "\$found_count" ] && [ "\$found_count" -gt 0 ]; then
                        printf "[%s] [SKIP] %s/%s - \"%s\" (Duplikat)\n" "\$ts" "\$folder_display" "\$fname" "\$subject"
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
                    item_id=\$(echo "\$add_res" | tr -d ' \r\n')
                    printf "[%s] [OK]   %s/%s - \"%s\" (ID: %s)\n" "\$ts" "\$folder_display" "\$fname" "\$subject" "\$item_id"
                    imported=\$((imported + 1))
                    f_new=\$((f_new + 1))
                else
                    err_msg=\$(echo "\$add_res" | head -n 1 | tr -d '\r\n')
                    printf "[%s] [FAIL] %s/%s - \"%s\" (Error: %s)\n" "\$ts" "\$folder_display" "\$fname" "\$subject" "\$err_msg"
                fi

                count=\$((count + 1))
                echo "\$count/\$total_msgs Import \$folder_display" > "$PROGRESS_DIR/$TARGET_ACCOUNT"
            done
            echo "\$folder_display|\$f_new|\$f_dup" >> "\$TEMP_ROOT/.folder_records"
        done < "\$TEMP_ROOT/.dirlist"
        echo "\$count/\$total_msgs Selesai" > "$PROGRESS_DIR/$TARGET_ACCOUNT"
        echo "\$total_msgs:\$imported:\$duplicate" > "\$TEMP_ROOT/.stat"
EOF

        local total="$total_msgs" imported=0 duplicate=0
        if [ -f "$TEMP_EXTRACT_DIR/.stat" ]; then
            IFS=':' read -r total imported duplicate < "$TEMP_EXTRACT_DIR/.stat"
        fi

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

        echo "[$end_time_str] Selesai untuk akun: $TARGET_ACCOUNT"
        echo "✅ BERHASIL: $TARGET_ACCOUNT (Total: $total, Terimport: $imported, Duplikat: $duplicate)" >> "$SUMMARY_LOG"
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
            -v dup="$duplicate" '
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
            if (!(f in order)) {
                order[f] = ++count
                names[count] = f
            }
        }
        END {
            imp_pct = (tot > 0) ? sprintf("(%.1f%%)", (imp * 100.0) / tot) : "(0.0%)"
            dup_pct = (tot > 0) ? sprintf("(%.1f%%)", (dup * 100.0) / tot) : "(0.0%)"

            printf "===============================================================================\n"
            title = "LAPORAN RESTORE MAILBOX: " acc
            pad = int((79 - length(title)) / 2)
            if (pad < 0) pad = 0
            printf "%*s%s\n", pad, "", title
            printf "===============================================================================\n"
            printf " Waktu Mulai   : %-22s  Status       : ✅ SELESAI\n", start
            printf " Waktu Selesai : %-22s  Durasi       : %s\n", end, dur
            printf "-------------------------------------------------------------------------------\n"
            printf " RINGKASAN:\n"
            printf "   • Total Pesan : %d pesan\n", tot
            printf "   • Pesan Baru  : %d pesan %s\n", imp, imp_pct
            printf "   • Duplikat    : %d pesan %s\n", dup, dup_pct
            printf "-------------------------------------------------------------------------------\n"
            printf " RINCIAN FOLDER:\n"
            printf "┌────────────────────────────────┬──────────┬────────────────┬────────────────┐\n"
            printf "│ Folder                         │    Total │       Baru (+) │   Duplikat (≈) │\n"
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

        echo "Menghapus file sementara di $TEMP_EXTRACT_DIR ..."
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
echo "              RINGKASAN HASIL IMPORT"
echo "=================================================="
if [ -f "$SUMMARY_LOG" ]; then
    cat "$SUMMARY_LOG" | sort
    
    success_count=$(grep -c "✅ BERHASIL" "$SUMMARY_LOG" 2>/dev/null || echo 0)
    fail_count=$(grep -c "❌ GAGAL" "$SUMMARY_LOG" 2>/dev/null || echo 0)
    total_accounts=$((success_count + fail_count))

    tot_msgs=$(awk -F'Total: ' '{print $2}' "$SUMMARY_LOG" | awk -F',' '{sum += $1} END {print sum+0}')
    tot_imported=$(awk -F'Terimport: ' '{print $2}' "$SUMMARY_LOG" | awk -F',' '{sum += $1} END {print sum+0}')
    tot_duplicate=$(awk -F'Duplikat: ' '{print $2}' "$SUMMARY_LOG" | awk -F')' '{sum += $1} END {print sum+0}')

    echo "--------------------------------------------------"
    echo "Total Akun Diproses : $total_accounts (Berhasil: $success_count, Gagal: $fail_count)"
    echo "Total Pesan         : $tot_msgs"
    echo "Total Terimport     : $tot_imported"
    echo "Total Duplikat      : $tot_duplicate"
else
    echo "Tidak ada data ringkasan."
fi
echo "=================================================="
rmdir "$RESTORE_TEMP_BASE" 2>/dev/null
echo "Semua proses restore massal selesai! Silakan cek log detail di $LOG_DIR/"
