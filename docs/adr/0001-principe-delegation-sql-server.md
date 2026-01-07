# ADR-0001: Principe de délégation SQL Server

## Statut
Accepté

## Date
2025-12-18

## Contexte

Le moteur de règles doit évaluer des expressions SQL complexes de manière performante et déterministe. Deux approches principales étaient possibles :

1. **Interprétation par le moteur** : Le moteur analyserait et calculerait lui-même les expressions SQL
2. **Délégation à SQL Server** : Le moteur orchestrerait uniquement, déléguant tous les calculs à SQL Server

La première approche présente plusieurs risques majeurs :
- Duplication de la logique SQL (complexe et source d'erreurs)
- Performances dégradées (interprétation vs exécution native)
- Divergence de comportement entre moteur et SQL Server
- Maintenance complexe (deux implémentations à maintenir)
- Perte du déterminisme de SQL Server

## Décision

**Le moteur orchestre uniquement ; SQL Server effectue 100% des calculs.**

Cela se traduit par les invariants suivants :

| # | Invariant | Description |
|---|-----------|-------------|
| **I1** | Orchestration | Le moteur orchestre l'évaluation |
| **I2** | Délégation | Le moteur ne calcule JAMAIS |
| **I3** | SQL Server | SQL Server effectue 100% des calculs |
| **I4** | Exécution directe | Toute expression finale est exécutable telle quelle par SQL Server |
| **I5** | Neutralité | Aucune interprétation sémantique par le moteur |

### Implications Concrètes

Le moteur se limite strictement à :
- ✅ Résoudre les tokens (remplacer `{pattern}` par des valeurs)
- ✅ Substituer les valeurs dans les expressions
- ✅ Déléguer l'exécution à SQL Server via `EXEC sp_executesql`
- ❌ Pas de `IIF`, `COALESCE`, ou logique conditionnelle dans les tokens
- ❌ Pas d'interprétation des opérateurs ou fonctions SQL
- ❌ Pas de calcul direct par le moteur

### Exemple

```sql
-- ❌ INTERDIT : Logique dans le token
{IIF({score} > 100, 'HIGH', 'LOW')}

-- ✅ CORRECT : Expression SQL pure
CASE WHEN {score} > 100 THEN 'HIGH' ELSE 'LOW' END
```

Le moteur remplace `{score}` par sa valeur (ex: `85`), puis exécute :
```sql
EXEC sp_executesql N'CASE WHEN 85 > 100 THEN ''HIGH'' ELSE ''LOW'' END'
```

## Conséquences

### Positives

- **Performance maximale** : Exécution native SQL Server, pas d'overhead d'interprétation
- **Déterminisme garanti** : Comportement identique à SQL Server pur
- **Simplicité du moteur** : Code concentré sur l'orchestration uniquement
- **Maintenance facilitée** : Une seule implémentation (SQL Server)
- **Puissance totale** : Accès à toutes les fonctionnalités SQL Server
- **Évolutivité** : Bénéficie automatiquement des optimisations SQL Server

### Négatives

- **Expressions plus verbeuses** : Les utilisateurs doivent écrire du SQL pur
- **Pas de sucre syntaxique** : Impossible d'ajouter des raccourcis comme `{IIF(...)}`
- **Validation différée** : Les erreurs SQL ne sont détectées qu'à l'exécution
- **Dépendance forte** : Le moteur est intrinsèquement lié à SQL Server

### Risques Atténués

- **Documentation claire** : Les utilisateurs sont guidés sur la syntaxe SQL pure
- **Messages d'erreur explicites** : Les erreurs SQL sont propagées avec contexte
- **Tests exhaustifs** : Validation de tous les cas d'usage courants

## Alternatives Considérées

### 1. Interprétation Partielle

**Description** : Le moteur interprèterait certaines constructions simples (IIF, COALESCE), délégant le reste à SQL Server.

**Rejet** : 
- Frontière floue entre ce qui est interprété et ce qui est délégué
- Risque de divergence de comportement
- Complexité accrue sans bénéfice clair
- Maintenance de deux logiques d'exécution

### 2. Langage d'Expression Dédié

**Description** : Créer un mini-langage d'expressions indépendant de SQL.

**Rejet** :
- Réinvention de SQL (effort considérable)
- Perte des fonctionnalités avancées SQL Server
- Courbe d'apprentissage pour les utilisateurs
- Performances probablement inférieures

### 3. Transpilation vers SQL

**Description** : Le moteur transformerait un langage simplifié en SQL.

**Rejet** :
- Complexité du transpilateur
- Risque de génération de SQL non optimal
- Maintenance d'un compilateur complexe
- Perte de contrôle sur le SQL généré

## Références

- Spécification v1.7.1, Section 1 "Objectifs et Invariants"
- ADR-0004 "Grammaire des tokens" (conséquence directe)
- Code source : `MOTEUR_REGLES_V6_9.sql`, procédure `sp_ResolveTokens`

## Notes

Ce principe est **cardinal** et **immuable**. Toute modification de ce principe constituerait un changement fondamental de l'architecture et nécessiterait une révision complète du moteur.

Les invariants I1-I5 sont considérés comme **non négociables** et doivent être respectés par toutes les implémentations futures.
