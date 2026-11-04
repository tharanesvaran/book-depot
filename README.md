# College Book Depot

Stationery management for a college depot: students request items and collect at the counter with a barcode ID; admins handle stock, prices, billing, walk-in sales and monthly reports.

Static site (no build step) + Supabase (Postgres, Google sign-in) + Vercel.

## Setup (about 20 minutes)

### 1. Database
1. Create a project at supabase.com.
2. **SQL Editor -> New query**, paste all of `supabase/schema.sql`, click **Run**.
3. Make yourself an admin (use your Google email, lowercase), in a new query:
   ```sql
   insert into public.admins(email) values ('you@gmail.com');
   ```
   Add more admins the same way. Remove one with `delete from public.admins where email = '...'`.

### 2. Connect the site
Open `config.js` and paste your **Project URL** and **anon public key** (Supabase -> Project Settings -> API). The anon key is meant to be public. Never use the `service_role` key.

### 3. Google sign-in
1. Google Cloud Console -> **APIs & Services -> OAuth consent screen**: choose External, fill in app name and support email, then click **Publish app** (set it to *In production*). If you skip this, only listed test users can sign in.
2. **Credentials -> Create credentials -> OAuth client ID -> Web application**.
   - Authorized JavaScript origins: `https://YOUR-APP.vercel.app` (and `http://localhost:3000` for testing).
   - Authorized redirect URI: `https://YOUR-PROJECT-REF.supabase.co/auth/v1/callback` (Supabase shows the exact URL on the Google provider page).
3. Supabase -> **Authentication -> Providers -> Google**: enable it and paste the Client ID and Client Secret.
4. Supabase -> **Authentication -> URL Configuration**:
   - Site URL: `https://YOUR-APP.vercel.app`
   - Redirect URLs: add `https://YOUR-APP.vercel.app` and `https://YOUR-APP.vercel.app/**` (plus `http://localhost:3000` for testing).

### 4. GitHub and Vercel
1. Push this folder to a GitHub repository.
2. Vercel -> **Add New -> Project** -> import the repo. Framework preset **Other**; leave build command and output directory empty. Deploy.
3. Use the Vercel URL in steps 3.2 and 3.4 above if you have not already.

### Test locally
```
python3 -m http.server 3000
```
then open http://localhost:3000

## How access works
- Anyone can sign in with Google. If the email is in `admins` they get the admin console; otherwise they register once as a student.
- The browser can only read data it is allowed to see (students see their own profile and orders; admins see everything).
- All changes (orders, billing, stock, prices, balances) go through database functions that check the caller is allowed, so stock and balances cannot be edited from the browser.
- Billing, walk-in sales and restocks run as single database transactions, so two admins cannot double-bill a request or oversell stock.

## Limits to know about
- Any Google account can register as a student (no roll-number registry check yet).
- Admin pages load the latest 1,000 orders and 1,000 restocks.
- Pages do not update live; they refresh when you return to the tab or act on something.
