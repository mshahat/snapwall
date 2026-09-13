{{- define "pulse.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "pulse.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "pulse.labels" -}}
{{ include "pulse.selectorLabels" . }}
app.kubernetes.io/version: {{ include "pulse.version" . | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "pulse.version" -}}
{{- .Values.image.tag | default .Chart.AppVersion -}}
{{- end -}}

{{- define "pulse.image" -}}
{{- printf "%s:%s" .Values.image.repository (include "pulse.version" .) -}}
{{- end -}}

{{- define "pulse.claimName" -}}
{{- .Values.persistence.existingClaim | default (printf "%s-data" (include "pulse.fullname" .)) -}}
{{- end -}}
