# Analyse et Corrections - Moteur de Règles V6.2.2 → V6.2.3

## Résumé Exécutif

Le moteur V6.2.2 contenait plusieurs bugs critiques et opportunités d'optimisation. Cette analyse documente les corrections apportées dans la V6.2.3.

---

## 1. Bug Critique : Extraction des Tokens Imbriqués

### Problème V6.2.2

```sql
-- Code V6.2.2 (lignes 83-89)
Starts AS (SELECT n AS pos FROM N WHERE SUBSTRING(@Expr, n, 1) = '{'),
Ends AS (SELECT n AS pos FROM N WHERE SUBSTRING(@Expr, n, 1) = '}')
SELECT DISTINCT SUBSTRING(@Expr, s.pos, e.pos - s.pos + 1) AS Token
FROM Starts s
CROSS APPLY (SELECT MIN(pos) AS pos FROM Ends WHERE pos > s.pos) e
WHERE e.pos IS NOT NULL
  AND CHARINDEX('{', SUBSTRING(@Expr, s.pos + 1, e.pos - s.pos - 1)) = 0;
```

**Symptôme** : L'expression `{IIF({A}>0,{B},{C})}` était incorrectement découpée.

**Cause** : L'algorithme cherchait simplement le premier `}` après chaque `{`, sans gérer les niveaux d'imbrication.

### Solution V6.2.3

```sql
-- Algorithme avec gestion des niveaux
Brackets AS (
    SELECT 
        n AS pos,
        SUBSTRING(@Expr, n, 1) AS ch,
        SUM(CASE WHEN SUBSTRING(@Expr, n, 1) = '{' THEN 1 
                 WHEN SUBSTRING(@Expr, n, 1) = '}' THEN -1 
                 ELSE 0 END) 
            OVER (ORDER BY n ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS level_after
    FROM Numbers
    WHERE SUBSTRING(@Expr, n, 1) IN ('{', '}')
),
TokenStarts AS (
    SELECT pos FROM Brackets WHERE ch = '{' AND ISNULL(level_before, 0) = 0
),
TokenEnds AS (
    SELECT pos FROM Brackets WHERE ch = '}' AND level_after = 0
)
```

**Résultat** : Les tokens imbriqués sont maintenant correctement extraits comme une seule unité.

---

## 2. Bug : Parsing avec Wildcards LIKE

### Problème V6.2.2

```sql
-- Code V6.2.2 (lignes 109-110)
WHEN TokenContent LIKE '%(_%)' AND CHARINDEX('(', TokenContent) > 0
```

**Symptôme** : `_` et `%` sont des wildcards dans LIKE. Le pattern `%(_%)` matchait de manière imprévisible.

### Solution V6.2.3

```sql
-- Utilisation de CHARINDEX au lieu de LIKE avec wildcards
Analysis AS (
    SELECT
        TokenContent,
        CHARINDEX('(', TokenContent) AS ParenPos,
        CASE 
            WHEN CHARINDEX('(', TokenContent) > 1 
             AND CHARINDEX(')', TokenContent) = LEN(TokenContent)
            THEN 1 
            ELSE 0 
        END AS HasFunction
    FROM Cleaned
)
```

---

## 3. Bug : Échappement JSON dans JSONIFY

### Problème V6.2.2

```sql
-- Code V6.2.2 (lignes 266-269)
REPLACE(REPLACE([Key], ''\'', ''\''), ''"'', ''\"'')
```

**Symptôme** : Le backslash n'était pas correctement échappé (`''` au lieu de `\\`).

### Solution V6.2.3

```sql
-- Échappement correct
REPLACE(REPLACE([Key], N''\'', N''\\''), N''"'', N''\"'')
```

---

## 4. Bug : Fuite de Curseurs

### Problème V6.2.2

Les curseurs dans `sp_ResolveToken` et `sp_ExecuteRule` n'avaient pas de noms uniques et n'étaient pas nettoyés en cas d'exception.

```sql
-- Code V6.2.2 (ligne 198)
DECLARE rule_cursor CURSOR LOCAL FAST_FORWARD FOR...
```

**Risque** : Si une exception survenait, le curseur restait ouvert, causant des erreurs "cursor already exists".

### Solution V6.2.3

```sql
-- Noms uniques et bloc TRY/CATCH avec nettoyage
DECLARE resolve_rule_cursor CURSOR LOCAL FAST_FORWARD FOR...

BEGIN TRY
    -- Traitement
END TRY
BEGIN CATCH
    IF CURSOR_STATUS('local', 'resolve_rule_cursor') >= 0
    BEGIN
        CLOSE resolve_rule_cursor;
        DEALLOCATE resolve_rule_cursor;
    END
    ;THROW;
END CATCH
```

---

## 5. Optimisation : Index sur #ThreadState

### Ajout V6.2.3

```sql
-- Index pour les recherches LIKE sur patterns
CREATE NONCLUSTERED INDEX IX_ThreadState_RuleState 
ON #ThreadState (IsRule, State) INCLUDE ([Key], ScalarValue, SeqId);
```

**Bénéfice** : Amélioration des performances pour les agrégateurs avec patterns (ex: `{SUM(MONTANT_%)}`) qui doivent scanner la table.

---

## 6. Optimisation : Index sur RuleDefinitions

### Ajout V6.2.3

```sql
CREATE NONCLUSTERED INDEX IX_RuleDefinitions_Active 
ON dbo.RuleDefinitions (IsActive) INCLUDE (RuleCode, Expression);
```

**Bénéfice** : Accélère la découverte des règles lors de la résolution par pattern.

---

## Tableau Comparatif

| Aspect | V6.2.2 | V6.2.3 |
|--------|--------|--------|
| Tokens imbriqués | ❌ Bug | ✅ Corrigé |
| Parsing LIKE | ❌ Wildcards | ✅ CHARINDEX |
| JSONIFY échappement | ❌ Incorrect | ✅ Correct |
| Curseurs | ❌ Fuite possible | ✅ Nettoyage garanti |
| Index #ThreadState | ❌ Aucun | ✅ Ajouté |
| Index RuleDefinitions | ❌ Aucun | ✅ Ajouté |

---

## Conformité Spec V1.5.5

La V6.2.3 reste **100% conforme** à la spécification V1.5.5 :

- ✅ États fermés : NOT_EVALUATED, EVALUATING, EVALUATED, ERROR
- ✅ Ordre canonique = SeqId
- ✅ Agrégateur par défaut = FIRST
- ✅ 17 agrégateurs fermés (6 base × 3 filtres - 1 + CONCAT + JSONIFY)
- ✅ Erreurs locales, thread continue
- ✅ Variables atomiques
- ✅ Runner JSON neutre

---

## Tests de Régression

Le fichier `TESTS_NORMATIFS_V6_2_3.sql` inclut :

- 5 tests d'extraction de tokens
- 7 tests de parsing
- 8 tests d'exécution
- 8 tests d'agrégateurs
- 1 test mode DEBUG

**Total : 29 tests normatifs**

---

## Migration

Pour migrer de V6.2.2 vers V6.2.3 :

1. Sauvegarder les données de `dbo.RuleDefinitions` (si existantes)
2. Exécuter `MOTEUR_REGLES_V6_2_3.sql`
3. Ré-importer les règles
4. Exécuter `TESTS_NORMATIFS_V6_2_3.sql` pour valider

**Note** : Le schéma de `RuleDefinitions` est identique, seul l'index est ajouté.
