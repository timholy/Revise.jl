@deprecate relocatable!(ex::Expr) RelocatableExpr(ex)
@deprecate relocatable!(ex::RelocatableExpr) ex
@deprecate get_method whichtt
Base.@deprecate_binding FileModules ModuleExprsSigs
@deprecate firstlineno(ex) firstline(ex).line
