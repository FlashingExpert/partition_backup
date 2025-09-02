#!/bin/bash

# === Partition Backup Tool ===
# Features: Compression presets, algorithm switching, persistent config, rotation, clean UI

# === Config ===
CONFIG_FILE="$HOME/.partition-backup.conf"
DEFAULT_BACKUP_DIR="$HOME/Boot-Partition-backup"
PARTITION=""
MAX_BACKUPS=5
GPG_SIGNING_ENABLED=true
GPG_KEY_ID=""

# Load config if available
load_config() {
    if [[ -f "$CONFIG_FILE" ]]; then
        source "$CONFIG_FILE"
    else
        BACKUP_DIR="$DEFAULT_BACKUP_DIR"
        COMPRESSION_PRESET="max"
        COMPRESSION_ALGO="zstd"
        save_config
    fi
}

set_backup_dir() {
    echo -e "\n\033[1;34m>>> Select Backup Directory <<<\033[0m"

    choices=()
    # Detect mounted drives
    if [ -d "/mnt" ]; then
        for d in /mnt/*; do
            [ -d "$d" ] && choices+=("$d")
        done
    fi
    if [ -d "/run/media/$USER" ]; then
        for d in /run/media/$USER/*; do
            [ -d "$d" ] && choices+=("$d")
        done
    fi

    # If no drives found, ask manually
    if [ ${#choices[@]} -eq 0 ]; then
        read -rp "No external drives found. Enter path manually: " new_dir
    else
        echo "Available mount points:"
        i=1
        for d in "${choices[@]}"; do
            echo "  $i) $d"
            ((i++))
        done
        echo "  $i) Enter custom path"
        read -rp "Choose [1-$i]: " choice

        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "$i" ]; then
            if [ "$choice" -eq "$i" ]; then
                read -rp "Enter full path manually: " new_dir
            else
                new_dir="${choices[$((choice-1))]}"
            fi
        else
            echo -e "\033[1;31mInvalid choice.\033[0m"
            return
        fi
    fi

    # Normalize path (remove trailing slash)
    new_dir="${new_dir%/}"

    # Check write permission
    if [ ! -w "$new_dir" ]; then
        echo -e "\033[1;31mNo write permission in $new_dir.\033[0m"
        return
    fi

    # Auto-create partition_backup subfolder
    BACKUP_DIR="$new_dir/partition_backup"
    if [ ! -d "$BACKUP_DIR" ]; then
        mkdir -p "$BACKUP_DIR" || {
            echo -e "\033[1;31mFailed to create backup folder: $BACKUP_DIR\033[0m"
            return
        }
        echo -e "\033[1;32mBackup folder created: $BACKUP_DIR\033[0m"
    else
        echo -e "\033[1;32mBackup folder exists: $BACKUP_DIR\033[0m"
    fi

    # Show free space
    FREE=$(df -h "$new_dir" | tail -1 | awk '{print $4}')
    echo "📦 Free space on selected drive: $FREE"

    save_config
    echo -e "\033[1;32m✅ Backup directory set to: $BACKUP_DIR\033[0m"
}

save_config() {
    cat <<EOF > "$CONFIG_FILE"
BACKUP_DIR="$BACKUP_DIR"
COMPRESSION_PRESET="$COMPRESSION_PRESET"
COMPRESSION_ALGO="$COMPRESSION_ALGO"
GPG_SIGNING_ENABLED="$GPG_SIGNING_ENABLED"
GPG_KEY_ID="$GPG_KEY_ID"
EOF
}

# === Compression Preset Logic ===
get_compression_args() {
    case "$COMPRESSION_ALGO" in
        zstd)
            case "$COMPRESSION_PRESET" in
                fast) echo "-1" ;;
                balanced) echo "-9" ;;
                max) echo "--ultra -22" ;;
            esac
            ;;
        gzip)
            case "$COMPRESSION_PRESET" in
                fast) echo "-1" ;;
                balanced) echo "-6" ;;
                max) echo "-9" ;;
            esac
            ;;
        xz)
            case "$COMPRESSION_PRESET" in
                fast) echo "-1" ;;
                balanced) echo "-6" ;;
                max) echo "-9e" ;;
            esac
            ;;
    esac
}

get_file_extension() {
    case "$COMPRESSION_ALGO" in
        zstd) echo "img.zst" ;;
        gzip) echo "img.gz" ;;
        xz) echo "img.xz" ;;
    esac
}

# === Partition Selection ===
select_partition() {
    echo "Available partitions:"
    PARTS=()
    i=1

    while read -r line; do
        DEVICE=$(echo "$line" | awk '{print $1}')
        SIZE=$(echo "$line" | awk '{print $2}')
        MOUNT=$(echo "$line" | cut -d' ' -f3-)
        PARTS+=("$DEVICE")
        printf "%2d) %-15s %-8s %s\n" "$i" "$DEVICE" "$SIZE" "$MOUNT"
        ((i++))
    done < <(lsblk -lnpo NAME,SIZE,MOUNTPOINT | grep -E '^/dev/')

    read -p "Enter number of partition to back up (or 0 to cancel): " CHOICE
    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#PARTS[@]} )); then
        PARTITION="${PARTS[$((CHOICE-1))]}"
        echo "✅ Selected partition: $PARTITION"

        BACKUP_MOUNT=$(df --output=source "$BACKUP_DIR" 2>/dev/null | tail -n1)
        BACKUP_FREE=$(df -h "$BACKUP_DIR" 2>/dev/null | tail -1 | awk '{print $4}')
        echo "📦 Free space on backup drive ($BACKUP_MOUNT): $BACKUP_FREE"
    else
        echo "❌ Invalid selection or canceled."
    fi
}

# === Backup Function ===
backup_partition() {
    if [ -z "$PARTITION" ]; then
        echo "⚠️ No partition selected. Use option 1 to select a partition first."
        return 1
    fi

    set -o errexit -o nounset -o pipefail

    # Ensure backup directory exists
    BACKUP_DIR="${BACKUP_DIR%/}/partition_backup"
    mkdir -p "$BACKUP_DIR"

    DATE=$(date +"%Y-%m-%d_%H-%M-%S")
    SAFE_NAME=$(echo "$PARTITION" | tr '/' '_')
    EXT=$(get_file_extension)
    BASENAME="${SAFE_NAME}-${DATE}"
    IMAGE="$BACKUP_DIR/${BASENAME}.${EXT}"
    CHECKSUM="$BACKUP_DIR/${BASENAME}.sha256"
    SIGNATURE="$BACKUP_DIR/${BASENAME}.sig"
    LOGFILE="$BACKUP_DIR/partition-backup.log"

    echo -e "\033[1;36m[$DATE] 🔁 Starting backup of $PARTITION using $COMPRESSION_ALGO ($COMPRESSION_PRESET preset)\033[0m" | tee -a "$LOGFILE"

    SIZE=$(sudo blockdev --getsize64 "$PARTITION")
    echo "Total size to back up: $(numfmt --to=iec "$SIZE")"

    START_TIME=$(date +%s)

    # Backup with dd + pv + compression
    case "$COMPRESSION_ALGO" in
        zstd)
            if ! sudo dd if="$PARTITION" bs=1M status=progress 2>/dev/null | \
                pv -s "$SIZE" -pterb --name "🔁 Backup Progress" | \
                zstd $(get_compression_args) -T0 -v -o "$IMAGE"; then
                echo -e "\033[1;31m❌ Backup failed during zstd compression.\033[0m" | tee -a "$LOGFILE"
                return 1
            fi
            ;;
        gzip)
            if ! sudo dd if="$PARTITION" bs=1M status=progress 2>/dev/null | \
                pv -s "$SIZE" -pterb --name "🔁 Backup Progress" | \
                gzip $(get_compression_args) -c > "$IMAGE"; then
                echo -e "\033[1;31m❌ Backup failed during gzip compression.\033[0m" | tee -a "$LOGFILE"
                return 1
            fi
            ;;
        xz)
            if ! sudo dd if="$PARTITION" bs=1M status=progress 2>/dev/null | \
                pv -s "$SIZE" -pterb --name "🔁 Backup Progress" | \
                xz $(get_compression_args) -c > "$IMAGE"; then
                echo -e "\033[1;31m❌ Backup failed during xz compression.\033[0m" | tee -a "$LOGFILE"
                return 1
            fi
            ;;
        *)
            echo "❌ Unsupported compression algorithm: $COMPRESSION_ALGO"
            return 1
            ;;
    esac

    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    ELAPSED_HMS=$(printf '%02d:%02d:%02d\n' $((ELAPSED/3600)) $(( (ELAPSED%3600)/60 )) $((ELAPSED%60)))

    # Verify backup file exists
    if [ ! -f "$IMAGE" ]; then
        echo -e "\033[1;31m❌ Backup file was not created: $IMAGE\033[0m" | tee -a "$LOGFILE"
        return 1
    fi

    FILESIZE=$(stat -c%s "$IMAGE")
    HUMAN_SIZE=$(numfmt --to=iec "$FILESIZE")
    echo -e "\033[1;32m[$DATE] ✅ Backup successful: $IMAGE\033[0m" | tee -a "$LOGFILE"
    echo "📦 Final backup size: $HUMAN_SIZE ($FILESIZE bytes)" | tee -a "$LOGFILE"

    # Compression ratio
    RATIO=$(awk "BEGIN {printf \"%.2f\", $FILESIZE/$SIZE*100}")
    echo "📊 Compression ratio: $RATIO%" | tee -a "$LOGFILE"
    echo "⏱️ Time taken: $ELAPSED_HMS (HH:MM:SS)" | tee -a "$LOGFILE"

    # SHA256 checksum
    sha256sum "$IMAGE" > "$CHECKSUM"
    echo "🔐 Checksum created: $CHECKSUM" | tee -a "$LOGFILE"

    # Optional GPG signing
    if [ "$GPG_SIGNING_ENABLED" = true ] && [ -n "$GPG_KEY_ID" ]; then
        if gpg --local-user "$GPG_KEY_ID" --output "$SIGNATURE" --detach-sign "$IMAGE"; then
            echo "🔏 GPG signature created: $SIGNATURE" | tee -a "$LOGFILE"
        else
            echo "❌ GPG signing failed." | tee -a "$LOGFILE"
        fi
    fi

    # === Backup Rotation ===
    echo "🔁 Checking for old backups to remove (limit: $MAX_BACKUPS)"
    PREFIX=$(echo "$PARTITION" | tr '/' '_')
    mapfile -t BACKUPS < <(ls -1t "$BACKUP_DIR"/"${PREFIX}-"*."$EXT" 2>/dev/null || true)
    COUNT=${#BACKUPS[@]}

    if (( COUNT > MAX_BACKUPS )); then
        for ((i=MAX_BACKUPS; i<COUNT; i++)); do
            OLD="${BACKUPS[$i]}"
            echo "🗑️  Removing old backup: $OLD"
            rm -f "$OLD" "$OLD.sha256" "$OLD.sig"
        done
    fi
}

# === Restore Function ===
restore_partition() {
    LOGFILE="$BACKUP_DIR/partition-backup.log"

    echo "🔍 Available backups:"
    mapfile -t BACKUPS < <(ls -1t "$BACKUP_DIR"/*.img.zst "$BACKUP_DIR"/*.img.gz "$BACKUP_DIR"/*.img.xz 2>/dev/null || true)

    if [ "${#BACKUPS[@]}" -eq 0 ]; then
        echo "❌ No backups found."
        return 1
    fi

    for i in "${!BACKUPS[@]}"; do
        echo "$((i+1))) $(basename "${BACKUPS[$i]}")"
    done

    read -p "Select backup to restore [1-${#BACKUPS[@]}] or 0 to cancel: " CHOICE
    if ! [[ "$CHOICE" =~ ^[0-9]+$ ]] || (( CHOICE < 1 || CHOICE > ${#BACKUPS[@]} )); then
        echo "Restore canceled."
        return
    fi

    SELECTED="${BACKUPS[$((CHOICE-1))]}"
    DATE=$(date +"%Y-%m-%d_%H-%M-%S")
    echo -e "[$DATE] 🔄 Selected backup: $SELECTED" | tee -a "$LOGFILE"

    # Verify checksum
    CHECKSUM_FILE="${SELECTED}.sha256"
    if [ -f "$CHECKSUM_FILE" ]; then
        if ! sha256sum -c "$CHECKSUM_FILE"; then
            echo "❌ Checksum verification failed. Aborting restore." | tee -a "$LOGFILE"
            return 1
        else
            echo "✅ Checksum verified." | tee -a "$LOGFILE"
        fi
    else
        echo "⚠️ Checksum file not found: $CHECKSUM_FILE" | tee -a "$LOGFILE"
    fi

    # Optional GPG signature
    SIGN_FILE="${SELECTED}.sig"
    if [ "$GPG_SIGNING_ENABLED" = true ] && [ -f "$SIGN_FILE" ]; then
        if gpg --verify "$SIGN_FILE" "$SELECTED"; then
            echo "🔏 GPG signature verified." | tee -a "$LOGFILE"
        else
            echo "❌ GPG signature verification failed. Aborting restore." | tee -a "$LOGFILE"
            return 1
        fi
    fi

    # Prompt target partition
    read -p "⚠️ Enter target partition to overwrite (e.g., /dev/sda1): " TARGET
    if ! [[ "$TARGET" =~ ^/dev/ ]]; then
        echo "❌ Invalid target device." | tee -a "$LOGFILE"
        return 1
    fi

    echo "⚠️ Restoring backup to $TARGET. All data on this partition will be lost!"
    echo "You have 5 seconds to cancel (Ctrl+C)..."
    sleep 5

    SIZE=$(stat -c%s "$SELECTED")
    EXT="${SELECTED##*.}"

    echo "🔁 Restoring $SELECTED → $TARGET" | tee -a "$LOGFILE"

    case "$EXT" in
        zst)
            if ! pv -s "$SIZE" "$SELECTED" | zstd -d -c | sudo dd of="$TARGET" bs=1M conv=fsync status=progress; then
                echo "❌ Restore failed during zstd decompression." | tee -a "$LOGFILE"
                return 1
            fi
            ;;
        gz)
            if ! pv -s "$SIZE" "$SELECTED" | gunzip -c | sudo dd of="$TARGET" bs=1M conv=fsync status=progress; then
                echo "❌ Restore failed during gzip decompression." | tee -a "$LOGFILE"
                return 1
            fi
            ;;
        xz)
            if ! pv -s "$SIZE" "$SELECTED" | unxz -c | sudo dd of="$TARGET" bs=1M conv=fsync status=progress; then
                echo "❌ Restore failed during xz decompression." | tee -a "$LOGFILE"
                return 1
            fi
            ;;
        *)
            echo "❌ Unsupported backup format: $EXT" | tee -a "$LOGFILE"
            return 1
            ;;
    esac

    echo -e "✅ Restore completed successfully: $TARGET" | tee -a "$LOGFILE"
}

# === Full Disk Backup (including bootloader) ===

FULL_DISK_MAX_BACKUPS="${FULL_DISK_MAX_BACKUPS:-5}"   # rotation for disk images

get_disk_compression_ext() {
    case "$COMPRESSION_ALGO" in
        zstd) echo "img.zst" ;;
        gzip) echo "img.gz" ;;
        xz)   echo "img.xz" ;;
        *)    echo "img" ;;
    esac
}

get_disk_compression_cmd() {
    case "$COMPRESSION_ALGO" in
        zstd) echo "zstd $(get_compression_args) -T0 -v -o" ;;
        gzip) echo "gzip $(get_compression_args) -c >" ;;
        xz)   echo "xz $(get_compression_args) -c >" ;;
    esac
}

select_disk() {
    echo -e "\n\033[1;34m>>> Select WHOLE DISK to back up (NOT a partition) <<<\033[0m"
    # List whole disks only
    lsblk -dnpo NAME,SIZE,TYPE,MODEL | awk '$3=="disk"{printf "%-20s %-8s %s\n",$1,$2,$4}'
    read -rp "Enter disk device (e.g., /dev/sda or /dev/nvme0n1), or empty to cancel: " WHOLE_DISK
    [[ -z "$WHOLE_DISK" ]] && { echo "Cancelled."; return 1; }

    # Validate it's a disk device
    if ! lsblk -dnpo NAME,TYPE | awk '$2=="disk"{print $1}' | grep -qx "$WHOLE_DISK"; then
        echo "❌ '$WHOLE_DISK' is not a whole-disk device."
        return 1
    fi

    # Warn if any partitions are mounted
    if lsblk -nrpo MOUNTPOINT "$WHOLE_DISK" | grep -q '/'; then
        echo "⚠️ One or more partitions on $WHOLE_DISK are mounted:"
        lsblk -nrpo NAME,MOUNTPOINT "$WHOLE_DISK" | awk '$2!=""{print " - "$1" -> "$2}'
        read -rp "Please unmount them first. Type 'OVERRIDE' to continue anyway: " OV
        [[ "$OV" != "OVERRIDE" ]] && { echo "Aborted."; return 1; }
    fi

    SELECTED_DISK="$WHOLE_DISK"
    echo "✅ Selected disk: $SELECTED_DISK"
}

ensure_disk_backup_dir() {
    # Create a sibling 'disk_backup' under the chosen BACKUP_DIR root
    BACKUP_ROOT="${BACKUP_DIR%/}"
    DISK_BACKUP_DIR="$BACKUP_ROOT/disk_backup"
    mkdir -p "$DISK_BACKUP_DIR"
    echo "📁 Disk backup directory: $DISK_BACKUP_DIR"
}

full_disk_backup() {
    if [[ -z "${SELECTED_DISK:-}" ]]; then
        echo "⚠️ No disk selected. Run 'select_disk' first."
        return 1
    fi

    ensure_disk_backup_dir

    DATE=$(date +"%Y-%m-%d_%H-%M-%S")
    SAFE_DISK=$(echo "$SELECTED_DISK" | tr '/' '_')
    EXT=$(get_disk_compression_ext)
    BASENAME="${SAFE_DISK}-${DATE}"
    IMAGE="$DISK_BACKUP_DIR/${BASENAME}.${EXT}"
    CHECKSUM="$DISK_BACKUP_DIR/${BASENAME}.sha256"
    SIGNATURE="$DISK_BACKUP_DIR/${BASENAME}.sig"
    LOGFILE="$DISK_BACKUP_DIR/full-disk-backup.log"

    # Reports (helpful for restore/migration)
    REPORT_DIR="$DISK_BACKUP_DIR/${BASENAME}_reports"
    mkdir -p "$REPORT_DIR"

    echo -e "\033[1;36m[$DATE] 🧰 Full-disk backup: $SELECTED_DISK using $COMPRESSION_ALGO ($COMPRESSION_PRESET)\033[0m" | tee -a "$LOGFILE"

    # Export partition table & metadata (text)
    sudo sfdisk -d "$SELECTED_DISK" > "$REPORT_DIR/partition-table.sfdisk" 2>/dev/null || true
    lsblk -e7 -o NAME,TYPE,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINT > "$REPORT_DIR/lsblk.txt" 2>/dev/null || true
    blkid > "$REPORT_DIR/blkid.txt" 2>/dev/null || true
    command -v efibootmgr >/dev/null && efibootmgr -v > "$REPORT_DIR/efibootmgr.txt" 2>/dev/null || true
    command -v sgdisk >/dev/null && sudo sgdisk --backup="$REPORT_DIR/gpt-backup.bin" "$SELECTED_DISK" 2>/dev/null || true
    command -v mdadm  >/dev/null && sudo mdadm --detail --scan > "$REPORT_DIR/mdadm.conf" 2>/dev/null || true

    SIZE=$(sudo blockdev --getsize64 "$SELECTED_DISK")
    echo "📏 Disk size: $(numfmt --to=iec "$SIZE")"

    echo "❗ This will READ the entire disk. To proceed, type the disk again: $SELECTED_DISK"
    read -rp "> " CONFIRM_DISK
    [[ "$CONFIRM_DISK" != "$SELECTED_DISK" ]] && { echo "Aborted."; return 1; }

    START_TIME=$(date +%s)

    # Stream + progress + compression
    case "$COMPRESSION_ALGO" in
        zstd)
            if ! sudo dd if="$SELECTED_DISK" bs=16M iflag=fullblock status=progress 2>/dev/null | \
                pv -s "$SIZE" -pterb --name "📀 Reading $SELECTED_DISK" | \
                zstd $(get_compression_args) -T0 -v -o "$IMAGE"; then
                echo -e "\033[1;31m❌ Full-disk backup failed (zstd).\033[0m" | tee -a "$LOGFILE"
                return 1
            fi
            ;;
        gzip)
            if ! sudo dd if="$SELECTED_DISK" bs=16M iflag=fullblock status=progress 2>/dev/null | \
                pv -s "$SIZE" -pterb --name "📀 Reading $SELECTED_DISK" | \
                gzip $(get_compression_args) -c > "$IMAGE"; then
                echo -e "\033[1;31m❌ Full-disk backup failed (gzip).\033[0m" | tee -a "$LOGFILE"
                return 1
            fi
            ;;
        xz)
            if ! sudo dd if="$SELECTED_DISK" bs=16M iflag=fullblock status=progress 2>/dev/null | \
                pv -s "$SIZE" -pterb --name "📀 Reading $SELECTED_DISK" | \
                xz $(get_compression_args) -c > "$IMAGE"; then
                echo -e "\033[1;31m❌ Full-disk backup failed (xz).\033[0m" | tee -a "$LOGFILE"
                return 1
            fi
            ;;
        *)
            echo "❌ Unsupported compression algorithm: $COMPRESSION_ALGO"
            return 1
            ;;
    esac

    END_TIME=$(date +%s)
    ELAPSED=$((END_TIME - START_TIME))
    ELAPSED_HMS=$(printf '%02d:%02d:%02d\n' $((ELAPSED/3600)) $(((ELAPSED%3600)/60)) $((ELAPSED%60)))

    if [ ! -f "$IMAGE" ]; then
        echo -e "\033[1;31m❌ No image produced: $IMAGE\033[0m" | tee -a "$LOGFILE"
        return 1
    fi

    FILESIZE=$(stat -c%s "$IMAGE")
    HUMAN_SIZE=$(numfmt --to=iec "$FILESIZE")
    RATIO=$(awk "BEGIN {printf \"%.2f\", $FILESIZE/$SIZE*100}")

    echo -e "\033[1;32m[$DATE] ✅ Full-disk backup complete: $IMAGE\033[0m" | tee -a "$LOGFILE"
    echo "📦 Compressed size: $HUMAN_SIZE ($FILESIZE bytes)" | tee -a "$LOGFILE"
    echo "📊 Compression ratio: $RATIO%" | tee -a "$LOGFILE"
    echo "⏱️ Elapsed: $ELAPSED_HMS" | tee -a "$LOGFILE"
    echo "📝 Reports saved to: $REPORT_DIR" | tee -a "$LOGFILE"

    sha256sum "$IMAGE" > "$CHECKSUM"
    echo "🔐 Checksum: $CHECKSUM" | tee -a "$LOGFILE"

    if [ "$GPG_SIGNING_ENABLED" = true ] && [ -n "$GPG_KEY_ID" ]; then
        if gpg --local-user "$GPG_KEY_ID" --output "$SIGNATURE" --detach-sign "$IMAGE"; then
            echo "🔏 GPG signature: $SIGNATURE" | tee -a "$LOGFILE"
        else
            echo "❌ GPG signing failed." | tee -a "$LOGFILE"
        fi
    fi

    # Rotation
    echo "🔁 Rotation (keep newest $FULL_DISK_MAX_BACKUPS)"
    PREFIX="$SAFE_DISK-"
    mapfile -t IMAGES < <(ls -1t "$DISK_BACKUP_DIR"/${PREFIX}*.${EXT} 2>/dev/null || true)
    COUNT=${#IMAGES[@]}
    if (( COUNT > FULL_DISK_MAX_BACKUPS )); then
        for ((i=FULL_DISK_MAX_BACKUPS; i<COUNT; i++)); do
            OLD="${IMAGES[$i]}"
            echo "🗑️  Deleting old: $OLD"
            rm -f "$OLD" "$OLD.sha256" "$OLD.sig"
            rm -rf "${OLD%.*}_reports"
        done
    fi
}

restore_full_disk() {
    ensure_disk_backup_dir
    echo "🔍 Available full-disk images:"
    mapfile -t IMAGES < <(ls -1t "$DISK_BACKUP_DIR"/*.img.zst "$DISK_BACKUP_DIR"/*.img.gz "$DISK_BACKUP_DIR"/*.img.xz 2>/dev/null || true)
    [[ "${#IMAGES[@]}" -eq 0 ]] && { echo "❌ No images found."; return 1; }

    for i in "${!IMAGES[@]}"; do
        echo "$((i+1))) $(basename "${IMAGES[$i]}")"
    done
    read -rp "Select image to restore [1-${#IMAGES[@]}] (0 to cancel): " CH
    [[ ! "$CH" =~ ^[0-9]+$ ]] && { echo "Cancelled."; return 1; }
    (( CH == 0 )) && { echo "Cancelled."; return 0; }
    (( CH < 1 || CH > ${#IMAGES[@]} )) && { echo "Invalid."; return 1; }

    IMG="${IMAGES[$((CH-1))]}"
    EXT="${IMG##*.}"
    echo "Selected: $IMG"

    # Optional checksum verify
    if [ -f "${IMG}.sha256" ]; then
        if ! sha256sum -c "${IMG}.sha256"; then
            echo "❌ Checksum failed; aborting."
            return 1
        fi
    fi

    # Target disk confirm
    lsblk -dnpo NAME,SIZE,TYPE,MODEL | awk '$3=="disk"{printf "%-20s %-8s %s\n",$1,$2,$4}'
    read -rp "⚠️ Target WHOLE DISK to overwrite (e.g., /dev/sda): " TARGET_DISK
    if ! lsblk -dnpo NAME,TYPE | awk '$2=="disk"{print $1}' | grep -qx "$TARGET_DISK"; then
        echo "❌ Not a disk: $TARGET_DISK"
        return 1
    fi
    echo "This will destroy ALL data on $TARGET_DISK. Type 'I UNDERSTAND' to proceed:"
    read -r CONFIRM
    [[ "$CONFIRM" != "I UNDERSTAND" ]] && { echo "Aborted."; return 1; }

    # Restore stream with progress
    case "$EXT" in
        zst)  zstd -d "$IMG" -c | sudo dd of="$TARGET_DISK" bs=16M conv=fsync status=progress ;;
        gz)   gunzip -c "$IMG"   | sudo dd of="$TARGET_DISK" bs=16M conv=fsync status=progress ;;
        xz)   unxz -c "$IMG"     | sudo dd of="$TARGET_DISK" bs=16M conv=fsync status=progress ;;
        *)    echo "❌ Unsupported format: $EXT"; return 1 ;;
    esac
    sync
    echo "✅ Full-disk restore complete. You may need to reconfigure UEFI boot order (see saved efibootmgr.txt)."
}

# === Menu hooks (add to your main menu) ===
full_disk_menu() {
    while true; do
        echo ""
        echo "==== Full Disk Backup ===="
        echo "Disk selected: ${SELECTED_DISK:-<none>}"
        echo "Backup root:   ${BACKUP_DIR:-<unset>}"
        echo "Compression:   $COMPRESSION_ALGO ($COMPRESSION_PRESET)"
        echo "---------------------------"
        echo "1) Select disk"
        echo "2) Run full-disk backup"
        echo "3) Restore full-disk image"
        echo "4) Show last reports folder"
        echo "5) Back"
        read -rp "Choose: " c
        case "$c" in
            1) select_disk ;;
            2) full_disk_backup ;;
            3) restore_full_disk ;;
            4) ls -1dt "${DISK_BACKUP_DIR:-$BACKUP_DIR/disk_backup}"/*_reports 2>/dev/null | head -n1 ;;
            5) break ;;
            *) echo "Invalid." ;;
        esac
    done
}
# === Main Menu ===
load_config

while true; do
    echo ""
    echo "==== Partition Backup Tool ===="
    echo "Selected partition: ${PARTITION:-<none>}"
    echo "Backup directory: $BACKUP_DIR"
    echo "Compression: $COMPRESSION_ALGO ($COMPRESSION_PRESET)"
    echo "GPG signing: ${GPG_SIGNING_ENABLED:-false}"
    echo "GPG key: ${GPG_KEY_ID:-<none>}"
    echo "------------------------------------"
    echo "1) Select partition to back up"
    echo "2) Backup selected partition"
    echo "3) Restore from backup"
    echo "4) Change compression preset"
    echo "5) Change compression algorithm"
    echo "6) Toggle GPG signing"
    echo "7) Set GPG key ID"
    echo "8) Set Backup Dir"
    echo "9) backup whole drive"
    echo "10) Exit"
    echo "------------------------------------"
    read -p "Choose an option [1-10]: " CHOICE

    case "$CHOICE" in
        1) select_partition ;;
        2) backup_partition ;;
        3) restore_partition ;;
        4)
            echo "Presets: fast, balanced, max"
            read -p "Enter compression preset: " PRESET
            if [[ "$PRESET" =~ ^(fast|balanced|max)$ ]]; then
                COMPRESSION_PRESET="$PRESET"
                save_config
            else
                echo "❌ Invalid preset."
            fi
            ;;
        5)
            echo "Algorithms: zstd, gzip, xz"
            read -p "Enter compression algorithm: " ALGO
            if [[ "$ALGO" =~ ^(zstd|gzip|xz)$ ]]; then
                COMPRESSION_ALGO="$ALGO"
                save_config
            else
                echo "❌ Invalid algorithm."
            fi
            ;;
        6)
            if [ "$GPG_SIGNING_ENABLED" = true ]; then
                GPG_SIGNING_ENABLED=false
            else
                GPG_SIGNING_ENABLED=true
            fi
            save_config
            echo "GPG signing set to: $GPG_SIGNING_ENABLED"
            ;;
        7)
            read -p "Enter GPG key ID/email to use for signing: " GPG_KEY_ID
            save_config
            ;;
        8) set_backup_dir ;;
        9) full_disk_menu ;;
        10) echo "Bye!"; exit 0 ;;
        *) echo "Invalid choice." ;;
    esac
done
