# CampusNest

Student rental discovery for Moi University. Source files stay in this repository. GitHub Pages can host the public static front end; Supabase provides shared accounts, verification, listings, rooms, and photos.

## Current state

- Browser-only simulations and fictional rental listings have been removed. Pages require a configured Supabase project to accept landlord requests, authenticate accounts, or show actual listings. Until configured, forms and listing management stay unavailable.
- `supabase/schema.sql` is the first shared-backend foundation. It includes RLS-protected tables, approval and KSh 200 payment gates before account creation, monthly subscription expiry checks, approved-listing visibility, and an image bucket limited to ordinary rental photos.
- Payment confirmation is intentionally not automated yet. A real M-Pesa integration needs a server-side function and Safaricom Daraja credentials. Never put service-role keys, payment secrets, or verification documents in a public HTML file or GitHub repository.
- No landlord ID, title deed, or private verification evidence should be uploaded to the public property-photo bucket. Verification should be done through a private review process.

## Set up the shared backend

1. Create a Supabase project and keep its database password private.
2. In the Supabase SQL Editor, run `supabase/schema.sql` once.
3. Configure Auth to allow your production GitHub Pages URL and local development URL. Require verified email addresses before sign-in.
4. Before the first reviewer signs up, add their verified email in the SQL Editor: `insert into public.admin_allowlist(email) values ('reviewer@example.com');`. The trigger grants the admin role once to that address. Remove or change this allowlist only from the SQL Editor. Never let browser users set their own admin role.
5. Put the project URL and publishable key in supabase-config.js. The publishable key can be public only because every exposed table has RLS. Never add the service-role/secret key to front-end code.
6. Configure a server-side payment flow to create and confirm KSh 200 monthly subscription payments. Do not mark a payment confirmed based only on a browser redirect.
7. Open `admin-review.html` after signing in with the allowlisted reviewer account. Check identity and property authority in person. Create a KSh 200 payment record only after approval; confirm it only after independently checking the real transaction. Tell the applicant to use the request reference in `landlord-account.html` after confirmation.
8. Landlords use `landlord-portal.html`; students use `homes.html`. Configure a secure M-Pesa callback before automating payment confirmation.

## Local entry point

Open `index.html` to reach the welcome page. For local Supabase Auth testing, serve the folder over HTTP (for example, VS Code Live Server at `http://127.0.0.1:5500/`) and add that URL to Supabase Auth redirect settings. To run this as a shared site, publish the repository using GitHub Pages from the repository root. GitHub Pages hosts static files; the database and accounts remain in Supabase.

## Publish the public website

1. In GitHub Desktop, commit the CampusNest files and push them to the `main` branch.
2. On GitHub, open this repository and select **Settings → Pages**.
3. Under **Build and deployment**, set the source to **Deploy from a branch**, choose **main** and **/(root)**, then save.
4. Wait for the Pages deployment to finish. GitHub will show the public website link in **Settings → Pages**. Open that link on a phone to view the site.

The public welcome page can load before the backend is configured. Landlord requests, landlord sign-in, and real property listings remain unavailable until Supabase is set up and its project URL and publishable key are added. Payment processing is also not connected. Do not accept real applications or payments yet.

## Before accepting real landlords

The application still needs an actual Supabase project and keys, a verified reviewer account, privacy notice and retention contact, rate limiting/abuse controls, an M-Pesa server-side callback, data deletion/support workflow, and a launch review. This is not yet a real online service and must not be presented as accepting live landlord applications or payments until these are completed. The included reviewer UI requires the admin role and the database policies enforce it; manual payment confirmation is not automated. Listings stay hidden until a reviewer approves the property and the landlord has an active subscription.

