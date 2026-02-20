# ReVISit study – Interactive, Web-Based User Studies.

Create your own interactive, web-based data visualization user studies by cloning/forking and editing configuration files and adding stimuli in the `public` folder.

ReVISit introduces reVISit.spec, a DSL for specifying study setups (consent forms, training, trials, etc.) for interactive web based studies. You describe your experimental setup in reVISit.spec, add your stimuli as images, forms, HTML pages, or React components, build and deploy — and you're ready to run your study. For tutorials and documentation, see the [reVISit website](https://revisit.dev).

## Paper

If you are using reVISit for a paper, please cite:

> Zach Cutler, Jack Wilburn, Hilson Shrestha, Yiren Ding, Brian Bollen, Khandaker Abrar Nadib, Tingying He, Andrew McNutt, Lane Harrison, Alexander Lex. [ReVISit 2: A Full Experiment Life Cycle User Study Framework](https://www.visdesignlab.net/publications/2025_vis_revisit/). IEEE Transactions on Visualization and Computer Graphics (VIS), 32(1): 13-23, [doi:10.1109/TVCG.2025.3633896](https://dx.doi.org/10.1109/TVCG.2025.3633896), 2026.

**IEEE VIS 2025 Best Paper Award**

GitHub citation metadata for this repository is available in [CITATION.cff](./CITATION.cff).

## Local development (native)

1. Install Node + Yarn.
2. Install dependencies:

	`yarn install`

3. Run the frontend dev server:

	`yarn serve`

4. Open [http://localhost:8080](http://localhost:8080).

### Optional: local Supabase for native dev

1. Start Supabase services (with local ports):

	`docker network inspect revisit_net >/dev/null 2>&1 || docker network create revisit_net`

	`docker compose -f supabase/docker-compose.yml -f supabase/docker-compose.local.yml --env-file supabase/.env up -d`

2. Point your local Vite app to Kong by setting:

	`VITE_STORAGE_ENGINE="supabase"`

	`VITE_SUPABASE_URL="http://localhost:8000"`

	`VITE_SUPABASE_ANON_KEY="<same value as ANON_KEY in supabase/.env>"`

## Full local Docker workflow

This runs app + reverse proxy + Supabase in containers.

1. Create shared network once:

	`docker network inspect revisit_net >/dev/null 2>&1 || docker network create revisit_net`

2. Start Supabase stack:

	`docker compose -f supabase/docker-compose.yml --env-file supabase/.env up -d`

3. Start app + Caddy proxy:

	`VITE_SUPABASE_ANON_KEY="<ANON_KEY from supabase/.env>" docker compose -f docker-compose.local.yml --env-file deploy/.env.local.example up -d --build`

4. Open:
	- App: [http://localhost:8080](http://localhost:8080)
	- API base: `http://api.localhost:8080`

If `api.localhost` does not resolve on your machine, add `127.0.0.1 api.localhost` to your hosts file.

## Production Docker deployment (DigitalOcean/VM)

This setup uses two public domains:
- Study UI: `study.<your-domain>`
- Supabase API gateway: `api.<your-domain>`

1. Copy and edit env templates:
	- `cp deploy/.env.prod.example deploy/.env.prod`
	- Update `deploy/.env.prod` with real domains.
	- Update `supabase/.env` with strong secrets and production URLs.

2. Ensure these Supabase values match your domains:
	- `SITE_URL=https://<study-domain>`
	- `API_EXTERNAL_URL=https://<api-domain>`
	- `SUPABASE_PUBLIC_URL=https://<api-domain>`

3. Create shared network:

	`docker network inspect revisit_net >/dev/null 2>&1 || docker network create revisit_net`

4. Start Supabase services:

	`docker compose -f supabase/docker-compose.yml --env-file supabase/.env up -d`

5. Build/start app + reverse proxy:

	`VITE_SUPABASE_ANON_KEY="<ANON_KEY from supabase/.env>" docker compose -f docker-compose.prod.yml --env-file deploy/.env.prod up -d --build`

6. Open firewall only for `80/443` publicly. Keep admin/internal ports private.

## Notes

- The app image now serves SPA routes correctly via nginx fallback to `index.html`.
- Production Docker build forces `VITE_BASE_PATH=/`.
- Configure your root app `.env` / build args for `VITE_STORAGE_ENGINE`, `VITE_SUPABASE_URL`, and `VITE_SUPABASE_ANON_KEY` to match your deployment.
