---
trigger: glob
globs: **/*.{cpp,cxx,cc,c++,h,hpp,hh,hxx,inl,ipp,tpp}
---

# Modern C++ Coding Standards

- **Memory Management**: Strictly avoid raw pointers (`*`) for ownership. Use smart pointers (`std::unique_ptr` and `std::shared_ptr`) via `std::make_unique` and `std::make_shared`.
- **RAII**: Rely on Resource Acquisition Is Initialization (RAII) to manage object lifetimes, file handles, and locks.
- **Const Correctness**: Use `const` variables wherever possible. Mark class methods as `const` if they do not modify the object's state. 
- **Rule of Zero / Five**: Prefer the Rule of Zero (letting the compiler generate destructors and copy/move constructors). If you must define a custom destructor, implement or `=delete` the copy and move constructors/assignments (Rule of Five).
- **Standard Library**: Prefer `<algorithm>` (e.g., `std::transform`, `std::find_if`) over writing manual `for` loops.
