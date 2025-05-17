Components for Extraction from Revise.jl

  CodeRepository.jl should provide a lightweight framework for representing and managing Julia code structures. The following components should be extracted from Revise.jl:

  1. Core Expression Comparison (relocatable_exprs.jl)

  The foundation of CodeRepository.jl, providing expression comparison while ignoring line numbers:

  - RelocatableExpr struct
  - LineSkippingIterator for ignoring line number nodes
  - Comparison operations (==, hash) for expression equality detection
  - Expression manipulation utilities (striplines!)

  2. Basic Data Structures (types.jl)

  Core data structures that represent code organization:

  - ExprsSigs: Maps expressions to their method signatures
  const ExprsSigs = OrderedDict{RelocatableExpr,Union{Nothing,Vector{Any}}}
  - ModuleExprsSigs: Maps modules to expression-signature mappings
  const ModuleExprsSigs = OrderedDict{Module,ExprsSigs}
  - Basic FileInfo: Structure holding expressions for a file
  struct FileInfo
      modexsigs::ModuleExprsSigs
  end
  - Basic PkgData: Structure for managing files in a package
  struct PkgData
      id::PkgId
      path::String
      fileinfos::Vector{FileInfo}
      files::Vector{String}
  end

  3. Essential Utilities (utils.jl)

  Minimal utilities needed for manipulating expressions and repositories:

  - unwrap: Returns the only non-trivial expression or itself
  - firstline: Extract line information from expressions
  - istrivial: Checks if an expression is trivial
  - Basic path utilities for file references

  4. Public API

  A minimalist API for managing code repositories:

  # Creating repositories
  create_repository(id::PkgId, path::String) -> PkgData

  # Adding files and expressions
  add_file!(repo::PkgData, filename::String, mod::Module) -> FileInfo
  add_expression!(fileinfo::FileInfo, mod::Module, expr::Expr) -> RelocatableExpr
  add_signature!(fileinfo::FileInfo, mod::Module, expr::Expr, sig::Any) -> Nothing

  # Querying repositories
  fileinfo(pkgdata::PkgData, file::String) -> FileInfo
  fileinfo(pkgdata::PkgData, i::Int) -> FileInfo

  Components to Remain in Revise.jl

  These components should remain in Revise.jl and not be extracted:

  - File watching and notification system
  - Code evaluation and diff-patching mechanisms
  - REPL integration and interactive features
  - Module tracking and code loading hooks
  - Revise-specific global variables and state management

  Implementation Notes

  1. CodeRepository.jl should have minimal dependencies:
    - OrderedCollections.jl for ordered dictionaries
  2. Type design should:
    - Provide clean separation between code representation and evaluation
    - Create extensible structures that can be subclassed in Revise.jl
    - Focus on immutable data where possible
  3. Performance considerations:
    - Efficient expression comparison for large codebases
    - Optimized hash functions for dictionary lookup
    - Minimal memory overhead for storing code representations
  4. Integration strategy:
    - Revise.jl should import and extend CodeRepository.jl types
    - Extended types can add Revise-specific fields and behaviors
    - Original function signatures should be preserved for compatibility

  By extracting these components, CodeRepository.jl will provide a focused toolkit for code representation and organization that can be used by various tools beyond Revise.jl,
  including language servers, static analyzers, and other development tools.
