#!/bin/bash
set -euo pipefail
# Script to reset corrupted Lumory database

echo "Lumory Database Reset Script"
echo "============================"
echo ""
echo "This script will help you reset the corrupted Lumory database."
echo "Your data will be restored from iCloud after reset."
echo ""

# Function to find and remove database files
reset_database() {
    local base_path="$1"
    local db_name="Model.sqlite"
    
    echo "Checking for database in: $base_path"
    
    if [ -d "$base_path" ]; then
        local db_path="$base_path/Documents/$db_name"
        
        if [ -f "$db_path" ]; then
            echo "Found database at: $db_path"
            
            # Create backup
            local backup_name="$db_path.backup.$(date +%Y%m%d_%H%M%S)"
            echo "Creating backup: $backup_name"
            cp "$db_path" "$backup_name" 2>/dev/null
            
            # Remove database files
            echo "Removing corrupted database files..."
            rm -f "$db_path"
            rm -f "${db_path}-wal"
            rm -f "${db_path}-shm"
            rm -f "${db_path}-ck"
            
            echo "Database reset complete!"
            return 0
        fi
    fi
    
    return 1
}

# iOS/iPadOS path
if [ -d "$HOME/Library/Mobile Documents/iCloud~com~Mingyi~Lumory" ]; then
    if reset_database "$HOME/Library/Mobile Documents/iCloud~com~Mingyi~Lumory"; then
        exit 0
    fi
fi

# macOS path
if [ -d "$HOME/Library/Containers/Mingyi.Lumory/Data/Library/Mobile Documents/iCloud~com~Mingyi~Lumory" ]; then
    if reset_database "$HOME/Library/Containers/Mingyi.Lumory/Data/Library/Mobile Documents/iCloud~com~Mingyi~Lumory"; then
        exit 0
    fi
fi

echo "Could not find Lumory database. Please make sure Lumory is installed and has been run at least once."
exit 1
