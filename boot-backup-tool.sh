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

    mkdir -p "$BACKUP_DIR"
    DATE=$(date +"%Y-%m-%d_%H-%M-%S")
    SAFE_NAME=$(echo "$PARTITION" | tr '/' '_' | tr -d '\n')
    EXT=$(get_file_extension)
    BASENAME="${SAFE_NAME}-${DATE}"
    IMAGE="$BACKUP_DIR/${BASENAME}.${EXT}"
    CHECKSUM="$BACKUP_DIR/${BASENAME}.sha256"
    SIGNATURE="$BACKUP_DIR/${BASENAME}.sig"
    LOGFILE="$BACKUP_DIR/partition-backup.log"

    echo -e "\033[1;36m[$DATE] 🔁 Starting backup of $PARTITION using $COMPRESSION_ALGO ($COMPRESSION_PRESET preset)\033[0m" | tee -a "$LOGFILE"

    SIZE=$(sudo blockdev --getsize64 "$PARTITION")

    case "$COMPRESSION_ALGO" in
        zstd)
            (
                sudo dd if="$PARTITION" bs=1M 2>/dev/null | \
                pv -s "$SIZE" --rate --eta --bytes --name "🔁 Backup Progress" | \
                zstd $(get_compression_args) -T0 -q -o "$IMAGE"
            )
            ;;
        gzip)
            (
                sudo dd if="$PARTITION" bs=1M 2>/dev/null | \
                pv -s "$SIZE" --rate --eta --bytes --name "🔁 Backup Progress" | \
                gzip $(get_compression_args) > "$IMAGE"
            )
            ;;
        xz)
            (
                sudo dd if="$PARTITION" bs=1M 2>/dev/null | \
                pv -s "$SIZE" --rate --eta --bytes --name "🔁 Backup Progress" | \
                xz $(get_compression_args) > "$IMAGE"
            )
            ;;
    esac

    if [ -f "$IMAGE" ]; then
        echo -e "\033[1;32m[$DATE] ✅ Backup successful: $IMAGE\033[0m" | tee -a "$LOGFILE"
        FILESIZE=$(du -h "$IMAGE" | cut -f1)
        echo "📦 Final backup size: $FILESIZE" | tee -a "$LOGFILE"
        sha256sum "$IMAGE" > "$CHECKSUM"

        if [ "$GPG_SIGNING_ENABLED" = true ] && [ -n "$GPG_KEY_ID" ]; then
            gpg --local-user "$GPG_KEY_ID" --output "$SIGNATURE" --detach-sign "$IMAGE"
            echo "🔏 GPG signature created: $SIGNATURE"
        fi
    else
        echo -e "\033[1;31m[$DATE] ❌ Backup failed or file not created: $IMAGE\033[0m" | tee -a "$LOGFILE"
        ls -l "$BACKUP_DIR"
        return 1
    fi

    # === Backup Rotation ===
    echo "🔁 Checking for old backups to remove (limit: $MAX_BACKUPS)"
    EXTENSION=$(get_file_extension)
    PREFIX=$(echo "$PARTITION" | tr '/' '_')
    BACKUPS=( $(ls -1t "$BACKUP_DIR"/${PREFIX}-*.${EXTENSION} 2>/dev/null) )

    if (( ${#BACKUPS[@]} > MAX_BACKUPS )); then
        for ((i=MAX_BACKUPS; i<${#BACKUPS[@]}; i++)); do
            echo "🗑️ Removing old backup: ${BACKUPS[$i]}"
            rm -f "${BACKUPS[$i]}"
            rm -f "${BACKUPS[$i]%.$EXTENSION}.sha256"
            rm -f "${BACKUPS[$i]%.$EXTENSION}.sig"
        done
    fi
}

# === Restore Function ===
restore_partition() {
    echo "Available backups:"
    BACKUPS=($(ls -1t "$BACKUP_DIR"/*.img.* 2>/dev/null))

    if [ ${#BACKUPS[@]} -eq 0 ]; then
        echo "❌ No backups found."
        return 1
    fi

    for i in "${!BACKUPS[@]}"; do
        echo "$((i+1))) $(basename "${BACKUPS[$i]}")"
    done

    read -p "Select backup to restore [1-${#BACKUPS[@]}] or 0 to cancel: " CHOICE
    if [[ "$CHOICE" =~ ^[0-9]+$ ]] && (( CHOICE >= 1 && CHOICE <= ${#BACKUPS[@]} )); then
        SELECTED="${BACKUPS[$((CHOICE-1))]}"
        echo "Selected: $SELECTED"

        read -p "⚠️ Confirm target partition to overwrite (e.g. /dev/sda1): " TARGET
        if [[ "$TARGET" =~ ^/dev/ ]]; then
            EXT="${SELECTED##*.}"
            case "$EXT" in
                zst) zstd -d "$SELECTED" -c | sudo dd of="$TARGET" bs=1M status=progress ;;
                gz) gunzip -c "$SELECTED" | sudo dd of="$TARGET" bs=1M status=progress ;;
                xz) unxz -c "$SELECTED" | sudo dd of="$TARGET" bs=1M status=progress ;;
            esac
            echo "✅ Restore completed."
        else
            echo "❌ Invalid target device."
        fi
    else
        echo "Restore canceled."
    fi
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
    echo "8) Exit"
    echo "------------------------------------"
    read -p "Choose an option [1-8]: " CHOICE

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
        8) echo "Bye!"; exit 0 ;;
        *) echo "Invalid choice." ;;
    esac
done







