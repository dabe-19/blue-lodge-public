---
name: 'Backend API Standards'
description: 'RESTful conventions, middleware, and request handling'
applyTo: '**/*Controller*.{cs,ts,js,py,go,rs,java,kt}, **/*Handler*.{cs,ts,js,py,go,rs,java,kt}, **/*Api*.{cs,ts,js,py,go,rs,java,kt}, **/routes/**/*.{ts,js,py,go,rs}, **/endpoints/**/*.{ts,js,py,go,rs}'
---
# Backend & API Standards

- **Statelessness**: Ensure API endpoints remain strictly stateless. All information necessary to process a request must be contained within the request itself (headers, tokens, payload).
- **Resource Naming (REST)**: Use nouns, not verbs, for endpoint paths (e.g., `POST /users`, not `POST /createUser`). Use standard HTTP methods correctly (GET for read, POST for create, PUT/PATCH for update, DELETE for removal).
- **Cross-Cutting Concerns**: Handle authentication, authorization, global error catching, and logging at the middleware/interceptor layer, keeping controllers and handlers clean.
- **Status Codes**: Return appropriate HTTP status codes (200 OK, 201 Created, 400 Bad Request, 401 Unauthorized, 403 Forbidden, 404 Not Found, 500 Internal Server Error). Do not return `200 OK` with an error message in the payload.