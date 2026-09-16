#!/bin/zsh
# Regenerate the Xcode project. Reads DEVELOPMENT_TEAM from .env (gitignored)
# so personal signing config stays out of the repo:
#   echo "DEVELOPMENT_TEAM=YOURTEAMID" > .env
#
# Uses project-local.yml when it exists (also gitignored) so a local spec —
# personal bundle IDs, entitlements — is picked up automatically. Running
# `xcodegen generate` by hand instead silently regenerates from project.yml
# with no team, which produces an ad-hoc-signed app: it builds and installs
# fine, then macOS treats it as a different app and withholds the Screen
# Recording grant, so the sender connects and sends nothing.
set -e
cd "$(dirname "$0")"
[[ -f .env ]] && export $(grep -v '^#' .env | xargs)

spec=project.yml
[[ -f project-local.yml ]] && spec=project-local.yml
echo "xcodegen: $spec (DEVELOPMENT_TEAM=${DEVELOPMENT_TEAM:-unset})"

exec xcodegen generate --spec "$spec"
