{{/*
Common name.
*/}}
{{- define "logto.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Fully qualified app name.
*/}}
{{- define "logto.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "logto.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "logto.labels" -}}
helm.sh/chart: {{ include "logto.chart" . }}
{{ include "logto.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{- define "logto.selectorLabels" -}}
app.kubernetes.io/name: {{ include "logto.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "logto.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "logto.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
Logto 컨테이너 이미지 참조
*/}}
{{- define "logto.image" -}}
{{- $tag := .Values.image.tag | default .Chart.AppVersion -}}
{{- printf "%s/%s:%s" .Values.image.registry .Values.image.repository $tag -}}
{{- end -}}

{{/*
차트 내장 단독 PostgreSQL 리소스 이름
*/}}
{{- define "logto.postgresqlFullname" -}}
{{- printf "%s-postgresql" (include "logto.fullname" .) -}}
{{- end -}}

{{/*
CNPG Cluster 이름 (cluster.create=true 일 때 이 차트가 생성/소유,
create=false 일 때는 참조할 기존(공용) 클러스터 이름)
*/}}
{{- define "logto.cnpgClusterName" -}}
{{- if .Values.cnpg.cluster.name -}}
{{- .Values.cnpg.cluster.name -}}
{{- else -}}
{{- printf "%s-logto" .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{/*
DB_URL 로 쓸 Secret 이름을 우선순위대로 결정합니다:
  1) externalSecret.enabled=true            -> ExternalSecret이 채우는 로컬 Secret
  2) cnpg.enabled=true, cluster.create=true  -> CNPG가 자동 생성하는 "<cluster>-app" Secret
  2) cnpg.enabled=true, cluster.create=false -> cnpg.existingOwnerSecret (필수)
  3) postgresql.enabled=true                 -> existingSecret 또는 차트가 생성하는 Secret
  4) 그 외                                    -> externalDatabase.existingSecret (필수)
*/}}
{{- define "logto.dbSecretName" -}}
{{- if .Values.externalSecret.enabled -}}
{{- printf "%s-external" (include "logto.fullname" .) -}}
{{- else if .Values.cnpg.enabled -}}
  {{- if .Values.cnpg.cluster.create -}}
{{- printf "%s-app" (include "logto.cnpgClusterName" .) -}}
  {{- else -}}
    {{- if not .Values.cnpg.existingOwnerSecret -}}
      {{- fail "cnpg.enabled=true 이고 cnpg.cluster.create=false 이면 cnpg.existingOwnerSecret 을 반드시 지정해야 합니다." -}}
    {{- end -}}
    {{- if eq (.Values.cnpg.existingOwnerSecretFormat | default "basic-auth") "uri" -}}
{{- .Values.cnpg.existingOwnerSecret -}}
    {{- else -}}
{{- printf "%s-cnpg-owner-uri" (include "logto.fullname" .) -}}
    {{- end -}}
  {{- end -}}
{{- else if .Values.postgresql.enabled -}}
  {{- if .Values.postgresql.auth.existingSecret -}}
{{- .Values.postgresql.auth.existingSecret -}}
  {{- else -}}
{{- include "logto.postgresqlFullname" . -}}
  {{- end -}}
{{- else -}}
  {{- if not .Values.externalDatabase.existingSecret -}}
    {{- fail "postgresql.enabled=false 이고 cnpg.enabled=false 이면 externalDatabase.existingSecret 을 반드시 지정해야 합니다." -}}
  {{- end -}}
{{- .Values.externalDatabase.existingSecret -}}
{{- end -}}
{{- end -}}

{{/*
DB_URL 값을 담고 있는 키 이름
*/}}
{{- define "logto.dbSecretKey" -}}
{{- if .Values.externalSecret.enabled -}}
uri
{{- else if .Values.cnpg.enabled -}}
  {{- if .Values.cnpg.cluster.create -}}
uri
  {{- else if eq (.Values.cnpg.existingOwnerSecretFormat | default "basic-auth") "uri" -}}
{{- .Values.cnpg.existingOwnerSecretKey | default "uri" -}}
  {{- else -}}
uri
  {{- end -}}
{{- else if .Values.postgresql.enabled -}}
uri
{{- else -}}
{{- .Values.externalDatabase.existingSecretKey | default "uri" -}}
{{- end -}}
{{- end -}}

{{/*
Logto 앱 전용 Secret 이름 (SECRET_VAULT_KEK 등). externalSecret 사용 시 그쪽 Secret과 통합됩니다.
*/}}
{{- define "logto.appSecretName" -}}
{{- if .Values.externalSecret.enabled -}}
{{- printf "%s-external" (include "logto.fullname" .) -}}
{{- else -}}
{{- include "logto.fullname" . -}}
{{- end -}}
{{- end -}}
