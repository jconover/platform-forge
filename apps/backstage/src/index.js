const backend = require('@backstage/backend-defaults').createBackend();

// Core plugins
backend.add(require('@backstage/plugin-app-backend').default);
backend.add(require('@backstage/plugin-catalog-backend').catalogPlugin);
backend.add(
  require('@backstage/plugin-catalog-backend-module-github').catalogModuleGithubEntityProvider,
);
backend.add(require('@backstage/plugin-proxy-backend').proxyPlugin);
backend.add(require('@backstage/plugin-scaffolder-backend').scaffolderPlugin);
backend.add(require('@backstage/plugin-search-backend').searchPlugin);
backend.add(
  require('@backstage/plugin-search-backend-module-catalog').searchModuleCatalogCollator,
);
backend.add(require('@backstage/plugin-techdocs-backend').techdocsPlugin);
backend.add(require('@backstage/plugin-kubernetes-backend').kubernetesPlugin);

backend.start();
