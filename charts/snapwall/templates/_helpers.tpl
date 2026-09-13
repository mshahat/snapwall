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

{{- define "snapwall.version" -}}
{{- .Values.image.tag | default .Chart.AppVersion -}}
{{- end -}}

{{- define "snapwall.image" -}}
{{- printf "%s:%s" .Values.image.repository (include "snapwall.version" .) -}}
{{- end -}}

{{- define "snapwall.claimName" -}}
{{- .Values.persistence.existingClaim | default (printf "%s-data" (include "snapwall.fullname" .)) -}}
{{- end -}}
