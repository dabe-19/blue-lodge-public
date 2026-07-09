---
name: 'Python Standards'
description: 'Python coding conventions, strict typing, and modern idioms'
applyTo: '**/*.py'
---
# Python Coding Standards

- **Strict Contracts**: Use the `abc` module (`ABC`, `@abstractmethod`) to create strict interfaces for base classes. Ensure concrete child classes fully implement required methods.
- **Type Hinting**: Include comprehensive type hints for all function arguments and return types. Use modern typing features (e.g., `list[str]`, `str | None` for Python 3.10+).
- **Data Structures**: Use `@dataclass` or `pydantic` models for pure data-holding objects instead of standard dictionaries or raw classes.
- **Asynchronous Processing**: Ensure correct usage of `async`/`await`. Avoid blocking standard library I/O calls within `async` event loops.
- **Comprehensions**: Favor list, dict, and set comprehensions over standard `for` loops for simple mapping and filtering, but prioritize readability.
- **Docstrings**: Use PEP 257 compliant docstrings for all modules, classes, and public functions. Include type information in docstrings if not using type hints.
- **Error Handling**: Use specific exception types and avoid catching broad exceptions. Ensure all exceptions are properly logged or handled to prevent silent failures.
- **Code Formatting**: Adhere to PEP 8 for code style. Use tools like `black` for automatic code formatting and `flake8` for linting to maintain consistency across the codebase.
- **Testing**: Write unit tests for all new code using `unittest` or `pytest`. Ensure tests cover edge cases and are included in the CI pipeline for continuous validation.