#!/bin/zsh
set -euo pipefail
node_root="${0:A:h:h}"
cd "$node_root"
: "${IPAD_DEVICE_ID:?Set IPAD_DEVICE_ID to your paired iPad identifier}"
: "${DEVELOPMENT_TEAM:?Set DEVELOPMENT_TEAM to your Apple development team}"
: "${BUNDLE_ID:?Set BUNDLE_ID to your unique application bundle ID}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
mkdir -p .local
chmod 700 .local
python3 - <<'PY'
from pathlib import Path
import os,secrets
p=Path('.local/ipad-api-token.txt')
if not p.exists():
    fd=os.open(p,os.O_CREAT|os.O_EXCL|os.O_WRONLY,0o600)
    with os.fdopen(fd,'w') as f:f.write(secrets.token_urlsafe(32))
os.chmod(p,0o600)
PY
xcodebuild -project mlx-swift-examples.xcodeproj -scheme LLMEval -configuration Release \
  -destination "id=$IPAD_DEVICE_ID" -derivedDataPath .local/DerivedData \
  -skipMacroValidation -allowProvisioningUpdates DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM" \
  PRODUCT_BUNDLE_IDENTIFIER="$BUNDLE_ID" build > .local/build.log 2>&1
xcrun devicectl device install app --device "$IPAD_DEVICE_ID" \
  .local/DerivedData/Build/Products/Release-iphoneos/LLMEval.app
xcrun devicectl device copy to --device "$IPAD_DEVICE_ID" --source .local/ipad-api-token.txt \
  --destination Documents/server-token.txt --domain-type appDataContainer --domain-identifier "$BUNDLE_ID"
xcrun devicectl device process launch --device "$IPAD_DEVICE_ID" --terminate-existing --activate "$BUNDLE_ID"
print 'Installed. Keep the iPad app foreground and open Model Manager to download a model.'
