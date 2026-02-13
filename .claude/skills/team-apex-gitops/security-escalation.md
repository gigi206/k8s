# Protocole d'escalade securite QA

## Changements CRITIQUES -> lancer 5 sous-agents en PARALLELE

Domaines declencheurs (si AU MOINS UN fichier touche ces domaines) :
- NetworkPolicy / CiliumNetworkPolicy / CiliumClusterwideNetworkPolicy / CalicoNetworkPolicy
- RBAC (ClusterRole, ClusterRoleBinding, Role, RoleBinding, ServiceAccount)
- Secrets (SOPS, ExternalSecret, ClusterSecretStore, credentials)
- TLS / certificats / ClusterIssuer / Certificate
- SecurityContext / PodSecurityStandard / PodSecurity labels
- Kyverno policies (ClusterPolicy, Policy)
- OAuth2 / OIDC / AuthorizationPolicy
- NeuVector (NvSecurityRule, NvClusterSecurityRule)

Action : lancer ces 5 sous-agents EN PARALLELE via le Task tool :
1. subagent_type="apex:review:phase1:review-security-analyst" -> vulnerabilites
2. subagent_type="apex:review:phase1:review-architecture-analyst" -> integrite architecturale
3. subagent_type="apex:review:phase1:review-code-quality-analyst" -> lisibilite, maintenabilite
4. subagent_type="apex:risk-analyst" -> risques et edge cases
5. subagent_type="apex:failure-predictor" -> prediction de defaillances

Attendre les 5 resultats, puis lancer le challenger :
6. subagent_type="apex:review:phase2:review-challenger" -> valide/invalide les findings,
   verifie l'historique, evalue le ROI, peut override les scores

Bloquer si un probleme critique survit au challenger.

## Changements STANDARDS -> lancer 2 sous-agents en PARALLELE

Domaines : Helm values, config dev/prod, HTTPRoute, monitoring, dashboards, resources basiques.
Action : appliquer la checklist securite (section 3) + lancer en parallele :
1. subagent_type="apex:review:phase1:review-architecture-analyst" -> coherence des patterns
2. subagent_type="apex:review:phase1:review-code-quality-analyst" -> qualite du code YAML

## Gestion des echecs de sub-agents

Si un sub-agent echoue ou retourne un resultat vide :
- NE PAS bloquer la review pour autant
- Compenser en faisant la verification manuellement pour le domaine du sub-agent defaillant
- Mentionner l'echec dans le rapport de review
