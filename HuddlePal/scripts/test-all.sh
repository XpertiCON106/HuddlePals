#!/bin/zsh
# Runs every test in the repo: the database/RLS suite (fresh schema and
# deployed schema + migrations), the iOS unit tests, and the UI journeys.
#
#   HuddlePal/scripts/test-all.sh                  # everything
#   SIMULATOR="My Test iPhone" HuddlePal/scripts/test-all.sh
#
# Builds always leave Supabase.plist out (EXCLUDED_SOURCE_FILE_NAMES), so
# no test run can reach the live backend, even when the plist is present.
#
# The UI tests wipe HuddlePals' data on the simulator they run on (every
# journey starts from a first launch). Point SIMULATOR at one you keep for
# testing, never one you're signed in on. Create one with:
#   xcrun simctl create "HuddlePals Tests" "iPhone 17 Pro"
set -euo pipefail

ROOT="${0:A:h:h}"                     # HuddlePal/
REPO="${ROOT:h}"
SIMULATOR="${SIMULATOR:-HuddlePals Tests}"
DERIVED="${DERIVED_DATA:-$ROOT/build/test-all}"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

step() { print -P "\n%F{cyan}== $1%f" }

step "Credentials are git-ignored"
for path in HuddlePal/HuddlePal/Supabase.plist Supabase.plist some/dir/Supabase.plist .env backend/.env.local AuthKey_ABC123.p8; do
  git -C "$REPO" check-ignore -q --no-index "$path" || { print "not ignored: $path"; exit 1 }
done
print "ok"

step "Database, RLS, storage policies, RPCs (PGlite)"
(cd "$ROOT/supabase/tests" && npm ci --no-audit --no-fund --silent && npm test)

step "iOS unit and UI tests ($SIMULATOR)"
xcodebuild test \
  -project "$ROOT/HuddlePal.xcodeproj" -scheme HuddlePal \
  -destination "platform=iOS Simulator,name=$SIMULATOR" \
  -derivedDataPath "$DERIVED" \
  -enableCodeCoverage YES \
  EXCLUDED_SOURCE_FILE_NAMES=Supabase.plist

print -P "\n%F{green}All tests passed.%f"
