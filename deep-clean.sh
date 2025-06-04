#!/bin/bash

# Deep clean script for Lumory to remove all build artifacts and caches

echo "Performing deep clean for Lumory..."

# Kill Xcode if running
echo "Closing Xcode if running..."
osascript -e 'quit app "Xcode"' 2>/dev/null || true

# Clean Xcode build
echo "Cleaning Xcode build..."
xcodebuild clean -project Lumory.xcodeproj -alltargets 2>/dev/null || true

# Remove DerivedData
echo "Removing DerivedData..."
rm -rf ~/Library/Developer/Xcode/DerivedData/Lumory-*
rm -rf ~/Library/Developer/Xcode/DerivedData/Chronote-*

# Clean Module Cache
echo "Cleaning Module Cache..."
rm -rf ~/Library/Developer/Xcode/DerivedData/ModuleCache*

# Clean build folder
echo "Cleaning build folder..."
rm -rf build/

# Remove .swiftpm
echo "Removing .swiftpm..."
rm -rf .swiftpm/

# Clean SPM cache
echo "Cleaning SPM cache..."
rm -rf ~/Library/Caches/org.swift.swiftpm

echo "Deep clean complete!"
echo "Please open Xcode and try building again."