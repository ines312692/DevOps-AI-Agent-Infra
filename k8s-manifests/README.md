# k8s-manifests

Ce répertoire contient les manifests Kubernetes gérés via Kustomize pour déployer l’agent IA dans différents environnements (dev, staging, prod).

## Structure

- `base/`
  - Manifests de base communs (ex: `namespace.yaml`, `resource-quota.yaml`, `kustomization.yaml`).
- `overlays/`
  - `dev/` : Overlays et patches spécifiques à l’environnement de développement.
    - `patches/deployment-patch.yaml`
    - `patches/service-patch.yaml`
    - `kustomization.yaml`
  - `staging/` : Overlays et patches pour pré‑production.
    - `patches/deployment-patch.yaml`
    - `patches/hpa-patch.yaml`
    - `kustomization.yaml`
  - `prod/` : Overlays pour production.
    - `blue-green/` : Manifests dédiés au déploiement blue‑green (ex: `deployment-blue.yaml`, `deployment-green.yaml`).
    - `kustomization.yaml`

Ressources connexes dans le dépôt :
- Argo CD : `argocd/applications/*.yaml`, `argocd/projects/devops-ai-project.yaml`
- CI/CD GitHub Actions : `github/workflows/deploy-prod.yaml`
- Scripts d’aide : `scripts/blue-green-switch.sh`, `scripts/canary-promote.sh`

## Prérequis

- kubectl ≥ 1.24
- kustomize (intégré à kubectl ≥ 1.14 via `kubectl apply -k`)
- Accès à un cluster Kubernetes et au contexte kubeconfig correct

## Utilisation rapide (kubectl + kustomize)

Appliquer la base seule (rarement nécessaire directement) :

```bash
kubectl apply -k k8s-manifests/base
```

Appliquer un overlay d’environnement :

- Dev :
```bash
kubectl apply -k k8s-manifests/overlays/dev
```
- Staging :
```bash
kubectl apply -k k8s-manifests/overlays/staging
```
- Prod (défaut) :
```bash
kubectl apply -k k8s-manifests/overlays/prod
```

Astuce Windows PowerShell (chemins relatifs depuis la racine du repo) :

```powershell
kubectl apply -k .\k8s-manifests\overlays\dev
```

## Déploiement blue‑green (prod)

Le répertoire `overlays/prod/blue-green/` contient deux Deployments distincts :
- `deployment-blue.yaml`
- `deployment-green.yaml`

Le Service de prod pointe sur l’un des deux (via labels/selector). Le flux typique :
1. Déployer la nouvelle version sur l’environnement « idle » (par ex. green) ;
2. Vérifier la santé (readiness, logs, metrics) ;
3. Basculer le trafic en mettant à jour le selector du Service pour cibler la couleur mise à jour ;
4. Surveiller, puis supprimer/mettre à jour l’ancienne couleur si OK.

Un script d’exemple est fourni : `scripts/blue-green-switch.sh` (Linux/macOS). Adaptez les commandes pour PowerShell si besoin.

## Intégration Argo CD

Des Applications Argo CD sont fournies :
- Dev : `argocd/applications/dev-application.yaml`
- Staging : `argocd/applications/staging-application.yaml`
- Prod : `argocd/applications/prod-application.yaml`

Avec le Projet : `argocd/projects/devops-ai-project.yaml`.

Vous pouvez pointer Argo CD vers ce dépôt et ces chemins Kustomize pour synchroniser automatiquement les environnements.

## Intégration CI/CD (GitHub Actions)

Le workflow `github/workflows/deploy-prod.yaml` illustre un déploiement en production. Assurez‑vous de configurer les secrets/permissions nécessaires (accès au cluster, etc.).

## Nettoyage

Pour supprimer les ressources d’un overlay :
```bash
kubectl delete -k k8s-manifests/overlays/dev
```
Adaptez le chemin (`staging`, `prod`) selon le besoin.

## Dépannage

- Vérifiez le Namespace : `kubectl get ns` (le fichier `base/namespace.yaml` doit le créer).
- Inspectez les Kustomization : `kustomize build k8s-manifests/overlays/dev` pour voir le rendu.
- Labels/Selectors incohérents : si le Service ne route pas, comparez `spec.selector` du Service avec les labels de Pods.
- HPA en staging : vérifier le metrics-server et les ressources requests/limits.

## Conventions

- Préférer Kustomize pour l’assemblage par environnement.
- Garder les patches minimalistes et spécifiques à l’overlay.
- Documenter tout changement de schéma (labels, annotations) impactant Services/HPA/Argo CD.
