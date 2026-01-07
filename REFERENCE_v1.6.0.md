# REFERENCE — Rules Engine
## Version 1.6.0 (Normative)

> Évolution contrôlée de la spécification v1.5.5  
> Cette version **reprend intégralement la structure et les garanties de la v1.5.5**,  
> et **formalise explicitement les modifications introduites en v1.6.0**, notamment sur :
> - la sémantique des agrégats,
> - la gestion des valeurs NULL,
> - la compilation des expressions et optimisations associées.

---

## 0. Historique et positionnement

- **v1.5.5** : version de stabilisation, verrouillage sémantique, gestion fine des NULL par agrégat.
- **v1.6.0** : version de simplification sémantique et d’optimisation moteur.

Cette évolution est **volontairement non rétro-compatible sur certains tests normatifs**, mais
**ne remet pas en cause les objectifs fondamentaux** du moteur.

---

## 1. Rappels invariants (hérités de v1.5.5)

### 1.1 Thread d’exécution
- Un *thread* est un ensemble de règles évaluées dans un contexte isolé.
- Les threads sont cloisonnés par session (tables temporaires).

### 1.2 Table d’état logique (`ThreadState`)
Chaque clé est **unique** (collation CI).

| Colonne | Type | Description |
|------|------|-------------|
| `[Key]` | NVARCHAR | Identifiant variable ou règle |
| `ScalarValue` | NVARCHAR(MAX) NULL | Valeur scalaire |
| `ValueType` | VARCHAR | STRING, NUMERIC, BOOLEAN, JSON… |
| `State` | ENUM | `EVALUATED` / `ERROR` |
| `SeqId` | INT | Ordre canonique d’insertion |

### 1.3 Gestion des erreurs
- Une règle en erreur :
  - `State = ERROR`
  - `ScalarValue = NULL`
- Une erreur :
  - est enregistrée,
  - n’interrompt jamais le thread,
  - n’empêche pas l’évaluation des autres règles.

---

## 2. Principe fondamental des agrégats (MODIFIÉ v1.6.0)

### 2.1 Règle globale

> **Tous les agrégats opèrent exclusivement sur les valeurs NON NULL.**

- Les valeurs NULL (y compris issues d’erreurs) :
  - sont conservées dans la table d’état,
  - **n’influencent jamais les agrégats**.

Cette règle remplace les exceptions spécifiques de la v1.5.5.

---

## 3. Sémantique des agrégats

### 3.1 Agrégats mathématiques (inchangés)
- `SUM`, `AVG`, `MIN`, `MAX`, `COUNT`
- Calculés sur les valeurs NON NULL uniquement.

### 3.2 Agrégats positionnels (MODIFIÉS / NOUVEAU)

#### FIRST (v1.6.0)
- Première valeur NON NULL selon `SeqId` croissant.

#### LAST (nouveau)
- Dernière valeur NON NULL selon `SeqId` décroissant.

### 3.3 Agrégats structurels (MODIFIÉS)

#### CONCAT
- Concatène les valeurs NON NULL,
- Ordonné par `SeqId`,
- Ensemble vide → chaîne vide.

#### JSONIFY
- Agrège uniquement les clés ayant une valeur NON NULL,
- Les clés en erreur (NULL) sont ignorées,
- Ensemble vide → `{}`.

---

## 4. Tokens et sélection d’ensemble (hérité v1.5.5)

- Les tokens identifient un sous-ensemble de clés via SQL LIKE.
- Les règles peuvent être découvertes et évaluées *lazy* (`rule:LIKE`).
- Un token retourne toujours une valeur scalaire.

---

## 5. Compilation des expressions (MODIFIÉ / OPTIMISÉ)

La procédure de compilation **doit intégrer explicitement les optimisations suivantes**,
déjà présentes dans les scripts moteurs récents.

### 5.1 Normalisation des littéraux

Avant toute évaluation SQL :
- Décimaux français :
  ```
  2,5 → 2.5
  ```
- Quotes normalisées (`"` → `'` si nécessaire).

### 5.2 Pré-compilation des règles
- Les règles sont compilées une seule fois par thread.
- Les expressions compilées sont mises en cache si le mode le permet.

### 5.3 Réduction des évaluations SQL
- Les agrégats sont évalués sur des ensembles filtrés (`ScalarValue IS NOT NULL`).
- Aucun calcul inutile sur des lignes en erreur ou NULL.

### 5.4 Représentation canonique des résultats
- Les résultats numériques sont normalisés (suppression des zéros inutiles).
- Les valeurs JSON / texte sont conservées intégralement (`NVARCHAR(MAX)`).

---

## 6. Contraintes techniques (héritées)

- SQL Server ≥ 2017 (CL ≥ 140).
- Aucune troncature implicite autorisée.
- Le moteur **ne parse pas le JSON métier** : il stocke des littéraux.

---

## 7. Impacts sur les tests normatifs

### 7.1 Tests supprimés (obsolètes)
- `X01_FirstNull`
- `X02_JsonifyError`

### 7.2 Tests ajoutés
- FIRST ignore NULL
- LAST ignore NULL
- JSONIFY ignore NULL
- JSONIFY ensemble vide

---

## 8. Conclusion

La version **1.6.0** :
- simplifie la sémantique des agrégats,
- réduit la complexité moteur,
- améliore la robustesse et la performance,
- prépare les évolutions futures sans ambiguïté.

Toute implémentation conforme **doit respecter la règle globale d’ignorance des NULL dans les agrégats**
et intégrer les optimisations de compilation décrites ci-dessus.
