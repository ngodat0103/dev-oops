{{/*
Chart name (also used as the release/app name). Argus is always deployed as "argus",
so we intentionally keep this stable and independent of the Helm release name.
*/}}
{{- define "argus.name" -}}
{{- .Chart.Name -}}
{{- end -}}

{{/*
Selector labels. MUST stay stable across releases: a Deployment's spec.selector is
immutable, and the live object selects on `app.kubernetes.io/name: argus`. Do NOT add
the version label here.
*/}}
{{- define "argus.selectorLabels" -}}
app.kubernetes.io/name: {{ include "argus.name" . }}
{{- end -}}

{{/*
Common metadata labels (safe to change between releases; not used as a selector).
*/}}
{{- define "argus.labels" -}}
{{ include "argus.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{/*
ServiceAccount name.
*/}}
{{- define "argus.serviceAccountName" -}}
{{- default (include "argus.name" .) .Values.serviceAccount.name -}}
{{- end -}}
