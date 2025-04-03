#!/bin/bash
set -e

RESIZE_SCRIPT="./auto-shrink-compress-img.sh"

echo "==== 🧠 SD Card Disk Imager + Auto Resize ===="

# === Step 1: Detect likely SD card devices ===
echo ""
echo "📦 Scanning for removable storage devices..."
mapfile -t DISKS < <(lsblk -dpno NAME,MODEL,SIZE,RM | awk '$4 == 1 { print $1 }')

if [ ${#DISKS[@]} -eq 0 ]; then
  echo "❌ No removable (likely SD card) devices found!"
  exit 1
fi

echo ""
echo "📂 Found the following removable block devices:"
for i in "${!DISKS[@]}"; do
  disk_info=$(lsblk -dno NAME,MODEL,SIZE "${DISKS[$i]}")
  printf "  [%d] %s\n" "$((i+1))" "$disk_info"
done

echo ""
read -p "👉 Enter the number of the disk to back up: " SELECTION

if ! [[ "$SELECTION" =~ ^[0-9]+$ ]] || [ "$SELECTION" -lt 1 ] || [ "$SELECTION" -gt "${#DISKS[@]}" ]; then
  echo "❌ Invalid selection."
  exit 1
fi

DISK="${DISKS[$((SELECTION-1))]}"
echo "✅ Selected disk: $DISK"
echo ""

# === Step 2: Ask for image filename ===
read -p "💾 Enter a name for the output image file (no extension): " IMG_NAME
IMG_FILE="${IMG_NAME}.img"

if [ -f "$IMG_FILE" ]; then
  echo "⚠️ File '$IMG_FILE' already exists! Please choose a different name."
  exit 1
fi

echo ""
echo "📸 Creating disk image from $DISK..."
sudo dd if="$DISK" of="$IMG_FILE" bs=4M status=progress conv=fsync

echo ""
echo "✅ Disk image created: $IMG_FILE"

# === Step 3: Ask if user wants to auto-shrink ===
echo ""
if [ ! -f "$RESIZE_SCRIPT" ]; then
  echo "⚠️ Resize script '$RESIZE_SCRIPT' not found! Skipping auto-shrink."
  exit 0
fi

echo "⏳ Would you like to resize & compress this image using:"
echo "    $RESIZE_SCRIPT"
echo ""
echo "It will auto-run in 30 seconds if no answer is given."
read -t 30 -p "Type 'n' to skip or press [Enter] to run: " ANSWER

if [[ "$ANSWER" =~ ^[Nn]$ ]]; then
  echo "🚫 Skipping resize/compression."
  exit 0
fi

# === Step 4: Run the shrink script ===
echo ""
echo "🚀 Running auto-shrink script..."
bash "$RESIZE_SCRIPT"

