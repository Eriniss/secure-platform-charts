## 보안 플랫폼 구축과 검증

### 1. 프로젝트 개요

- **목적**: 이미지 출처를 단일화하는 통제와 런타임 이상행위 탐지라는 두 개의 통제 지점을 온프레미스에서 직접 구축하고, 실제 동작으로 검증
- **핵심 스택**: RKE2, Cilium + Hubble, Harbor + Trivy, Kyverno, Falco, LGTM + Alloy, Vault + ESO, ArgoCD, CNPG, Logto, GitLab CI, OpenEBS, Velero
- **환경**: Proxmox 위 컨트롤플레인 1 + 워커 3 (노드당 4 vCPU / 16GB), 외부 MinIO, OPNsense 플랫 네트워크

### 2. 문제 설명 (Problem Statement)

- **검증 없는 배포 경로**: AI 코딩 도구로 코드에서 배포까지의 주기가 짧아지면서, 출처가 검증되지 않은 이미지가 그대로 배포되는 구조적 위험이 커졌습니다.
- **"설정했으니 되겠지"의 위험**: 씬풀 자동확장을 기본값으로 믿었다가 실제 장애를 겪은 전례가 있어서, 모든 통제를 장애 주입으로 확인하는 원칙을 세웠습니다.
- **범위 폭주**: 한 번에 많은 도구를 켜면 막힌 지점을 찾을 수 없어서, 이미지 서명 같은 복잡한 체계는 제외하고 "신뢰할 수 있는 단일 경로"와 "이상행위 관측"에 집중했습니다.

### 3. 해결 과정 (Solution Process)

#### 1) 목표를 검증 방법과 함께 정의

6개 목표를 검증 방법과 1:1로 묶고, 앞 Phase를 검증한 뒤 다음으로 넘어가도록 8단계로 나눴습니다. 중간에 GitLab 도입을 번복하면서 역할을 "코드 호스팅 + CI"로 한정하고, GitOps 소스는 GitHub에 두는 것으로 정리했습니다.

#### 2) 단일 이미지 소스 강제 (Harbor + Kyverno)

Harbor 프록시 캐시로 외부 레지스트리를 단일 주소로 모으고, Kyverno Mutate로 이미지 주소를 치환한 뒤 Validate로 매핑에 없는 레지스트리를 거부했습니다. kind에서 Audit → Enforce를 먼저 연습했습니다. 이 과정에서 만난 문제는 다음과 같습니다.

- initContainers가 없는 Pod가 전부 차단됨
- 401의 원인이 인증이 아니라 프로젝트 누락이었음
- 거부 테스트가 통과한 이유가 이미 매핑된 레지스트리를 썼기 때문이었음

#### 3) 취약점 탐지 거버넌스 (Trivy)

React2Shell 취약 버전(19.2.0)으로 3-Tier 앱을 만들어 Kaniko CI로 Harbor에 푸시했고, Critical 1건을 포함한 10건이 탐지되는 것을 확인했습니다. 목표 중 "12시간 내 인지"는 측정 기준이 정의되지 않아서 24시간 주기 스캔으로 조정했고, Harbor 웹훅으로 Slack 알림을 붙였습니다.

#### 4) 런타임 탐지 (Falco)

modern eBPF 드라이버로 DaemonSet을 올리고 Loki로 수집한 뒤, stable 룰만으로는 놓치는 탐지를 incubating 룰셋으로 보강했습니다. 15가지 의심 행위 중 9개를 탐지했고 6개는 미탐지로 기록했습니다. 오탐은 커스텀 룰 예외로 정리했고, Grafana 알림은 Warning 이상만, 같은 이벤트는 묶어서 한 번만 Slack으로 보내도록 했습니다.

#### 5) 제로트러스트 네트워크 (Cilium + Hubble)

Hubble로 실제 트래픽을 관찰해 front, back, DB 3개 정책을 작성했습니다. `enableDefaultDeny.egress: true`만으로는 egress가 막히지 않는다는 점을 파드 안에서 직접 확인하고 빈 규칙으로 수정했습니다. CNPG 백업을 일부러 걸어 DROPPED가 FORWARDED로 바뀌는 것까지 보고 `toFQDNs`로 허용했습니다.

### 4. 결론 (Conclusion & Insights)

- **성과**: 6개 목표 중 Harbor/Trivy 탐지, Falco 알림 도달, Kyverno 차단은 검증을 마쳤고, Cilium 정책은 egress 차단과 DB 통신 허용까지 확인했습니다. 외부 노출 취소, Trivy SLO 조정처럼 범위를 근거 있게 줄였습니다. 계획 외로 Velero/Kopia 백업과 CNPG PITR 복구도 구현했습니다.
- **기술적 통찰**: `VALID`는 "강제됨"이 아니라서 파드 안 통신 테스트로 확인해야 합니다. 서드파티 앱은 Hubble만으로 필요한 통신을 다 알 수 없으므로, 일부러 트래픽을 일으켜 관찰하고 허용하는 루프가 현실적입니다. 증상(401, 연결 재시도)과 원인이 다른 경우가 많아서, 서버 쪽 로그를 먼저 보는 것이 빨랐습니다.
- **한계**:
    - Kyverno는 테스트 네임스페이스 한 곳에만 적용했고 `failurePolicy: Ignore`라서 Kyverno가 죽으면 우회됩니다.
    - Vault 재기동 후 ESO 재동기화와 ArgoCD OutOfSync 검증은 하지 못했습니다.
    - Cilium은 VXLAN 터널 모드를 유지했고 native routing 전환은 하지 않았습니다.
    - Falco 미탐지 6건의 원인은 확인하지 못했습니다.
- **향후 계획**: 위 검증 항목을 닫고, Kyverno 적용 범위 확대(Fail 모드), CNP의 GitOps 이관, Hubble 메트릭 장기 보관과 차단 이벤트 알림을 진행합니다.
