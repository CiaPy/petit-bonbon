# Petit Bonbon

**Des inconnus. Des compliments. Aucune pression.**

Application web installable (PWA) : on choisit une identité du jour, on découvre les personnes présentes dans la même ville, et on leur envoie un compliment choisi dans une liste. **L'app de base est gratuite** ; les options (messages perso, vocaux, photos, musique, liens) seront réservées à un abonnement Premium, pas encore développé.

Coût fixe : **0 €** — GitHub Pages (hébergement), Supabase offre gratuite (comptes et base de données), Stripe (commission uniquement à chaque vente).

---

## Mise en ligne, pas à pas

### 1. Activer GitHub Pages (1 min)
Dépôt › **Settings** › **Pages** › *Build and deployment* › Source : **Deploy from a branch** › Branche **main**, dossier **/ (root)** › **Save**.

L'app sera en ligne à l'adresse **https://petitbonbon.github.io/petit-bonbon/** (1 à 2 minutes après).

### 2. Créer la base Supabase (5 min)
1. Sur [supabase.com](https://supabase.com), **New project**. Région : **Europe** (ou un pays de l’UE). Note le mot de passe de la base quelque part.
2. **SQL Editor** › **New query** › colle tout le contenu de `supabase/schema.sql` › **Run**. Le message doit être *Success*.
3. **Authentication** › **Sign In / Providers** : active **Allow anonymous sign-ins** et enregistre.
   *Pourquoi :* Petit Bonbon s'utilise sans compte. Chaque appareil reçoit un identifiant anonyme invisible, qui suffit pour les bonbons, les blocages, les signalements et le paiement. Un vrai compte (e-mail) ne servira que pour le futur Premium.
   *Conseillé ensuite :* **Authentication › Attack Protection** › active une protection CAPTCHA (Cloudflare Turnstile, gratuit) pour limiter la création d'identifiants en masse.
4. **Authentication** › **URL Configuration** : *Site URL* = `https://petitbonbon.github.io/petit-bonbon/`, et ajoute la même adresse dans *Redirect URLs*.
5. **Project Settings** › **API** : copie **Project URL** et la clé **anon public** dans `config.js`.
   ⚠️ Ne mets **jamais** la clé `service_role` dans `config.js` : ce fichier est public.

### 3. Créer le paiement Stripe (10 min)
> **À faire plus tard.** L'app de base est gratuite (`paywall_enabled = false`). Les étapes 3 et 4 ne servent que si tu veux un jour rendre l'entrée payante ; l'abonnement Premium demandera un autre branchement Stripe (abonnement mensuel).

1. Crée ton compte sur [stripe.com](https://stripe.com) et complète la vérification d'identité.
2. **Catalogue de produits** › **Ajouter un produit** : « Accès Petit Bonbon », **0,99 €**, paiement **unique**.
3. **Liens de paiement** › **Nouveau** › ce produit. Dans les options :
   - *Après le paiement* › **Ne pas afficher de page de confirmation, rediriger vers votre site** : `https://petitbonbon.github.io/petit-bonbon/?paid=1`
   - **Exiger que les clients acceptent vos conditions d'utilisation** (renseigne l'adresse de `cgu.html` dans les paramètres publics Stripe), et ajoute ce texte personnalisé :
     *« Je demande l'activation immédiate de mon accès et je renonce à mon droit de rétractation. »*
4. Copie le lien (`https://buy.stripe.com/…`) dans `config.js` › `STRIPE_PAYMENT_LINK`.

### 4. Débloquer l'accès après paiement (10 min)
1. Supabase › **Edge Functions** › **Deploy a new function** › **Via Editor**. Nom : `stripe-webhook`. Colle le contenu de `supabase/functions/stripe-webhook/index.ts` › **Deploy**.
2. Dans les détails de la fonction, désactive **Verify JWT** (Stripe n'envoie pas de jeton Supabase ; la sécurité vient de la signature Stripe).
3. Stripe › **Développeurs** › **Webhooks** › **Ajouter une destination** :
   - URL : `https://<ID-DU-PROJET>.supabase.co/functions/v1/stripe-webhook`
   - Événements : `checkout.session.completed` et `checkout.session.async_payment_succeeded`
4. Copie le **secret de signature** (`whsec_…`) › Supabase › **Edge Functions** › **Secrets** › nouveau secret `STRIPE_WEBHOOK_SECRET`.
5. Teste avec un vrai paiement de 0,99 € : l'écran de paiement doit disparaître tout seul.

### 5. Compléter les pages légales
Remplace les `[CROCHETS]` dans `mentions-legales.html`, `cgu.html` et `confidentialite.html`, et mets ton adresse de contact dans `config.js`. Vendre suppose un statut (ex. micro-entreprise) et un numéro SIRET. Fais relire ces textes avant de lancer à grande échelle.

---

## Pilotage au quotidien (Supabase › SQL Editor)

```sql
-- Ouvrir l'app gratuitement (soirée de lancement, événement…)
update app_settings set paywall_enabled = false;
-- …et refermer
update app_settings set paywall_enabled = true;

-- Changer le nombre de bonbons par jour
update app_settings set daily_send_limit = 15;

-- Nombre de personnes nécessaires dans une ville pour ouvrir « Découvrir » (2 par défaut)
update app_settings set min_city_people = 2;

-- Bonbons max vers une même personne sur 7 jours (2 par défaut)
update app_settings set weekly_pair_limit = 2;

-- Signalements à traiter
select created_at, reason, pseudo_seen, bio_seen, reported_id
from reports where not handled order by created_at desc;

-- Lever une suspension (après vérification)
update profiles set banned = false where id = '<reported_id>';
update reports set handled = true where reported_id = '<reported_id>';

-- Offrir l'accès à tout le monde pendant les tests : voir paywall_enabled ci-dessus.
-- (Sans compte, il n'y a pas d'e-mail pour retrouver une personne précise.)

-- Chiffres du jour
select (select count(*) from profiles where paid_at is not null) as payants,
       (select count(*) from sessions where expires_at > now())   as connectes,
       (select count(*) from bonbons where created_at > now() - interval '24 hours') as bonbons_24h;
```

## Sécurité, en bref
- Aucune table n'est lisible directement depuis le navigateur : tout passe par des fonctions qui vérifient l'appelant et ne renvoient que le nécessaire. Les identifiants des autres utilisateurs ne sortent jamais de la base.
- Compliments uniquement choisis dans une liste (pas de texte libre). Le pseudo et la phrase de présentation sont libres mais courts, et signalables.
- Signaler bloque définitivement dans les deux sens ; 3 signalements distincts en 30 jours suspendent le compte.
- 10 bonbons par jour maximum, un seul par personne et par jour.
- Ville uniquement, jamais de position GPS. Identité du jour effacée après 12 h.

## Structure
```
index.html, style.css, app.js   l'application
config.js                       réglages publics (Supabase, Stripe, contact)
manifest.webmanifest, sw.js     installation sur l'écran d'accueil
cgu.html, confidentialite.html, mentions-legales.html
supabase/schema.sql             base de données et règles de sécurité
supabase/functions/stripe-webhook/index.ts   déblocage après paiement
```

**Ajouter des compliments :** ajoute-les **à la fin** de la liste `COMPLIMENTS` dans `app.js` (12 maximum ; la base stocke leur numéro).

---

## Feuille de route Premium (pas encore développé)

Options prévues : message personnalisé, note vocale, photo éphémère, musique, lien (2,99 €/mois, compte avec e-mail requis).

**Règles décidées pour les photos**
- **Éphémère, 10 secondes** : une photo reçue s'ouvre une seule fois, reste visible 10 secondes (avec un compte à rebours), puis elle est supprimée définitivement du serveur. Aucune galerie, aucun enregistrement, aucune réouverture. Une photo jamais ouverte est supprimée automatiquement au bout de 24 heures.
- **Yeux masqués par défaut** : avant l'envoi, l'app détecte les visages *sur le téléphone* (ex. MediaPipe Face Landmarker, gratuit, fonctionne dans le navigateur) et pixelise une bande sur les yeux, dans le style pixel de l'app. La photo d'origine ne quitte jamais l'appareil : seule la version filtrée est envoyée.
- **Aperçu obligatoire avant envoi** : la détection peut rater un visage (profil, lunettes, faible lumière). La personne voit le résultat et peut ajouter une bande à la main, ou pixeliser tout le visage.
- **Retirer le filtre** est possible, mais doit rester un choix volontaire à chaque envoi, jamais un réglage permanent.
- **Modération** : filtrage automatique de la nudité avant réception, signalement en un geste, et suppression des métadonnées (position GPS de la photo, modèle de téléphone).
