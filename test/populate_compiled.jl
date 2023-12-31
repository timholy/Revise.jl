# This runs only on CI. The goal is to populate the `.julia/compiled/v*` directory
# with some additional files, so that `filter_valid_cachefiles` has to run.
# This is to catch problems like #460.

using Pkg
using Test

Pkg.add(PackageSpec(name="EponymTuples", version="0.2.0"))
using EponymTuples  # force compilation
id = Base.PkgId(EponymTuples)
paths = Base.find_all_in_cache_path(id)
Pkg.rm("EponymTuples") # we don't need it anymore
path = first(paths)
base, ext = splitext(path)
mv(path, base*"blahblah"*ext; force=true)
Pkg.add(PackageSpec(name="EponymTuples"))
