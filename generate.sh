#!/bin/bash
set -e

REPO_DIR=$(pwd)
GENERATOR_REPO_DIR="/tmp/swift-openapi-generator"
GENERATOR_REPO_URL="https://github.com/apple/swift-openapi-generator.git"
BUNDLED_OPENAPI="/tmp/bundled-openapi.yaml"

# Check if the repository already exists
if [ ! -d "$GENERATOR_REPO_DIR" ]; then
    echo "Cloning swift-openapi-generator repository..."
    git clone "$GENERATOR_REPO_URL" "$GENERATOR_REPO_DIR"
else
    echo "Repository already exists, resetting to main and pulling latest changes..."
    cd "$GENERATOR_REPO_DIR"
    git fetch origin
    git reset --hard origin/main
    git checkout main
    git pull
fi

rm -rf $BUNDLED_OPENAPI
openapi bundle https://api.gabber.dev/openapi.yaml -o $BUNDLED_OPENAPI

# Navigate to the repository directory
cd "$GENERATOR_REPO_DIR"

# Run the OpenAPI generator
swift run swift-openapi-generator generate \
    --mode types \
    --mode client \
    --output-directory "$REPO_DIR/Sources/Gabber/Generated" \
    --access-modifier public \
    $BUNDLED_OPENAPI


