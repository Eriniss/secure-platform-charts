# logto (Helm Chart)

Logto(오픈소스 IAM/SSO 플랫폼)를 위한 Helm 차트입니다. 이 프로젝트(RKE2 + Cilium Gateway API +
cert-manager + Vault/ESO + ArgoCD + OpenEBS LVM LocalPV + CloudNativePG)에 맞춰 설계했습니다.

## 설계 방향

1. **Ingress / Gateway API(HTTPRoute)는 이 차트가 만들지 않습니다.**
   여타 Helm 차트들과 동일한 관례대로, 서비스 노출은 앱 배포와 분리해서 별도 매니페스트로
   관리하도록 유도합니다. `examples/httproute.yaml`(Gateway API, 권장)과
   `examples/ingress.yaml`(전통적 Ingress)을 참고해 GitOps 저장소 등에 따로 추가하세요.

2. **데이터베이스는 기본값이 차트 내장 단독 PostgreSQL** (`postgresql.enabled=true`, 단일
   레플리카 StatefulSet) 입니다 - 여타 Helm 차트의 "bundled DB 기본값"과 동일한 관례로,
   빠른 시작/테스트용입니다. **프로덕션에서는 `cnpg.enabled=true` 로 전환해
   CloudNativePG를 사용하는 것을 강력히 권장**합니다. `cnpg.enabled=true` 이면
   `postgresql.enabled` 값과 무관하게 CNPG가 우선합니다.

   Bitnami postgresql 서브차트 등 외부 의존성을 두지 않고 표준 `postgres` 이미지로
   직접 만든 이유: 이 프로젝트는 Kyverno로 "허용된 레지스트리(Harbor) 외 이미지 admission
   차단"을 계획하고 있어(`k8s-security-project-plan.md`), 사이드카/이니셜 컨테이너가
   많은 무거운 서브차트보다 이미지 출처를 통제하기 쉬운 최소 구성이 낫다고 판단했습니다.

## 데이터베이스 3가지 모드

| 모드 | 값 | 용도 |
|---|---|---|
| 단독 Postgres (기본값) | `postgresql.enabled=true` | 빠른 시작/테스트. 복제·백업 없음 |
| CNPG 전용 클러스터 (권장) | `cnpg.enabled=true`, `cnpg.cluster.create=true` | Logto만을 위한 CNPG Cluster를 이 차트가 생성 |
| CNPG 공용 클러스터 | `cnpg.enabled=true`, `cnpg.cluster.create=false` | GitLab/Harbor와 공유하는 기존 CNPG 클러스터에 Database CR만 추가 |

`examples/values-cnpg-dedicated.yaml`, `examples/values-cnpg-shared.yaml` 참고.

CNPG 공용 클러스터 모드는 이 프로젝트의 기술 스택 표에 있는 "CNPG(공용 Postgres) -
GitLab/Harbor/Logto 등 공용" 방향과 맞습니다. 다만 CNPG의 `Database` CRD는 참조하는
`Cluster`와 **같은 네임스페이스**에 있어야 하므로, 공용 클러스터와 Logto를 같은
네임스페이스에 두거나 네임스페이스 구성을 다시 검토하세요.

## 빠른 시작

```bash
# 1) 단독 Postgres로 빠르게 띄워보기 (테스트용)
helm install logto ./logto-chart \
  --namespace logto --create-namespace \
  --set logto.endpoint=https://logto.example.com \
  --set logto.adminEndpoint=https://logto-admin.example.com

# 2) 프로덕션: CNPG 전용 클러스터 (권장 기본 경로)
helm install logto ./logto-chart \
  --namespace logto --create-namespace \
  -f examples/values-cnpg-dedicated.yaml

# 3) 프로덕션: 기존 공용 CNPG 클러스터 재사용
helm install logto ./logto-chart \
  --namespace <공용 클러스터와 동일한 namespace> \
  -f examples/values-cnpg-shared.yaml
```

설치 후 `helm install`이 출력하는 NOTES.txt 안내(HTTPRoute 추가, 최초 로그인,
SECRET_VAULT_KEK 백업, 이미지 출처 정책 관련 안내)를 확인하세요.

## 트러블슈팅

- **`logto` 파드가 `Init:CrashLoopBackOff`, db-init 로그에
  `getaddrinfo ENOTFOUND logto-postgresql.<ns>.svc.cluster.local`**: 단독 Postgres
  StatefulSet(`logto-postgresql-0`)이 아직 Ready가 아니라는 뜻입니다(headless Service는
  Ready 엔드포인트가 없으면 DNS도 해석되지 않습니다). `kubectl -n <ns> get pod
  logto-postgresql-0`으로 Ready 여부를 먼저 확인하세요.
- **`logto-postgresql-0`이 계속 재시작하고, 이벤트에 `Readiness probe failed:
  /var/run/postgresql:5432 - no attempt` 또는 `OCI runtime exec failed ... broken
  pipe`가 보임**: 로컬 Docker Desktop 등 일부 환경에서 `pg_isready` exec 프로브가
  컨테이너 런타임 fork/exec 부하로 간헐적으로 실패하는 것을 실제로 겪었습니다
  (`logto-helm-chart-guide.md` 참고). v0.1.1부터 이 프로브를 `tcpSocket`으로 바꿔
  기본 해결되어 있습니다 - 그래도 재현되면 `postgresql.resources`로 요청/제한을
  넉넉히 주거나 Docker Desktop 리소스 할당을 늘려보세요.
- **db-init 로그에 `password authentication failed for user "logto"`**: 단독 Postgres
  모드에서 PVC(`data-<release>-postgresql-0`)는 그대로 둔 채 `helm uninstall` 후
  `helm install`로 재설치하면(버전을 올릴 때 흔히 하는 실수) 발생합니다. Secret은
  삭제됐다 새로 임의 비밀번호로 재생성되지만, 기존 PVC의 PGDATA에는 예전 비밀번호가
  이미 초기화되어 있어 서로 어긋납니다. v0.1.3부터는 이 상황(같은 이름의 PVC는 있는데
  Secret은 없음)을 감지하면 조용히 어긋난 비밀번호를 만드는 대신 바로 에러를 내고
  멈춥니다. 버전만 올릴 때는 `helm uninstall`+`helm install`이 아니라 **`helm
  upgrade`**를 쓰세요 - 이미 어긋난 상태라면 Postgres 파드에 `exec`로 들어가
  `ALTER ROLE "<user>" WITH PASSWORD '<현재 Secret의 password>';` 로 DB 쪽 비밀번호를
  Secret에 맞춰주면 데이터 손실 없이 복구됩니다.
- **CNPG 모드에서 db-init 로그에 `error: Only roles with the CREATEROLE attribute may
  create roles` (PG 코드 `42501`)**: Logto의 `db seed`가 내부적으로 `CREATE ROLE`을
  실행하는데, CNPG의 `bootstrap.initdb.owner` 롤은 표준 `postgres` 이미지의
  `POSTGRES_USER`와 달리 **기본적으로 슈퍼유저가 아닙니다** (게다가 CNPG 기본값은
  `enableSuperuserAccess: false`라 슈퍼유저 접속 자체가 막혀 있습니다). v0.1.4부터는
  `cnpg.cluster.ownerCreateRole=true`(기본값, 전용 클러스터 경로에서만 적용)가
  CNPG 공식 예시(`cluster-example-with-roles.yaml`)와 같은 패턴으로 owner와 동일한
  이름의 `managed.roles` 항목을 선언해 `createrole: true`를 부여합니다.
  **이미 이 에러를 겪고 있는 기존 설치**는 `helm upgrade`로 차트를 v0.1.4 이상으로
  올리면 CNPG의 role 리컨실러가 살아있는 Cluster에 알아서 반영합니다(파드 재시작
  불필요). 공용 클러스터 모드(`cnpg.cluster.create=false`)라면 이 차트가 아니라
  **공용 클러스터를 관리하는 쪽 매니페스트**에 같은 패턴을 추가해야 합니다 -
  `examples/values-cnpg-shared.yaml`의 주석 예시를 참고하세요.

## 외부 노출 (직접 추가)

```bash
kubectl apply -f examples/httproute.yaml   # <release-namespace>, <release-name>, 도메인을 실제 값으로 교체
```

`argocd-provisioning-guide.md`에서 겪은 것과 동일하게, HTTPRoute의 `backendRefs.port`는
**Service가 노출하는 포트**(core=3001, admin=3002)를 가리켜야 합니다 - 파드의 targetPort가
아닙니다.

## Vault + External Secrets Operator 연동 (선택)

`cert-manager-install-guide.md`에서 Cloudflare 토큰을 kubectl 직접 생성 방식에서
Vault/ESO로 전환한 것과 같은 방향입니다. `externalSecret.enabled=true` 로 두면 이
차트는 `DB_URL`/`SECRET_VAULT_KEK` 용 Secret을 직접 만들지 않고 `ExternalSecret`이
Vault에서 값을 가져오도록 위임합니다. `examples/values-vault-eso.yaml` 참고.

## 알려진 제약사항

- **수평 확장(`replicaCount > 1`)과 커넥터**: Admin Console에서 "공식 커넥터"를 설치하면
  커넥터 코드가 파드 로컬 파일시스템에 저장됩니다. 여러 레플리카가 이를 공유하려면
  ReadWriteMany 볼륨이 필요한데, 이 프로젝트의 OpenEBS LVM LocalPV는 ReadWriteOnce만
  지원합니다. `replicaCount`를 1보다 크게 쓰려면 커넥터를 쓰지 않거나, 커넥터가 포함된
  커스텀 이미지를 미리 빌드하는 방식을 검토하세요.
- **최초 설치 시 동시 마이그레이션 경합**: DB 시드/마이그레이션은 각 파드의 initContainer로
  실행됩니다(idempotent). 완전히 빈 DB에 대한 최초 설치는 `replicaCount=1`로 시작해 정상
  기동을 확인한 뒤 늘리는 것을 권장합니다.
- **PgBouncer Pooler**: `cnpg.pooler.enabled=true`로 Pooler 리소스는 만들 수 있지만, CNPG가
  자동 생성하는 `-app` Secret의 host는 항상 `-rw` 서비스를 가리킵니다. Pooler를 실제로
  경유하게 하려면 `-pooler` 서비스를 가리키는 Secret을 별도로 만들어
  `cnpg.existingOwnerSecret`(또는 `externalSecret`)로 지정하세요.
- **이미지 출처 통제(Kyverno 등)**: Logto 이미지, 단독 Postgres 이미지, CNPG가 쓰는 Postgres
  이미지 모두 `image.*` / `postgresql.image.*` / `cnpg.cluster.imageName` 값으로 레지스트리를
  바꿀 수 있습니다. Harbor 단일 소스 강제 정책을 쓰는 시점이 되면 먼저 미러링부터 하세요.
- **`lookup` 기반 로직**: 비밀번호/KEK 자동 생성-보존, 공용 CNPG 클러스터의 owner Secret
  참조는 모두 Helm `lookup` 함수를 씁니다. 실제 클러스터에 연결된 `helm install/upgrade`에서만
  동작하며, 오프라인 `helm template`으로는 해당 경로를 미리보기 할 수 없습니다.

## 주요 values

| 키 | 기본값 | 설명 |
|---|---|---|
| `logto.endpoint` / `logto.adminEndpoint` | 예시 도메인 | 외부에서 접근할 실제 URL (필수) |
| `logto.secretVaultKEK` | `""` (자동 생성) | SSO 커넥터 시크릿 등을 암호화하는 키. 분실 시 복호화 불가 |
| `postgresql.enabled` | `true` | 차트 내장 단독 Postgres 사용 여부 |
| `cnpg.enabled` | `false` | CloudNativePG 사용 여부 (프로덕션 권장) |
| `cnpg.cluster.create` | `true` | 전용 클러스터 생성 vs 기존 공용 클러스터 재사용 |
| `externalSecret.enabled` | `false` | Vault/ESO로 DB_URL, SECRET_VAULT_KEK 관리 |
| `networkPolicy.enabled` | `false` | core/admin 인그레스 및 DNS/DB/HTTPS 이그레스로 트래픽 제한 |
| `dbInit.enabled` | `true` | DB 시드/마이그레이션 initContainer 실행 여부 |

전체 옵션은 `values.yaml`의 주석을 참고하세요.
