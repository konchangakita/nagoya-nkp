{{- define "dify.name" -}}
{{ .Chart.Name }}
{{- end -}}

{{- define "dify.externalURL" -}}
{{- if .Values.external.host -}}
{{ .Values.external.scheme | default "https" }}://{{ .Values.external.host }}
{{- else -}}
{{- /* 空文字列を返す（相対パスで動作） */}}
{{- end -}}
{{- end -}}

