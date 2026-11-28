# Décisions client / serveur ServeIPA

## 2026-11-03 — Architecture

- Deux cibles : ServeIPA sur macOS et ServeIPAClient sur iPhone/iPad (iOS 17 minimum pour le client ; chaque IPA garde sa propre version minimale).
- Adresse initiale : `https://lucifer.tail0ad79c.ts.net`. Adresse HTTPS modifiable et persistée dans les réglages. Aucun contournement de certificat TLS.
- API JSON v1 : `GET /api/v1/health`, `GET /api/v1/apps`, `POST /api/v1/sessions?app=…`, `GET /api/v1/sessions/{uuid}`, et les ressources `manifest` et `ipa` de cette session.
- Le site web existant reste disponible à la racine. Le serveur reste lié à 127.0.0.1 et exposé par Tailscale Serve. Les ACL du tailnet contrôlent l’accès ; pas de publication Internet via Funnel.
- Une session UUID accompagne le manifeste jusqu’au transfert IPA. Le suivi du client est isolé entre appareils et tentatives. Sessions en mémoire, expiration après 24 h, maximum 1000. Un redémarrage du serveur invalide les suivis ; on relance alors une installation.
- Le client valide la version de l’API et l’origine des liens d’installation. Recherche par nom, identifiant, version et build, actualisation manuelle et au retour au premier plan.

## Tailscale

- Vérifier l’accès HTTPS réel au service ServeIPA est le diagnostic utilisable par le client. Cela prouve l’accessibilité du serveur, pas l’état interne du VPN.
- Une application iOS ne peut pas lire la configuration VPN d’une autre application. Ne pas prétendre détecter « Tailscale déconnecté » lorsque le Mac peut simplement être arrêté ou une ACL bloquer la connexion.
- Amélioration proposée : automatisation Raccourcis personnelle « À l’ouverture de ServeIPAClient → Connect Tailscale ». Tailscale fournit aussi une action Get Status ; une intégration explicite via Raccourcis reste possible.

## Télécharger, installer, ouvrir

- « Télécharger le fichier IPA » utilise URLSession, vérifie le succès HTTP et la taille reçue, enregistre dans Documents/Downloads et propose le partage vers Fichiers. C’est une confirmation de réception locale du fichier, pas une preuve d’installation. La taille seule n’est pas une vérification cryptographique.
- « Installer » confie le manifeste HTTPS à iOS via `itms-services`. L’IPA doit être signé et provisionné pour l’appareil. Le client n’installe pas arbitrairement un fichier dans le système.
- Le suivi OTA distingue attente, transfert, transfert HTTP terminé et échec. Les octets envoyés par le serveur ne prouvent ni la réception complète côté installateur, ni la validation de signature, ni la fin de l’installation. Aucun état mensonger « installation réussie ».
- iOS ne fournit pas de notification publique de fin d’installation pour une autre app, ni de lecture générale de sa version installée.
- Ouverture manuelle via un schéma d’URL déclaré par l’IPA. Aucun lancement par bundle identifier via API privée.
- Ouverture automatique facultative, au premier plan uniquement, lorsque le transfert est terminé ET qu’un schéma autorisé passe de non disponible à disponible. Ne pas l’utiliser pour une mise à jour d’une app déjà présente. Un schéma peut être partagé entre apps ; la disponibilité n’est pas une attestation d’identité ni de version.
- `Configuration/Client-Info.plist` contient les schémas interrogés. Avec le SDK iOS 27, Apple limite LSApplicationQueriesSchemes à 25 entrées. Ajouter les schémas nécessaires puis recompiler le client.
- IPA existants inspectés : iMetar déclare `imetar` (activé dans le client). rSSH déclare `rssh` (activé dans le client le 28/11/2026). iABView déclare `iabview` (activé dans le client le 28/11/2026). NZBPad déclare `nzbpad` (activé dans le client le 28/11/2026). FlightWall ne déclare aucun schéma ; ajouter CFBundleURLTypes dans son projet puis produire un nouvel IPA pour permettre son ouverture depuis ServeIPAClient.
- Le suivi OTA est persisté localement et repris au retour dans le client. Le téléchargement de fichier utilise une session standard ; une reprise garantie après fermeture forcée nécessiterait une URLSession de fond.

## 2026-11-26 — Lien d'installation `serveipa://`

- Le client déclare le schéma `serveipa`. `serveipa://install?app=iMetar` (ou `serveipa://install/iMetar`) installe le dernier build de l'app. La recherche porte sur l'identifiant de bundle exact, puis sur le nom (produit ou affiché) et le dernier composant de l'identifiant. Casse, espaces et ponctuation sont ignorés.
- Si le serveur signale un `projectBuild` (projet Xcode plus récent que la release), le client lance d'abord `POST /api/v1/builds` et suit le job. Il attend ensuite qu'un nouveau build apparaisse dans le catalogue, puis lance l'installation OTA habituelle. En cas d'échec de compilation, aucune installation n'est lancée.
- Le client doit rester au premier plan pendant la compilation : iOS suspend la tâche en arrière-plan, et le suivi reprend au retour dans l'app. Utilisable depuis Raccourcis (action « Ouvrir les URL »), Safari ou une autre app.
- Sur macOS, après l’installation dans Applications, le lien quitte l’instance en cours de l’app (demande normale, arrêt forcé après 8 s) puis lance la nouvelle version. Le client se relance lui-même par un shell détaché. Les installations lancées depuis l’interface ne relancent rien.

## Améliorations proposées

- Contrat de lancement explicite dans chaque application et callback authentifié contenant sa version/build : permettrait de confirmer la version qui s’est réellement exécutée.
- SHA-256 calculé au scan, mis en cache selon taille/date de modification et vérifié après téléchargement.
- Téléchargements de fond, reprise HTTP Range, historique et suppression des IPA locaux.
- Regroupement des versions par app, favoris, indicateur de compatibilité appareil/signature et affichage des erreurs de scan du serveur.
- Distribution gérée par MDM si une confirmation d’installation fiable et centralisée devient indispensable.

## Sources

- https://developer.apple.com/documentation/uikit/uiapplication/canopenurl(_:)
- https://developer.apple.com/documentation/networkextension/netunnelprovidermanager/loadallfrompreferences(completionhandler:)
- https://support.apple.com/guide/deployment/depce7cefc4d/web
- https://tailscale.com/docs/features/mac-ios-shortcuts

## Validation

- Compilations en ligne de commande des cibles macOS et iOS réussies, sans signature (`CODE_SIGNING_ALLOWED=NO`). Les appels BuildProject de cette session n’ont pas retourné de résultat.
- Serveur existant accessible en HTTPS ; métadonnées des cinq IPA existants inspectées.
- Tests Swift Testing ajoutés pour les adresses et les liens du protocole, mais non exécutés sur appareil.
- Aucun runtime de simulateur installé ; l’outil Device Interaction ne prend pas en charge les appareils physiques disponibles.
- La nouvelle API n’a pas encore été déployée et vérifiée sur le serveur actif. Installation OTA et ouverture automatique non validées sur iPhone/iPad.
- Les réglages de compilation modifiés via Xcode doivent encore être vérifiés dans le produit final : le premier produit iOS compilé indiquait iOS 27 et ne contenait pas encore la configuration personnalisée Info.plist. La cible dans Xcode indique iOS 17 et Configuration/Client-Info.plist.
- Ce commit constitue une première implémentation ; la validation de bout en bout reste à terminer.

## 2026-11-27 — Actions à distance, file d'attente et mise à jour du serveur

- Le serveur démarre avec l'app macOS (`AppDelegate`), indépendamment de ses fenêtres. L'actualisation automatique et la compilation de nuit suivent la même durée de vie.
- Ajout de projet : `GET /api/v1/projects` (scan ; dernier résultat renvoyé pendant une compilation) puis `POST /api/v1/projects?project=…&platform=…`. Seuls les identifiants issus du scan sont acceptés.
- File d'attente : les demandes des clients (recompilation, ajout, maintenance, mise à jour) sont exécutées l'une après l'autre ; une demande identique rend le même identifiant ; 50 au plus. La mise à jour de ServeIPA passe en dernier. La file est en mémoire : un redémarrage la vide.
- `GET /api/v1/builds` publie `job`, `queue`, `history` (20 jobs terminés, conservés d'un lancement à l'autre) et `serverUpdate`. États : queued, running, succeeded, failed, cancelled.
- Annulation : `DELETE /api/v1/builds?job=…`, refusée pendant l'installation d'une mise à jour. Chaque étape xcodebuild est interrompue après 45 minutes.
- Journaux : `~/Library/Logs/ServeIPA/builds` (30 conservés), lus par `GET /api/v1/builds/log?job=…` (200 derniers Ko).
- Mise à jour : `POST /api/v1/server/update`. Release exportée réutilisée si les sources n'ont pas changé, sinon compilation. L'ancienne app est conservée jusqu'à ce que `/api/v1/health` réponde avec le nouveau build (90 s), sinon restaurée et relancée. Conséquence : une panne de Tailscale au même moment provoque aussi une restauration. La protection s'applique à partir d'une version qui contient ce script.
- Empreinte des sources : `Scripts/source-fingerprint.sh`, commun au numéro de build et à la détection de mise à jour (code, ressources, configuration, scripts, `project.pbxproj`).
- Notifications locales sur le client. Sur iOS, la vérification en arrière-plan (`BGAppRefreshTask`) dépend du système : pas de délai garanti sans notifications push.
- Non traité : les routes n'ont pas d'authentification propre ; les ACL du tailnet restent le seul contrôle d'accès, journaux de compilation compris.


## 2026-11-28 — Mise à jour des apps macOS

- Une release est plus récente par sa version, sinon par son numéro de build, sinon, à numéros égaux, par la date de son exécutable (`builtAt`, tolérance de 5 s). Un serveur sans `builtAt` ne permet pas ce dernier critère.
- Une app ouverte depuis l'emplacement installé quitte **avant** d'être remplacée, puis est relancée (client et serveur). Elle n'est jamais forcée sans accord : sans réponse ou avec « Plus tard », rien n'est modifié. Le serveur ne force jamais et signale les apps reportées, y compris pendant la maintenance de nuit.
- rClaude n'est ni quitté ni remplacé tant qu'un processus fils `claude -p` tourne.
- Le client se remplace par un script détaché, après sa fermeture ; l'ancienne version est restaurée si la copie échoue, et l'échec est signalé au lancement suivant.
- Mise à jour groupée : ServeIPA en avant-dernier, le client en dernier. Un ServeIPA en cours d'exécution sur le Mac serveur est mis à jour par `POST /api/v1/server/update`.
- « Compiler puis mettre à jour » compile les projets plus avancés que les apps installées, puis installe les releases.
- Une app déjà installée dans `~/Applications` est remplacée à cet emplacement.

## 2026-11-28 — Notifications du client

- Notifications locales activables par famille : fin des compilations demandées d'ici, nouvelles releases (apps installées plus anciennes) et nouvelles apps, mise à jour du serveur disponible, échecs des autres travaux, installations Mac quand le client n'est pas actif, connexion perdue ou retrouvée (désactivée par défaut).
- Le premier relevé d'un serveur ne signale rien. Le catalogue est relu environ toutes les minutes.
- Sur Mac, le suivi vit avec la fenêtre. Sur iOS, la vérification en arrière-plan dépend de `BGAppRefreshTask`.

## 2026-11-28 — Indicateur de prompt rClaude

- Le serveur relève toutes les 3 s les commandes `claude -p` portant la consigne « Contexte rClaude … projet « X » » et publie les noms dans `activePrompts` (`GET /api/v1/builds`).
- Une app est marquée si X correspond à son nom, au nom de son dossier d'export ou à la fin de son identifiant. Dépend du texte de la consigne écrite par `Executor.command` dans rClaude.
- Seuls les prompts visibles depuis le Mac serveur sont signalés (exécutés ici ou envoyés d'ici par SSH).

## 2026-11-28 — Nettoyage après compilation

- Une compilation réussie supprime définitivement les autres releases de la même app (identifiant de bundle et plateforme), quel que soit le réglage « builds conservés ».
- Rien n'est supprimé si le nouvel export n'apparaît pas au scan, ni la racine, ni un dossier partagé avec une release à garder (`ObsoleteBuilds`).

## 2026-11-28 — Installer compile d'abord

- Le bouton Installer, sur le dernier build d'une app, compile d'abord le projet s'il a un numéro de build plus récent et qu'aucun prompt rClaude n'est en cours (relu au moment de l'appui) ; sinon la release du serveur est installée. En cas d'échec ou d'annulation de la compilation, rien n'est installé.
- Exclu : un ServeIPA ouvert sur le Mac, que le serveur compile lui-même lors de sa mise à jour. Les liens `serveipa://` suivent la même règle.

## 2026-11-28 — Pas de mise à jour pendant un prompt

- Tant qu'un prompt rClaude tourne sur le projet « ServeIPA » ou « ServeIPAClient », les boutons qui mettent à jour le client ou le serveur sont grisés (bandeaux, réglages, lignes de ces deux apps, menu et réglages de ServeIPA) et la mise à jour groupée les ignore. Le client relit l'état avant de lancer.
- Le contrôle est fait par les interfaces : l'API du serveur, la maintenance et la compilation de nuit ne le font pas.

## 2026-11-28 — Pas de compilation pendant un prompt

- Un prompt rClaude sur un projet interdit de compiler ce projet (ServeIPA et ServeIPAClient se bloquent mutuellement) ; les autres projets restent compilables. Une compilation déjà lancée n'est pas interrompue.
- Le serveur l'impose au démarrage de chaque compilation (demande locale, distante ou en file : le travail échoue avec ce motif). La baguette magique et la compilation de nuit sautent ces apps et les signalent.
- Les interfaces grisent les boutons de compilation ; Installer et les liens `serveipa://` installent alors la release disponible.

## 2026-11-28 — Dates git des projets

- `GET /api/v1/apps` publie `lastCommit` et `lastPush` (secondes depuis 1970) pour le dernier build de chaque app. Commit : date de `HEAD` du dépôt contenant le projet. Push : dernière entrée « update by push » du reflog de la branche distante suivie, donc seulement les push faits depuis le Mac serveur.

## 2026-11-28 — Fermeture du client iOS pour sa mise à jour

- Quand l'IPA du client lui-même est transmis (session « transferred »), le client iOS affiche un message 3 s puis quitte (`exit(0)`, acceptable pour une app diffusée hors App Store). Seul un suivi lancé depuis l'ouverture en cours le déclenche. Sur Mac, le client quittait déjà avant son remplacement.

## 2026-11-28 — Détection d'un projet modifié mais non compilé

- Bug : `.build-number` n'avance qu'à la compilation ; des sources modifiées sans build (ou un compteur restauré) laissaient le projet au numéro de la release, donc sans nouvelle version signalée.
- ServeIPA exécute la commande `hash=$(…)` du `Scripts/build-number.sh` du projet (au plus toutes les 30 s) ; si elle diffère de l'empreinte inscrite, le build du projet publié est le numéro inscrit + 1. Sans script reconnu, le numéro inscrit est gardé. Les projets sans `.build-number` ne sont pas concernés.

## 2026-11-28 — Build commité et poussé

- `GET /api/v1/apps` publie `lastCommitBuild` et `lastPushBuild` (jamais la version marketing) : numéro de build lu dans le commit concerné (`.build-number`, `BuildNumber.swift`, sinon `CURRENT_PROJECT_VERSION` pour les projets sans compteur).
- Quand `.build-number` n'est pas suivi par git, ServeIPA retient le numéro d'un commit s'il l'observe avec un dossier sans modification et un compteur correspondant aux sources (`commitBuilds`, 500 au plus). Les commits antérieurs sans numéro n'affichent que la date.

## 2026-11-28 — Délai de détection d'un projet plus récent

- Causes : empreinte réutilisée 30 s, numéros publiés seulement après la lecture git de tous les projets (plusieurs secondes), mise à jour du serveur cherchée toutes les 60 s, liste relue par le client environ toutes les minutes.
- Désormais : empreinte réutilisée 8 s, numéros publiés avant les dates git (relevées à part, toutes les 30 s), recherche de mise à jour toutes les 10 s, et `catalogRevision` dans `GET /api/v1/builds` qui fait relire la liste au client dès qu'elle change.

## 2026-11-28 — Bandeaux de mise à jour d'après la liste des apps

- Le bandeau du client paraît dès que la release ou le projet du client dépasse le build en cours ; son bouton compile d'abord si le projet est en avance.
- Le bandeau du serveur paraît dès qu'une release ou un projet de ServeIPA/client dépasse le build du serveur (compteur commun), sans attendre `serverUpdate`, qui reste le motif par défaut.

## 2026-11-28 — Commit et push depuis le client

- Menu « … » du dernier build : « Stage et commit… » et « Stage, commit et push… », avec saisie du message.
- `POST /api/v1/git?app=…&message=…&push=0|1` : `git add -A` et commit limités au dossier du projet, puis `git push` sur la branche courante. Sans changement, le push est tout de même tenté. Aucune demande de mot de passe possible ; chaque commande est interrompue après 90 s.
- Refusé pendant une compilation et pendant un prompt rClaude sur le projet (menu grisé, contrôle refait par le serveur juste avant git ; ServeIPA et son client se bloquent mutuellement). Comme les autres routes, sans authentification propre : les ACL du tailnet sont le seul contrôle d'accès.

## 2026-11-28 — La baguette magique commite et pousse

- En dernière étape, pour chaque dossier de projet des apps servies : `git add -A` limité au dossier, commit « Build N », puis push si la branche suit une branche distante. Ignorés : hors dépôt, prompt rClaude en cours, recompilation échouée.
- Déclenché par la baguette de ServeIPA et par celle du client (`POST /api/v1/maintenance?git=1`). La compilation de nuit et les anciens clients ne commitent rien.

## 2026-11-28 — Client en attente pendant la mise à jour du serveur

- Tant que le serveur se met à jour (en file ou en cours), le client ne peut pas être installé : bandeau et bouton Installer grisés, mise à jour groupée et liens refusés pour lui. La compilation reste possible.

## 2026-11-28 — Emplacements des projets mémorisés

- La détection des builds plus récents réutilise l'emplacement trouvé (5 min ; 1 min pour une app sans projet ; recherche immédiate si le projet a disparu). Recompilation, commit et push refont toujours la recherche.
