# ---- build ----
FROM node:20-alpine AS build
WORKDIR /app
COPY package.json yarn.lock ./
RUN yarn install --frozen-lockfile
COPY . .
ARG VITE_BASE_PATH=/
ARG VITE_SUPABASE_URL=__UNSET__
ARG VITE_SUPABASE_ANON_KEY=__UNSET__
RUN export VITE_BASE_PATH="$VITE_BASE_PATH" \
	&& if [ "$VITE_SUPABASE_URL" != "__UNSET__" ]; then export VITE_SUPABASE_URL="$VITE_SUPABASE_URL"; fi \
	&& if [ "$VITE_SUPABASE_ANON_KEY" != "__UNSET__" ]; then export VITE_SUPABASE_ANON_KEY="$VITE_SUPABASE_ANON_KEY"; fi \
	&& NODE_OPTIONS="--max-old-space-size=4096" yarn build

# ---- serve static ----
FROM nginx:alpine
COPY --from=build /app/dist /usr/share/nginx/html
COPY ./deploy/nginx.conf /etc/nginx/conf.d/default.conf
