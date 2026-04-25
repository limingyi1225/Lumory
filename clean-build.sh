#!/bin/bash
set -euo pipefail

# Clean script for Lumory to remove build artifacts and caches

echo "Cleaning Lumory build artifacts..."

# Clean Xcode build
echo "Cleaning Xcode build..."
if ! xcodebuild clean -project Lumory.xcodeproj -alltargets; then
    echo "xcodebuild clean failed; continuing with local artifact cleanup..."
fi

# Remove DerivedData
echo "Removing DerivedData..."
rm -rf ~/Library/Developer/Xcode/DerivedData/Lumory-*

# Clean build folder
echo "Cleaning build folder..."
rm -rf build/

echo "Clean complete!"
echo "Please restart Xcode and try building again."
