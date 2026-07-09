---
name: 'Backend API & Logic Standards'
description: 'FastAPI/Python routing, schema validation, and business logic separation'
applyTo: '{api,backend,server,services,app,src}/**/*.py, **/routers/**/*.py, **/handlers/**/*.py, **/views/**/*.py'
---
# Backend API & Data Modeling Standards

- **Layered Architecture**: Keep route handlers (`main.py` or API routers) extremely thin. They should only handle HTTP concerns (parsing requests, returning status codes). Push all core business rules into dedicated modules (e.g., the `logic/` directory).
- **Data Validation vs. Database Models**: Maintain a strict separation between Data Transfer Objects/Validation (e.g., Pydantic schemas in `schemas.py`) and Database Object Relational Mapping (e.g., SQLAlchemy models in `models.py`). Never expose raw DB models directly to the API response without passing through a schema.
- **Stateless Routing**: Ensure API endpoints remain strictly stateless. State should be managed in the database or client, not in backend memory.
- **Error Handling**: Catch expected domain exceptions in the logic layer, but map them to appropriate HTTP exceptions (e.g., 400 Bad Request, 404 Not Found) at the routing layer.