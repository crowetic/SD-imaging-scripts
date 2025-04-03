#!/bin/bash
set -e

SECTOR_SIZE=512
PADDING_MB=4
IMAGE=""
RESIZED_IMAGE=""
COMPRESSED_NAME=""

echo "==== 🔍 Smart SD Image Shrinker ===="

# === Step 1: Find .img files ===
mapfile -t IMAGES < <(find . -maxdepth 1 -type f -name "*.img" | sort)

if [ ${#IMAGES[@]} -eq 0 ]; then
  echo "❌ No .img files found in the current directory."
  exit 1
fi

echo ""
echo "📂 Found the following .img files:"
for i in "${!IMAGES[@]}"; do
  printf "  [%d] %s\n" "$((i+1))" "${IMAGES[$i]}"
done

echo ""
read -p "👉 Enter the number of the image you want to shrink: " SELECTION

if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt "${#IMAGES[@]}" ]; then
  echo "❌ Invalid selection."
  exit 1
fi

IMAGE="${IMAGES[$((SELECTION-1))]}"
BASENAME=$(basename "$IMAGE")
echo "✅ Selected: $IMAGE"
echo ""

# === Step 2: Select auto or manual sizing ===
echo "📏 Choose target size mode:"
echo "  [1] Auto-select smallest SD card (adds 2GB headroom)"
echo "  [2] Choose target SD card size manually"
read -p "👉 Enter your choice [1-2]: " SIZE_MODE

if [[ "$SIZE_MODE" != "1" && "$SIZE_MODE" != "2" ]]; then
  echo "❌ Invalid selection."
  exit 1
fi

# === Step 3: Auto-fix GPT if needed ===
echo "[*] Pre-checking GPT for leftover space issues..."
echo -e "w\ny\n" | sudo gdisk "$IMAGE" >/dev/null 2>&1 || true

# === Step 4: Attach image to loop device ===
echo "📌 Attaching image to loop device..."
LOOP_DEV=$(sudo losetup --show -Pf "$IMAGE")

# === Step 5: Detect rootfs ===
PARTS=$(lsblk -nrpo NAME "$LOOP_DEV" | grep -E "$LOOP_DEV"p)
ROOT_PART=$(for P in $PARTS; do lsblk -bno SIZE "$P" | awk -v p="$P" '{print $1, p}'; done | sort -nr | head -n1 | awk '{print $2}')

if [ -z "$ROOT_PART" ]; then
  echo "❌ Error: Couldn't detect root partition."
  sudo losetup -d "$LOOP_DEV"
  exit 1
fi

PART_NUM=$(basename "$ROOT_PART" | grep -o '[0-9]*$')
echo "🔍 Detected rootfs: $ROOT_PART (Partition #$PART_NUM)"

# === Step 6: Unmount if mounted ===
sudo umount "$ROOT_PART" 2>/dev/null || true

# === Step 7: Determine used space + headroom ===
USED_MB=$(sudo df -m "$ROOT_PART" | awk 'NR==2 {print $3}')
REQUIRED_MB=$(( USED_MB + 2048 ))

# === Define known SD card sizes (actual usable MB) ===
declare -A SD_SIZES
SD_SIZES=(
  ["8GB"]=6900
  ["16GB"]=13500
  ["32GB"]=29000
  ["64GB"]=59000
  ["128GB"]=119000
)

# === Determine final TARGET_SIZE_MB ===
if [ "$SIZE_MODE" == "1" ]; then
  echo "🧠 Auto-selecting smallest SD card size to fit $REQUIRED_MB MB..."

  for label in 8GB 16GB 32GB 64GB 128GB; do
    if [ "$REQUIRED_MB" -le "${SD_SIZES[$label]}" ]; then
      TARGET_SIZE_MB=${SD_SIZES[$label]}
      SIZE_LABEL=$label
      echo "✅ Selected size: $SIZE_LABEL (${TARGET_SIZE_MB} MB)"
      break
    fi
  done

  if [ -z "$SIZE_LABEL" ]; then
    echo "❌ No supported SD size large enough. Required: $REQUIRED_MB MB"
    sudo losetup -d "$LOOP_DEV"
    exit 1
  fi

else
  echo ""
  echo "📐 Choose target SD card size:"
  OPTIONS=("8GB" "16GB" "32GB" "64GB" "128GB")
  for i in "${!OPTIONS[@]}"; do
    printf "  [%d] %s\n" "$((i+1))" "${OPTIONS[$i]}"
  done
  read -p "👉 Enter your choice [1-5]: " SIZE_CHOICE

  if ! [[ "$SIZE_CHOICE" =~ ^[1-5]$ ]]; then
    echo "❌ Invalid selection."
    sudo losetup -d "$LOOP_DEV"
    exit 1
  fi

  SIZE_LABEL=${OPTIONS[$((SIZE_CHOICE-1))]}
  TARGET_SIZE_MB=${SD_SIZES[$SIZE_LABEL]}

  if [ "$REQUIRED_MB" -gt "$TARGET_SIZE_MB" ]; then
    echo "⚠️  $SIZE_LABEL is too small to hold this data (need $REQUIRED_MB MB)"
    echo "🔁 Auto-selecting next size up..."

    FOUND=0
    for label in 16GB 32GB 64GB 128GB; do
      if [ "$REQUIRED_MB" -le "${SD_SIZES[$label]}" ]; then
        TARGET_SIZE_MB=${SD_SIZES[$label]}
        SIZE_LABEL=$label
        echo "✅ Switched to: $SIZE_LABEL (${TARGET_SIZE_MB} MB)"
        FOUND=1
        break
      fi
    done

    if [ "$FOUND" -eq 0 ]; then
      echo "❌ No SD size large enough. Required: $REQUIRED_MB MB"
      sudo losetup -d "$LOOP_DEV"
      exit 1
    fi
  else
    echo "✅ Selected target: $SIZE_LABEL (${TARGET_SIZE_MB} MB)"
  fi
fi

# === Step 8: fsck and resize ===
echo "🔧 Running fsck and shrinking rootfs..."
sudo e2fsck -fy "$ROOT_PART" | tee fsck.log
if grep -q "FILE SYSTEM WAS MODIFIED" fsck.log; then
  echo "🔁 FS was modified. Re-checking..."
  sudo e2fsck -fy "$ROOT_PART"
fi
rm -f fsck.log
sudo resize2fs "$ROOT_PART" "${TARGET_SIZE_MB}M"

# === Step 9: Resize partition ===
START_SECTOR=$(sudo parted -s "$IMAGE" unit s print | grep "^ $PART_NUM" | awk '{print $2}' | sed 's/s//')
TARGET_SECTORS=$((TARGET_SIZE_MB * 1024 * 1024 / SECTOR_SIZE))
END_SECTOR=$((START_SECTOR + TARGET_SECTORS - 1))

PART_TYPE=$(sudo parted -s "$IMAGE" print | grep "Partition Table" | awk '{print $3}')
echo "🧠 Partition table type: $PART_TYPE"

if [[ "$PART_TYPE" == "msdos" ]]; then
  echo "🔧 Updating MBR partition..."
  PART_DEV="./${BASENAME}${PART_NUM}"
  echo "🧪 Looking for partition entry named: $PART_DEV"
  echo "📄 sfdisk --dump preview:"
  sudo sfdisk --dump "$IMAGE" | grep "$PART_DEV"
  TEMP_SFDISK="temp-sfdisk-edit.txt"

  echo "📄 Updating partition entry for: $PART_DEV"

  sudo sfdisk --dump "$IMAGE" | awk -v dev="$PART_DEV" -v start="$START_SECTOR" -v end="$END_SECTOR" '
  BEGIN { updated = 0 }
  {
    if ($1 == dev) {
      size = end - start + 1
      print $1 " : start=" start ", size=" size ", type=83"
      updated = 1
    } else {
      print $0
    } 
  }
  END {
    if (updated == 0) {
      print "❌ Failed to update partition: entry not found for " dev > "/dev/stderr"
      exit 1
    }
  }' > "$TEMP_SFDISK"

  sudo sfdisk "$IMAGE" < "$TEMP_SFDISK"
  rm -f "$TEMP_SFDISK"

elif [[ "$PART_TYPE" == "gpt" ]]; then
  echo "🔧 Updating GPT partition..."
  sudo sgdisk --delete=$PART_NUM "$IMAGE"
  sudo sgdisk --new=$PART_NUM:$START_SECTOR:$END_SECTOR "$IMAGE"
else
  echo "❌ Unknown partition type: $PART_TYPE"
  sudo losetup -d "$LOOP_DEV"
  exit 1
fi

# === Step 10: Detach + truncate resized image ===
sudo losetup -d "$LOOP_DEV"
TRUNC_SIZE=$(( (END_SECTOR + (PADDING_MB * 1024 * 1024 / SECTOR_SIZE)) * SECTOR_SIZE ))
RESIZED_IMAGE="resized-${SIZE_LABEL}-${BASENAME}"
echo "✂️ Creating resized image: $RESIZED_IMAGE"
dd if="$IMAGE" of="$RESIZED_IMAGE" bs=1M count=$((TRUNC_SIZE / 1024 / 1024)) status=progress

# === Step 11: Compress ===
echo "📦 Compressing to .xz..."
xz -T0 -9 "$RESIZED_IMAGE"
echo ""
echo "🔍 Verifying compressed image..."
if xz -t "${RESIZED_IMAGE}.xz"; then
  echo "✅ Compression verified!"
else
  echo "❌ Compression failed! The .xz file may be corrupted."
  exit 1
fi
echo ""
echo "✅ Done! Output: ${RESIZED_IMAGE}.xz"

