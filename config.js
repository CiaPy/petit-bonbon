// =====================================================================
// Petit Bonbon — configuration
// Remplace les valeurs ci-dessous (voir README.md, étapes 2 à 4).
// Tout ce qui est ici est PUBLIC par nature : ne mets JAMAIS la clé
// « service_role » de Supabase ni une clé secrète Stripe dans ce fichier.
// =====================================================================
window.PB_CONFIG = {
  // Supabase › Project Settings › API › Project URL
  SUPABASE_URL: "https://uyantfocqwhrqzqlqgah.supabase.co",

  // Supabase › Project Settings › API › anon public key
  SUPABASE_ANON_KEY: "sb_publishable_a6PyUzv-Mtdi40BZ_uvrUQ_jJPLcyzp",

  // Stripe › Liens de paiement › ton lien à 0,99 € (ex. https://buy.stripe.com/xxxx)
  // Laisse vide tant que Stripe n'est pas prêt : l'écran de paiement le signalera.
  STRIPE_PAYMENT_LINK: "",

  // Adresse affichée pour le contact et les signalements urgents
  CONTACT_EMAIL: "petitbonbon-app@proton.me",
};
