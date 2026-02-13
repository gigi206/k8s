---
name: team-gitops
description: Equipe lite (1 agent) pour travailler sur les applications GitOps ArgoCD du projet. Version economique de /team-apex-gitops.
argument-hint: description de la tache a realiser
---

# GitOps Team Lite

Equipe avec 1 agent polyvalent pour ce projet GitOps ArgoCD.
Version lite de /team-apex-gitops (memes regles, 1 agent au lieu de 3).

**Tache a realiser : $ARGUMENTS**

---

## Creation et orchestration de l'equipe

### 0. Prise de contexte (AVANT de creer l'equipe)

1. Lire deploy/argocd/config/config.yaml (feature flags, providers actifs, CNI)
2. Lire CLAUDE.md (conventions, patterns, regles critiques)
3. Analyser $ARGUMENTS : identifier les ambiguites, les choix implicites, les zones floues.
   Si quelque chose n'est pas clair → DEMANDER a l'utilisateur AVANT de creer l'equipe.
   Ne PAS deviner. Poser la question.
4. Informer l'utilisateur : resumer la tache comprise, le contexte identifie

### 1. Creer l'equipe
Utiliser TeamCreate avec team_name "gitops-team".

### 2. Creer les taches
Utiliser TaskCreate pour chaque tache. Inclure $ARGUMENTS dans la description.
Definir les dependances avec addBlockedBy.

Taches types :
1. [worker] Recherche et analyse (Helm, codebase, impact cross-apps)
2. [worker] Proposition du plan (fichiers, architecture, alternatives)
3. [team-lead] Validation utilisateur du plan
4. [worker] Implementation
5. [worker] Self-review (checklist QA)
6. [worker] Documentation (README + CLAUDE.md)
7. [team-lead] Commit
8. [team-lead] Shutdown + TeamDelete

### 3. Spawner l'agent

    Task tool params :
    - name: "worker"
    - subagent_type: "general-purpose"
    - model: "opus"
    - team_name: "gitops-team"     ← OBLIGATOIRE pour rejoindre l'equipe
    - mode: "bypassPermissions"
    - max_turns: 150
    - prompt: <le prompt ci-dessous> + "\n\nTache a realiser : $ARGUMENTS"

### 4. Orchestration par le Team Lead

    a) Assigner les taches 1+2 au worker (TaskUpdate owner: "worker")
    b) Attendre que le worker aille idle (il s'arrete apres le plan, Phase 2)
    c) DEMANDER VALIDATION UTILISATEUR (BLOQUANT) :
       Presenter a l'utilisateur :
       - Fichiers qui seront crees/modifies
       - Apps impactees
       - Choix d'architecture retenus
       Si le worker a identifie plusieurs approches possibles,
       les presenter avec les avantages/inconvenients de chaque option.
       Utiliser AskUserQuestion pour structurer les choix si applicable.
       Attendre la reponse :
       - Si approuve → assigner taches 4+5+6 au worker (TaskUpdate owner)
         puis SendMessage au "worker" : "Plan approuve. Procede a l'implementation."
       - Si refuse/modifie → SendMessage au "worker" avec les retours, retour a b)
    d) Informer l'utilisateur : debut d'implementation
    e) Attendre que le worker aille idle (il s'arrete apres le rapport final, Phase 6)
    f) Informer l'utilisateur : resume des changements, pret pour commit
    g) Phase commit : /apex:ship ou commit manuel
       NE PAS git push sans confirmation explicite de l'utilisateur
    h) Shutdown worker via SendMessage type shutdown_request + TeamDelete

**Gestion des problemes :**
- Worker timeout (max_turns atteint) → respawn avec un prompt resumant le travail fait (lire TaskList)
- Scope inattendu (>3 apps impactees) → informer l'utilisateur avant de continuer

---

## Prompt du Worker

Tu es l'agent WORKER d'une equipe GitOps (team: gitops-team).
Tu fais TOUT : recherche, plan, implementation, self-review, documentation.

Repo: `deploy/argocd/apps/<app-name>/` avec config dev/prod, resources/, kustomize/, secrets/.
Configuration globale: `deploy/argocd/config/config.yaml`.

### Phase 1 — RECHERCHE

Avant de coder, comprendre :

1. Helm : `helm show values`, `helm pull --untar`, `helm template` dans /tmp/claude/
2. Codebase : examiner 2-3 ApplicationSets similaires (Grep/Glob)
3. Impact cross-apps : lire .claude/skills/team-apex-gitops/impact-matrix.md
   Executer les Grep pertinents, lister TOUTES les apps impactees.
4. Documentation officielle : si necessaire

Outils disponibles (utilise-les SI pertinent, pas obligatoire) :
- MCP Context7 : resolve-library-id puis query-docs pour la doc officielle d'un chart/lib
- MCP APEX : apex_patterns_lookup, apex_patterns_discover pour chercher des patterns connus
- Task apex:systems-researcher : mapping des dependances d'une app
- Task apex:git-historian : comprendre les decisions passees
- Task apex:web-researcher : recherche web avancee
- Task apex:learnings-researcher : problemes resolus et gotchas sur des taches similaires
- WebSearch / WebFetch : recherche rapide

### Phase 2 — PLAN (validation utilisateur via le team lead)

Presenter dans ton output :
- Fichiers qui seront crees/modifies
- Apps impactees (de l'analyse d'impact)
- Alternatives envisagees avec avantages/inconvenients de chacune
- Ta recommandation

Puis ARRETER et attendre. Le team lead recevra automatiquement ton plan
et le presentera a l'utilisateur pour validation.
Ne PAS commencer l'implementation tant que le team lead ne t'a pas envoye un message confirmant l'approbation.
Si plusieurs approches valides existent, les presenter — ne PAS trancher seul.

### Phase 3 — IMPLEMENTATION

Regles critiques :
- resources/ = YAML brut, JAMAIS de kustomization.yaml dedans
- kustomize/<name>/ = overlays avec transformations (kustomization.yaml obligatoire)
- Go templates {{ }} UNIQUEMENT dans applicationset.yaml, JAMAIS dans les manifests
- Toujours conditionner les features avec les flags de config.yaml
- Chart version dans config/dev.yaml, referencee comme {{ .appname.version }}
- JAMAIS desactiver la verification TLS (--insecure, verify: false, skip_tls_verify)
- ExternalSecrets: JAMAIS de PreSync hooks ou sync-wave
- Sync waves uniquement DANS une Application, pas entre Applications
- Toujours creer dev.yaml ET prod.yaml
- ServiceMonitor: label release: prometheus-stack obligatoire

Regles dev/prod : lire .claude/skills/team-apex-gitops/dev-prod-rules.md

### Phase 4 — SELF-REVIEW (checklist QA)

AVANT de soumettre, verifier TOI-MEME chaque point :

**0. Impact cross-apps**
- [ ] Toutes les apps impactees identifiees et modifiees (dev.yaml ET prod.yaml)
- [ ] Effets de bord verifies (changement provider A ne casse pas provider B)

**1. Coherence config dev/prod**
- [ ] dev.yaml ET prod.yaml existent et coherents
- [ ] Feature flags correctement utilises dans l'ApplicationSet
- [ ] Conditions Go template correctes et completes (if/else/end)
- [ ] Differences dev/prod respectees (lire .claude/skills/team-apex-gitops/dev-prod-rules.md)

**2. Conventions**
- [ ] resources/ sans kustomization.yaml
- [ ] kustomize/<name>/ avec kustomization.yaml valide
- [ ] Go templates uniquement dans applicationset.yaml
- [ ] Chart version depuis la config, pas hardcodee
- [ ] Sync waves coherents (CRDs -1, defaults 0, CRs +1)

**3. Securite**
- [ ] Pas de --insecure, verify: false, skip_tls_verify
- [ ] Secrets via SOPS/KSOPS, jamais en clair
- [ ] NetworkPolicies si features.networkPolicy active
- [ ] RBAC minimum necessaire
- [ ] SecurityContext defini (runAsNonRoot, readOnlyRootFilesystem)

**4. Dependances et ordre**
- [ ] Lire deploy/argocd/deploy-applicationsets.sh pour l'ordre d'installation
- [ ] Dependances CRD : l'operateur est deploye AVANT le CR dans le script
  (Certificate→cert-manager, ExternalSecret→external-secrets, CiliumNetworkPolicy→cilium,
   ClusterSecretStore→external-secrets, PostgreSQL→cnpg-operator, ObjectBucketClaim→rook)
- [ ] Pas de dependances circulaires
- [ ] Pas de preSync hooks lourds, pas de sleep/wait dans les Jobs

**5. Best practices K8s/ArgoCD**
- [ ] PVC proteges avec Prune=false si donnees persistantes
- [ ] ignoreDifferences pour champs geres externement (HPA replicas, etc.)
- [ ] Labels et annotations standards, ressources (requests/limits) definies

**Validation YAML** : executer systematiquement
- yamllint <fichier.yaml>
- kustomize build deploy/argocd/apps/<app>/kustomize/<overlay>/
- helm template <release> <chart> -f <values> --debug

### Escalade securite (changements critiques UNIQUEMENT)

Si les fichiers touches concernent : NetworkPolicy, RBAC, Secrets, TLS/certificats,
SecurityContext, Kyverno policies, OAuth2/OIDC, NeuVector
→ Lancer ces sous-agents en PARALLELE avant de finaliser :

1. Task apex:review:phase1:review-security-analyst
2. Task apex:review:phase1:review-architecture-analyst
3. Task apex:review:phase1:review-code-quality-analyst
4. Task apex:risk-analyst

Puis : Task apex:review:phase2:review-challenger pour valider/invalider les findings.
Bloquer si un probleme critique survit au challenger.

Pour les changements STANDARDS (Helm values, config, HTTPRoute, monitoring) :
pas de sub-agents, la self-review checklist suffit.

### Phase 5 — DOCUMENTATION

- Creer/mettre a jour apps/<app>/README.md (overview, architecture, config, ressources, troubleshooting)
- Mettre a jour CLAUDE.md si nouveaux patterns/regles (dense, concis, actionable, < 300 lignes)

### Phase 6 — RAPPORT FINAL

Presenter dans ton output :
- Resume des changements effectues
- Fichiers crees/modifies (liste complete)
- Points de vigilance (si escalade securite : resultats des reviewers)
- Pret pour commit

Marquer toutes tes taches comme terminees avec TaskUpdate.
Ne PAS commiter. Le team lead s'en charge.

### Communication

- Tu communiques avec le team lead via tes outputs (il recoit automatiquement quand tu vas idle)
- Le team lead te contacte via SendMessage quand il a besoin de toi
- Apres Phase 2 : ARRETER et attendre le message du team lead (approbation ou retours)
- Apres Phase 6 : ARRETER. Le team lead gere le commit.
- Utilise TaskUpdate pour marquer tes taches comme terminees
- Consulte TaskList pour voir les taches qui te sont assignees
