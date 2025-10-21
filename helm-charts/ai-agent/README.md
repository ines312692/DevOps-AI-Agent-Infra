# DevOps AI Agent Helm Chart

This Helm chart deploys the DevOps AI Agent application to Kubernetes. It supports standard rolling updates, optional Blue/Green deployments, Horizontal Pod Autoscaling, persistence, and Prometheus monitoring via ServiceMonitor and alerting rules.

- Chart name: devops-ai-agent
- Chart version: 1.0.0
- App version: 1.0.0

## Prerequisites
- Kubernetes >= 1.24
- Helm >= 3.9
- (Optional) Prometheus Operator for ServiceMonitor/PrometheusRule CRDs
- (Optional) An ingress controller (e.g., NGINX) when enabling ingress

## Quick start

1) Add and update your chart repository (if you publish this chart in a repo). Otherwise, you can install from path.

```bash
# From chart directory (repo root assumed)
helm upgrade --install ai-agent ./helm-charts/ai-agent -n ai-agent --create-namespace
```

PowerShell (from repository root):
```powershell
helm upgrade --install ai-agent .\helm-charts\ai-agent -n ai-agent --create-namespace
```

2) Verify resources:
```bash
kubectl get all -n ai-agent
```

3) Uninstall:
```bash
helm uninstall ai-agent -n ai-agent
```

## Configuration
All configurable values are in values.yaml. You can override any of them with --set or a custom values file.

Example with a custom values file:
```bash
helm upgrade --install ai-agent ./helm-charts/ai-agent -n ai-agent -f my-values.yaml
```

### Key values overview
- replicaCount: number of pods (ignored if autoscaling.enabled=true)
- image:
  - repository, tag, pullPolicy
- imagePullSecrets: list of secrets for private registries
- nameOverride, fullnameOverride
- serviceAccount:
  - create, annotations, name
- podAnnotations: includes default Prometheus scrape hints
- podSecurityContext: runAsNonRoot, runAsUser, fsGroup
- securityContext: drops capabilities, readOnlyRootFilesystem, no privilege escalation
- service:
  - type (ClusterIP/NodePort/LoadBalancer)
  - port (app), targetPort (container), metricsPort, annotations
- ingress:
  - enabled, className, annotations, hosts[], tls[]
- resources: requests/limits
- livenessProbe, readinessProbe: HTTP checks on /healthz and /ready by default
- autoscaling:
  - enabled, minReplicas, maxReplicas
  - targetCPUUtilizationPercentage, targetMemoryUtilizationPercentage (HPA v2)
- nodeSelector, tolerations, affinity (with soft pod anti-affinity preset)
- podDisruptionBudget: enabled, minAvailable
- config:
  - logLevel (INFO, DEBUG, ...)
  - metricsSource: csv or prometheus
  - metricsPath: path to CSV when metricsSource=csv
  - detectionMethod, zscoreThreshold, rollingWindow, limitAlerts
  - enableNotifications: toggles notifier print/slack/email flags
- secrets:
  - slackWebhookUrl, emailSmtpPassword (inline values used in ConfigMap to toggle notifiers)
  - existingSecret (optional): name of a Secret to source SLACK_WEBHOOK_URL and EMAIL_SMTP_PASSWORD env vars
- persistence:
  - enabled, storageClass, accessMode, size, mountPath
- monitoring:
  - enabled
  - serviceMonitor: enabled, interval, scrapeTimeout, labels
  - prometheusRule: enabled, labels, rules[] (default example alerts included)
- strategy: Deployment strategy (RollingUpdate by default)
- blueGreen:
  - enabled: when true, creates blue and green Deployments and Services
  - activeColor: blue or green; Service selector points to the active color
- canary: enabled, weight (placeholder values for future extension)
- networkPolicy: enabled, policyTypes, ingress/egress examples

Refer to values.yaml for the full, up-to-date list and defaults.

## Ingress example
Enable ingress and set host/tls:
```yaml
ingress:
  enabled: true
  className: nginx
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  hosts:
    - host: ai.example.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: ai-example-com-tls
      hosts:
        - ai.example.com
```

## Autoscaling (HPA) example
```yaml
autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70
  targetMemoryUtilizationPercentage: 80
```
Note: When autoscaling.enabled=true, replicaCount is ignored by the Deployment template.

## Persistence example
```yaml
persistence:
  enabled: true
  storageClass: standard
  accessMode: ReadWriteOnce
  size: 5Gi
  mountPath: /app/data
```

## Monitoring (Prometheus) example
To enable ServiceMonitor and sample alert rules:
```yaml
monitoring:
  enabled: true
  serviceMonitor:
    enabled: true
    interval: 30s
    scrapeTimeout: 10s
    labels:
      release: prometheus-stack
  prometheusRule:
    enabled: true
    labels:
      release: prometheus-stack
```
This requires the Prometheus Operator CRDs in the cluster.

## Secrets and notifications
You can provide secrets in two ways:

1) Inline values (useful for dev/test only):
```yaml
secrets:
  slackWebhookUrl: "https://hooks.slack.com/services/T000/B000/XXXX"
  emailSmtpPassword: "change-me"
```
This toggles Slack/Email flags in the ConfigMap; the app may still need env vars when sending real notifications.

2) Existing Secret (recommended for production):
```yaml
secrets:
  existingSecret: ai-agent-secrets
```
Provide a Secret with keys:
- slack-webhook-url
- email-smtp-password

These will be projected to env vars SLACK_WEBHOOK_URL and EMAIL_SMTP_PASSWORD in the container.

## Blue/Green deployments
Enable Blue/Green and choose the active color:
```yaml
blueGreen:
  enabled: true
  activeColor: blue  # or green
```
The chart will create:
- Two Deployments: <release>-devops-ai-agent-blue and ...-green
- Three Services: main Service selecting deployment-color: <activeColor>, plus -blue and -green services

To switch traffic:
- Update values to set blueGreen.activeColor to the other color and upgrade the release:
```bash
helm upgrade ai-agent ./helm-charts/ai-agent -n ai-agent --reuse-values --set blueGreen.activeColor=green
```
- Verify Service selector now points to the new color.

## Argo CD / GitOps
You can manage this chart with Argo CD by pointing an Application spec to helm-charts/ai-agent and passing values through spec.sources.helm or a values file in repo. Example knobs include blueGreen.activeColor, autoscaling, ingress, and monitoring.

## Notes
- Probes default to ports defined under service.targetPort and service.metricsPort.
- When autoscaling is enabled, ensure requests are set and metrics server is installed.
- If you enable networkPolicy, adjust allowed namespaces/selectors to your environment (ingress controller, Prometheus, etc.).

## Troubleshooting
- Pods not ready: check readinessProbe endpoints (/ready) and container logs
- No metrics scraped: ensure ServiceMonitor is enabled and labels/selectors match; verify Prometheus Operator is installed
- Ingress 404/SSL: verify ingressClass, hostnames, DNS and cert-manager issuer
- Blue/Green not switching: confirm Service selector label deployment-color matches blueGreen.activeColor

## License
This chart is provided under the same license as the repository unless stated otherwise.
