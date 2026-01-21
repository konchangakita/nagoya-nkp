{{- define "dify.name" -}}
{{ .Chart.Name }}
{{- end -}}

{{- define "dify.externalURL" -}}
{{ required "external.scheme is required" .Values.external.scheme }}://{{ required "external.host is required" .Values.external.host }}{{ .Values.expose.path }}
{{- end -}}

