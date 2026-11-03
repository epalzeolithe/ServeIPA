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
- IPA existants inspectés : iMetar déclare `imetar` (activé dans le client). FlightWall, NZBPad et iABView ne déclarent aucun schéma ; ajouter CFBundleURLTypes dans leurs projets puis produire de nouveaux IPA pour permettre leur ouverture depuis ServeIPAClient.
- Le suivi OTA est persisté localement et repris au retour dans le client. Le téléchargement de fichier utilise une session standard ; une reprise garantie après fermeture forcée nécessiterait une URLSession de fond.

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
