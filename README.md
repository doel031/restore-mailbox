# Zimbra / Carbonio Bulk Mailbox Restore Script

An automated bash script for bulk restoring (importing) mailboxes from `.tgz` backup archives into a Zimbra Collaboration Suite (ZCS) or Zextras Carbonio Mailbox server.

---

## 🚀 Key Features

- **Automatic Platform Detection (Zimbra / Carbonio)**: Automatically detects the running mail server platform (`zimbra` in `/opt/zimbra` or `zextras` in `/opt/zextras`), executes commands under the appropriate user (`zimbra` or `zextras`), and configures the correct binary path.
- **Parallel Processing (Multi-Jobs)**: Supports concurrent execution of multiple accounts (default: 10 parallel jobs) to significantly speed up bulk restorations.
- **Real-time Status Monitoring**: Live terminal progress display showing current active folder and processed message counter for each account.
- **Duplicate Prevention**: Checks email `Message-ID` headers prior to importing to prevent duplicate messages in the mailbox.
- **Hierarchical Folder Creation (`mkdir -p`)**: Automatically creates all ancestor/parent directories down to the deepest nested subfolders before importing messages.
- **Modern Table Reports per Account**: Generates clean, formatted Unicode/ASCII table reports at the end of each account's log file with durations, message counts, and percentage of new vs duplicate messages.
- **Automated Batch Log Numbering**: Automatically detects existing batches and creates the next sequential batch directory (`batch-1`, `batch-2`, etc.) under `/var/log/restore-mailbox/`.
- **Safe Cache Cleanup**: Cleans up temporary files automatically upon completion of each account and safely cleans all cache directories upon manual cancellation (`Ctrl+C`).

---

## 📋 Requirements

1. Linux server with **Zimbra Collaboration Suite (ZCS)** (user `zimbra`) or **Carbonio / Zextras** (user `zextras`).
2. **Root** privileges (required for switching to `zimbra` or `zextras` user via `su -`).
3. Standard utilities: `tar`, `grep`, `awk`, `find`, `sed`.

---

## 📁 Input File Format (CSV)

Prepare a comma-separated text file (`account_name, /path/to/backup.tgz`):

```csv
user1@domain.com, /backup/user1@domain.com.tgz
user2@domain.com, /backup/user2@domain.com.tgz
user3@domain.com, /backup/user3@domain.com.tgz
```

---

## 🛠️ Usage

1. Grant execute permissions to the script:
   ```bash
   chmod +x import-mailbox.sh
   ```

2. Run the script as root with the path to your CSV input file:
   ```bash
   sudo ./import-mailbox.sh /path/to/input_file.csv
   ```

3. *(Optional)* Override mail user manually if needed:
   ```bash
   sudo MAIL_USER=zimbra ./import-mailbox.sh /path/to/input_file.csv
   ```

---

## 📊 Log & Report Locations

- **Batch Log Directory**: `/var/log/restore-mailbox/batch-X/`
- **Summary Report**: `/var/log/restore-mailbox/batch-X/summary_report.txt`
- **Detailed Account Logs**: `/var/log/restore-mailbox/batch-X/<account_name>.log`

---

## 📄 License

MIT License.
