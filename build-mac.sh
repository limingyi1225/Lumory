#!/bin/bash

# Build script for Lumory Mac Catalyst version
# This script builds the Mac Catalyst version of the app

echo "Building Lumory for Mac Catalyst..."

# Clean build folder
echo "Cleaning build folder..."
xcodebuild clean -project Lumory.xcodeproj -scheme Lumory -destination 'platform=macOS,variant=Mac Catalyst'

# Build for Mac Catalyst
echo "Building for Mac Catalyst..."
xcodebuild build \
    -project Lumory.xcodeproj \
    -scheme Lumory \
    -destination 'platform=macOS,variant=Mac Catalyst' \
    -configuration Debug \
    DEVELOPMENT_TEAM="" \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO

if [ $? -eq 0 ]; then
    echo "Build succeeded!"
    echo "The Mac app can be found in the build folder"
else
    echo "Build failed!"
    exit 1
fi