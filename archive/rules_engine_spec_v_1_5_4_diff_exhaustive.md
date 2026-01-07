# RULES ENGINE SPECIFICATION
## v1.5.4 — VERSION DIFFÉE EXHAUSTIVE

> Base : rules-engine-spec-v1.5.4.md (verbatim conservé)
>
> Convention :
> - [ORIGINAL 1.5.4] : texte strictement issu de la spec 1.5.4
> - [AJOUT v1.5.5] : ajout explicite ultérieur
> - [AJOUT v1.6.0] : ajout explicite ultérieur
> - [AJOUT POST] : décision ultérieure validée (discussions, grammaire tokens)
> - [INCOMPATIBILITÉ] : point devenu incompatible mais conservé pour traçabilité

---

## 1. Objectifs

[ORIGINAL 1.5.4]
Le moteur de règles a pour objectif de :
- évaluer des règles scalaires
- à partir de variables initialisées
- dans un thread isolé
- de manière déterministe et performante

[AJOUT v1.5.4]
- évaluation paresseuse (lazy)

[AJOUT v1.6.0]
- optimisation prioritaire sur la performance globale

[AJOUT POST]
- Le moteur orchestre uniquement l’évaluation.
- **SQL Server est responsable de tous les calculs.**

---

## 2. Principes fondamentaux

[ORIGINAL 1.5.4]
- Le moteur ne calcule pas les expressions.
- Les règles sont exprimées en SQL.

[AJOUT POST]
- Aucune interprétation sémantique des expressions.
- Toute expression finale doit être exécutable telle quelle par SQL Server.

---

## 3. Règles

### 3.1 Définition

[ORIGINAL 1.5.4]
Une règle est une expression SQL pouvant référencer des variables et des agrégats.

[AJOUT v1.6.0]
- Une règle peut référencer d’autres règles.

[AJOUT POST]
- Une règle n’a **aucun scope**.
- Le scope est exclusivement une propriété des tokens.

---

### 3.2 États d’une règle

[AJOUT v1.6.0]
États observés : NOT_EVALUATED, IN_PROGRESS, EVALUATED, ERROR.

[AJOUT POST]
- NULL n’est jamais une erreur.
- ERROR est bloquant et propagé.

---

## 4. Tokens

### 4.1 Définition

[ORIGINAL 1.5.4]
Un token représente une référence à un ensemble de valeurs agrégées.

[AJOUT POST]
- Le token est la seule unité interprétée par le moteur.

---

### 4.2 Grammaire du token

[ORIGINAL 1.5.4]
Syntaxe simplifiée : {expression}

[AJOUT v1.6.0]
Support des agrégateurs explicites.

[AJOUT POST — GRAMMAIRE VALIDÉE]
```
{ [AGG] ( [scope:] sql_like_expression ) }
```

- AGG optionnel (défaut = SUM)
- scope optionnel
- sql_like_expression obligatoire

Équivalences :
```
{A*}        ≡ {SUM(all:A%)}
{var:A*}    ≡ {SUM(var:A%)}
{rule:R_*}  ≡ {SUM(rule:R_%)}
```

---

### 4.3 Scope

[AJOUT POST]
Scopes supportés : var, rule, all.

- scope par défaut = all
- le scope ne s’applique qu’au token

---

### 4.4 Wildcards

[AJOUT v1.6.0]
Support des patterns SQL LIKE.

[AJOUT POST]
- Alias utilisateur : * → %, ? → _
- Normalisation obligatoire avant compilation.

---

## 5. Agrégateurs

### 5.1 Agrégateurs normatifs

[ORIGINAL 1.5.4]
SUM, AVG, MIN, MAX, COUNT.

[AJOUT v1.6.0]
FIRST, LAST, FIRST_POS, FIRST_NEG, LAST_POS, LAST_NEG.

[AJOUT POST]
SUM_POS, SUM_NEG, COUNT_POS, COUNT_NEG, CONCAT, JSONIFY.

---

### 5.2 Règles communes

[AJOUT v1.6.0]
- NULL ignorés
- Ensemble vide → NULL (sauf COUNT = 0)

[AJOUT POST]
- Ordre basé exclusivement sur SeqId

---

## 6. Évaluation lazy

[AJOUT v1.6.0]
- Une règle n’est évaluée que si nécessaire.

[AJOUT POST]
- Lazy au niveau : rule, token, RuleRef, LIKE.
- Aucune évaluation anticipée.

---

## 7. Dépendances et cycles

[AJOUT v1.6.0]
- Détection des cycles.

[AJOUT POST]
- Cycle ⇒ ERROR bloquant.

---

## 8. Compilation

[ORIGINAL 1.5.4]
Compilation SQL des expressions.

[AJOUT v1.6.0]
- Compilation différée.

[AJOUT POST]
- Normalisation canonique préalable.
- Cache de compilation distinct du cache d’exécution.

---

## 9. Caches

[AJOUT v1.6.0]
- Cache LRU.

[AJOUT POST]
- Invalidation fine (rule / var / dépendances).
- Mode debug désactive tous les caches.

---

## 10. Mode debug

[ORIGINAL 1.5.4]
Mode debug disponible.

[AJOUT POST]
- Trace SQL final.
- Trace ordre d’évaluation.

---

## 11. Déterminisme

[ORIGINAL 1.5.4]
Résultats déterministes.

[AJOUT POST]
- Interdiction de tout ordre SQL implicite.

---

## 12. JSONIFY / CONCAT

[AJOUT v1.6.0]
Fonctions d’agrégation textuelles.

[AJOUT POST]
- Ordre préservé.
- Support unicode.

---

## 13. Runner

[AJOUT v1.6.0]
Exécution isolée.

[AJOUT POST]
- Un runner par contexte.
- Isolation mémoire et cache.

---

## 14. Points contradictoires ou non normés

- Agrégateurs étendus présents dans des tests mais absents des specs initiales.
- Certains comportements lazy implicites avant formalisation.

---

## FIN DU DOCUMENT

