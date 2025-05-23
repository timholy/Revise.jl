module CodeManagement

export RelocatableExpr, LineSkippingIterator, ExprsSigs, ModuleExprsSigs, FileInfo, PkgFiles, PkgData
export firstline, unwrap, pushex!, srcfiles, basedir, fileindex, hasfile, fileinfo

using Base: PkgId, isexpr
using OrderedCollections: OrderedDict

function srcfiles end
function basedir end

include("relocatable_exprs.jl")
include("exprsigs.jl")
include("fileinfo.jl")
include("pkgfiles.jl")
include("pkgdata.jl")

end # module CodeManagement
