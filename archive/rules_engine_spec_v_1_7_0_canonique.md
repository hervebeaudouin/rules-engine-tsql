# RULES ENGINE — SPECIFICATION CANONIQUE
## Version 1.7.0

> **Statut** : Canonique
>
> Ce document est la référence normative unique du moteur de règles.
> Il intègre **sans omission** :
> - la SPEC v1.5.4 (socle historique),
> - les évolutions v1.5.5 et v1.6.0,
> - les documents IA_FIRST, CHECKLIST, OPTIMISATIONS,
> - les décisions formelles ultérieures,
> - **la grammaire des tokens validée le 2026‑01‑06**.
>
> Les tests existants sont **informatifs** sauf mention contraire.

---

## 1. Objectifs et invariants

### 1.1 Objectifs

Le moteur de règles a pour objectif de :

- évaluer des **règles scalaires**
- à partir de **variables initialisées**
- dans un **thread isolé**
- de manière **déterministe**, **paresseuse** et **performante**

### 1.2 Invariants fondamentaux (NON NÉGOCIABLES)

- Le moteur **orchestre** l’évaluation
- Le moteur **ne calcule jamais**
- **SQL Server effectue 100 % des calculs**
- Toute expression finale doit être **exécutable telle quelle** par SQL Server
- Aucune interprétation sémantique n’est réalisée par le moteur

---

## 2. Règles

### 2.1 Définition

- Une règle est une **expression SQL** valide
- Elle peut contenir :
  - littéraux
  - opérateurs SQL
  - fonctions SQL natives
  - **tokens `{}`**

### 2.2 Portée

- Une règle **n’a aucun scope**
- Le scope n’existe **qu’au niveau du token**

### 2.3 États d’une règle

| État | Description |
|-----|-------------|
| NOT_EVALUATED | jamais évaluée |
| EVALUATING | en cours |
| EVALUATED | résultat disponible |
| ERROR | erreur bloquante |

- `NULL` n’est **pas** une erreur
- `ERROR` est **bloquant et propagé**

---

## 3. Tokens (LANGAGE DU MOTEUR)

### 3.1 Principe

Le token est :

- la **seule unité interprétée** par le moteur
- responsable de la **sélection**, de l’**agrégation** et de la **réduction scalaire**

---

### 3.2 Grammaire canonique du token

```
TOKEN :=
{
  [AGG]
  [ ( ]
    [ SCOPE ':' ]
    SQLLIKE_EXPRESSION
  [ ) ]
}
```

Où :

- `AGG` est un agrégateur (optionnel)
- `SCOPE` est optionnel
- `SQLLIKE_EXPRESSION` est obligatoire

---

### 3.3 Agrégateur par défaut

- Si `AGG` absent → **SUM**

Exemples :

```
{A%}        ≡ {SUM(all:A%)}
{R_*}       ≡ {SUM(all:R_*)}
{SUM(A%)}   ≡ {SUM(all:A%)}
```

---

### 3.4 Scope

Scopes supportés :

| Scope | Signification |
|------|---------------|
| var | variables |
| rule | résultats de règles |
| all | union `var ∪ rule` |

- Scope par défaut : **all**
- Le scope **ne s’applique jamais à la règle**

---

### 3.5 Wildcards et UX utilisateur

- Syntaxe SQL native : `%` `_`
- Alias utilisateur autorisés :
  - `*` → `%`
  - `?` → `_`

- Les espaces sont tolérés :
```
{SUM ( var:A% )} == {SUM(var:A%)}
```

---

## 4. Agrégateurs

### 4.1 Agrégateurs normatifs

- SUM
- AVG
- MIN
- MAX
- COUNT
- FIRST / LAST
- FIRST_POS / FIRST_NEG
- LAST_POS / LAST_NEG
- SUM_POS / SUM_NEG
- COUNT_POS / COUNT_NEG
- CONCAT
- JSONIFY

### 4.2 Règles communes

- `NULL` ignorés
- Ensemble vide :
  - `NULL` (COUNT → 0)
- Ordre strictement basé sur **SeqId**

### 4.3 Agrégateurs non normatifs (héritage)

- AVG_POS / AVG_NEG
- MIN_POS / MIN_NEG
- MAX_POS / MAX_NEG

> Présents dans certains tests, **non garantis**

---

## 5. Évaluation paresseuse (LAZY)

### 5.1 Lazy rule

- Une règle n’est évaluée **que si requise**

### 5.2 Lazy token

- Seules les règles **réellement matchées** sont évaluées

### 5.3 Lazy RuleRef / LIKE

- Les règles non matchées par pattern ne sont jamais évaluées

---

## 6. Dépendances et cycles

- Dépendances dynamiques
- Détection de cycles obligatoire
- Cycle ⇒ `ERROR`

---

## 7. Compilation

### 7.1 Compilation SQL

- Compilation différée
- Expression finale canonique

### 7.2 Cache de compilation

- Cache distinct du cache d’exécution
- Invalidation fine (rule / var / dépendances)

---

## 8. Cache d’exécution

- Cache résultats
- Stratégie LRU possible
- Désactivé en mode debug

---

## 9. Mode debug

En mode debug :

- caches désactivés
- recompilation forcée
- traçabilité complète :
  - tokens
  - SQL final
  - ordre d’évaluation

---

## 10. Déterminisme

- Résultats identiques à entrée identique
- Aucun ordre SQL implicite autorisé
- Ordre = SeqId uniquement

---

## 11. JSONIFY / CONCAT

### JSONIFY

- Préserve l’ordre
- Ignore NULL
- Supporte types multiples
- Unicode supporté

---

## 12. Runner / orchestration

- Un runner par contexte
- Isolation mémoire et cache
- Aucune logique métier

---

## 13. Tests

- Les tests existants sont **informatifs**
- Seuls les tests explicitement rattachés à un invariant sont normatifs

---

## 14. Clôture

Cette SPEC v1.7.0 est la référence unique.
Toute évolution ultérieure doit être tracée par amendement explicite.

