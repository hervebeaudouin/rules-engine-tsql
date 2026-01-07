# Changelog

Tous les changements notables de ce projet seront documentés dans ce fichier.

Le format est basé sur [Keep a Changelog](https://keepachangelog.com/fr/1.0.0/),
et ce projet adhère au [Semantic Versioning](https://semver.org/lang/fr/).

---

## [1.7.1] - 2026-01-07

### Référence Normative
- **Document de référence** : `RULES_ENGINE_SPEC_V1.7.1_CANONIQUE.md` établi comme spécification normative unique
- Toute implémentation DOIT se conformer à cette spécification

### Améliorations
- Grammaire formelle des tokens validée et documentée
- Tests exhaustifs V6.9 pour validation de conformité
- Consolidation de la documentation technique

### Moteur
- Version : V6.9
- Lignes de code : 1520
- Conformité : Spécification v1.7.1

---

## [1.7.0] - 2026-01-06

### Documentation
- Spécification canonique consolidée établie
- Grammaire BNF formelle du token documentée
- Référence consolidée v1.5.4 → v1.6.0 créée

### Améliorations
- Clarification de la sémantique des tokens
- Documentation des invariants fondamentaux (I1-I5)
- Formalisation du modèle de données atomique

### Moteur
- Versions : V6.8 / V6.9
- Optimisations de performance mineures
- Amélioration de la robustesse

---

## [1.6.0] - 2025-12-23 - **BREAKING CHANGES** ⚠️

### 🚨 Changements Cassants

#### Sémantique NULL Unifiée
- **RÈGLE GLOBALE** : Tous les agrégats opèrent EXCLUSIVEMENT sur valeurs NON NULL
- Les valeurs NULL sont conservées mais n'influencent jamais les agrégats

#### Agrégats Modifiés
- **FIRST** : Retourne la première valeur NON NULL (ignorant les NULL en tête)
  - ⚠️ Breaking : FIRST ne retourne plus NULL si la première valeur est NULL
- **CONCAT** : Concatène uniquement les valeurs NON NULL
  - Ensemble vide retourne `""` (chaîne vide)
- **JSONIFY** : Agrège uniquement les clés avec valeurs NON NULL
  - ⚠️ Breaking : Les clés avec valeur NULL sont omises du JSON
  - Ensemble vide retourne `"{}"` (objet JSON vide)

### ✨ Nouvelles Fonctionnalités
- **Agrégat LAST** : Symétrique à FIRST, retourne la dernière valeur NON NULL
- **Normalisation décimaux français** : Conversion automatique `2,5` → `2.5`
- **Normalisation quotes** : Conversion automatique `"` → `'`
- **Fonction fn_NormalizeLiteral()** : Normalisation des littéraux pour SQL Server

### 📈 Performance
- +10-20% sur cas simples (règles sans tokens)
- +30-50% sur cas avec NULL (filtrage précoce)
- +30-50% sur cas avec erreurs (court-circuit)
- +5-15% sur cas complexes (agrégats)

### 🔧 Changements Techniques
- Optimisations de compilation
- Propagation NULL optimisée
- Gestion erreurs conforme spécification
- Code plus maintenable (complexité réduite)

### Moteur
- Version : V6.5
- Lignes de code : 714
- Conformité : Spécification v1.6.0

### Migration
- Guide de migration fourni : `GUIDE_MIGRATION_V6_4_V6_5.md`
- Suite de tests de conformité : `TESTS_CONFORMITE_V1_6_0.sql`
- Plan de rollback documenté

---

## [1.5.5] - 2025-12-19

### Clarifications
- **Modèle atomique explicite** : Une clé = Une valeur scalaire unique
- Multiplicité obtenue par sélection LIKE sur plusieurs clés (non par multi-lignes)
- Formalisation du Runner JSON

### Améliorations
- **Scope par défaut** : Défini comme `all` pour tous les tokens
- Documentation du modèle de données atomique
- Clarification de la structure #ThreadState

### Moteur
- Version : V6.4
- Optimisations mineures
- Code plus robuste

---

## [1.5.4] - 2025-12-18 - **FONDATION** 🏛️

### 🎯 Principe Cardinal Établi

> **« Le moteur orchestre ; SQL Server calcule. »**

Ce principe fondamental définit l'architecture du moteur et reste immuable.

### Invariants Fondamentaux (I1-I5)

| # | Invariant | Description |
|---|-----------|-------------|
| **I1** | Orchestration | Le moteur orchestre l'évaluation |
| **I2** | Délégation | Le moteur ne calcule JAMAIS |
| **I3** | SQL Server | SQL Server effectue 100% des calculs |
| **I4** | Exécution directe | Toute expression finale est exécutable telle quelle par SQL Server |
| **I5** | Neutralité | Aucune interprétation sémantique par le moteur |

### États de Règle Définis

| État | Code | Description |
|------|------|-------------|
| NOT_EVALUATED | 0 | Règle non encore évaluée |
| EVALUATING | 1 | Évaluation en cours |
| EVALUATED | 2 | Évaluation terminée avec succès |
| ERROR | 9 | Erreur lors de l'évaluation |

### Agrégateurs de Base

Implémentation des agrégateurs fondamentaux :
- **SUM** : Somme des valeurs numériques
- **AVG** : Moyenne des valeurs numériques
- **MIN** : Valeur minimale
- **MAX** : Valeur maximale
- **COUNT** : Nombre de valeurs
- **FIRST** : Première valeur selon SeqId
- **CONCAT** : Concaténation avec séparateur
- **JSONIFY** : Agrégation en objet JSON

### Structure de Données

Table d'état normative (#ThreadState) établie avec colonnes :
- SeqId, Key, IsRule, State, ScalarValue, ValueIsNumeric, ErrorCategory, ErrorCode

### Moteur
- Version : V4
- Lignes de code : ~2000 (avec tests)
- Premier moteur conforme aux invariants

---

## Légende

- **BREAKING CHANGES** : Modifications incompatibles avec versions antérieures
- **FONDATION** : Version établissant l'architecture de base
- 🚨 : Attention requise lors de la migration
- ✨ : Nouvelle fonctionnalité
- 📈 : Amélioration de performance
- 🔧 : Changement technique
- 🎯 : Décision architecturale majeure

---

## Notes de Migration

### v1.5.5 → v1.6.0
- **Obligatoire** : Lire `GUIDE_MIGRATION_V6_4_V6_5.md`
- **Tests** : Exécuter `TESTS_CONFORMITE_V1_6_0.sql`
- **Risques** : Changements cassants sur FIRST et JSONIFY
- **Bénéfices** : Performance +10-50%, code plus simple

### v1.5.4 → v1.5.5
- **Sans risque** : Clarifications uniquement
- **Pas de changement** de comportement
- **Migration** : Aucune action requise

---

*Pour plus de détails sur l'architecture et les décisions, consulter les [ADR (Architecture Decision Records)](docs/adr/).*
