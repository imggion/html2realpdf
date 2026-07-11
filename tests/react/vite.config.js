import { fileURLToPath, URL } from "node:url";

const repositoryRoot = fileURLToPath(new URL("../..", import.meta.url));

export default {
  resolve: {
    alias: {
      "@imggion/html2realpdf": fileURLToPath(new URL("../../bindings/js/dist/index.js", import.meta.url)),
    },
  },
  server: {
    fs: {
      allow: [repositoryRoot],
    },
  },
};
