# ADR-0004: Grammaire des tokens

## Statut
Accepté

## Date
2025-12-18

## Contexte

Le moteur de règles utilise des "tokens" pour référencer dynamiquement des valeurs dans les expressions SQL. Il était nécessaire de définir une syntaxe formelle, non ambiguë et facile à parser.

Les besoins identifiés :
- Référencer une ou plusieurs clés via pattern matching
- Supporter les agrégateurs (SUM, AVG, FIRST, etc.)
- Permettre la limitation de scope (all, rule, var)
- Être compatible avec la syntaxe SQL
- Être facile à lire et écrire pour les humains

## Décision

### Syntaxe Formelle

**Grammaire BNF du Token :**

```bnf
<token>      ::= '{' [<aggregator>] '(' [<scope>':'] <pattern> ')' '}'

<aggregator> ::= 'SUM' | 'AVG' | 'MIN' | 'MAX' | 'COUNT' 
               | 'FIRST' | 'LAST' | 'CONCAT' | 'JSONIFY'

<scope>      ::= 'all' | 'rule' | 'var'

<pattern>    ::= <literal> | <wildcard>
<literal>    ::= [A-Za-z0-9_]+
<wildcard>   ::= <literal> ['*' | '%']
```

### Exemples Valides

| Token | Description |
|-------|-------------|
| `{price}` | Valeur de la clé "price" (FIRST implicite) |
| `{FIRST(price)}` | Première valeur de "price" (explicite) |
| `{SUM(item_*)}` | Somme de toutes les clés matchant "item_*" |
| `{AVG(rule:score_*)}` | Moyenne des règles matchant "score_*" |
| `{COUNT(var:input_%)}` | Compte des variables matchant "input_%" |
| `{CONCAT(all:tag_*, ',')}` | Concatène tous les tags avec virgule |
| `{JSONIFY(metric_*)}` | Agrégation JSON des métriques |

### Valeurs par Défaut

| Élément | Défaut | Description |
|---------|--------|-------------|
| **Agrégateur** | `FIRST` | Si omis, FIRST est utilisé |
| **Scope** | `all` | Si omis, recherche dans toutes les clés |
| **Pattern** | Exact | Si pas de wildcard, matching exact |

### Exemples d'Équivalence

```sql
{price}           ≡ {FIRST(all:price)}
{SUM(item_*)}     ≡ {SUM(all:item_*)}
{rule:total}      ≡ {FIRST(rule:total)}
```

## Conséquences

### Positives

- **Clarté** : Syntaxe explicite et non ambiguë
- **Expressivité** : Couvre tous les cas d'usage identifiés
- **Compatibilité SQL** : `{...}` ne conflit pas avec SQL standard
- **Extensibilité** : Facile d'ajouter de nouveaux agrégateurs
- **Lisibilité** : Format naturel et intuitif
- **Parsing simple** : Grammaire régulière facile à parser

### Négatives

- **Verbosité** : Syntaxe plus longue que des alternatives (ex: `$price`)
- **Accolades** : Peuvent gêner dans certains contextes (échappement nécessaire)
- **Case sensitivity** : Nécessite documentation sur la casse (agrégateurs en MAJUSCULES recommandé)

### Impact sur le Code

#### Parsing des Tokens

```sql
-- Pattern de détection
DECLARE @TokenPattern NVARCHAR(100) = N'{[^}]+}'

-- Extraction via PATINDEX et SUBSTRING
WHILE PATINDEX(@TokenPattern, @Expression) > 0
BEGIN
    -- Extraire le token complet {AGG(scope:pattern)}
    -- Parser les composants : agrégateur, scope, pattern
    -- Remplacer par la valeur résolue
END
```

#### Résolution

```sql
-- Exemple : {SUM(var:price_*)}
-- Étapes :
-- 1. Extraire : aggregator='SUM', scope='var', pattern='price_*'
-- 2. Construire requête :
SELECT SUM(CAST(ScalarValue AS DECIMAL(18,2)))
FROM #ThreadState
WHERE [Key] LIKE 'price_%'  -- pattern → LIKE
  AND IsRule = 0            -- scope='var'
  AND ScalarValue IS NOT NULL

-- 3. Remplacer token par résultat
```

## Scopes Définis

### `all` (par défaut)
Recherche dans toutes les clés (variables + règles)

```sql
{price}          -- Cherche 'price' partout
{SUM(all:item_*)} -- Somme toutes les clés 'item_*'
```

### `rule`
Limite la recherche aux règles uniquement

```sql
{rule:total}      -- Uniquement la règle 'total'
{AVG(rule:score_*)} -- Moyenne des règles 'score_*'
```

### `var`
Limite la recherche aux variables uniquement

```sql
{var:input}       -- Uniquement la variable 'input'
{COUNT(var:tag_*)} -- Compte des variables 'tag_*'
```

### Traduction SQL

| Scope | Clause WHERE |
|-------|--------------|
| `all` | *(aucune restriction)* |
| `rule` | `AND IsRule = 1` |
| `var` | `AND IsRule = 0` |

## Wildcards Supportés

### `*` (Wildcard SQL standard)

```sql
{SUM(price_*)}   -- Transformé en LIKE 'price_%'
{CONCAT(tag_*)}  -- Transformé en LIKE 'tag_%'
```

**Note** : `*` en fin de pattern est automatiquement converti en `%` pour SQL LIKE.

### `%` (Wildcard SQL natif)

```sql
{SUM(price_%)}   -- Utilisé tel quel dans LIKE
{CONCAT(%_tag)}  -- Wildcard au début
```

**Note** : `%` est passé directement à LIKE sans conversion.

### Matching Exact

```sql
{price}          -- LIKE 'price' (matching exact)
{total_amount}   -- LIKE 'total_amount'
```

## Agrégateurs Spéciaux

### CONCAT avec Séparateur

**Syntaxe** : `{CONCAT(pattern, 'separator')}`

```sql
{CONCAT(tag_*, ',')}       -- tag_1,tag_2,tag_3
{CONCAT(status_*, ' | ')}  -- PENDING | SHIPPED | DONE
```

**Implémentation** :
```sql
SELECT STRING_AGG(ScalarValue, ',')  -- Séparateur = ','
FROM #ThreadState
WHERE [Key] LIKE 'tag_%'
  AND ScalarValue IS NOT NULL
ORDER BY SeqId
```

### JSONIFY

**Syntaxe** : `{JSONIFY(pattern)}`

```sql
{JSONIFY(metric_*)}  
-- → {"metric_cpu":"45","metric_ram":"78"}
```

**Implémentation** :
```sql
-- Construit un objet JSON clé:valeur
SELECT '{' + STRING_AGG(
    '"' + [Key] + '":"' + ScalarValue + '"', 
    ','
) + '}'
FROM #ThreadState
WHERE [Key] LIKE 'metric_%'
  AND ScalarValue IS NOT NULL
```

## Alternatives Considérées

### 1. Syntaxe Dollar `$variable`

**Exemple** : `$price`, `$SUM(item_*)`

**Rejet** :
- Conflit avec variables T-SQL (@variable, @@variable)
- Moins explicite (pas de délimiteur de fin)
- Difficult à parser dans expressions complexes
- Pas de support scope sans surcharge syntaxique

### 2. Syntaxe Double Accolade `{{variable}}`

**Exemple** : `{{price}}`, `{{SUM(item_*)}}`

**Rejet** :
- Plus verbeux que `{...}`
- Pas de bénéfice clair
- Difficile à taper rapidement
- Confusion avec templates (Mustache, Handlebars)

### 3. Syntaxe XML `<var>price</var>`

**Exemple** : `<var>price</var>`, `<agg type="SUM">item_*</agg>`

**Rejet** :
- Extrêmement verbeux
- Difficile à lire dans expressions SQL
- Parsing complexe
- Pas naturel pour des développeurs SQL

### 4. Syntaxe Fonctionnelle `TOKEN('price')`

**Exemple** : `TOKEN('price')`, `TOKEN('SUM', 'item_*')`

**Rejet** :
- Confusion avec fonctions SQL réelles
- Impossible à parser sans exécution
- Violation du principe de délégation
- Pas de support wildcard naturel

### 5. Syntaxe @ `@price`

**Exemple** : `@price`, `@SUM(item_*)`

**Rejet** :
- Conflit DIRECT avec variables T-SQL (@variable)
- Impossibilité de distinguer variable locale vs token
- Risque d'injection SQL
- Ambiguïté dans expressions

## Cas d'Usage Avancés

### Token dans Expression Complexe

```sql
-- Règle : Calcul de prix TTC
CASE 
    WHEN {country} = 'FR' THEN {price} * 1.20
    WHEN {country} = 'BE' THEN {price} * 1.21
    ELSE {price}
END
```

### Tokens Imbriqués (NON SUPPORTÉS)

```sql
-- ❌ INTERDIT : Tokens imbriqués
{SUM({prefix}_*)}

-- ✅ CORRECT : Pattern statique
{SUM(item_*)}
```

**Justification** : Les tokens imbriqués violeraient le principe de délégation (moteur devrait interpréter).

### Multiple Tokens

```sql
-- ✅ AUTORISÉ : Plusieurs tokens dans une expression
{price} * {quantity} * (1 + {tax_rate})

-- Résolution séquentielle :
-- 1. Résoudre {price} → 100
-- 2. Résoudre {quantity} → 5
-- 3. Résoudre {tax_rate} → 0.20
-- 4. Expression finale : 100 * 5 * (1 + 0.20) = 600
```

## Références

- Spécification v1.7.1, Section 4 "Tokens"
- ADR-0001 "Principe de délégation SQL Server"
- ADR-0003 "Modèle de données atomique" (pattern matching)
- Code source : `src/MOTEUR_REGLES.sql`, procédure `sp_ResolveTokens`

## Notes

La grammaire des tokens est conçue pour être :
- **Simple** : Facile à comprendre et utiliser
- **Robuste** : Non ambiguë et déterministe
- **Extensible** : Nouveaux agrégateurs ajoutables facilement
- **Cohérente** : Alignée avec les principes du moteur

Les choix de syntaxe privilégient la clarté et la maintenabilité sur la concision.
