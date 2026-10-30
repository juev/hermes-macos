#!/bin/sh
# Generates Hermes.xcodeproj from project.yml and builds the app, without a window and without
# taking the keyboard.
set -eu

cd "$(dirname "$0")/.."

xcodegen generate --quiet
xcodebuild \
	-project Hermes.xcodeproj \
	-scheme Hermes \
	-configuration "${CONFIGURATION:-Debug}" \
	-derivedDataPath build \
	build
