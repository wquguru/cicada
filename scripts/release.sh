#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=${1:?usage: scripts/release.sh <version, e.g. 1.0.1>}
TAG="v$VERSION"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "version must look like 1.2.3" >&2; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "working tree is not clean" >&2; exit 1; }
git fetch -q origin main --tags
git merge-base --is-ancestor origin/main HEAD || { echo "HEAD is behind origin/main: rebase first" >&2; exit 1; }
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null && { echo "tag $TAG exists here: git tag -d $TAG" >&2; exit 1; }
git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null && { echo "tag $TAG exists on origin" >&2; exit 1; }

trap 'git checkout -q -- CHANGELOG.md VERSION site/changelog.json' ERR
scripts/changelog.py "$VERSION"
echo "$VERSION" > VERSION
python3 - "$VERSION" <<'PY'
import datetime, json, sys
version, path = sys.argv[1], "site/changelog.json"
with open(path, encoding="utf-8") as f:
    entries = json.load(f)
undated = [e for e in entries if e.get("date") is None]
own = [e for e in entries if e.get("version") == version and e.get("date")]
if len(undated) > 1 or (undated and own):
    sys.exit(f"{path}: merge the undated entries and any dated {version} one into one for {version}")
target = undated or own
if not target:
    sys.exit(f"{path}: no undated entry for {version}: every user-visible change needs a Chinese item")
target[0]["version"], target[0]["date"] = version, datetime.date.today().isoformat()
with open(path, "w", encoding="utf-8") as f:
    f.write(json.dumps(entries, indent=2, ensure_ascii=False) + "\n")
PY
git add CHANGELOG.md VERSION site/changelog.json
git commit -q --allow-empty -m "chore: release $TAG"
trap - ERR
git tag -a "$TAG" -m "Cicada $VERSION"
if ! git push --atomic origin HEAD:main "$TAG"; then
  git tag -d "$TAG" >/dev/null
  git reset -q --keep HEAD~1
  echo "push rejected (main moved): rebase on origin/main and run again" >&2
  exit 1
fi
echo "Pushed $TAG ($(git rev-parse --short HEAD)); follow it at https://github.com/wquguru/cicada/actions/workflows/release.yml, then try the draft and scripts/publish-release.sh $VERSION"
