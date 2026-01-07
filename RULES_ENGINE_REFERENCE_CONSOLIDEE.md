# RULES ENGINE — RÉFÉRENCE CONSOLIDÉE EXHAUSTIVE
## De v1.5.4 à v1.6.0 — Document Unique de Traçabilité

> **Statut** : Document de référence consolidé  
> **Versions couvertes** : v1.5.4, v1.5.5, v1.6.0  
> **Date de consolidation** : 2025-01-06  
> **Objectif** : Fournir une traçabilité complète de l'évolution sémantique du moteur

---

# TABLE DES MATIÈRES

1. [Historique et Évolution des Versions](#1-historique-et-évolution-des-versions)
2. [Objectifs Fondamentaux](#2-objectifs-fondamentaux)
3. [Token (Cœur du Moteur)](#3-token-cœur-du-moteur)
4. [Règles](#4-règles)
5. [Variables](#5-variables)
6. [Thread d'Exécution](#6-thread-dexécution)
7. [Agrégateurs](#7-agrégateurs)
8. [Gestion des Erreurs](#8-gestion-des-erreurs)
9. [Compilation et Normalisation](#9-compilation-et-normalisation)
10. [Modes d'Exécution](#10-modes-dexécution)
11. [Runner JSON](#11-runner-json)
12. [Tests Normatifs](#12-tests-normatifs)
13. [Optimisations (v6.6)](#13-optimisations-v66)
14. [Annexes](#14-annexes)

---

# 1. HISTORIQUE ET ÉVOLUTION DES VERSIONS

## 1.1 Chronologie

| Version | Date | Nature | Changements Majeurs |
|---------|------|--------|---------------------|
| **v1.5.4** | 2025-12-18 | Fondation | Sémantique de base verrouillée |
| **v1.5.5** | 2025-12-19 | Stabilisation | Clarification modèle atomique, runner JSON |
| **v1.6.0** | 2025-12-20 | Simplification | Sémantique NULL unifiée dans agrégats |

## 1.2 Matrice de Compatibilité

| Aspect | v1.5.4 | v1.5.5 | v1.6.0 | Notes |
|--------|--------|--------|--------|-------|
| Sémantique de base | ✅ | ✅ | ✅ | Invariant |
| Modèle atomique | Implicite | ✅ Explicite | ✅ | Clarifié en v1.5.5 |
| NULL dans FIRST | Peut retourner NULL | Peut retourner NULL | ❌ Ignore NULL | **Breaking change** |
| NULL dans JSONIFY | Clé présente avec `null` | Clé présente avec `null` | ❌ Clé ignorée | **Breaking change** |
| LAST agrégateur | ❌ | ❌ | ✅ Nouveau | Extension |
| Runner JSON | Implicite | ✅ Formalisé | ✅ | Verrouillé |

## 1.3 Décisions Architecturales Clés

### v1.5.4 — Fondation
- **Principe cardinal** : « Le moteur orchestre ; SQL Server calcule »
- États de règle fermés : NOT_EVALUATED, EVALUATING, EVALUATED, ERROR
- Ordre canonique = SeqId (ordre d'insertion)
- Collation case-insensitive obligatoire

### v1.5.5 — Clarification
- **Modèle atomique explicite** : une clé = une valeur (jamais de multi-lignes)
- Multiplicité = sélection de plusieurs clés via LIKE
- Runner JSON formalisé avec contraintes strictes
- Token = seule unité interprétée par le moteur

### v1.6.0 — Simplification
- **Règle universelle NULL** : tous les agrégats ignorent NULL
- Suppression des exceptions (FIRST pouvait retourner NULL)
- Ajout de LAST
- Optimisations de compilation formalisées

---

# 2. OBJECTIFS FONDAMENTAUX

## 2.1 Objectifs (Invariants depuis v1.5.4)

| Objectif | Description | Source |
|----------|-------------|--------|
| **Robustesse** | Erreurs localisées, pas d'arrêt du thread | v1.5.4 |
| **Déterminisme** | Mêmes entrées ⇒ mêmes sorties | v1.5.4 |
| **Performance** | Mode NORMAL minimal, DEBUG explicite | v1.5.4 |
| **Évolutivité** | Langage fermé, extensions versionnées | v1.5.4 |

## 2.2 Principe Fondamental

> **Le moteur orchestre ; SQL Server calcule.**

Ce principe signifie :
- Le moteur **n'interprète jamais** les expressions SQL
- Le moteur **ne calcule jamais** directement (pas de IIF, COALESCE, etc. dans `{...}`)
- Toute expression finale est exécutée **telle quelle** par SQL Server
- Le moteur se limite à : résoudre les tokens, substituer les valeurs, déléguer l'exécution

✅ **Constant depuis v1.5.4**

---

# 3. TOKEN (CŒUR DU MOTEUR)

> Cette section constitue la spécification exhaustive du token, élément central du moteur.

## 3.1 Définition du Token

**Sources** : REFERENCE_v1.5.4, REFERENCE_v1.5.5, REFERENCE_v1.6.0

Un token est :
- Une **unité autonome** de résolution
- Le **seul élément interprété** par le moteur
- Encadré par `{` et `}`

### Rôle du Token

Un token effectue **exactement quatre opérations** :

1. **Sélectionner** un sous-ensemble de clés (variables ou règles)
2. **Résoudre** les valeurs correspondantes (lazy pour les règles)
3. **Appliquer** un agrégateur unique
4. **Retourner** un scalaire

### Ce qu'un Token NE FAIT PAS

- ❌ Aucune logique SQL évaluée dans `{...}`
- ❌ Pas de `IIF`, `COALESCE`, ou calcul
- ❌ Pas de manipulation de collections persistées
- ❌ Pas de transformation sémantique

✅ **Constant depuis v1.5.4**

---

## 3.2 Scope du Token

**Sources** : REFERENCE_v1.5.4, REFERENCE_v1.5.5, rules_engine_spec_v1.5.4_diff_exhaustive

### Scopes Disponibles

| Scope | Description | Comportement |
|-------|-------------|--------------|
| `var` | Variables uniquement | Sélectionne dans les variables |
| `rule` | Règles uniquement | Sélectionne dans les règles |
| `all` | Variables et règles | Sélectionne dans les deux |

### Règles de Scope

- Le scope **appartient exclusivement au token**
- Une règle **n'a jamais de scope** (le scope n'existe pas au niveau règle)
- Le scope **n'existe pas** au niveau de la table d'état

### Scope par Défaut

| Version | Scope par défaut | Notes |
|---------|------------------|-------|
| v1.5.4 | Non explicité | Comportement `all` implicite |
| v1.5.5+ | `all` | Formalisé explicitement |

⚠️ **Clarification v1.5.5** : Le scope `all` (implicite) était le comportement de facto en v1.5.4, mais n'était pas formalisé. La clarification est **rétro-compatible**.

### Exemples

```
{MONTANT}         → scope = all (par défaut)
{var:MONTANT%}    → scope = var (explicite)
{rule:R_%}        → scope = rule (explicite)
{SUM(var:A%)}     → scope = var (dans agrégat)
```

---

## 3.3 Agrégateur du Token

**Sources** : REFERENCE_v1.5.4, REFERENCE_v1.5.5, REFERENCE_v1.6.0

### Spécification de l'Agrégateur

- L'agrégateur peut être **explicite** ou **implicite**
- Un seul agrégateur par token

### Agrégateur par Défaut

| Version | Agrégateur par défaut | Notes |
|---------|----------------------|-------|
| v1.5.4 | `FIRST` | Documenté |
| v1.5.5 | `FIRST` | Confirmé |
| v1.6.0 | `FIRST` | Confirmé |

⚠️ **Attention** : Dans certains tests et discussions, `SUM` apparaît comme agrégateur implicite pour les tokens wildcards. Cependant, la **spécification normative** indique `FIRST` comme défaut.

**Recommandation** : Toujours utiliser un agrégateur explicite pour éviter toute ambiguïté.

✅ **Constant : FIRST est le défaut normatif**

---

## 3.4 Syntaxe du Token

**Sources** : REFERENCE_v1.5.4, REFERENCE_v1.5.5, REFERENCE_v1.6.0

### Grammaire Normative (BNF)

```bnf
Token        ::= "{" Lookup "}"
Lookup       ::= [ Aggregator "(" ] Selector [ ")" ]
Selector     ::= [ Scope ":" ] IdentifierOrPattern
Scope        ::= "var" | "rule"
IdentifierOrPattern ::= Identifier | Pattern
Pattern      ::= SqlLikeExpression

Aggregator   ::= "FIRST" | "LAST"
              | "SUM" | "AVG" | "MIN" | "MAX" | "COUNT"
              | "SUM_POS" | "AVG_POS" | "MIN_POS" | "MAX_POS" | "COUNT_POS"
              | "SUM_NEG" | "AVG_NEG" | "MIN_NEG" | "MAX_NEG" | "COUNT_NEG"
              | "FIRST_POS" | "FIRST_NEG" | "LAST_POS" | "LAST_NEG"
              | "CONCAT" | "JSONIFY"
```

### Formes Syntaxiques Valides

| Forme | Exemple | Description |
|-------|---------|-------------|
| Simple | `{MONTANT}` | Variable unique |
| Avec pattern | `{MONTANT_%}` | Sélection LIKE |
| Avec agrégateur | `{SUM(MONTANT_%)}` | Agrégat explicite |
| Avec scope | `{rule:R_%}` | Scope explicite |
| Complet | `{SUM(var:MONTANT_%)}` | Tous éléments |

### Identifiants

**Règles pour les identifiants** :
- Espaces autorisés dans les identifiants
- Quotes `'...'` ou `"..."` autorisées pour échappement
- Échappement interne : `''` dans `'...'`, `""` dans `"..."`
- Caractères structurants interdits hors quotes : `{ } [ ] ( ) :`

**Exemples valides** :
```
{MONTANT HT}              → Identifiant avec espace
{'Clé avec {accolades}'}  → Identifiant quoté
{"Valeur ""échappée"""}   → Double-quote échappée
```

### Tolérance aux Espaces

⚠️ **Point non formalisé** : La tolérance aux espaces autour des éléments structurants n'est pas explicitement normée.

| Expression | Statut |
|------------|--------|
| `{SUM(A%)}` | ✅ Valide (normatif) |
| `{ SUM(A%) }` | ⚠️ Toléré (implicite) |
| `{SUM( A% )}` | ⚠️ Toléré (implicite) |

**Recommandation** : Utiliser la forme canonique sans espaces superflus.

---

## 3.5 Wildcards et LIKE

**Sources** : REFERENCE_v1.5.4, REFERENCE_v1.5.5, tests normatifs

### Mécanisme de Sélection

La sélection de clés est réalisée via un comportement **SQL LIKE** sur la colonne `[Key]`.

| Caractéristique | Comportement |
|-----------------|--------------|
| Case-sensitivity | **Case-insensitive** (via collation) |
| Cardinalité résultat | 0, 1 ou N clés |
| Ensemble vide | ValueSet vide (traité par agrégateur) |

### Syntaxe des Wildcards

**Deux syntaxes coexistent** :

| Syntaxe | Caractères | Usage |
|---------|------------|-------|
| SQL LIKE (canonique) | `%`, `_` | Côté SQL Server |
| Alias utilisateur | `*`, `?` | Côté expression utilisateur |

### Normalisation des Wildcards

⚠️ **Point formalisé tardivement** (rules_engine_spec_v1.5.4_diff_exhaustive)

La normalisation des alias utilisateur vers SQL LIKE **doit être effectuée avant la compilation** :

```
* → %    (zéro ou plusieurs caractères)
? → _    (exactement un caractère)
```

**Exemples** :

| Expression utilisateur | Après normalisation | Signification |
|------------------------|---------------------|---------------|
| `{A*}` | `{A%}` | Toutes clés commençant par A |
| `{A?B}` | `{A_B}` | Clés de forme AXB |
| `{*_TOTAL}` | `{%_TOTAL}` | Clés finissant par _TOTAL |

### Équivalences Complètes

```
{A*}        ≡ {FIRST(all:A%)}    (scope all implicite, FIRST implicite)
{var:A*}    ≡ {FIRST(var:A%)}    (scope var explicite)
{rule:R_*}  ≡ {FIRST(rule:R_%)}  (scope rule explicite)
{SUM(A*)}   ≡ {SUM(all:A%)}      (agrégat explicite)
```

---

## 3.6 Résolution du Token

### Algorithme de Résolution

```
1. Parser le token → extraire (agrégateur, scope, pattern)
2. Normaliser le pattern (wildcards)
3. Sélectionner les clés via SQL LIKE
   - Si scope = var : WHERE IsRule = 0
   - Si scope = rule : WHERE IsRule = 1
   - Si scope = all : Pas de filtre IsRule
4. Pour chaque clé de type règle :
   - Résoudre lazy si NOT_EVALUATED
5. Appliquer l'agrégateur sur l'ensemble
6. Retourner le scalaire
```

### Résolution Lazy des Règles

Quand un token référence une règle (`rule:` ou règle découverte) :

1. Si état = EVALUATED → utiliser la valeur cachée
2. Si état = ERROR → contribuer NULL
3. Si état = NOT_EVALUATED → évaluer puis cacher
4. Si état = EVALUATING → **cycle détecté** → ERROR

✅ **Constant depuis v1.5.4**

---

## 3.7 Ensemble Transitoire

**Source** : REFERENCE_v1.5.5 (clarification explicite)

### Définition

Le token construit un **ensemble transitoire** :
- N'existe que pendant la résolution du token
- N'est jamais persisté
- Est immédiatement agrégé en scalaire

### Cycle de Vie

```
[Sélection LIKE] → [Ensemble transitoire] → [Agrégation] → [Scalaire]
                         ↑
                   Jamais persisté
```

### Implications

- Aucune collection n'est stockée dans `ThreadState`
- La multiplicité n'existe que pendant la résolution
- Impossible de « récupérer l'ensemble » après agrégation

✅ **Clarifié en v1.5.5, invariant depuis**

---

## 3.8 Récapitulatif Token

| Aspect | Statut | Notes |
|--------|--------|-------|
| Définition | ✅ Constant | Unité autonome de résolution |
| Scopes (var/rule/all) | ✅ Constant | `all` par défaut |
| Agrégateur par défaut | ✅ Constant | `FIRST` (normatif) |
| Syntaxe | ✅ Constant | Grammaire formalisée |
| Tolérance espaces | ⚠️ Implicite | Non formalisé |
| Wildcards SQL | ✅ Constant | `%`, `_` |
| Wildcards alias | ⚠️ Tardif | `*`, `?` → normalisés |
| Ensemble transitoire | ✅ Constant | Jamais persisté |

---

# 4. RÈGLES

## 4.1 Définition

**Sources** : REFERENCE_v1.5.4, REFERENCE_v1.5.5, REFERENCE_v1.6.0

Une règle :
- Possède une **clé unique** (case-insensitive)
- Contient une **expression SQL** pouvant référencer des tokens
- Retourne une **valeur scalaire** (ou NULL en cas d'erreur)
- **N'a pas de scope** (le scope est une propriété du token)

✅ **Constant depuis v1.5.4**

## 4.2 États d'une Règle

**États fermés** (énumération exhaustive) :

| État | Description | Transition depuis |
|------|-------------|-------------------|
| `NOT_EVALUATED` | Règle non encore évaluée | État initial |
| `EVALUATING` | Évaluation en cours | NOT_EVALUATED |
| `EVALUATED` | Évaluation terminée avec succès | EVALUATING |
| `ERROR` | Erreur lors de l'évaluation | EVALUATING ou ré-entrée |

### Machine d'États

```
    ┌─────────────────┐
    │  NOT_EVALUATED  │
    └────────┬────────┘
             │ Début évaluation
             ▼
    ┌─────────────────┐
    │   EVALUATING    │◄──┐
    └────────┬────────┘   │ Ré-entrée
             │            │ (cycle détecté)
    ┌────────┴────────┐   │
    │                 │   │
    ▼                 ▼   │
┌─────────┐     ┌─────────┐
│EVALUATED│     │  ERROR  │
└─────────┘     └─────────┘
```

✅ **Constant depuis v1.5.4**

## 4.3 Évaluation Lazy

**Contrat de résolution** :

- Si `EVALUATED` → retourner la valeur cachée
- Si `ERROR` → retourner NULL
- Si `NOT_EVALUATED` → passer à EVALUATING, exécuter, puis EVALUATED ou ERROR
- Si `EVALUATING` (ré-entrée) → cycle détecté → ERROR avec RECURSION/RECURSIVE_DEPENDENCY

**Garantie** : Une règle est évaluée **au plus une fois** par thread.

✅ **Constant depuis v1.5.4**

## 4.4 Référence Inter-Règles

**Ajout v1.6.0** : Une règle peut explicitement référencer d'autres règles via le scope `rule:`.

```
R_TOTAL = {SUM(rule:R_%)}
```

**Mécanisme** :
1. Le token `{rule:R_%}` sélectionne les règles correspondantes
2. Chaque règle est évaluée lazy
3. L'agrégateur est appliqué sur les résultats

✅ **Ajouté en v1.6.0, compatible v1.5.x**

---

# 5. VARIABLES

## 5.1 Modèle de Données

### v1.5.4 (Original)

Description initiale :
> « Une variable est un ensemble de valeurs associées à une clé. Une variable peut être multi-valeurs (plusieurs lignes). »

### v1.5.5 (Clarification)

**Modèle atomique explicite** :
> « Une variable est un littéral atomique associé à une clé unique. La multiplicité est obtenue exclusivement par sélection de plusieurs clés via SQL LIKE. »

| Propriété | v1.5.4 | v1.5.5+ |
|-----------|--------|---------|
| Clé | Unique (CI) | Unique (CI) |
| Valeur | « Ensemble de valeurs » | Scalaire unique |
| Multi-valeurs | Par clé (ambigu) | Par sélection LIKE |

⚠️ **Clarification non-breaking** : Le comportement v1.5.5 était déjà le comportement de facto des implémentations conformes.

## 5.2 Structure de Stockage

**Table logique `ThreadState`** (v1.5.5+) :

| Colonne | Type | Description |
|---------|------|-------------|
| `[Key]` | NVARCHAR + collation CI | Identifiant unique |
| `ScalarValue` | NVARCHAR(MAX) | Valeur textuelle (peut contenir JSON) |
| `ValueType` | VARCHAR | STRING, NUMERIC, BOOLEAN, JSON, NULL |
| `State` | ENUM | EVALUATED pour variables |
| `SeqId` | INT | Ordre d'insertion |
| `IsRule` | BIT | 0 pour variable |

## 5.3 Exemple de Données

**Nomenclature atomique** (v1.5.5+) :

| SeqId | Key | ScalarValue | ValueType |
|-------|-----|-------------|-----------|
| 1 | MONTANT_1 | 100 | DECIMAL |
| 2 | MONTANT_2 | 200 | DECIMAL |
| 3 | MONTANT_3 | -50 | DECIMAL |
| 4 | MONTANT_4 | 150 | DECIMAL |
| 5 | MONTANT_5 | -25 | DECIMAL |
| 6 | MONTANT_6 | NULL | NULL |

**Sélection via token** : `{SUM(MONTANT_%)}` → sélectionne les 6 clés

---

# 6. THREAD D'EXÉCUTION

## 6.1 Définition

Un **thread** est un contexte isolé d'évaluation contenant :
- Variables initialisées (littéraux atomiques)
- Règles précompilées
- État d'exécution des règles
- Mode d'exécution (NORMAL ou DEBUG)

## 6.2 Invariants

| Invariant | Description |
|-----------|-------------|
| **Isolation** | Pas d'état partagé entre threads |
| **Cache unique** | Une règle évaluée au plus une fois par thread |
| **Continuation** | Les erreurs n'interrompent pas le thread |
| **Déterminisme** | Mêmes entrées ⇒ mêmes sorties |

✅ **Constant depuis v1.5.4**

## 6.3 Collation

**Collation contractuelle** : `SQL_Latin1_General_CP1_CI_AS`

- Clés **case-insensitive** : `Toto = TOTO = toto`
- **Pas de LOWER/UPPER** : comparaison déléguée à SQL Server
- Tables temporaires : collation **doit être explicitée** (héritage tempdb)

✅ **Constant depuis v1.5.4**

---

# 7. AGRÉGATEURS

## 7.1 Liste des Agrégateurs

### Agrégateurs de Base (v1.5.4)

| Agrégateur | Description | Ensemble vide |
|------------|-------------|---------------|
| `SUM` | Somme | NULL |
| `AVG` | Moyenne | NULL |
| `MIN` | Minimum | NULL |
| `MAX` | Maximum | NULL |
| `COUNT` | Comptage | 0 |
| `FIRST` | Premier (SeqId) | NULL |
| `CONCAT` | Concaténation | Chaîne vide (v1.6.0) |
| `JSONIFY` | Objet JSON | `{}` |

### Agrégateurs Positionnels Étendus (v1.5.4)

| Agrégateur | Description |
|------------|-------------|
| `FIRST_POS` | Premier positif |
| `FIRST_NEG` | Premier négatif |
| `SUM_POS` | Somme des positifs |
| `SUM_NEG` | Somme des négatifs |
| `AVG_POS` / `AVG_NEG` | Moyenne filtrée |
| `MIN_POS` / `MIN_NEG` | Minimum filtré |
| `MAX_POS` / `MAX_NEG` | Maximum filtré |
| `COUNT_POS` / `COUNT_NEG` | Comptage filtré |

### Agrégateurs Ajoutés (v1.6.0)

| Agrégateur | Description |
|------------|-------------|
| `LAST` | Dernier NON NULL (SeqId décroissant) |
| `LAST_POS` | Dernier positif |
| `LAST_NEG` | Dernier négatif |

## 7.2 Sémantique NULL — Évolution Majeure

### v1.5.4 / v1.5.5

| Agrégateur | Traitement NULL |
|------------|-----------------|
| SUM/AVG/MIN/MAX/COUNT | NULL ignoré |
| FIRST | **Peut retourner NULL** si premier = NULL |
| CONCAT | NULL ignoré |
| JSONIFY | **Clé présente avec valeur `null`** |

### v1.6.0 (Simplification)

**Règle universelle** :
> Tous les agrégats opèrent exclusivement sur les valeurs NON NULL.

| Agrégateur | Traitement NULL v1.6.0 |
|------------|------------------------|
| Tous | **NULL ignoré** |
| FIRST | Premier NON NULL |
| LAST | Dernier NON NULL |
| JSONIFY | Clé avec NULL **ignorée** |

⚠️ **Breaking changes v1.5.5 → v1.6.0** :
- `FIRST` ne retourne plus NULL si la première valeur est NULL
- `JSONIFY` n'inclut plus les clés avec valeur NULL

## 7.3 Ordre Canonique

**Définition** : L'ordre canonique est l'ordre d'insertion (`SeqId`), pas l'ordre alphabétique de la clé.

**Implications** :
- FIRST retourne selon SeqId croissant
- LAST retourne selon SeqId décroissant
- CONCAT agrège selon SeqId
- JSONIFY sérialise selon SeqId (l'objet JSON reste sémantiquement non ordonné)

✅ **Constant depuis v1.5.4**

---

# 8. GESTION DES ERREURS

## 8.1 Contrat Unifié

Toute erreur lors de l'évaluation d'une règle :
1. Marque la règle **ERROR**
2. Associe `ErrorCategory` et `ErrorCode`
3. Valeur scalaire = **NULL**
4. Le thread **continue**

## 8.2 Catégories d'Erreurs (Fermées)

| Catégorie | Codes Typiques |
|-----------|----------------|
| `RECURSION` | RECURSIVE_DEPENDENCY |
| `NUMERIC` | DIVIDE_BY_ZERO, OVERFLOW |
| `STRING` | (Réservé) |
| `TYPE` | TYPE_MISMATCH |
| `SYNTAX` | INVALID_EXPRESSION |
| `SQL` | SQL_ERROR |
| `UNKNOWN` | UNEXPECTED |

## 8.3 Propagation dans les Agrégats

| Agrégateur | Comportement face à ERROR/NULL |
|------------|--------------------------------|
| SUM/AVG/MIN/MAX | NULL ignoré |
| COUNT | NULL ignoré (compte non-NULL) |
| FIRST/LAST | NULL ignoré (v1.6.0) |
| CONCAT | NULL ignoré |
| JSONIFY | Clé ignorée (v1.6.0) |

✅ **Constant depuis v1.5.4** (avec évolution NULL en v1.6.0)

---

# 9. COMPILATION ET NORMALISATION

## 9.1 Normalisation des Littéraux

Le compilateur normalise **avant exécution SQL** :

| Transformation | Exemple |
|----------------|---------|
| Quotes | `"texte"` → `'texte'` |
| Séparateur décimal | `2,5` → `2.5` |
| Échappement | `'` → `''` |

## 9.2 Normalisation des Résultats (v1.6.0)

- Résultats numériques : suppression des zéros inutiles
- Valeurs JSON/texte : conservées intégralement (`NVARCHAR(MAX)`)

## 9.3 Forme Canonique des Tokens

**Normalisation des wildcards** :

```
{A*}     → {A%}
{A?B}    → {A_B}
{* → %}
{? → _}
```

✅ **Constant depuis v1.5.4** (wildcards formalisés tardivement)

---

# 10. MODES D'EXÉCUTION

## 10.1 Mode NORMAL (Défaut)

**Objectif** : Performance maximale

- Aucune journalisation détaillée
- Stockage minimal : State, Value, ErrorCategory, ErrorCode
- Caches activés

## 10.2 Mode DEBUG

**Objectif** : Diagnostic

- Journalisation activée (durées, SQL compilé)
- **Doit être explicitement activé**
- Caches potentiellement désactivés

✅ **Constant depuis v1.5.4**

---

# 11. RUNNER JSON

## 11.1 Rôle (v1.5.5)

Le runner JSON est un **orchestrateur neutre**. Il :
1. Initialise le thread
2. Charge les variables atomiques
3. Exécute une **liste explicite** de règles
4. Retourne les résultats

## 11.2 Ce que le Runner NE FAIT PAS

- ❌ N'interprète pas les tokens
- ❌ N'applique pas d'agrégateurs
- ❌ Ne résout pas de dépendances
- ❌ N'utilise pas `rule:` ni patterns dans `rules[]`

## 11.3 Schéma JSON (Normatif)

```json
{
  "mode": "NORMAL|DEBUG",
  "variables": [
    { "key": "MONTANT_1", "type": "DECIMAL", "value": "100" },
    { "key": "CONFIG", "type": "JSON", "value": "{\"a\":1}" }
  ],
  "rules": ["RULE_A", "RULE_B"],
  "options": {
    "stopOnFatal": false,
    "returnStateTable": true,
    "returnDebug": false
  }
}
```

## 11.4 Contraintes

| Élément | Contrainte |
|---------|------------|
| `variables[].key` | Unique (CI) |
| `variables[].value` | Scalaire texte |
| `rules[]` | Liste de **clés** (pas de motif, pas de `rule:`) |

✅ **Formalisé en v1.5.5, invariant depuis**

---

# 12. TESTS NORMATIFS

## 12.1 Structure d'un Test

Chaque test produit :
- `Category`, `Name`
- `InputExpression`
- `Expected`, `Actual`
- `Pass` (0/1)
- `Details`

## 12.2 Fixtures Standard

### Variables MONTANT_%

| SeqId | Key | ScalarValue |
|-------|-----|-------------|
| 1 | MONTANT_1 | 100 |
| 2 | MONTANT_2 | 200 |
| 3 | MONTANT_3 | -50 |
| 4 | MONTANT_4 | 150 |
| 5 | MONTANT_5 | -25 |
| 6 | MONTANT_6 | NULL |

### Variables LIBELLE_%

| SeqId | Key | ScalarValue |
|-------|-----|-------------|
| 1 | LIBELLE_1 | 'A' |
| 2 | LIBELLE_2 | 'B' |
| 3 | LIBELLE_3 | NULL |
| 4 | LIBELLE_4 | 'C' |

## 12.3 Matrice de Tests (Extrait)

### Agrégateurs Numériques

| Test | Expression | Attendu |
|------|------------|---------|
| A01 | `{SUM(MONTANT_%)}` | 375 |
| A02 | `{SUM_POS(MONTANT_%)}` | 450 |
| A03 | `{SUM_NEG(MONTANT_%)}` | -75 |
| A04 | `{AVG(MONTANT_%)}` | 75 |
| A05 | `{AVG_NEG(MONTANT_%)}` | -37.5 |
| A08 | `{COUNT(MONTANT_%)}` | 5 |

### Ordre Canonique

| Test | Expression | Attendu |
|------|------------|---------|
| O01 | `{FIRST(MONTANT_%)}` | 100 |
| O02 | `{FIRST_NEG(MONTANT_%)}` | -50 |
| O03 | `{CONCAT(LIBELLE_%)}` | 'A,B,C' |

### Tests Modifiés v1.6.0

| Test v1.5.5 | Test v1.6.0 | Raison |
|-------------|-------------|--------|
| X01_FirstNull | **Supprimé** | FIRST ignore NULL |
| X02_JsonifyError | **Supprimé** | JSONIFY ignore NULL |

---

# 13. OPTIMISATIONS (V6.6)

## 13.1 Gains Attendus

| Phase | Optimisations | Gain |
|-------|---------------|------|
| Phase 1+2 | Cache compilation, pré-calcul types, élimination cursor, STRING_AGG | +150-400% |
| Phase 3 | Parallélisation, columnstore | +200-1000% |

## 13.2 Optimisations Implémentées

| # | Optimisation | Gain | Complexité |
|---|--------------|------|------------|
| 1 | Cache de compilation persistant | +30-50% | Moyenne |
| 2 | Pré-calcul types numériques | +15-25% | Faible |
| 3 | Élimination cursor tokens | +40-80% | Élevée |
| 4 | Fonction inline agrégats | +20-40% | Moyenne |
| 5 | STRING_AGG natif JSONIFY | +50-100% | Faible |
| 6 | Tables temporaires adaptatives | +30-60% | Moyenne |

## 13.3 Conformité Préservée

Toutes les optimisations maintiennent :
- ✅ Sémantique agrégats v1.6.0
- ✅ Comportement FIRST/LAST
- ✅ Gestion erreurs
- ✅ API JSON inchangée

---

# 14. ANNEXES

## 14.1 Contrat IA-First

**Règles impératives pour assistants IA** :

### Interdictions
- Ne pas inventer de grammaire ou d'agrégateur
- Ne pas évaluer SQL dans `{...}`
- Ne pas changer l'ordre canonique (SeqId)
- Ne pas stopper le thread en cas d'erreur

### Obligations
- États fermés : NOT_EVALUATED, EVALUATING, EVALUATED, ERROR
- Ré-entrée EVALUATING → ERROR + NULL
- Stockage NVARCHAR(MAX)
- Collation case-insensitive

## 14.2 Glossaire

| Terme | Définition |
|-------|------------|
| **Token** | Unité `{...}` de résolution → scalaire |
| **Thread** | Contexte isolé d'évaluation |
| **SeqId** | Ordre d'insertion (ordre canonique) |
| **Lazy** | Évaluation à la demande avec cache |
| **Scope** | Filtre de sélection (var/rule/all) |
| **ValueSet** | Ensemble transitoire avant agrégation |

## 14.3 Références des Documents Sources

| Document | Version | Rôle |
|----------|---------|------|
| REFERENCE_v1.5.4.md | v1.5.4 | Fondation sémantique |
| REFERENCE_v1.5.5.md | v1.5.5 | Stabilisation, modèle atomique |
| REFERENCE_v1.6.0.md | v1.6.0 | Simplification NULL |
| IA_FIRST_v1.5.4.md | v1.5.4 | Contrat IA |
| rules_engine_spec_v1.5.4_diff_exhaustive.md | - | Traçabilité |
| OPTIMISATIONS_AVANCEES_V1_6_0.md | v6.6 | Optimisations |
| RESUME_OPTIMISATIONS.md | v6.6 | Synthèse |

---

# FIN DU DOCUMENT

**Version consolidée** : 1.0.0  
**Couverture** : v1.5.4 → v1.6.0  
**Statut** : Référence unique de traçabilité
