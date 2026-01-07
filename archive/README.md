# Archive - Versions Historiques

Ce dossier contient les anciennes versions du moteur de règles et de la documentation, conservées pour référence historique.

## ⚠️ Avertissement

**Les fichiers de ce dossier sont obsolètes et ne doivent PAS être utilisés en production.**

- Version actuelle du moteur : `src/MOTEUR_REGLES.sql` (V6.9, conforme v1.7.1)
- Documentation actuelle : `docs/SPECIFICATION.md`
- Tests actuels : `tests/`

## Contenu de l'Archive

### Moteurs de Règles (SQL)

Versions historiques du moteur, conservées pour traçabilité :

- **V4** : Version fondation (2025-12-18) - Établissement des invariants I1-I5
- **V6.x** : Évolution progressive vers conformité v1.6.0
  - V6.0 : Base de la série V6
  - V6.1 : Ajout JSON Runner
  - V6.2.x : Optimisations multiples (V6.2, V6.2.1, V6.2.2, V6.2.3)
  - V6.3 : Performance améliorée
  - V6.4 : Conforme v1.5.5
  - V6.5 : Conforme v1.6.0 (Breaking changes NULL)
  - V6.6.x : Optimisations avancées (V6.6, patches)
  - V6.7 : Version intermédiaire
  - V6.8 : Pré-v1.7.0

### Documentation Historique

Spécifications et références des versions antérieures :

- **Spécifications** : `rules-engine-spec-v1.5.4.md`, etc.
- **Références** : `REFERENCE_v1.5.4.md`, `REFERENCE_v1.5.5.md`, `REFERENCE_v1.6.0.md`
- **Analyses** : Documents d'analyse et de synthèse des évolutions

### Tests Historiques

Anciennes suites de tests, conservées pour référence :

- Tests normatifs par version
- Tests de conformité spécifiques
- Benchmarks historiques

## Pourquoi Archiver ?

Les anciennes versions sont conservées pour :

1. **Traçabilité** : Historique complet des évolutions
2. **Audit** : Possibilité de vérifier l'origine des décisions
3. **Régression** : Analyse comparative de performance
4. **Apprentissage** : Comprendre l'évolution de l'architecture
5. **Rollback d'urgence** : En cas de problème critique (non recommandé)

## Structure Recommandée

Si vous devez consulter l'historique :

1. **Consulter CHANGELOG.md** : Vue d'ensemble des évolutions
2. **Consulter docs/adr/** : Décisions architecturales documentées
3. **Si nécessaire** : Explorer ce dossier pour détails spécifiques

## Migration depuis Version Archivée

Si vous utilisez une version archivée :

| Version Actuelle | Action Recommandée |
|------------------|-------------------|
| **V4** | Migrer vers V6.9 via V6.4 puis V6.5 (voir guides) |
| **V6.0-V6.3** | Migrer vers V6.4 puis V6.5 puis V6.9 |
| **V6.4** | Lire `docs/GUIDE_MIGRATION.md` pour migration vers V6.5+ |
| **V6.5-V6.8** | Migration directe vers V6.9 (compatible) |

## Support

**Aucun support n'est fourni pour les versions archivées.**

Pour toute question :
- Consulter la documentation actuelle dans `docs/`
- Consulter les ADR dans `docs/adr/`
- Utiliser la version actuelle du moteur

## Notes Importantes

### Versions Majeures Archivées

- **V4** (Fondation) : Établissement du principe de délégation SQL Server
- **V6.4** (v1.5.5) : Dernière version avant breaking changes NULL
- **V6.5** (v1.6.0) : Introduction sémantique NULL unifiée (breaking)
- **V6.9** (v1.7.1) : Version actuelle (NON archivée, dans `src/`)

### Breaking Changes

⚠️ **Attention aux breaking changes entre versions** :

- **V6.4 → V6.5** : Sémantique NULL unifiée
  - FIRST ignore NULL
  - JSONIFY ignore clés NULL
  - CONCAT ignore NULL
  
Consulter `docs/GUIDE_MIGRATION.md` avant toute migration.

---

*Ce dossier est géré automatiquement. Ne pas modifier les fichiers archivés.*
