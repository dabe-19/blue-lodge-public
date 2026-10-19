---
trigger: glob
globs:**/{*Dockerfile*,*.dockerfile,Containerfile,.dockerignore,{docker-compose,compose}*.{yml,yaml}}:wq
---

# Docker & Containerization Standards

- **Multi-Stage Builds**: Use multi-stage builds in Dockerfiles to compile code/assets in one stage and copy only the necessary artifacts to a minimal runtime image, keeping final image sizes small.
- **Specific Tags**: Never use the `:latest` tag for base images. Always specify explicit version tags (e.g., `node:18-alpine`, `python:3.11-slim`) to ensure reproducible builds.
- **Least Privilege**: Avoid running containers as the `root` user. Create a dedicated application user within the Dockerfile and switch to it using the `USER` directive before the `CMD` or `ENTRYPOINT`.
- **Caching Optimization**: Order Dockerfile commands from least frequently changed (e.g., copying package manifests and installing dependencies) to most frequently changed (e.g., copying source code) to maximize layer caching.
