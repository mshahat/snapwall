{{- define "snapwall.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "snapwall.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "snapwall.labels" -}}
{{ include "snapwall.selectorLabels" . }}
app.kubernetes.io/version: {{ include "snapwall.version" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- /* Flux's Revision strategy versions the chart as 1.2.13+<sha>; "+" is not valid in a label. */}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end -}}

{{- define "snapwall.tag" -}}
{{- .Values.image.tag | default .Chart.AppVersion -}}
{{- end -}}

{{- /* Version shown on screen: the image tag, or appVersion when the tag says nothing (latest). */}}
{{- define "snapwall.version" -}}
{{- $tag := include "snapwall.tag" . -}}
{{- eq $tag "latest" | ternary .Chart.AppVersion $tag -}}
{{- end -}}

{{- define "snapwall.image" -}}
{{- printf "%s:%s" .Values.image.repository (include "snapwall.tag" .) -}}
{{- end -}}

{{- /* Ingress host: the ingress.host value if set, else ingress.host from the cluster ConfigMap.
     lookup reads the live cluster at install/upgrade (empty under helm template), so with
     neither set the Ingress answers on any hostname. */}}
{{- define "snapwall.ingressHost" -}}
{{- $cm := lookup "v1" "ConfigMap" .Release.Namespace .Values.clusterConfig.configMapName | default dict -}}
{{- .Values.ingress.host | default (dig "data" "ingress.host" "" $cm) -}}
{{- end -}}

{{- define "snapwall.claimName" -}}
{{- .Values.persistence.existingClaim | default (printf "%s-data" (include "snapwall.fullname" .)) -}}
{{- end -}}
