#!/usr/bin/env bash
#
# Host the Lightwell workshop artifacts that no real repository serves, in
# Artifactory, so the remediations RHTPA recommends can actually resolve.
#
# WHY: rhtpa-load-lightwell-data.sh loads advisory LW-DEMO-0011, which says
# org.apache.commons:commons-lang3:3.14.0.rhlw-00001 fixes CVE-2025-48924.
# agentic-cve-remediation therefore pins that version -- but the upstream demo
# channel the `lightwell-remediated` proxy points at
# (packages.redhat.com/lightwell/public-lightwell-demo/java/remediated/) only
# carries spring-core and woodstox-core. The GAV only ever existed in the old
# Nexus lightwell-repo seed, which Artifactory replaced without taking over
# the seeding. Result: ai-remediate-dependency fails its verification build
# with "Could not find artifact ...:3.14.0.rhlw-00001 in artifactory".
#
# WHAT THIS DOES (idempotent; safe to re-run):
#   1. Checks the LOCAL Maven repo `lightwell-remediated-local` exists. It is
#   2. created -- FIRST in the `maven` and `lightwell` virtual repos -- by the
#      first-boot bootstrap import in automation/gitops/artifactory/
#      openshift-extras.yaml (Artifactory OSS has no other way to create
#      repos). If it is missing the script stops and says how to fix that.
#   3. Uploads commons-lang3 3.14.0.rhlw-00001: the workshop POM from
#      automation/gitops/components/lightwell-repo/files/seed/ plus the real
#      Apache Commons Lang 3.14.0 jar (ASL 2.0) from Maven Central, after
#      checking it against Central's published SHA-1 -- exactly what the old
#      Nexus seed published.
#   4. Verifies the GAV resolves through the `maven` virtual.
#
# Everything runs inside the artifactory-0 pod against localhost, using the
# admin credential from Secret artifactory-admin (passed on stdin, never on a
# command line or in output).
#
# Usage:
#   ./artifactory-seed-lightwell-local.sh [-n artifactory-namespace]
#
set -euo pipefail

NS=artifactory
POD=artifactory-0
CONTAINER=artifactory
LOCAL_REPO=lightwell-remediated-local
VIRTUALS="maven lightwell"

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--namespace) NS="$2"; shift 2 ;;
    -h|--help) sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 1 ;;
  esac
done

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_DIR="$(cd "${HERE}/../../automation/gitops/components/lightwell-repo/files/seed" && pwd)"
POM_FILE="${SEED_DIR}/commons-lang3-3.14.0.rhlw-00001.pom"
[[ -f "$POM_FILE" ]] || { echo "ERROR: seed POM not found: $POM_FILE" >&2; exit 1; }

ADMIN_PW=$(oc -n "$NS" get secret artifactory-admin -o jsonpath='{.data.password}' | base64 -d | sed 's/^admin@\*=//')
[[ -n "$ADMIN_PW" ]] || { echo "ERROR: could not read Secret artifactory-admin in $NS" >&2; exit 1; }

# The remote half. Reads: line 1 = admin password, then the POM (base64) on
# the remaining lines.
IFS= read -r -d '' REMOTE <<'EOS' || true
set -euo pipefail
read -r PW
POM_B64=$(cat)
A=http://localhost:8082/artifactory
LOCAL_REPO="__LOCAL_REPO__"
VIRTUALS="__VIRTUALS__"
c() { curl -sS -u "admin:${PW}" "$@"; }
code() { c -o /dev/null -w '%{http_code}' "$@"; }

# 1-2. Repository setup. On Artifactory OSS 7.161 repos can ONLY be created by
# the first-boot bootstrap import (REST and the UI's backend both answer
# "available only in Artifactory Pro"; it also refuses deploys into a remote
# repo's cache). lightwell-remediated-local is defined in
# automation/gitops/artifactory/openshift-extras.yaml, so it exists on any
# instance initialized from that ConfigMap. Check, and explain if not.
if c "$A/api/repositories" | tr -d '\n ' | grep -q "\"key\":\"$LOCAL_REPO\""; then
  echo "local repo $LOCAL_REPO: exists"
else
  cat <<MSG
ERROR: local repo $LOCAL_REPO does not exist. Artifactory OSS can only create
repos at first boot, from the artifactory-repo-bootstrap ConfigMap. This
instance was initialized before $LOCAL_REPO was added there, so it has to be
re-initialized -- see "Adding a repository" in automation/gitops/artifactory/README.md.
MSG
  exit 2
fi

# 3. upload
G=org/apache/commons/commons-lang3
V=3.14.0.rhlw-00001
W=$(mktemp -d)
printf '%s' "$POM_B64" | base64 -d > "$W/pom"
curl -sSf -o "$W/jar" https://repo.maven.apache.org/maven2/$G/3.14.0/commons-lang3-3.14.0.jar
want=$(curl -sSf https://repo.maven.apache.org/maven2/$G/3.14.0/commons-lang3-3.14.0.jar.sha1 | cut -c1-40)
have=$(sha1sum "$W/jar" | cut -c1-40)
[ "$want" = "$have" ] || { echo "ERROR: commons-lang3-3.14.0.jar SHA-1 mismatch ($have != $want)"; exit 1; }
echo "commons-lang3 3.14.0 jar from Maven Central: SHA-1 verified ($have)"
for ext in pom jar; do
  s1=$(sha1sum "$W/$ext" | cut -c1-40)
  rc=$(code -X PUT -H "X-Checksum-Sha1: $s1" -T "$W/$ext" "$A/$LOCAL_REPO/$G/$V/commons-lang3-$V.$ext")
  case "$rc" in 200|201) echo "uploaded commons-lang3-$V.$ext ($rc)";; *) echo "ERROR: upload .$ext returned HTTP $rc"; exit 1;; esac
done
rm -rf "$W"

# 4. verify through the virtuals Maven actually uses. A 404 here with the
# upload above succeeding means $LOCAL_REPO is not (yet) in that virtual --
# see step 2 of the UI instructions.
fail=0
for v in $VIRTUALS; do
  for ext in pom jar; do
    rc=$(code "$A/$v/$G/$V/commons-lang3-$V.$ext")
    echo "resolve via $v virtual: commons-lang3-$V.$ext -> $rc"
    [ "$rc" = "200" ] || fail=1
  done
done
[ "$fail" = 0 ] || { echo "ERROR: uploaded, but not resolvable through every virtual -- add $LOCAL_REPO to it (top of the list) in the UI."; exit 1; }
EOS
REMOTE=${REMOTE//__LOCAL_REPO__/$LOCAL_REPO}
REMOTE=${REMOTE//__VIRTUALS__/$VIRTUALS}

{ printf '%s\n' "$ADMIN_PW"; base64 < "$POM_FILE"; } \
  | oc -n "$NS" exec -i "$POD" -c "$CONTAINER" -- bash -c "$REMOTE"
unset ADMIN_PW
echo "Done. Re-run the failed agentic-cve-remediation PipelineRun."
