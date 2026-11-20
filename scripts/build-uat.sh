#!/usr/bin/env bash
set -euo pipefail
# SECURITY: Only these four files are ever uploaded to the UAT Worker.
# No migrations, Edge code, internal docs, Git files or secrets are bundled.
rm -rf .uat-dist
mkdir -p .uat-dist/assets
cp index.html config.js .uat-dist/
cp assets/app.js assets/styles.css .uat-dist/assets/
echo "UAT public assets prepared: index.html, config.js, assets/app.js, assets/styles.css"
