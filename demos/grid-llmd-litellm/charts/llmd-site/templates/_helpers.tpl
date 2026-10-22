{{- define "llmd-site.site" -}}
{{- required "site is required: it names the InferencePool and distinguishes this site's candidate" .Values.site -}}
{{- end -}}

{{- define "llmd-site.modelSelector" -}}
app: vllm-sim
pool: {{ include "llmd-site.site" . | quote }}
{{- end -}}
