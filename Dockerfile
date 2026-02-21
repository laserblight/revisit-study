# ---- build ----
FROM node:20-alpine AS build
WORKDIR /app
COPY package.json yarn.lock ./
RUN sed -i 's#https://registry.yarnpkg.com/#https://registry.npmjs.org/#g' yarn.lock \
	&& yarn config set network-timeout 600000 -g \
	&& yarn config set registry https://registry.npmjs.org -g \
	&& (yarn install --frozen-lockfile --network-timeout 600000 || yarn install --frozen-lockfile --network-timeout 600000)
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
EXPOSE 80
COPY --from=build /app/dist /usr/share/nginx/html
COPY ./deploy/nginx.conf /etc/nginx/conf.d/default.conf
