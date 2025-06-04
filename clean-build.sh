#!/bin/bash

# Clean script for Lumory to remove build artifacts and caches

echo "Cleaning Lumory build artifacts..."

# Clean Xcode build
echo "Cleaning Xcode build..."
xcodebuild clean -project Lumory.xcodeproj -alltargets

# Remove DerivedData
echo "Removing DerivedData..."
rm -rf ~/Library/Developer/Xcode/DerivedData/Lumory-*

# Clean build folder
echo "Cleaning build folder..."
rm -rf build/

echo "Clean complete!"
echo "Please restart Xcode and try building again."