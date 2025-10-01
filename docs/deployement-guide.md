# Guide de Déploiement Détaillé

Ce guide vous accompagne pas à pas dans le déploiement du DevOps AI Agent sur Kubernetes.

## Table des matières

1. [Préparation de l'environnement](#préparation-de-lenvironnement)
2. [Configuration du cluster](#configuration-du-cluster)
3. [Déploiement en développement](#déploiement-en-développement)
4. [Déploiement en staging](#déploiement-en-staging)
5. [Déploiement en production](#déploiement-en-production)
6. [Vérification post-déploiement](#vérification-post-déploiement)
7. [Troubleshooting](#troubleshooting)

---

## Préparation de l'environnement

### 1.1 Prérequis

Assurez-vous d'avoir installé:

```bash
# Vérifier les versions
helm version          # v3.12.0+
kubectl version       # v1.24+
docker version        # 20.10+
git --version         # 2.0+
```

### 1.2 Accès au cluster

```bash
# Configurer kubectl
export KUBECONFIG=~/.kube/config

# Vérifier la connexion
kubectl cluster-info
kubectl get nodes
```

### 1.3 Cloner le repository

```bash
git clone https://github.com/your-username/DevOps-AI-Agent-Infra.git
cd DevOps-AI-Agent-Infra
```

---

## Configuration du cluster

### 2.1 Créer les namespaces

```bash
kubectl create namespace devops-ai-dev
kubectl create namespace devops-ai-staging
kubectl create namespace devops-ai-prod
kubectl create namespace monitoring
```

### 2.2 Créer les secrets

#### Pour développement:

```bash
kubectl create secret generic devops-ai-dev-secrets \
  --from-literal=slack-webhook-url='https://hooks.slack.com/services/YOUR/WEBHOOK/URL' \
  --from-literal=email-smtp-password='your-smtp-password' \
  -n devops-ai-dev
```

#### Pour production:

```bash
kubectl create secret generic devops-ai-prod-secrets \
  --from-literal=slack-webhook-url='https://hooks.slack.com/services/YOUR/WEBHOOK/URL' \
  --from-literal=email-smtp-password='your-smtp-password' \
  -n devops-ai-prod
```

**Note:** En production, utilisez un gestionnaire de secrets comme:
- **Sealed Secrets** (recommandé pour GitOps)
- **External Secrets Operator**
- **HashiCorp Vault**
- **AWS Secrets Manager / Azure Key Vault / GCP Secret Manager**

### 2.3 Configurer le stockage persistant (optionnel)

```bash
# Créer une StorageClass rapide si nécessaire
cat <<EOF | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: fast-ssd
provisioner: kubernetes.io/gce-pd
parameters:
  type: pd-ssd
  replication-type: regional-pd
allowVolumeExpansion: true
EOF
```

---

## Déploiement en développement

### 3.1 Valider le chart Helm

```bash
# Lint
make lint

# Dry-run
make dry-run-dev

# Template (vérifier le YAML généré)
make template-dev > /tmp/dev-manifest.yaml
cat /tmp/dev-manifest.yaml
```

### 3.2 Déployer

**Option A: Via Makefile (recommandé)**

```bash
make deploy-dev
```

**Option B: Via Helm directement**

```bash
helm upgrade --install devops-ai-agent helm/devops-ai-agent \
  -f helm/devops-ai-agent/values-dev.yaml \
  --namespace devops-ai-dev \
  --create-namespace \
  --wait \
  --timeout 5m
```

### 3.3 Vérifier le déploiement

```bash
# Status global
make status-dev

# Pods
kubectl get pods -n devops-ai-dev -w

# Logs
make logs-dev

# Events
kubectl get events -n devops-ai-dev --sort-by='.lastTimestamp'
```

### 3.4 Accéder à l'application

```bash
# Port forward
make port-forward-dev

# Ou manuellement
kubectl port-forward -n devops-ai-dev svc/devops-ai-agent 8501:8501
```

Ouvrir dans le navigateur: http://localhost:8501

### 3.5 Tests de santé

```bash
# Health check
curl http://localhost:8501/healthz

# Metrics
curl http://localhost:8501/metrics
```

---

## Déploiement en staging

### 4.1 Pré-déploiement

```bash
# Vérifier que dev fonctionne bien
kubectl get all -n devops-ai-dev

# Valider le chart staging
make dry-run-staging
```

### 4.2 Déployer en staging

```bash
make deploy-staging
```

### 4.3 Tests d'intégration

```bash
# Attendre que les pods soient prêts
kubectl wait --for=condition=ready pod \
  -l app.kubernetes.io/name=devops-ai-agent \
  -n devops-ai-staging \
  --timeout=5m

# Port forward
make port-forward-staging

# Exécuter smoke tests
curl -f http://localhost:8501/healthz || echo "Health check failed"
curl -f http://localhost:8501/ready || echo "Ready check failed"

# Vérifier les métriques Prometheus
kubectl port-forward -n devops-ai-staging svc/devops-ai-agent 8000:8000
curl http://localhost:8000/metrics | grep devops_ai
```

### 4.4 Tests de charge (optionnel)

```bash
# Installer k6 (load testing)
brew install k6  # macOS

# Créer un test simple
cat <<EOF > load-test.js
import http from 'k6/http';
import { check, sleep } from 'k6';

export let options = {
  stages: [
    { duration: '2m', target: 10 },
    { duration: '5m', target: 50 },
    { duration: '2m', target: 0 },
  ],
};

export default function () {
  let res = http.get('http://localhost:8501/healthz');
  check(res, { 'status is 200': (r) => r.status === 200 });
  sleep(1);
}
EOF

# Exécuter le test
k6 run load-test.js
```

---

## Déploiement en production

### 5.1 Stratégie: Blue-Green Deployment

La production utilise une stratégie **Blue-Green** pour un rollback instantané.

#### Architecture Blue-Green:

```
┌─────────────────────────────────────────┐
│         Production Namespace            │
│                                         │
│  ┌──────────────┐    ┌──────────────┐ │
│  │   Blue       │    │   Green      │ │
│  │ Deployment   │    │ Deployment   │ │
│  │ (v1.0.0)     │    │ (v1.1.0)     │ │
│  └──────┬───────┘    └──────┬───────┘ │
│         │                    │         │
│         └────────┬───────────┘         │
│                  │                     │
│         ┌────────▼────────┐            │
│         │  Main Service   │            │
│         │  (selector: →)  │            │
│         └────────┬────────┘            │
│                  │                     │
│         ┌────────▼────────┐            │
│         │     Ingress     │            │
│         └─────────────────┘            │
└─────────────────────────────────────────┘
```

### 5.2 Préparation

```bash
# Vérifier que staging est stable
kubectl get all -n devops-ai-staging

# Backup de la config actuelle
helm get values devops-ai-agent -n devops-ai-prod > /tmp/prod-backup-values.yaml

# Vérifier la version de l'image
grep "tag:" helm/devops-ai-agent/values-prod.yaml
```

### 5.3 Déploiement initial (première fois)

```bash
# Déployer avec Blue-Green activé
helm upgrade --install devops-ai-agent helm/devops-ai-agent \
  -f helm/devops-ai-agent/values-prod.yaml \
  --set blueGreen.enabled=true \
  --set blueGreen.activeColor=blue \
  --set image.tag=1.0.0 \
  --namespace devops-ai-prod \
  --create-namespace \
  --wait \
  --timeout 15m
```

### 5.4 Déploiement d'une nouvelle version

#### Étape 1: Identifier la couleur active

```bash
CURRENT_COLOR=$(kubectl get service devops-ai-agent \
  -n devops-ai-prod \
  -o jsonpath='{.spec.selector.deployment-color}')

echo "Active color: $CURRENT_COLOR"

# Déterminer la nouvelle couleur
if [ "$CURRENT_COLOR" = "blue" ]; then
  NEW_COLOR="green"
else
  NEW_COLOR="blue"
fi

echo "Will deploy to: $NEW_COLOR"
```

#### Étape 2: Déployer sur la couleur inactive

```bash
# Mettre à jour le Helm release (déploie sur les deux couleurs)
helm upgrade devops-ai-agent helm/devops-ai-agent \
  -f helm/devops-ai-agent/values-prod.yaml \
  --set image.tag=1.1.0 \
  --set blueGreen.enabled=true \
  --set blueGreen.activeColor=$CURRENT_COLOR \
  --namespace devops-ai-prod \
  --wait \
  --timeout 15m
```

#### Étape 3: Vérifier la nouvelle version

```bash
# Vérifier que les pods sont prêts
kubectl get pods -n devops-ai-prod -l deployment-color=$NEW_COLOR

# Tester directement le service inactive
kubectl port-forward -n devops-ai-prod \
  svc/devops-ai-agent-$NEW_COLOR 8502:8501 &

# Health check
curl http://localhost:8502/healthz

# Smoke tests
curl http://localhost:8502/ready
```

#### Étape 4: Switch du trafic

**Option A: Via script (recommandé)**

```bash
chmod +x scripts/blue-green-switch.sh
./scripts/blue-green-switch.sh $NEW_COLOR devops-ai-prod
```

**Option B: Via Makefile**

```bash
# Si nouvelle couleur est green
make blue-green-switch-green

# Si nouvelle couleur est blue
make blue-green-switch-blue
```

**Option C: Manuellement**

```bash
helm upgrade devops-ai-agent helm/devops-ai-agent \
  -f helm/devops-ai-agent/values-prod.yaml \
  --reuse-values \
  --set blueGreen.activeColor=$NEW_COLOR \
  --namespace devops-ai-prod \
  --wait
```

#### Étape 5: Monitoring post-switch

```bash
# Observer les logs
kubectl logs -f -l deployment-color=$NEW_COLOR -n devops-ai-prod

# Surveiller les métriques
kubectl top pods -n devops-ai-prod

# Vérifier les alertes Prometheus
kubectl port-forward -n monitoring svc/prometheus-server 9090:80
```

Ouvrir: http://localhost:9090

Requêtes utiles:
```promql
# Taux d'erreurs
rate(http_requests_total{status=~"5.."}[5m])

# Latence p95
histogram_quantile(0.95, rate(http_request_duration_seconds_bucket[5m]))

# Pods disponibles
up{job="devops-ai-agent"}
```

#### Étape 6: Rollback si problème

**En cas de problème, rollback immédiat:**

```bash
# Switch instantané vers l'ancienne version
./scripts/blue-green-switch.sh $CURRENT_COLOR devops-ai-prod

# Ou via Makefile
make blue-green-switch-blue  # si l'ancienne était blue
```

#### Étape 7: Cleanup (optionnel)

```bash
# Scale down l'ancienne version après confirmation que tout fonctionne
kubectl scale deployment devops-ai-agent-$CURRENT_COLOR \
  --replicas=0 \
  -n devops-ai-prod
```

---

## Vérification post-déploiement

### 6.1 Checklist de vérification

```bash
# ✅ Pods en running
kubectl get pods -n devops-ai-prod

# ✅ Services exposés
kubectl get svc -n devops-ai-prod

# ✅ Ingress configuré
kubectl get ingress -n devops-ai-prod

# ✅ HPA actif
kubectl get hpa -n devops-ai-prod

# ✅ PDB configuré
kubectl get pdb -n devops-ai-prod

# ✅ ServiceMonitor actif
kubectl get servicemonitor -n devops-ai-prod

# ✅ Secrets présents
kubectl get secrets -n devops-ai-prod
```

### 6.2 Tests fonctionnels

```bash
# Test de l'application
curl https://devops-ai.yourdomain.com/healthz

# Test des métriques
curl https://devops-ai.yourdomain.com/metrics

# Test de l'UI
open https://devops-ai.yourdomain.com
```

### 6.3 Vérification des ressources

```bash
# CPU/Memory usage
kubectl top pods -n devops-ai-prod

# Resource limits/requests
kubectl describe deployment devops-ai-agent -n devops-ai-prod | grep -A 5 "Limits\|Requests"
```

---

## Troubleshooting

### 7.1 Pods ne démarrent pas

```bash
# Vérifier l'état
kubectl describe pod <pod-name> -n devops-ai-prod

# Vérifier les events
kubectl get events -n devops-ai-prod --sort-by='.lastTimestamp' | tail -20

# Vérifier les logs
kubectl logs <pod-name> -n devops-ai-prod --previous
```

**Causes communes:**
- Image non trouvée: vérifier `image.repository` et `image.tag`
- Secrets manquants: créer les secrets requis
- Resources insuffisantes: ajuster `resources.requests`
- Volume mount failed: vérifier PVC

### 7.2 Service non accessible

```bash
# Vérifier les endpoints
kubectl get endpoints devops-ai-agent -n devops-ai-prod

# Vérifier le selector
kubectl get svc devops-ai-agent -n devops-ai-prod -o yaml | grep selector -A 3

# Test de connectivité interne
kubectl run test-pod --rm -it --image=curlimages/curl -- sh
curl http://devops-ai-agent.devops-ai-prod:8501/healthz
```

### 7.3 HPA ne scale pas

```bash
# Vérifier les métriques
kubectl get hpa -n devops-ai-prod
kubectl describe hpa devops-ai-agent -n devops-ai-prod

# Vérifier metrics-server
kubectl top nodes
kubectl top pods -n devops-ai-prod

# Installer metrics-server si absent
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

### 7.4 Prometheus ne scrape pas

```bash
# Vérifier ServiceMonitor
kubectl get servicemonitor -n devops-ai-prod
kubectl describe servicemonitor devops-ai-agent -n devops-ai-prod

# Vérifier les labels
kubectl get svc devops-ai-agent -n devops-ai-prod --show-labels

# Vérifier dans Prometheus UI
kubectl port-forward -n monitoring svc/prometheus-server 9090:80
# Aller à Status > Targets
```

### 7.5 Blue-Green switch échoue

```bash
# Vérifier l'état des deux déploiements
kubectl get deployments -n devops-ai-prod

# Vérifier les pods de chaque couleur
kubectl get pods -n devops-ai-prod -l deployment-color=blue
kubectl get pods -n devops-ai-prod -l deployment-color=green

# Vérifier le service selector
kubectl get svc devops-ai-agent -n devops-ai-prod -o yaml | grep deployment-color

# Force update du service
kubectl patch svc devops-ai-agent -n devops-ai-prod \
  -p '{"spec":{"selector":{"deployment-color":"blue"}}}'
```

### 7.6 Rollback complet

```bash
# Via Helm
helm rollback devops-ai-agent -n devops-ai-prod

# Spécifier une révision
helm history devops-ai-agent -n devops-ai-prod
helm rollback devops-ai-agent 3 -n devops-ai-prod
```

---

## Monitoring continu

### Dashboard Grafana

1. Accéder à Grafana:
```bash
kubectl port-forward -n monitoring svc/prometheus-grafana 3000:80
```

2. Login: admin / (récupérer le password)
```bash
kubectl get secret -n monitoring prometheus-grafana \
  -o jsonpath="{.data.admin-password}" | base64 -d
```

3. Importer le dashboard: `monitoring/grafana/dashboards/devops-ai-dashboard.json`

### Alertes Slack

Configurer AlertManager:
```bash
kubectl edit configmap alertmanager -n monitoring
```

Ajouter:
```yaml
receivers:
  - name: 'slack'
    slack_configs:
      - api_url: 'YOUR_SLACK_WEBHOOK'
        channel: '#devops-alerts'
```

---

## Conclusion

Vous avez maintenant déployé avec succès le DevOps AI Agent avec:
- ✅ Stratégie Blue-Green en production
- ✅ Auto-scaling avec HPA
- ✅ Monitoring avec Prometheus/Grafana
- ✅ GitOps avec ArgoCD
- ✅ Pipeline CI/CD automatisé

**Prochaines étapes:**
1. Configurer les alertes Slack/email
2. Intégrer avec votre Prometheus existant
3. Ajouter des dashboards personnalisés
4. Documenter les runbooks d'incident