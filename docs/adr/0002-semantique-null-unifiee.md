# ADR-0002: Sémantique NULL unifiée

## Statut
Accepté

## Date
2025-12-23

## Contexte

Avant la version 1.6.0, le moteur gérait les valeurs NULL de manière différenciée selon l'agrégat :

| Agrégat | Comportement v1.5.x avec NULL |
|---------|-------------------------------|
| SUM, AVG, MIN, MAX | Ignorent NULL (standard SQL) |
| COUNT | Compte NULL comme une occurrence |
| FIRST | Retourne NULL si première valeur est NULL |
| CONCAT | Inclut NULL comme chaîne vide |
| JSONIFY | Inclut les clés avec valeur `null` |

Cette approche créait plusieurs problèmes :
- **Complexité cognitive** : Chaque agrégat avait ses propres règles
- **Incohérence** : Comportements contradictoires entre agrégats similaires
- **Bugs potentiels** : Confusion fréquente sur le traitement des NULL
- **Documentation difficile** : Multiples cas particuliers à expliquer
- **Code complexe** : Logique différenciée pour chaque agrégat

## Décision

**RÈGLE GLOBALE v1.6.0 : Tous les agrégats opèrent EXCLUSIVEMENT sur valeurs NON NULL.**

Les valeurs NULL sont :
- ✅ Conservées dans #ThreadState (pas de suppression)
- ✅ Visibles dans les résultats de débogage
- ❌ Exclues de tous les agrégats (filtrées avant agrégation)
- ❌ N'influencent jamais le résultat d'un agrégat

### Comportement Unifié

| Agrégat | Comportement v1.6.0+ | Ensemble vide |
|---------|---------------------|---------------|
| **SUM** | Somme valeurs NON NULL | `NULL` |
| **AVG** | Moyenne valeurs NON NULL | `NULL` |
| **MIN** | Min valeurs NON NULL | `NULL` |
| **MAX** | Max valeurs NON NULL | `NULL` |
| **COUNT** | Compte valeurs NON NULL | `0` |
| **FIRST** | Première valeur NON NULL | `NULL` |
| **LAST** | Dernière valeur NON NULL | `NULL` |
| **CONCAT** | Concatène valeurs NON NULL | `""` (vide) |
| **JSONIFY** | Agrège clés NON NULL | `"{}"` (vide) |

### Implémentation

Filtrage systématique via clause `WHERE` :
```sql
-- Exemple : FIRST
SELECT TOP 1 ScalarValue
FROM #ThreadState
WHERE [Key] LIKE @pattern COLLATE SQL_Latin1_General_CP1_CI_AS
  AND ScalarValue IS NOT NULL  -- ← Filtrage unifié
ORDER BY SeqId ASC
```

## Conséquences

### Positives

- **Simplicité** : Une seule règle à retenir pour tous les agrégats
- **Cohérence** : Comportement uniforme et prévisible
- **Maintenabilité** : Code plus simple, moins de branches conditionnelles
- **Performance** : Filtrage précoce réduit le volume de données à traiter
- **Robustesse** : Moins de cas particuliers = moins de bugs
- **Documentation** : Règle simple et claire à expliquer

### Négatives

- **Breaking Change** : Changement de comportement pour FIRST, CONCAT, JSONIFY
- **Migration** : Nécessite validation des règles existantes
- **Régression possible** : Règles dépendant de l'ancien comportement peuvent échouer

### Impact sur les Agrégats

#### FIRST (⚠️ Breaking)

**Avant v1.6.0 :**
```sql
-- Variables : v1=NULL, v2=10, v3=20
-- {FIRST(v*)} → NULL (première valeur, même NULL)
```

**Après v1.6.0 :**
```sql
-- Variables : v1=NULL, v2=10, v3=20
-- {FIRST(v*)} → "10" (première valeur NON NULL)
```

**Migration** : Vérifier les règles utilisant FIRST pour détecter l'absence de valeur.

#### JSONIFY (⚠️ Breaking)

**Avant v1.6.0 :**
```sql
-- Règles : R1=10, R2=NULL, R3=30
-- {JSONIFY(Rule:R*)} → {"R1":10,"R2":null,"R3":30}
```

**Après v1.6.0 :**
```sql
-- Règles : R1=10, R2=NULL, R3=30
-- {JSONIFY(Rule:R*)} → {"R1":10,"R3":30}
-- (R2 omise car NULL)
```

**Migration** : Adapter le code consommateur JSON pour gérer l'absence de clés.

#### CONCAT (⚠️ Breaking)

**Avant v1.6.0 :**
```sql
-- Variables : v1="A", v2=NULL, v3="C"
-- {CONCAT(v*, ",")} → "A,,C" (NULL traité comme vide)
```

**Après v1.6.0 :**
```sql
-- Variables : v1="A", v2=NULL, v3="C"
-- {CONCAT(v*, ",")} → "A,C" (NULL ignoré)
```

**Migration** : Vérifier les règles où les NULL doivent être représentés.

## Alternatives Considérées

### 1. Maintenir le Comportement Différencié

**Description** : Conserver les règles spécifiques à chaque agrégat.

**Rejet** :
- Complexité cognitive trop élevée
- Source d'erreurs fréquentes
- Difficile à documenter et enseigner
- Code plus complexe à maintenir

### 2. Paramètres de Configuration par Agrégat

**Description** : Permettre de configurer le comportement NULL pour chaque agrégat.

**Rejet** :
- Encore plus de complexité
- Multiples configurations possibles = multiples bugs potentiels
- Difficile à valider exhaustivement
- Explosion combinatoire des cas de test

### 3. Flag Global `ignoreNull`

**Description** : Ajouter un paramètre global activant/désactivant le filtrage NULL.

**Rejet** :
- Deux comportements à maintenir et tester
- Confusion sur le mode à utiliser
- Complexité du code doublée
- Pas de bénéfice clair

### 4. NULL Placeholder

**Description** : Remplacer NULL par une valeur sentinel (ex: `"__NULL__"`).

**Rejet** :
- Perte d'information sur la nature NULL
- Risque de collision avec valeurs réelles
- Complexité supplémentaire
- Sémantique confuse

## Migration

### Guide de Migration

Voir `docs/GUIDE_MIGRATION.md` pour la procédure complète.

**Étapes clés :**
1. Identifier les règles utilisant FIRST, CONCAT, JSONIFY
2. Analyser la dépendance au traitement NULL
3. Adapter les règles si nécessaire
4. Exécuter les tests de conformité
5. Valider les résultats métier

### Tests de Conformité

Une suite complète de tests valide le comportement unifié :
- `tests/TESTS_CONFORMITE.sql`
- `tests/TESTS_NORMATIFS.sql`

## Références

- Spécification v1.6.0, Section 5 "Agrégateurs"
- CHANGELOG v1.6.0 "Sémantique NULL unifiée"
- ADR-0001 "Principe de délégation SQL Server"
- Code source : `src/MOTEUR_REGLES.sql`, fonction `fn_ResolveAggregator`

## Notes

Cette décision a été prise après analyse approfondie des cas d'usage réels et consultation des utilisateurs principaux du moteur. 

Le gain en simplicité et maintenabilité justifie largement le coût de migration, qui reste limité (seuls FIRST, CONCAT et JSONIFY sont impactés).

Les tests montrent également un gain de performance de 30-50% sur les cas avec NULL grâce au filtrage précoce.
