# Rules Engine – IA-First Contract (v1.5.4)
## Règles impératives pour tout assistant IA

Ce document est **NORMATIF**. Respect strict requis.

### 1) Interdictions (ne jamais faire)
- Ne pas inventer de grammaire ou d’agrégateur.
- Ne pas évaluer SQL dans `{...}` (aucune logique dans tokens).
- Ne pas changer l’ordre: l’ordre canonique est **SeqId (ordre d’insertion)**.
- Ne pas stopper le thread en cas d’erreur: **erreur locale à la règle**.
- Ne pas imposer un schéma physique unique: seuls les invariants sont contractuels.

### 2) Obligations (toujours faire)
- États de règle fermés: NOT_EVALUATED, EVALUATING, EVALUATED, ERROR.
- Référence à une règle EVALUATING ⇒ passer en ERROR, retourner NULL.
- Toute erreur (SQL, numeric, type, etc.) ⇒ ERROR + (ErrorCategory, ErrorCode) + NULL, thread continue.
- Mode NORMAL: pas de debug; mode DEBUG: instrumentation explicite uniquement.
- Comparaison des clés case-insensitive via collation SQL (ex: SQL_Latin1_General_CP1_CI_AS).

### 3) Conformité
Une proposition d’implémentation est conforme si et seulement si:
- elle respecte la sémantique verrouillée,
- elle passe tous les tests normatifs définis dans le document de référence.

Si une information n’est pas spécifiée: considérer que c’est **interdit** ou **à expliciter** dans une nouvelle version.
