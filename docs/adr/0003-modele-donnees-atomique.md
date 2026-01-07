# ADR-0003: Modèle de données atomique

## Statut
Accepté

## Date
2025-12-19

## Contexte

Les premières versions du moteur laissaient une ambiguïté sur la représentation des données :
- Une clé peut-elle avoir plusieurs valeurs (multi-lignes) ?
- Comment gérer la multiplicité des données ?
- Quelle est la sémantique de la table #ThreadState ?

Cette ambiguïté créait :
- **Confusion** : Interprétations différentes selon les développeurs
- **Bugs potentiels** : Comportements inattendus sur données multiples
- **Documentation floue** : Explications contradictoires
- **Complexité inutile** : Code gérant des cas qui ne devraient pas exister

### Ancien Modèle Ambigu

```sql
-- ❓ Était-ce autorisé ?
INSERT INTO #ThreadState (Key, ScalarValue) VALUES ('price', '10')
INSERT INTO #ThreadState (Key, ScalarValue) VALUES ('price', '20')
INSERT INTO #ThreadState (Key, ScalarValue) VALUES ('price', '30')
```

Si oui, `{FIRST(price)}` devrait retourner quoi ? 10 ? [10, 20, 30] ?

## Décision

**INVARIANT depuis v1.5.5 : Une clé = Une valeur scalaire unique.**

### Modèle Atomique Strict

| Concept | Définition |
|---------|------------|
| **Clé** | Identifiant unique (case-insensitive) |
| **Valeur** | Scalaire unique de type `NVARCHAR(MAX)` |
| **Multiplicité** | Obtenue uniquement par sélection LIKE sur plusieurs clés distinctes |
| **Ligne** | Une ligne = une clé unique = une valeur unique |

### Représentation de la Multiplicité

```sql
-- ✅ CORRECT : Multiplicité par clés distinctes
INSERT INTO #ThreadState (Key, ScalarValue) VALUES ('price_1', '10')
INSERT INTO #ThreadState (Key, ScalarValue) VALUES ('price_2', '20')
INSERT INTO #ThreadState (Key, ScalarValue) VALUES ('price_3', '30')

-- Agrégation via pattern matching
{SUM(price_*)}  → 60
{FIRST(price_*)} → "10" (SeqId le plus petit)
{COUNT(price_*)} → 3
```

### Interdiction des Doublons

```sql
-- ❌ INTERDIT : Clé dupliquée
INSERT INTO #ThreadState (Key, ScalarValue) VALUES ('price', '10')
INSERT INTO #ThreadState (Key, ScalarValue) VALUES ('price', '20')  -- ERREUR

-- En pratique, SQL Server empêche cela si PK/UNIQUE sur Key
```

## Conséquences

### Positives

- **Clarté** : Sémantique simple et sans ambiguïté
- **Déterminisme** : Un SeqId unique par clé garantit un ordre canonique
- **Simplicité** : Pas de gestion de collections complexes
- **Performance** : Index efficace sur clé unique
- **Évolutivité** : Base solide pour optimisations futures
- **Testabilité** : Comportement prévisible facilite les tests

### Négatives

- **Verbosité** : Nécessité de nommer les clés explicitement (price_1, price_2...)
- **Limitation apparente** : Pas de tableau ou collection directe
- **Pattern matching obligatoire** : Usage de LIKE requis pour multiplicité

### Justifications des Négativités

1. **Verbosité** : Acceptable car clarté > concision
2. **Limitation** : Contournée élégamment par pattern matching
3. **LIKE obligatoire** : Bénéficie de l'indexation SQL Server

## Implémentation

### Structure #ThreadState

```sql
CREATE TABLE #ThreadState (
    SeqId           INT IDENTITY(1,1) PRIMARY KEY,  -- Ordre canonique
    [Key]           NVARCHAR(200) UNIQUE NOT NULL,  -- Clé unique (!)
    IsRule          BIT NOT NULL,
    State           TINYINT NOT NULL,
    ScalarValue     NVARCHAR(MAX),                  -- Valeur scalaire
    ValueIsNumeric  BIT,
    ErrorCategory   VARCHAR(50),
    ErrorCode       VARCHAR(50)
)
```

**Points clés :**
- `SeqId` : AUTO_INCREMENT garantit ordre d'insertion
- `Key` : UNIQUE empêche doublons (contrainte stricte)
- `ScalarValue` : UN seul champ, UNE seule valeur

### Pattern Matching

Les patterns LIKE permettent de sélectionner plusieurs clés :

```sql
-- Sélection de toutes les clés commençant par "item_"
SELECT ScalarValue
FROM #ThreadState
WHERE [Key] LIKE 'item_%'  -- Pattern matching
ORDER BY SeqId

-- Agrégation sur pattern
SELECT SUM(CAST(ScalarValue AS DECIMAL(18,2)))
FROM #ThreadState
WHERE [Key] LIKE 'price_%'
  AND ScalarValue IS NOT NULL
```

### Collation

**Obligatoire** : `SQL_Latin1_General_CP1_CI_AS` (Case-Insensitive)

```sql
-- Comparaisons insensibles à la casse
WHERE [Key] = @SearchKey COLLATE SQL_Latin1_General_CP1_CI_AS
WHERE [Key] LIKE @Pattern COLLATE SQL_Latin1_General_CP1_CI_AS
```

## Alternatives Considérées

### 1. Modèle Multi-Valeurs

**Description** : Autoriser plusieurs lignes avec la même clé.

**Rejet** :
- Perte du déterminisme (quel SeqId pour une clé donnée ?)
- Complexité de gestion des doublons
- Ambiguïté sur l'ordre des valeurs
- Impossibilité d'indexer efficacement sur Key
- Code plus complexe pour gérer les cas multiples

### 2. Colonne Array/Collection

**Description** : Stocker plusieurs valeurs dans une colonne JSON ou XML.

**Rejet** :
- Complexité de parsing et manipulation
- Performance dégradée (pas d'index direct sur éléments)
- Violation du principe de délégation (moteur devrait parser)
- Type non scalaire (contraire à l'invariant I4)
- Difficulté d'agrégation SQL standard

### 3. Table Séparée pour Multiplicité

**Description** : Clés simples dans #ThreadState, valeurs multiples dans #ThreadStateValues.

**Rejet** :
- Complexité architecturale (deux tables à gérer)
- Jointures obligatoires (perte de performance)
- Confusion sur la table à utiliser
- Pas de bénéfice clair sur pattern matching

### 4. Notation Array dans ScalarValue

**Description** : Stocker `"[10,20,30]"` comme valeur unique.

**Rejet** :
- Nécessiterait parsing par le moteur (violation I2)
- Type non scalaire du point de vue SQL
- Pas d'agrégation SQL native possible
- Sérialisation/désérialisation complexe

## Cas d'Usage

### Exemple 1 : Liste de Prix

```sql
-- Initialisation
INSERT INTO #ThreadState (Key, IsRule, State, ScalarValue)
VALUES 
    ('price_product_A', 0, 0, '10.50'),
    ('price_product_B', 0, 0, '25.00'),
    ('price_product_C', 0, 0, '8.75')

-- Règle : Prix moyen
-- Expression : {AVG(price_product_*)}
-- Résultat : 14.75
```

### Exemple 2 : Statuts Multiples

```sql
-- Initialisation
INSERT INTO #ThreadState (Key, IsRule, State, ScalarValue)
VALUES 
    ('status_order_1', 0, 0, 'SHIPPED'),
    ('status_order_2', 0, 0, 'PENDING'),
    ('status_order_3', 0, 0, 'DELIVERED')

-- Règle : Tous les statuts
-- Expression : {CONCAT(status_order_*, ',')}
-- Résultat : "SHIPPED,PENDING,DELIVERED"
```

### Exemple 3 : Agrégation JSON

```sql
-- Initialisation
INSERT INTO #ThreadState (Key, IsRule, State, ScalarValue)
VALUES 
    ('metric_cpu', 0, 0, '45.2'),
    ('metric_memory', 0, 0, '78.9'),
    ('metric_disk', 0, 0, '12.3')

-- Règle : JSON des métriques
-- Expression : {JSONIFY(metric_*)}
-- Résultat : {"metric_cpu":"45.2","metric_memory":"78.9","metric_disk":"12.3"}
```

## Références

- Spécification v1.7.1, Section 2 "Modèle de Données"
- ADR-0004 "Grammaire des tokens" (pattern matching)
- Code source : `src/MOTEUR_REGLES.sql`, table #ThreadState

## Notes

Le modèle atomique est un choix de design fondamental qui simplifie considérablement l'architecture du moteur. 

Bien que moins intuitif au premier abord qu'un modèle multi-valeurs, il s'avère plus robuste, plus performant et plus facile à raisonner.

Le pattern matching SQL (LIKE) offre toute la flexibilité nécessaire pour représenter la multiplicité, tout en restant dans le cadre du principe de délégation SQL Server.
