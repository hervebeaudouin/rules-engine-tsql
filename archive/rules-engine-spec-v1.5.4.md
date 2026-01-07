# Rules Engine – Specification
## Scalar Rules Engine
## Version 1.5.4

---

## Statut du document

**NORMATIF**

Ce document définit de manière contractuelle le comportement du moteur de règles.  
Toute implémentation, optimisation ou extension **DOIT** s’y conformer.

En cas de divergence entre :
- une implémentation,
- une documentation secondaire,
- un commentaire de code,

**ce document prévaut.**

---

## 1. Objectifs

Le moteur de règles a pour objectif de :

- évaluer des **règles scalaires**
- à partir de **variables initialisées**
- dans un **thread isolé**
- de manière **déterministe**, **paresseuse** et **performante**

Le moteur :
- **orchestre** la résolution
- **ne calcule pas** les expressions

👉 **SQL Server est responsable de tous les calculs.**

---

## 2. Principes fondamentaux

### 2.1. Séparation stricte des responsabilités

| Composant | Responsabilité |
|---------|----------------|
| Moteur | Sélection, orchestration, agrégation |
| SQL Server | Calcul, logique, typage |

Le moteur :
- ne parse pas SQL
- ne valide pas les expressions SQL
- ne tente aucune évaluation partielle

---

### 2.2. Thread

Un **thread** est un contexte d’exécution isolé contenant :

- un ensemble de variables initialisées
- un ensemble de règles précompilées
- une table d’état des règles
- un mode d’exécution

Un thread :
- est **isolé**
- est **non partageable**
- ne dépend d’aucun état global

---

## 3. Modes d’exécution

```
ExecutionMode ∈ { NORMAL, DEBUG }
```

### 3.1. Mode NORMAL (défaut)

Objectif : **performance maximale**

Caractéristiques :
- aucune journalisation détaillée
- aucune mesure de durée
- aucune trace SQL
- stockage minimal dans la table d’état
- gestion d’erreurs locale uniquement

Ce mode est **obligatoire en production**.

---

### 3.2. Mode DEBUG

Objectif : **diagnostic et audit**

Fonctionnalités activées :
- journalisation par règle
- timestamps d’exécution
- durée d’exécution
- message d’erreur détaillé
- SQL compilé (optionnel)

Le mode DEBUG est :
- explicitement activé
- jamais implicite

---

## 4. Table d’état du thread

### 4.1. Structure minimale (contractuelle)

```sql
CREATE TABLE #ThreadState (
    SeqId INT IDENTITY(1,1) NOT NULL,
    [Key] NVARCHAR(200)
        COLLATE SQL_Latin1_General_CP1_CI_AS
        NOT NULL,
    State TINYINT NOT NULL,
    ScalarValue SQL_VARIANT NULL,
    ErrorCategory VARCHAR(20) NULL,
    ErrorCode VARCHAR(50) NULL,
    CONSTRAINT PK_ThreadState PRIMARY KEY (SeqId),
    CONSTRAINT UQ_ThreadState_Key UNIQUE ([Key])
);
```

### 4.2. États possibles

```
State ∈ {
  NOT_EVALUATED,
  EVALUATING,
  EVALUATED,
  ERROR
}
```

---

## 5. Ordre canonique

> **L’ordre canonique des valeurs est l’ordre d’insertion dans la table d’état.**

- matérialisé par `SeqId`
- indépendant de la clé
- strictement déterministe dans un thread

Les agrégateurs dépendant de l’ordre **DOIVENT** utiliser `SeqId`.

---

## 6. Identifiants et collation

### 6.1. Identifiants

- peuvent contenir des espaces
- peuvent être quotés (`'...'` ou `"..."`)
- peuvent contenir `%` et `_` (SqlLike)

Caractères interdits hors quotes :
```
{}[]():
```

---

### 6.2. Collation et unicité

- unicité **case-insensitive**
- comparaison déléguée à SQL Server
- collation obligatoire :

```
SQL_Latin1_General_CP1_CI_AS
```

Exemples équivalents :
```
Toto = TOTO = toto
```

Aucune normalisation de casse n’est effectuée par le moteur.

---

## 7. Tokens `{...}`

### 7.1. Principe

Un token :
- sélectionne un **sous-ensemble de clés**
- résout leurs valeurs
- applique **un agrégateur unique**
- retourne **un scalaire**

> **Aucune logique n’est évaluée dans `{}`.**

---

### 7.2. Grammaire formelle

```ebnf
Token ::= "{" Lookup "}"

Lookup ::= Aggregator "(" Selector ")"
         | Selector

Selector ::= Identifier
           | "rule:" Identifier

Aggregator ::= FIRST
             | SUM | AVG | MIN | MAX | COUNT
             | FIRST_POS | SUM_POS | AVG_POS | MIN_POS | MAX_POS | COUNT_POS
             | FIRST_NEG | SUM_NEG | AVG_NEG | MIN_NEG | MAX_NEG | COUNT_NEG
             | CONCAT
             | JSONIFY
```

Agrégateur par défaut : `FIRST`

---

## 8. Sélection des clés

- la sélection utilise un `SqlLike`
- appliqué sur la colonne `[Key]`
- case-insensitive
- peut retourner :
  - 0 clé
  - 1 clé
  - N clés

---

## 9. Agrégateurs

### 9.1. Agrégateurs numériques

- ignorent les valeurs `NULL`
- respectent SQL standard

### 9.2. Agrégateurs dépendant de l’ordre

- FIRST
- FIRST_POS / FIRST_NEG
- CONCAT
- JSONIFY

➡️ **ordre = SeqId**

---

## 10. Règles et récursivité

### 10.1. Résolution paresseuse

- une règle est évaluée **au plus une fois**
- la valeur est mise en cache dans le thread

---

### 10.2. Récursivité

> **Si une règle est référencée alors qu’elle est à l’état EVALUATING, elle passe immédiatement à l’état ERROR.**

- aucune exception globale
- la règle retourne `NULL`
- le thread continue

---

## 11. Gestion des erreurs (globale)

### 11.1. Principe

> **Toute erreur lors de l’évaluation d’une règle la fait passer à l’état ERROR.**

- valeur scalaire = `NULL`
- erreur locale à la règle
- le thread n’est jamais interrompu

---

### 11.2. Catégories d’erreurs

```
RECURSION
NUMERIC
STRING
TYPE
SQL
SYNTAX
UNKNOWN
```

---

## 12. Interaction erreurs / agrégateurs

- règle en ERROR → valeur `NULL`
- comportement SQL standard

---

## 13. Compilation SQL

Responsabilités du compilateur :

- `"texte"` → `'texte'`
- échappement des quotes
- `2,5` → `2.5`

Aucune autre transformation.

---

## 14. Performance (contractuel)

> **Le moteur est optimisé pour le mode NORMAL.**

Toute fonctionnalité de diagnostic est conditionnée au mode DEBUG.

---

## 15. Versionnage

```
Version : 1.5.4
```

---

## 16. Règle d’or finale

> **Le moteur sélectionne et orchestre.  
> SQL calcule.  
> Le thread isole.  
> Les erreurs sont locales.  
> La performance est le défaut.**

---

Fin du document.
