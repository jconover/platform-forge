const { createBackend } = require('@backstage/backend-defaults');

const backend = createBackend();

backend.add(require('@backstage/plugin-app-backend'));
backend.add(require('@backstage/plugin-catalog-backend'));
backend.add(require('@backstage/plugin-catalog-backend-module-github'));
backend.add(require('@backstage/plugin-proxy-backend'));
backend.add(require('@backstage/plugin-search-backend'));
backend.add(require('@backstage/plugin-search-backend-module-catalog'));
backend.add(require('@backstage/plugin-techdocs-backend'));
backend.add(require('@backstage/plugin-kubernetes-backend'));

backend.start();
