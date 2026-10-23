#!/usr/bin/env bash
# set-quote-app-default.sh
# Assigns PS_Quote_Record_Page as the App Default Quote record page (desktop) for
# the Revenue Cloud Lightning app, the same result as Lightning App Builder ->
# Activation -> App Default.
#
# Usage:
#   bash scripts/set-quote-app-default.sh <orgUsername> [appDeveloperName]
#
# Arguments:
#   orgUsername       - Salesforce username or alias. Optional if SF_TARGET_ORG is set.
#                       Required one way or the other — the CLI default org for this
#                       SFDX project must not be used silently.
#   appDeveloperName  - Optional. Defaults to the unmanaged app labeled "Revenue Cloud"
#                       (RLM_Revenue_Cloud in RLM template orgs), looked up at runtime.
#
# Requirements:
#   - sf CLI authenticated to the target org
#   - python3
#   - PS_Quote_Record_Page already deployed to the org
#
# Why retrieve-edit-deploy (not a CustomApplication in force-app/):
#   Deploying a CustomApplication replaces the whole app (navigation items, utility
#   bar, every page assignment). Editing the target org's own copy changes only the
#   Quote View override and leaves the rest of that org's app untouched.

set -euo pipefail

TARGET_ORG="${1:-${SF_TARGET_ORG:-}}"
APP_NAME="${2:-}"
PAGE_NAME="PS_Quote_Record_Page"
SOBJECT="Quote"

if [[ -z "$TARGET_ORG" ]]; then
  echo "ERROR: Target org is required." >&2
  echo "       Pass username/alias as the first argument, or set SF_TARGET_ORG." >&2
  echo "       Usage: $0 <orgUsername> [appDeveloperName]" >&2
  exit 1
fi

PAGE_COUNT=$(sf data query --use-tooling-api --target-org "$TARGET_ORG" --json \
  -q "SELECT Id FROM FlexiPage WHERE DeveloperName = '$PAGE_NAME'" 2>/dev/null \
  | python3 -c 'import json,sys; print(json.load(sys.stdin).get("result", {}).get("totalSize", 0))')
if [[ "$PAGE_COUNT" != "1" ]]; then
  echo "ERROR: FlexiPage $PAGE_NAME is not deployed to $TARGET_ORG. Deploy the project first." >&2
  exit 1
fi

if [[ -z "$APP_NAME" ]]; then
  APP_NAME=$(sf data query --target-org "$TARGET_ORG" --json \
    -q "SELECT DeveloperName FROM AppDefinition WHERE Label = 'Revenue Cloud' AND NamespacePrefix = null" 2>/dev/null \
    | python3 -c 'import json,sys
r = json.load(sys.stdin)["result"]["records"]
print(r[0]["DeveloperName"] if len(r) == 1 else "")')
  if [[ -z "$APP_NAME" ]]; then
    echo "ERROR: Could not find exactly one unmanaged app labeled 'Revenue Cloud'." >&2
    echo "       Pass the app developer name as the second argument." >&2
    exit 1
  fi
fi

echo "Org: $TARGET_ORG"
echo "App: $APP_NAME"
echo "Page: $PAGE_NAME ($SOBJECT, View, Large)"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Retrieving CustomApplication:$APP_NAME..."
sf project retrieve start --metadata "CustomApplication:$APP_NAME" \
  --target-metadata-dir "$WORK_DIR/retrieve" --unzip --target-org "$TARGET_ORG" >/dev/null 2>&1

APP_FILE=$(find "$WORK_DIR/retrieve" -name "$APP_NAME.app" | head -1)
if [[ -z "$APP_FILE" ]]; then
  echo "ERROR: Retrieve did not return $APP_NAME.app." >&2
  exit 1
fi
PKG_DIR=$(dirname "$(dirname "$APP_FILE")")

RESULT=$(python3 - "$APP_FILE" "$PAGE_NAME" "$SOBJECT" <<'PY'
import re, sys
path, page, sobject = sys.argv[1:4]
xml = open(path, encoding="utf-8").read()
block_re = re.compile(r"[ \t]*<actionOverrides>.*?</actionOverrides>\n?", re.S)

def tag(block, name):
    m = re.search(rf"<{name}>(.*?)</{name}>", block, re.S)
    return m.group(1).strip() if m else None

matches = [m for m in block_re.finditer(xml)
           if tag(m.group(0), "actionName") == "View"
           and tag(m.group(0), "formFactor") == "Large"
           and tag(m.group(0), "pageOrSobjectType") == sobject]

if any(tag(m.group(0), "content") == page and tag(m.group(0), "type") == "Flexipage" for m in matches) and len(matches) == 1:
    print("UNCHANGED")
    sys.exit(0)

new_block = (
    "    <actionOverrides>\n"
    "        <actionName>View</actionName>\n"
    "        <comment>Action override set by scripts/set-quote-app-default.sh.</comment>\n"
    f"        <content>{page}</content>\n"
    "        <formFactor>Large</formFactor>\n"
    "        <skipRecordTypeSelect>false</skipRecordTypeSelect>\n"
    "        <type>Flexipage</type>\n"
    f"        <pageOrSobjectType>{sobject}</pageOrSobjectType>\n"
    "    </actionOverrides>\n"
)

if matches:
    previous = tag(matches[0].group(0), "content")
    first = matches[0]
    for m in reversed(matches[1:]):
        xml = xml[:m.start()] + xml[m.end():]
    xml = xml[:first.start()] + new_block + xml[first.end():]
    print(f"REPLACED {previous}")
else:
    m = re.search(r"<CustomApplication[^>]*>\n", xml)
    xml = xml[:m.end()] + new_block + xml[m.end():]
    print("ADDED")

open(path, "w", encoding="utf-8").write(xml)
PY
)

if [[ "$RESULT" == "UNCHANGED" ]]; then
  echo "SUCCESS: $PAGE_NAME is already the App Default for $SOBJECT in $APP_NAME. Nothing to deploy."
  exit 0
fi
echo "Override: $RESULT"

if grep -q "<profileActionOverrides>" "$APP_FILE" && \
   python3 -c 'import re,sys; x=open(sys.argv[1]).read(); sys.exit(0 if re.search(r"<profileActionOverrides>(?:(?!</profileActionOverrides>).)*<pageOrSobjectType>Quote</pageOrSobjectType>", x, re.S) else 1)' "$APP_FILE"; then
  echo "WARNING: $APP_NAME has profile-specific Quote page assignments. Those take precedence over the App Default for the assigned profiles."
fi

echo "Deploying $APP_NAME..."
DEPLOY_JSON=$(sf project deploy start --metadata-dir "$PKG_DIR" --target-org "$TARGET_ORG" --wait 20 --json 2>/dev/null || true)
DEPLOY_OK=$(printf '%s' "$DEPLOY_JSON" | python3 -c 'import json,sys
t = sys.stdin.read(); t = t[t.find("{"):]
try:
    r = json.loads(t).get("result", {})
except Exception:
    print("PARSE_ERROR"); sys.exit()
if r.get("success"):
    print("OK")
else:
    f = (r.get("details") or {}).get("componentFailures") or []
    f = [f] if isinstance(f, dict) else f
    print("; ".join(x.get("problem", "") for x in f) or json.dumps(r)[:500])')

if [[ "$DEPLOY_OK" != "OK" ]]; then
  echo "ERROR: Deploy failed: $DEPLOY_OK" >&2
  exit 1
fi

echo "Verifying..."
sf project retrieve start --metadata "CustomApplication:$APP_NAME" \
  --target-metadata-dir "$WORK_DIR/verify" --unzip --target-org "$TARGET_ORG" >/dev/null 2>&1
VERIFY_FILE=$(find "$WORK_DIR/verify" -name "$APP_NAME.app" | head -1)
if python3 - "$VERIFY_FILE" "$PAGE_NAME" "$SOBJECT" <<'PY'
import re, sys
path, page, sobject = sys.argv[1:4]
xml = open(path, encoding="utf-8").read()
for b in re.findall(r"<actionOverrides>.*?</actionOverrides>", xml, re.S):
    if (f"<pageOrSobjectType>{sobject}</pageOrSobjectType>" in b and "<actionName>View</actionName>" in b
            and "<formFactor>Large</formFactor>" in b):
        sys.exit(0 if f"<content>{page}</content>" in b else 1)
sys.exit(1)
PY
then
  echo "SUCCESS: $PAGE_NAME is now the App Default Quote record page in $APP_NAME."
else
  echo "ERROR: Deploy succeeded but the retrieved app does not show $PAGE_NAME for $SOBJECT." >&2
  exit 1
fi
