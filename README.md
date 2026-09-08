# Zimbra / Carbonio Bulk Mailbox Restore Script

Skrip bash otomatis untuk melakukan restore mailbox massal (bulk import) dari file arsip `.tgz` ke server Zimbra / Carbonio / Zextras Mailbox.

---

## 🚀 Fitur Utama

- **Pemrosesan Paralel (Multi-Jobs)**: Mendukung eksekusi beberapa akun secara bersamaan (default: 10 paralel) untuk mempercepat proses restore massal.
- **Tampilan Status Real-time**: Menampilkan progres berjalan di terminal secara live (folder yang sedang diproses dan counter pesan per akun).
- **Pencegahan Pesan Duplikat**: Mengecek `Message-ID` pesan sebelum diimpor ke Zimbra untuk mencegah duplikasi email.
- **Pembuatan Folder Hierarkis Otomatis (`mkdir -p`)**: Otomatis membuat seluruh folder induk hingga subfolder turunan terdalam sebelum pesan diimpor.
- **Laporan Modern Table per Akun**: Menyajikan laporan akhir di log akun dalam bentuk tabel ASCII/Unicode yang rapi lengkap dengan persentase pesan baru vs duplikat dan durasi pengerjaan.
- **Penomoran Batch Log Otomatis**: Otomatis mendeteksi nomor batch (`batch-1`, `batch-2`, dst.) di `/var/log/restore-mailbox/`.
- **Pembersihan Cache Aman**: Membersihkan file sementara secara otomatis setelah akun selesai, termasuk saat skrip dihentikan paksa menggunakan `Ctrl+C`.

---

## 📋 Persyaratan

1. Server Linux dengan Zimbra Collaboration Suite (ZCS) atau Carbonio / Zextras.
2. Hak akses **root** (karena skrip menjalankan `su - zextras`).
3. Utilitas dasar: `tar`, `grep`, `awk`, `find`, `sed`.

---

## 📁 Format File Input (CSV)

Siapkan file teks input berformat CSV (`nama_akun, /path/ke/file_backup.tgz`):

```csv
user1@domain.com, /backup/user1@domain.com.tgz
user2@domain.com, /backup/user2@domain.com.tgz
user3@domain.com, /backup/user3@domain.com.tgz
```

---

## 🛠️ Cara Penggunaan

1. Berikan izin eksekusi pada skrip:
   ```bash
   chmod +x import-mailbox.sh
   ```

2. Jalankan skrip sebagai root dengan menyertakan path file input:
   ```bash
   sudo ./import-mailbox.sh /path/ke/file_input.csv
   ```

---

## 📊 Lokasi Log & Laporan

- **Direktori Log Batch**: `/var/log/restore-mailbox/batch-X/`
- **Ringkasan Seluruh Akun**: `/var/log/restore-mailbox/batch-X/summary_report.txt`
- **Log Rinci per Akun**: `/var/log/restore-mailbox/batch-X/<nama_akun>.log`

---

## 📄 Lisensi

MIT License.
