# ADR-0005: Gestion des erreurs non-bloquante

## Statut
Accepté

## Date
2025-12-18

## Contexte

Lors de l'évaluation des règles, diverses erreurs peuvent survenir :
- Erreurs SQL (division par zéro, conversion impossible, syntaxe invalide)
- Tokens non résolus (pattern ne matche aucune clé)
- Dépendances circulaires
- Timeouts d'exécution

Deux approches principales étaient possibles :

1. **Approche bloquante** : Toute erreur stoppe immédiatement l'exécution du thread
2. **Approche non-bloquante** : Les erreurs sont enregistrées mais le thread continue

L'approche bloquante présente des risques majeurs :
- **Fragilité** : Une règle défectueuse bloque tout le thread
- **Effet domino** : Impossibilité d'évaluer les règles indépendantes
- **Debugging difficile** : Pas de visibilité sur l'état global
- **Robustesse faible** : Système sensible aux erreurs isolées

## Décision

**Les erreurs ne stoppent JAMAIS le thread d'exécution.**

### Principe Fondamental

> **« Une erreur isole la règle défectueuse sans affecter les règles indépendantes. »**

### États de Règle

| État | Code | Description |
|------|------|-------------|
| **NOT_EVALUATED** | 0 | Règle non encore évaluée |
| **EVALUATING** | 1 | Évaluation en cours |
| **EVALUATED** | 2 | Évaluation terminée avec succès |
| **ERROR** | 9 | Erreur lors de l'évaluation |

### Comportement en Cas d'Erreur

Quand une règle rencontre une erreur :

1. **État** : Passe à `ERROR` (9)
2. **Valeur** : `ScalarValue = NULL`
3. **Catégorie** : `ErrorCategory` renseigné (ex: "SQL_ERROR")
4. **Code** : `ErrorCode` renseigné (ex: "DIVIDE_BY_ZERO")
5. **Propagation** : Les règles dépendantes échouent également
6. **Thread** : Continue à évaluer les règles indépendantes

### Propagation des Erreurs

```sql
-- Exemple de propagation
R1 = 10 / 0              -- ERREUR (division par zéro)
R2 = {R1} + 5            -- ERREUR (dépend de R1)
R3 = 20 + 30             -- ✅ OK (indépendante)
R4 = {R2} * 2            -- ERREUR (dépend de R2)
R5 = {R3} * 2            -- ✅ OK (dépend de R3 qui est OK)

-- Résultat final :
-- R1: NULL (ERROR)
-- R2: NULL (ERROR)
-- R3: 50 (EVALUATED)
-- R4: NULL (ERROR)
-- R5: 100 (EVALUATED)
```

**Note** : Les règles R3 et R5 sont évaluées avec succès malgré les erreurs sur R1, R2, R4.

## Conséquences

### Positives

- **Robustesse** : Le système continue malgré des erreurs isolées
- **Visibilité** : Toutes les erreurs sont enregistrées et consultables
- **Debugging** : État complet disponible pour diagnostic
- **Résilience** : Règles indépendantes non affectées par erreurs ailleurs
- **Auditabilité** : Trace complète des succès et échecs
- **Flexibilité** : Permet des règles optionnelles (erreur acceptable)

### Négatives

- **Complexité** : Code de gestion des erreurs plus élaboré
- **Validation différée** : Erreurs découvertes à l'exécution, pas avant
- **Dépendances** : Nécessite graphe de dépendances correct
- **Confusion possible** : Utilisateur peut ne pas voir qu'une règle a échoué

### Mitigation des Négativités

1. **Complexité** : Encapsulée dans le moteur, transparente pour l'utilisateur
2. **Validation** : Mode DEBUG offre visibilité complète
3. **Dépendances** : Détection automatique des cycles
4. **Confusion** : Documentation claire + mode STRICT optionnel

## Implémentation

### Capture d'Erreur

```sql
BEGIN TRY
    -- Tentative d'exécution de la règle
    EXEC sp_executesql @FinalExpression, N'@Result NVARCHAR(MAX) OUTPUT', @Result OUTPUT
    
    -- Succès
    UPDATE #ThreadState 
    SET State = 2,              -- EVALUATED
        ScalarValue = @Result,
        ValueIsNumeric = dbo.fn_IsNumeric(@Result)
    WHERE [Key] = @RuleKey
    
END TRY
BEGIN CATCH
    -- Erreur capturée
    UPDATE #ThreadState
    SET State = 9,              -- ERROR
        ScalarValue = NULL,
        ErrorCategory = ERROR_PROCEDURE(),
        ErrorCode = ERROR_MESSAGE()
    WHERE [Key] = @RuleKey
    
    -- ⚠️ PAS DE THROW : Thread continue
END CATCH
```

### Détection de Dépendance Échouée

```sql
-- Avant évaluation, vérifier que les dépendances sont OK
IF EXISTS (
    SELECT 1 
    FROM #ThreadState t
    INNER JOIN #RuleDependencies d ON d.DependsOn = t.[Key]
    WHERE d.RuleKey = @CurrentRule
      AND t.State = 9  -- Dépendance en erreur
)
BEGIN
    -- Marquer comme erreur sans essayer d'évaluer
    UPDATE #ThreadState
    SET State = 9,
        ScalarValue = NULL,
        ErrorCategory = 'DEPENDENCY_ERROR',
        ErrorCode = 'DEPENDENCY_FAILED'
    WHERE [Key] = @CurrentRule
    
    CONTINUE  -- Passer à la règle suivante
END
```

### Mode DEBUG

Mode spécial offrant visibilité complète :

```json
{
  "mode": "DEBUG",
  "options": {
    "returnStateTable": true,
    "returnDebug": true
  },
  "variables": [...],
  "rules": [...]
}
```

**Output** :
```json
{
  "status": "PARTIAL_SUCCESS",
  "evaluatedRules": 3,
  "errorRules": 2,
  "stateTable": [
    {"key": "R1", "state": "ERROR", "value": null, "error": "Division by zero"},
    {"key": "R2", "state": "ERROR", "value": null, "error": "Dependency failed"},
    {"key": "R3", "state": "EVALUATED", "value": "50"},
    {"key": "R4", "state": "ERROR", "value": null, "error": "Dependency failed"},
    {"key": "R5", "state": "EVALUATED", "value": "100"}
  ],
  "debugLog": [...]
}
```

## Catégories d'Erreur

| Catégorie | Description | Exemple |
|-----------|-------------|---------|
| **SQL_ERROR** | Erreur SQL Server | Division par zéro, conversion impossible |
| **TOKEN_ERROR** | Token non résolu | Pattern ne matche aucune clé |
| **DEPENDENCY_ERROR** | Dépendance échouée | Règle dépend d'une règle en erreur |
| **CYCLE_ERROR** | Dépendance circulaire | R1 dépend de R2 qui dépend de R1 |
| **TIMEOUT_ERROR** | Délai dépassé | Règle prend trop de temps |
| **SYNTAX_ERROR** | Expression invalide | SQL malformé |

### Codes d'Erreur Typiques

```sql
-- SQL_ERROR
'DIVIDE_BY_ZERO'          -- Division par zéro
'INVALID_CAST'            -- Conversion impossible
'ARITHMETIC_OVERFLOW'     -- Dépassement arithmétique
'STRING_TRUNCATION'       -- Chaîne trop longue

-- TOKEN_ERROR
'TOKEN_NOT_FOUND'         -- Pattern ne matche rien
'AMBIGUOUS_TOKEN'         -- Pattern ambigu
'CIRCULAR_REFERENCE'      -- Référence circulaire

-- DEPENDENCY_ERROR
'DEPENDENCY_FAILED'       -- Dépendance en erreur
'MISSING_DEPENDENCY'      -- Dépendance inexistante
```

## Mode STRICT (Optionnel)

Mode alternatif stoppant sur première erreur :

```json
{
  "mode": "STRICT",
  "variables": [...],
  "rules": [...]
}
```

**Comportement** :
- Première erreur rencontrée → THROW immédiat
- Thread stoppé
- Aucune règle suivante évaluée

**Usage** : Validation stricte lors du développement.

## Alternatives Considérées

### 1. Approche Bloquante Stricte

**Description** : Toute erreur stoppe immédiatement le thread.

**Rejet** :
- Fragilité excessive du système
- Impossibilité d'obtenir résultats partiels
- Debugging très difficile
- Une règle cassée bloque tout

### 2. Exceptions avec Catch Global

**Description** : Exceptions levées mais catchées au niveau thread.

**Rejet** :
- Pas de différence pratique avec approche bloquante
- Thread stoppé de toute façon
- Pas de bénéfice clair

### 3. Valeur par Défaut sur Erreur

**Description** : En cas d'erreur, retourner valeur par défaut (ex: 0, "").

**Rejet** :
- Masque les erreurs (silencieusement)
- Résultats incorrects propagés
- Debugging impossible
- Violation du principe de transparence

### 4. Flag `continueOnError`

**Description** : Paramètre contrôlant le comportement.

**Implémentation partielle** :
- Mode par défaut : Non-bloquant
- Mode STRICT : Bloquant (opt-in)
- Meilleur compromis entre robustesse et strictitude

### 5. Retry Automatique

**Description** : Réessayer automatiquement en cas d'erreur.

**Rejet** :
- Erreurs déterministes ne se résolvent pas
- Risque de boucle infinie
- Complexité inutile
- Timeout difficile à gérer

## Gestion des Cycles

Détection précoce des dépendances circulaires :

```sql
-- Algorithme de détection (avant évaluation)
WITH RecursiveDeps AS (
    SELECT RuleKey, DependsOn, 1 AS Level
    FROM #RuleDependencies
    
    UNION ALL
    
    SELECT r.RuleKey, d.DependsOn, Level + 1
    FROM RecursiveDeps r
    INNER JOIN #RuleDependencies d ON r.DependsOn = d.RuleKey
    WHERE Level < 100  -- Limite profondeur
)
SELECT RuleKey
FROM RecursiveDeps
WHERE RuleKey = DependsOn  -- Cycle détecté !
```

**Action** : Règles cycliques marquées ERROR avant évaluation.

## Références

- Spécification v1.7.1, Section 7 "Gestion des Erreurs"
- ADR-0001 "Principe de délégation SQL Server"
- Code source : `src/MOTEUR_REGLES.sql`, gestion TRY/CATCH

## Notes

La gestion des erreurs non-bloquante est cruciale pour la robustesse du moteur en production.

Elle permet :
- **Résilience** : Le système continue malgré des règles défectueuses
- **Observabilité** : Vue complète de l'état pour diagnostic
- **Flexibilité** : Règles optionnelles ou expérimentales possibles

Le mode STRICT reste disponible pour les cas nécessitant validation stricte (développement, tests).

La propagation des erreurs via dépendances garantit que les résultats incorrects ne sont jamais utilisés, tout en permettant l'évaluation des règles indépendantes.
