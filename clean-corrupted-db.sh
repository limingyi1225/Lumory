#!/bin/bash
set -euo pipefail

DB_NAME="Model.sqlite"
TIMESTAMP="$(date +%Y%m%d_%H%M%S)"
BACKUP_ROOT="${LUMORY_DB_BACKUP_DIR:-$HOME/Desktop/Lumory_Corrupt_DB_Backup_$TIMESTAMP}"
backup_root_prepared=0

echo "Lumory Database Cleanup Script"
echo "=============================="
echo ""
echo "This removes Lumory's exact local Core Data store files after making a backup."
echo "It will not delete iCloud legacy stores or .legacy-* migration archives."
echo ""
read -r -p "Do you want to continue? (y/n) " REPLY
echo ""

if [[ ! "$REPLY" =~ ^[Yy]$ ]]; then
  echo "Cancelled."
  exit 1
fi

candidate_dirs=(
  "$HOME/Library/Containers/Mingyi.Lumory/Data/Library/Application Support"
  "$HOME/Library/Containers/com.Mingyi.Lumory/Data/Library/Application Support"
)

support_dirs_for() {
  local sqlite_path="$1"
  local store_dir
  local file_name
  local base_name
  store_dir="$(dirname "$sqlite_path")"
  file_name="$(basename "$sqlite_path")"
  base_name="${file_name%.sqlite}"
  printf '%s\n' "$store_dir/.$base_name"_SUPPORT
  printf '%s\n' "$store_dir/$base_name"_SUPPORT
  printf '%s\n' "$sqlite_path"_SUPPORT
}

backup_if_exists() {
  local source_path="$1"
  local backup_dir="$2"
  if [ -e "$source_path" ]; then
    mkdir -p "$backup_dir"
    cp -a "$source_path" "$backup_dir/"
  fi
}

remove_if_exists() {
  local target_path="$1"
  if [ -e "$target_path" ]; then
    rm -rf "$target_path"
  fi
}

store_artifact_exists() {
  local sqlite_path="$1"
  if [ -e "$sqlite_path" ] ||
     [ -e "$sqlite_path-wal" ] ||
     [ -e "$sqlite_path-shm" ] ||
     [ -e "$sqlite_path-ck" ]; then
    return 0
  fi
  while IFS= read -r support_dir; do
    if [ -e "$support_dir" ]; then
      return 0
    fi
  done < <(support_dirs_for "$sqlite_path")
  return 1
}

prepare_backup_root() {
  if [ "$backup_root_prepared" -eq 1 ]; then
    return
  fi
  if [ -e "$BACKUP_ROOT" ]; then
    echo "Backup directory already exists: $BACKUP_ROOT"
    echo "Choose a new LUMORY_DB_BACKUP_DIR or remove the old backup directory first."
    exit 1
  fi
  mkdir -p "$BACKUP_ROOT"
  backup_root_prepared=1
}

clean_store() {
  local sqlite_path="$1"
  local backup_dir="$2"

  prepare_backup_root

  echo "Found local store artifacts for: $sqlite_path"
  echo "Backing up exact store files to: $backup_dir"
  backup_if_exists "$sqlite_path" "$backup_dir"
  backup_if_exists "$sqlite_path-wal" "$backup_dir"
  backup_if_exists "$sqlite_path-shm" "$backup_dir"
  backup_if_exists "$sqlite_path-ck" "$backup_dir"
  while IFS= read -r support_dir; do
    backup_if_exists "$support_dir" "$backup_dir"
  done < <(support_dirs_for "$sqlite_path")

  echo "Removing exact local store files..."
  remove_if_exists "$sqlite_path"
  remove_if_exists "$sqlite_path-wal"
  remove_if_exists "$sqlite_path-shm"
  remove_if_exists "$sqlite_path-ck"
  while IFS= read -r support_dir; do
    remove_if_exists "$support_dir"
  done < <(support_dirs_for "$sqlite_path")
}

found=0
for index in "${!candidate_dirs[@]}"; do
  dir="${candidate_dirs[$index]}"
  sqlite_path="$dir/$DB_NAME"
  if store_artifact_exists "$sqlite_path"; then
    found=1
    clean_store "$sqlite_path" "$BACKUP_ROOT/source-$((index + 1))"
  fi
done

if [ "$found" -eq 0 ]; then
  echo "No local Lumory database found in Lumory container Application Support locations."
  exit 1
fi

echo ""
echo "Cleanup complete."
echo "Backup saved under: $BACKUP_ROOT"
echo "Restart Lumory to recreate the local store and resume CloudKit sync."
