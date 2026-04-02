#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$SCRIPT_DIR/DoubleClap.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"

mkdir -p "$MACOS_DIR"

echo "Compiling DoubleClap..."
swiftc -O \
    -o "$MACOS_DIR/DoubleClap" \
    "$SCRIPT_DIR/DoubleClap.swift" \
    -framework AVFoundation \
    -framework Cocoa \
    -framework Accelerate \
    -framework CoreAudio \
    -framework UniformTypeIdentifiers

echo "Built: $APP_DIR"
echo ""
echo "To run:  open $APP_DIR"
