# Architecture Decision Records (ADR)

Ce dossier contient les Architecture Decision Records (ADR) du projet Rules Engine T-SQL.

## Qu'est-ce qu'un ADR ?

Un ADR est un document qui capture une décision architecturale importante, son contexte, les alternatives considérées, et les conséquences de cette décision.

## Format

Chaque ADR suit le format suivant :
- **Statut** : Accepté, Déprécié, Remplacé, etc.
- **Date** : Date de la décision
- **Contexte** : Description du problème ou de la situation
- **Décision** : La décision prise
- **Conséquences** : Les conséquences positives et négatives
- **Alternatives considérées** : Les autres options envisagées

## Index des ADR

### Décisions Fondamentales

- [ADR-0001](0001-principe-delegation-sql-server.md) - Principe de délégation SQL Server
- [ADR-0002](0002-semantique-null-unifiee.md) - Sémantique NULL unifiée (v1.6.0)
- [ADR-0003](0003-modele-donnees-atomique.md) - Modèle de données atomique
- [ADR-0004](0004-grammaire-tokens.md) - Grammaire des tokens
- [ADR-0005](0005-gestion-erreurs-non-bloquante.md) - Gestion des erreurs non-bloquante

## Ordre de Lecture Recommandé

Pour comprendre l'architecture du moteur, il est recommandé de lire les ADR dans l'ordre suivant :

1. **ADR-0001** : Comprendre le principe fondamental de délégation
2. **ADR-0003** : Comprendre le modèle de données atomique
3. **ADR-0004** : Comprendre la syntaxe des tokens
4. **ADR-0002** : Comprendre la gestion des NULL
5. **ADR-0005** : Comprendre la gestion des erreurs

## Contribuer

Lors de l'ajout d'un nouvel ADR :
1. Créer un nouveau fichier avec le numéro séquentiel suivant
2. Utiliser le format standard défini ci-dessus
3. Mettre à jour cet index
4. Référencer les ADR connexes le cas échéant

## Ressources

- [Architecture Decision Records (ADR)](https://adr.github.io/)
- [Format ADR de Michael Nygard](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions)
