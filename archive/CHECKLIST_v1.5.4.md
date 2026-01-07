# Implementation Conformance Checklist – v1.5.4
## (Audit technique avant merge / release)

### A. Sémantique (bloquants)
- [ ] Le moteur n’évalue pas de logique SQL dans `{...}`.
- [ ] Une seule agrégation par token; agrégateur par défaut = FIRST.
- [ ] États EXACTS: NOT_EVALUATED, EVALUATING, EVALUATED, ERROR.
- [ ] Récursivité: référence à EVALUATING ⇒ règle en ERROR, valeur NULL, thread continue.
- [ ] Erreurs (toutes): TRY/CATCH autour de l’exécution SQL ⇒ ERROR + NULL, thread continue.
- [ ] ErrorCategory ∈ {RECURSION, NUMERIC, STRING, TYPE, SQL, SYNTAX, UNKNOWN}.
- [ ] Ordre canonique: dépend de SeqId (ordre d’insertion), jamais de Key.

### B. Collation / unicité (bloquants)
- [ ] Colonne Key en collation CI (ex: SQL_Latin1_General_CP1_CI_AS).
- [ ] Tables temporaires: collation Key explicitée (tempdb-proof).
- [ ] Unicité des clés garantie (CI) par contrainte/index unique.

### C. Agrégateurs (bloquants)
- [ ] SUM/AVG/MIN/MAX ignorent NULL; COUNT ignore NULL; FIRST peut renvoyer NULL.
- [ ] *_POS filtre >0; *_NEG filtre <0; filtrage AVANT agrégation.
- [ ] CONCAT ignore NULL, respecte ordre SeqId, séparateur ','.
- [ ] JSONIFY: clé→valeur, erreurs => null, ensemble vide => {}.

### D. Lazy & cache (bloquants)
- [ ] Une règle est évaluée au plus une fois par thread (cache).
- [ ] Une règle en ERROR ne se réévalue pas et retourne NULL.

### E. Performance (bloquants)
- [ ] Mode NORMAL: aucune instrumentation (durées, SQL compilé, traces) ni écritures debug.
- [ ] Mode DEBUG: instrumentation seulement si activée explicitement.
- [ ] Aucune boucle O(N²) évitable sur grands ensembles (tokens, dépendances).

### F. Tests (bloquants)
- [ ] La suite de tests normative passe (Parsing, Collation, Ordre, Agrégateurs, Lazy, Erreurs, Performance).
- [ ] Tests d’ordre: fixtures contrôlent l’ordre d’insertion.
- [ ] Tests d’erreur: vérifient State=ERROR et ErrorCategory/ErrorCode.
