{{- define "crowdsec-firewall-bouncer.name" -}}
{{- default "crowdsec-firewall-bouncer" .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "crowdsec-firewall-bouncer.labels" -}}
app.kubernetes.io/name: {{ include "crowdsec-firewall-bouncer.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
