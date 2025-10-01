# ArgoCD GitOps Configuration

Ce dossier contient la configuration ArgoCD pour le déploiement GitOps du DevOps AI Agent.

## Architecture GitOps

```
GitHub Repository (Source of Truth)
        ↓
    ArgoCD (Reconciliation)
        ↓
    Kubernetes Cluster
```

## Structure

```
argocd/
├── projects/
│   └── devops-ai-project.yaml      # ArgoCD Project
└── applications/
    ├── dev-application.yaml        # Dev environment
    ├── staging-application.yaml    # Staging environment
    └── prod-application.yaml       # Production environment
```

## Installation d'ArgoCD

### 1. Installer ArgoCD

```bash
# Créer le namespace
kubectl create namespace argocd

# Installer ArgoCD
kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml

# Attendre que les pods soient prêts
kubectl wait --for=condition=ready pod --all -n argocd --timeout=5m
```

### 2. Exposer l'interface ArgoCD

**Option A: Port Forward (dev/test)**

```bash
kubectl port-forward svc/argocd-server -n argocd 8080:443
```

**Option B: Ingress (production)**

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: argocd-server
  namespace: argocd
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/backend-protocol: "HTTPS"
spec:
  ingressClassName: nginx
  rules:
  - host: argocd.yourdomain.com
    http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: argocd-server
            port:
              number: 443
  tls:
  - hosts:
    - argocd.yourdomain.com
    secretName: argocd-server-tls
```

### 3. Récupérer le mot de passe admin

```bash
# Get initial password
kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" | base64 -d; echo
```

### 4. Login via CLI

```bash
# Install ArgoCD CLI
brew install argocd  # macOS
# ou
curl -sSL -o argocd-linux-amd64 https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
sudo install -m 555 argocd-linux-amd64 /usr/local/bin/argocd

# Login
argocd login localhost:8080
# Username: admin
# Password: <from previous step>

# Change password
argocd account update-password
```

## Déploiement des Applications

### 1. Créer le projet ArgoCD

```bash
kubectl apply -f argocd/projects/devops-ai-project.yaml
```

Cela crée un projet avec:
- Repositories autorisés
- Destinations autorisées (namespaces)
- Ressources Kubernetes autorisées
- Permissions

### 2. Déployer les applications

#### Development

```bash
kubectl apply -f argocd/applications/dev-application.yaml

# Ou via CLI
argocd app create devops-ai-dev \
  --repo https://github.com/your-username/DevOps-AI-Agent-Infra.git \
  --path helm/devops-ai-agent \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace devops-ai-dev \
  --helm-set-file values=helm/devops-ai-agent/values-dev.yaml \
  --sync-policy automated \
  --auto-prune \
  --self-heal
```

#### Staging

```bash
kubectl apply -f argocd/applications/staging-application.yaml
```

#### Production

```bash
kubectl apply -f argocd/applications/prod-application.yaml
```

**Note:** La production nécessite une sync manuelle pour plus de contrôle.

## Gestion des Applications

### Visualiser l'état

```bash
# Liste des applications
argocd app list

# Détails d'une application
argocd app get devops-ai-prod

# Status
argocd app status devops-ai-prod

# Historique
argocd app history devops-ai-prod
```

### Synchronisation

```bash
# Sync manuelle
argocd app sync devops-ai-prod

# Sync avec prune (supprime les ressources orphelines)
argocd app sync devops-ai-prod --prune

# Force sync (ignore les différences)
argocd app sync devops-ai-prod --force

# Dry-run
argocd app sync devops-ai-prod --dry-run
```

### Diff

```bash
# Voir les différences entre Git et Cluster
argocd app diff devops-ai-prod

# Diff d'une ressource spécifique
argocd app diff devops-ai-prod --resource apps/Deployment/devops-ai-agent
```

### Rollback

```bash
# Lister l'historique
argocd app history devops-ai-prod

# Rollback vers une révision
argocd app rollback devops-ai-prod 5
```

## Workflow GitOps

### Déploiement Dev (Auto-sync)

1. Developer push du code sur `main`
2. GitHub Actions:
    - Build image Docker
    - Push vers registry
    - Update `values-dev.yaml` avec nouveau tag
    - Commit & push
3. ArgoCD détecte le changement (polling toutes les 3min)
4. **Sync automatique** vers dev
5. Notifications Slack

### Déploiement Staging (Auto-sync)

1. Tag Git créé: `v1.0.0-rc1`
2. GitHub Actions:
    - Build & push image
    - Update `values-staging.yaml`
3. ArgoCD sync automatique
4. Tests d'intégration automatiques

### Déploiement Production (Manual sync)

1. Tag Git release: `v1.0.0`
2. GitHub Actions:
    - Build & push image
    - Crée PR pour update `values-prod.yaml`
3. **Review & Approval** requis
4. Merge de la PR
5. ArgoCD détecte le changement
6. **Sync manuelle requise** par ops team
7. Blue-Green deployment
8. Validation & monitoring

## Configuration Avancée

### Sync Waves (Ordre de déploiement)

Utilisez les annotations pour contrôler l'ordre:

```yaml
metadata:
  annotations:
    argocd.argoproj.io/sync-wave: "0"  # Deploy first
```

Exemple d'ordre:
- Wave 0: Namespaces, ConfigMaps, Secrets
- Wave 1: PVCs, ServiceAccounts
- Wave 2: Deployments, Services
- Wave 3: Ingress, HPA

### Sync Options

```yaml
syncPolicy:
  syncOptions:
    - CreateNamespace=true       # Créer namespace si absent
    - PrunePropagationPolicy=foreground
    - PruneLast=true             # Prune après sync
    - Replace=false              # Use patch instead of replace
    - ServerSideApply=true       # Server-side apply
```

### Health Assessment personnalisé

```yaml
spec:
  ignoreDifferences:
  - group: apps
    kind: Deployment
    jsonPointers:
    - /spec/replicas  # Ignore HPA changes
  
  - group: ""
    kind: Secret
    name: argocd-secret
    jsonPointers:
    - /data/admin.password  # Ignore password changes
```

### Resource Hooks

```yaml
metadata:
  annotations:
    argocd.argoproj.io/hook: PreSync           # Run before sync
    argocd.argoproj.io/hook-delete-policy: HookSucceeded
```

Types de hooks:
- `PreSync`: Avant la sync
- `Sync`: Pendant la sync
- `PostSync`: Après la sync
- `SyncFail`: En cas d'échec

## Notifications

### Configuration Slack

```bash
# Create secret
kubectl create secret generic argocd-notifications-secret \
  --from-literal=slack-token=<YOUR_SLACK_TOKEN> \
  -n argocd

# Configure notifications
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-notifications-cm
  namespace: argocd
data:
  service.slack: |
    token: \$slack-token
  
  template.app-deployed: |
    message: |
      Application {{.app.metadata.name}} is now running new version.
    slack:
      attachments: |
        [{
          "title": "{{ .app.metadata.name}}",
          "color": "good",
          "fields": [{
            "title": "Sync Status",
            "value": "{{.app.status.sync.status}}",
            "short": true
          }, {
            "title": "Repository",
            "value": "{{.app.spec.source.repoURL}}",
            "short": true
          }]
        }]
  
  trigger.on-deployed: |
    - when: app.status.operationState.phase in ['Succeeded']
      send: [app-deployed]
  
  subscriptions: |
    - recipients:
      - slack:devops-alerts
      triggers:
      - on-deployed
EOF
```

### Ajouter notifications aux apps

```yaml
metadata:
  annotations:
    notifications.argoproj.io/subscribe.on-deployed.slack: devops-alerts
```

## Monitoring ArgoCD

### Prometheus Metrics

ArgoCD expose des métriques Prometheus:

```bash
kubectl port-forward -n argocd svc/argocd-metrics 8082:8082
curl http://localhost:8082/metrics
```

Métriques importantes:
- `argocd_app_info`: Info sur les apps
- `argocd_app_sync_total`: Total syncs
- `argocd_app_k8s_request_total`: Requêtes K8s

### Grafana Dashboard

Importer le dashboard officiel ArgoCD:
- Dashboard ID: `14584`
- URL: https://grafana.com/grafana/dashboards/14584

### Health Checks

```bash
# ArgoCD components
kubectl get pods -n argocd

# Application health
argocd app list --output json | jq '.[] | {name: .metadata.name, health: .status.health.status}'
```

## Troubleshooting

### Application OutOfSync

```bash
# Identifier les différences
argocd app diff devops-ai-prod

# Causes communes:
# 1. HPA modifie replicas → ajouter ignoreDifferences
# 2. Secrets modifiés manuellement → resync
# 3. Resources non trackés → vérifier .spec.source.path
```

### Sync Failed

```bash
# Voir les logs de sync
argocd app logs devops-ai-prod

# Voir les events
kubectl get events -n devops-ai-prod --sort-by='.lastTimestamp'

# Causes communes:
# 1. Helm chart invalide → helm lint
# 2. Ressources insuffisantes → check quotas
# 3. RBAC → check serviceAccount permissions
```

### Application Stuck in Progressing

```bash
# Check health
argocd app get devops-ai-prod

# Check resources
kubectl get all -n devops-ai-prod

# Force refresh
argocd app get devops-ai-prod --refresh

# Hard refresh (clear cache)
argocd app get devops-ai-prod --hard-refresh
```

### Performance Issues

```bash
# Augmenter la fréquence de polling (défaut: 3min)
kubectl patch configmap argocd-cm -n argocd --type merge -p '{"data":{"timeout.reconciliation":"60s"}}'

# Disable auto-sync temporairement
argocd app set devops-ai-prod --sync-policy none
```

## Best Practices

### 1. Structure Git

```
 Bon:
helm/
  devops-ai-agent/
    values-dev.yaml
    values-staging.yaml
    values-prod.yaml

 Mauvais:
envs/
  dev/
    helm/
  staging/
    helm/
```

### 2. Secrets Management

**Ne jamais commiter de secrets en clair!**

Options:
- **Sealed Secrets** (recommandé)
- **External Secrets Operator**
- **Vault Plugin**

Exemple Sealed Secrets:

```bash
# Installer sealed-secrets
kubectl apply -f https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.24.0/controller.yaml

# Seal un secret
kubectl create secret generic mysecret --dry-run=client -o yaml | \
  kubeseal -o yaml > sealed-secret.yaml

# Commit sealed-secret.yaml (safe)
```

### 3. Multi-Cluster

Pour gérer plusieurs clusters:

```yaml
# argocd-cm ConfigMap
data:
  clusters: |
    - name: staging-cluster
      server: https://staging.k8s.example.com
      config:
        tlsClientConfig:
          caData: ...
          certData: ...
    
    - name: prod-cluster
      server: https://prod.k8s.example.com
```

### 4. ApplicationSet

Pour gérer plusieurs apps similaires:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: devops-ai-multienv
spec:
  generators:
  - list:
      elements:
      - env: dev
        replicas: "1"
      - env: staging
        replicas: "2"
      - env: prod
        replicas: "3"
  template:
    metadata:
      name: 'devops-ai-{{env}}'
    spec:
      project: devops-ai
      source:
        repoURL: https://github.com/your-username/DevOps-AI-Agent-Infra.git
        path: helm/devops-ai-agent
        helm:
          valueFiles:
          - values-{{env}}.yaml
      destination:
        server: https://kubernetes.default.svc
        namespace: 'devops-ai-{{env}}'
```

## Ressources

- [ArgoCD Documentation](https://argo-cd.readthedocs.io/)
- [Best Practices](https://argo-cd.readthedocs.io/en/stable/user-guide/best_practices/)
- [GitOps Principles](https://www.gitops.tech/)

## Support

Pour des questions:
- GitHub Issues: https://github.com/your-username/DevOps-AI-Agent-Infra/issues
- Slack: #devops-team