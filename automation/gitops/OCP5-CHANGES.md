# Running the demo on OpenShift 5.0: changes and status

What had to change to get the TSSC CVE-remediation demo working on an
**OpenShift 5.0.0** single-node cluster (`sno1`, apps domain
`apps.sno.myocp.net`), what was done directly on the cluster, and what is still
open. Status as of 2026-11-16.

Most fixes are in git and apply to any OpenShift 5 cluster. Section 2 covers
one-off actions on this cluster that a fresh install will not need, unless it
starts from the same state.

## Status at a glance

| Area | Status |
|---|---|
| Operators (Pipelines, Quay, RHTAS, RHBK, RHTPA) | Installed and healthy |
| Argo CD: all `ssc-*` Applications | Synced / Healthy |
| Keycloak (RHBK 26.6) + issuer `https://sso.apps.sno.myocp.net/realms/backstage` | Working |
| RHTPA 3.1 + Route `server-trusted-profile-analyzer.apps.sno.myocp.net` | Working |
| `spring-boot-example-dev` | Running from the local Quay |
| `spring-boot-example-qa` / `-prod` | **Pending:** need a first promotion (§3.2) |
| `agentic-cve-remediation` for `commons-lang3` | **Pending:** Artifactory re-initialization (§3.1) |
| LVMS storage on the SATA HDD | **Pending:** rebuild planned, not applied (§3.3) |

---

## 1. Changes in git

All under `automation/gitops/` unless the path says otherwise.

### 1.1 Operators the OpenShift 5.0 catalog doesn't carry (commit `5587c18`)

**Problem.** On OpenShift 5.0, `redhat-operators` is
`registry.redhat.io/redhat/redhat-operator-index:v5.0`, and that index does not
contain `rhbk-operator` or `rhtpa-operator`. Their Subscriptions failed with
`constraints not satisfiable: no operators found in package rhbk-operator in
the catalog referenced by subscription ...`.

**Fix.**
- New component `components/operator-catalogs/` adds a CatalogSource,
  `redhat-operators-v4-21` (`redhat-operator-index:v4.21`), in
  `openshift-marketplace`.
- `bootstrap-infra` creates it as the Application `ssc-operator-catalogs` at
  sync-wave `-1`, before anything subscribes.
- New values `components.keycloak.subscription.{channel,source}` and
  `components.rhtpaOperator.source` point both Subscriptions at that catalog.

**Revert when** both packages appear in the default catalog:
```
oc get packagemanifests -o custom-columns=PKG:.metadata.name,CAT:.status.catalogSource | grep -E 'rhbk-operator|rhtpa-operator'
```
Then set both `source` values back to `redhat-operators` and set
`components.operatorCatalogs.enabled: false`.

### 1.2 Keycloak: RHBK 24 → 26.6 (commits `5587c18`, `babcda4`)

**Problem.** The `stable-v24` channel no longer exists, and RHBK 26 changed the
Keycloak CR's hostname options.

**Fix.**
- The channel is now `stable-v26.6`.
- `components/keycloak/keycloak/templates/keycloak.yaml` uses the hostname-v2
  options: `hostname.hostname` and `hostname.admin` are full `https://` URLs (the
  removed `adminUrl` is gone), and `proxy.headers: xforwarded` is set. Without the
  `https://` the edge-terminated Route makes Keycloak publish an `http://` issuer,
  which RHTAS, RHTPA and the pipelines all reject.
- **Route host bug (`babcda4`).** `keycloak/templates/route.yaml` only set
  `spec.host` when `route.host` was given explicitly, so with the default
  `localName: sso` OpenShift assigned `keycloak-keycloak.<domain>`, while
  Keycloak advertised `https://sso.<domain>`. Nothing served the issuer, and
  `ssc-rhtpa-prerequisites` waited forever in its `wait-for-keycloak` hook. The
  Route now always uses the same `keycloak.hostname` helper as the CR.

### 1.3 Keycloak database: init loop and PostgreSQL version (commits `45bcecf`, `6c078c9`)

**Problem 1: first boot killed partway through.** The liveness probe gave
Postgres about 35 s (5 s delay × 3 failures), and the CPU limit was 250m. The
image's first boot listens only on a Unix socket while it runs `initdb` and then
creates the role and database, so the TCP probe killed it between those steps.
Every later start failed with `role "keycloak" does not exist`, and the crash
recovery that followed was killed the same way. The log showed
`pg_ctl: another server might be running`.

**Fix 1** (`components/keycloak/keycloak-db/`):
- added a `startupProbe` (TCP 5432, 10 s × 30 = 5 min)
- raised the limits to 1 CPU / 512Mi
- removed a stray `volumes:` key from inside the volumeMount

**Problem 2: version too old.** RHBK 26 refuses PostgreSQL < 13 (`configured to
run with a database version of at least '13.0.0'`).

**Fix 2:** the image is now `registry.redhat.io/rhel9/postgresql-16:1` (same
image family, so the env vars, mount path and probes are unchanged).

### 1.4 RHTPA database: same init loop (commit `ff7b336`)

`components/rhtpa/tpa-prerequisites/` (`tpa-postgresql`) had the same probe
problem, and it surfaced as `database "trustify" does not exist`. It gets the
same 5-minute `startupProbe`.

**Follow-up (2026-11-18): crash-recovery restart loop once the database holds
data.**
- **What happened:** after the importers loaded about 8 GB, a pod stop on Nov 18
  at 22:39 (probably a 1-second liveness probe that failed under import load)
  sent SIGTERM, and Postgres was SIGKILLed 30 s later, partway through its
  shutdown checkpoint.
- **Why it looped:** every later start went into crash recovery, which fsyncs
  every file in the data directory (200+ s on this disk) before replaying WAL.
  The 5-minute startup probe killed it before it finished, 47 times.
- **Fix** (in the working tree, not yet committed):
  - `recovery_init_sync_method = syncfs`, through a new ConfigMap
    `tpa-postgresql-cfg` mounted at `/opt/app-root/src/postgresql-cfg/`
  - `terminationGracePeriodSeconds: 300`
  - a more tolerant liveness probe (5 s timeout, 6 × 20 s)
  - a 30-minute startup budget
  - a checksum annotation, so the pod restarts when the config changes
  - **demo-only speed-up:** `fsync = off`, `synchronous_commit = off` and
    `full_page_writes = off`, so commits no longer wait on the slow disk. A
    clean restart loses nothing; a hard crash can corrupt the database, and then
    you wipe `/var/lib/pgsql/data/userdata`. I chose this over an `emptyDir`
    because RHTPA creates its schema only in Helm install/upgrade hooks, so an
    empty database after each restart would leave it broken.

### 1.4b The same crash-recovery loop in Artifactory's and GitLab's Postgres (2026-11-18)

Both other Postgres instances on the HDD-backed `lvms-vg1` volume group hit
the same loop: an unclean stop left a crash recovery that ran longer than the
pod would wait, so the pod was killed and recovery restarted from scratch.

| Instance | What killed recovery | Fix | How it's applied |
|---|---|---|---|
| `artifactory-postgresql` (JFrog chart, PostgreSQL 17) | Liveness probe after about 90 s, no startup probe | `artifactory.postgresql.primary`: `terminationGracePeriodSeconds: 300`, a startup probe (180 × 10 s), liveness 6 × 20 s, and `extendedConfiguration` with `recovery_init_sync_method = syncfs` plus the demo-only `fsync` / `synchronous_commit` / `full_page_writes = off` | `artifactory/application-artifactory.yaml`. **Re-apply it with `oc apply -f`**: the Application is standalone, not generated from git. Done 2026-11-18 |
| `gitlab-postgresql` (`quay.io/redhat-gpte/gitlab-postgresql:14`) | Liveness after about 60 s, and the image's own `pg_ctl -w start`, which gives up after 60 s (`pg_ctl: server did not start in time`) | `PGCTLTIMEOUT=1800`, server args `-c recovery_init_sync_method=syncfs -c fsync=off -c synchronous_commit=off -c full_page_writes=off`, a startup probe (180 × 10 s), liveness 6 × 20 s, grace period 300 s | `components/gitlab/templates/deploy-postgresql.yaml` (git, synced by `ssc-gitlab`) |

For GitLab, the `-c` arguments only reach the final server. The image's
temporary setup start, where crash recovery runs, keeps the `postgresql.conf`
defaults, so it relies on the longer `PGCTLTIMEOUT`.

### 1.5 GitLab seeding job: image repository never changed (commit `3bca268`)

**Problem.** The applications in `spring-boot-example-{dev,qa,prod}` pulled from
`quay.apps.cluster-6gpcf.dyn.redhatworkshops.io` (the authoring cluster). The
`initialize-gitlab` job's step that rewrites `image.repository` in the imported
GitOps repo produced an **empty commit**. It had inlined the same
`regex_replace` in both `when:` and `content:`, and on current ansible-core
(reproduced on 2.22) the two contexts unescape `\\s` / `\\1` differently. The
`when:` matched, so the task ran; the `content:` didn't, so GitLab got the
unchanged file.

**Fix** (`components/gitlab/templates/cm-gitlab-init.yaml`):
- the new file content is computed once, with the pattern and replacement
  passed as plain variables
- that single value drives both the skip check and the commit
- a new step re-reads the file and **fails the job** if it doesn't reference
  this cluster's Quay

### 1.6 ODF channel (commit `5587c18`)

The OpenShift 5.0 catalog offers ODF only as `stable-4.22`. The defaults were
changed from `stable-4.21` in `bootstrap-infra/values.yaml`,
`components/odf/values.yaml`, `components/odf/odf-operator/values.yaml` and the
RUNBOOK. ODF is still `enabled: false` by default.

### 1.7 LVMS storage plan (commit `3bca268`, documentation only)

`automation/cluster/lvms/` (`lvmcluster.yaml` + `README.md`) contains a
**not-applied** plan to split the NVMe and the HDD into separate volume groups.
See §3.3.

### 1.8 Uncommitted: Artifactory hosted repo for `commons-lang3`

| File | Change |
|---|---|
| `artifactory/openshift-extras.yaml` | The bootstrap import defines a local repo, `lightwell-remediated-local`, listed **first** in the `maven` and `lightwell` virtual repos |
| `pipelines/ops/artifactory-seed-lightwell-local.sh` (new) | Uploads `commons-lang3:3.14.0.rhlw-00001` (the workshop POM + the real Commons Lang 3.14.0 jar, SHA-1 checked against Maven Central) and verifies it resolves through both virtual repos |
| `artifactory/README.md` | Why the repo exists, and the safe re-initialization procedure |

Why this is needed: see §3.1. I tested the bootstrap import on a local
`artifactory-oss:7.161.26` + PostgreSQL 16: all six repos were created, and the
artifact uploaded (201) and resolved through both virtual repos (200).

---

## 2. Changes made directly on the cluster (not in git)

| # | What | Why | Done by |
|---|---|---|---|
| 1 | Deleted Subscription `limitador-operator-stable-redhat-operators-openshift-marketplace` (`openshift-operators`) | Its package isn't in the 5.0 catalog. OLM resolves every Subscription in a namespace together, so this one failure blocked Quay, RHTAS and Pipelines | Claude |
| 2 | Removed Red Hat Connectivity Link: Subscriptions `rhcl-operator`, `authorino-operator…`, `dns-operator…`; CSVs `rhcl-operator.v1.4.3`, `authorino-operator.v1.4.3`, `dns-operator.v1.4.2`, `limitador-operator.v1.4.2` | `rhcl-operator`'s `stable` channel is gone in 5.0 (only `stable-1.5`), so it blocked the namespace next. Unused: no Kuadrant, Limitador or Authorino resources existed | Claude |
| 3 | Terminated the stuck `ssc-keycloak` sync operation | It was pinned to an old commit and waiting for a `keycloak-db` that could only get healthy with the newer commit (Argo won't start a new sync while one is running) | You |
| 4 | Re-ran the bootstrap: `helm template ssc automation/gitops/bootstrap-infra -f <values> \| oc apply -f -` | `bootstrap-infra` isn't tracked by Argo; the new `ssc-operator-catalogs` Application and the Subscription `source` values only take effect this way | You |
| 5 | Wiped `/var/lib/pgsql/data/userdata` on `keycloak-db`, twice: after the init loop, and after the switch to PostgreSQL 16 | A half-initialized data directory can't recover, and a v12 data directory won't start under v16. The database was empty both times | You |
| 6 | Wiped `/var/lib/pgsql/data/userdata` on `tpa-postgresql` | Half-initialized; the `trustify` database was never created | You |
| 7 | Deleted the orphaned Ingress `server` in `trusted-profile-analyzer` and restarted `rhtpa-operator-controller-manager` | A failed first install (Postgres was down) left the Ingress without Helm ownership annotations, so every retry refused to adopt it, and there was no Route or server pod. The restart cleared the operator's error backoff | Claude |
| 8 | Recreated Secret `tpa-secret` (`tssc-app-ci`) with `oidc_client_secret` copied from `oidc-tpa-cli` | It held a different, 28-character value, and Keycloak returned 401 `unauthorized_client` | You |
| 9 | Fixed `image.repository` in the GitLab repo `development/spring-boot-example-gitops` (`app/spring-boot-example/values.yaml`) to `quay.apps.sno.myocp.net/tssc/spring-boot-example-application` | Cleans up the empty commit described in §1.5 on this cluster; the template fix only helps future seedings | You |
| 10 | Removed the stale Subscriptions `rhsso-operator` (`keycloak`) and `rhtpa-operator` (`tpa-system`) | Leftovers that would block or conflict with the demo's operators | You (no longer on the cluster as of 2026-11-16) |

---

## 3. Still open

### 3.1 Artifactory re-initialization (blocks `agentic-cve-remediation` for `commons-lang3`)

**Problem.** RHTPA advisory `LW-DEMO-0011` (loaded by
`pipelines/ops/rhtpa-load-lightwell-data.sh`) recommends
`commons-lang3:3.14.0.rhlw-00001`. No real repository has it: the upstream
Lightwell demo channel only carries `spring-core` and `woodstox-core`, and the
GAV only ever came from the old Nexus seed. `ai-remediate-dependency` fails with
`Could not find artifact ...:3.14.0.rhlw-00001 in artifactory`. The five
`woodstox-core` Lightwell advisories (the design doc's main scenario) are not
affected.

**Why re-initialize.** Artifactory OSS 7.161 creates repos only at first boot.
REST and the UI return "available only in Artifactory Pro", and it refuses
deploys into a proxy's cache.

**Steps:** the "Adding a repository" section of `artifactory/README.md`, then
`pipelines/ops/artifactory-seed-lightwell-local.sh`.

**Do not `oc apply -f openshift-extras.yaml` as a whole.** It resets the three
real Artifactory Secrets to `REPLACE_ME`. Apply only the ConfigMap, as the
README shows. The pipeline's `maven-settings` uses `admin` with the bootstrap
password, so it keeps working after the re-init.

### 3.2 First promotion to QA and prod

Both reference `cdx16-d7978efb`, a tag built on the authoring cluster that
doesn't exist in the local Quay. Promote the image dev runs:
```
IMG=quay.apps.sno.myocp.net/tssc/spring-boot-example-application:1f931871ad8050c35cc1729c30193e360f64474d
tkn pipeline start gitops-cd-qa   -n tssc-app-ci -p image=$IMG --use-param-defaults --showlog
tkn pipeline start gitops-cd-prod -n tssc-app-ci -p image=$IMG --use-param-defaults --showlog
```
Then merge the two MRs in GitLab (`auto-merge` is `false` for QA and prod).

### 3.3 Storage: the LVMS volume group includes a SATA hard drive

The `LVMCluster` has no `deviceSelector`, so `vg1` (StorageClass `lvms-vg1`)
spans the WD_BLACK SN770 NVMe **and** an 8 TB Seagate ST8000DM004 (5400 rpm,
SMR). Most extents landed on the HDD: it showed 100% busy, ~48 ms flushes and
30–130 ms Postgres writes. That explains the slow Postgres first boots. The fix
(separate NVMe and HDD device classes) needs a full LVMS rebuild that wipes
every `lvms-vg1` PVC; see `automation/cluster/lvms/README.md`. Until then,
expect slow I/O on all `lvms-vg1` volumes.

### 3.4 Other follow-ups

- **Duplicate installs:** `keycloak26` still runs a second `rhbk-operator`
  (v26.6.7), and `openshift-operators` has two Pipelines Subscriptions
  (`openshift-pipelines-operator` and `openshift-pipelines-operator-rh`). They are
  harmless today, but worth removing.
- **Exploit IQ** is in the design doc but not enabled: nothing sets
  `spec.exploitIntelligence` on the `TrustedProfileAnalyzer`.
- **Conforma** runs with an empty `conforma-policy-configuration`, so the
  must-fix list comes from the severity fallback (≥ high), not an `ec` policy.

---

## 4. Things worth knowing on OpenShift 5

- **One broken Subscription blocks its whole namespace.** OLM resolves every
  Subscription in a namespace together. If many fail with the same message
  naming one package, fix or remove that package. `openshift-operators` is the
  usual place this happens.
- **Argo CD can deadlock on an old commit.** A sync waiting on a resource that
  only the newer commit fixes never ends, and auto-sync won't preempt it. Check
  `status.operationState.operation.sync.revision`, then terminate the operation.
- **`bootstrap-infra` changes need a re-run** of the `helm template … | oc apply`
  step (RUNBOOK §5). A git push alone only updates the component charts.
- **`oc get pipeline` returns Kubeflow's resource** when OpenShift AI is
  installed: `pipelines.kubeflow.org` sorts before `tekton.dev`. Use
  `oc get pipelines.tekton.dev`, or `tkn`.
- **Postgres pods need a startup probe** on slow storage. Without one, a killed
  first boot leaves a data directory that never recovers. Wipe the data
  directory only when the database is known to be empty.
