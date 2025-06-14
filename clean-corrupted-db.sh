#!/bin/bash

echo "Lumory Database Cleanup Script"
echo "=============================="
echo ""
echo "This script will clean up corrupted database files."
echo "WARNING: This will delete all local data. iCloud data will re-sync."
echo ""
read -p "Do you want to continue? (y/n) " -n 1 -r
echo ""

if [[ ! $REPLY =~ ^[Yy]$ ]]
then
    echo "Cancelled."
    exit 1
fi

# Define the iCloud container path
ICLOUD_PATH="$HOME/Library/Mobile Documents/iCloud~com~Mingyi~Lumory/Documents"

# Check if the path exists
if [ -d "$ICLOUD_PATH" ]; then
    echo "Found iCloud database directory: $ICLOUD_PATH"
    
    # List database files
    echo ""
    echo "Database files found:"
    ls -la "$ICLOUD_PATH"/*.sqlite* 2>/dev/null || echo "No database files found"
    
    # Backup corrupted files
    BACKUP_DIR="$HOME/Desktop/Lumory_Backup_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    
    echo ""
    echo "Backing up files to: $BACKUP_DIR"
    cp -r "$ICLOUD_PATH"/*.sqlite* "$BACKUP_DIR/" 2>/dev/null || echo "No files to backup"
    
    # Remove database files
    echo ""
    echo "Removing corrupted database files..."
    rm -f "$ICLOUD_PATH"/Model.sqlite*
    rm -f "$ICLOUD_PATH"/*.sqlite-wal
    rm -f "$ICLOUD_PATH"/*.sqlite-shm
    rm -f "$ICLOUD_PATH"/*.sqlite-ck
    
    echo "Database files removed."
else
    echo "iCloud directory not found at: $ICLOUD_PATH"
fi

# Also clean local app data
LOCAL_PATH="$HOME/Library/Containers/com.Mingyi.Lumory/Data/Library/Application Support"
if [ -d "$LOCAL_PATH" ]; then
    echo ""
    echo "Cleaning local app data..."
    rm -rf "$LOCAL_PATH"/*.sqlite*
fi

echo ""
echo "Cleanup complete!"
echo "Please restart Lumory. The database will be recreated automatically."
echo "Your iCloud data will sync once the app starts."
echo ""
echo "Backup saved to: $BACKUP_DIR"