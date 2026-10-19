(function () {
  const config = window.CAMPUSNEST_CONFIG || {};
  const ready = window.supabase &&
    /^https:\/\/[a-z0-9-]+\.supabase\.co$/i.test(config.supabaseUrl || '') &&
    config.publishableKey && config.publishableKey !== 'YOUR_SUPABASE_PUBLISHABLE_KEY';
  window.campusNestBackendReady = Boolean(ready);
  window.campusNestClient = ready
    ? window.supabase.createClient(config.supabaseUrl, config.publishableKey)
    : null;
})();
