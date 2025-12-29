module test_visit

using Revise, Test

function record_invalidations_for_type_deletion(@nospecialize oldtype)
    reeval_list = IdSet{Union{Method,Type}}()
    handled_types = IdSet{Type}()
    alltypes = Revise.collect_all_subtypes(Any)
    Revise.record_invalidations_for_type_deletion!(oldtype, reeval_list, handled_types, alltypes)
    return reeval_list
end

struct TestVisitInner1; x::Int; end
struct TestVisit1; x::TestVisitInner1; end
func_test_visit1(::TestVisit1) = nothing
let oldtype = TestVisitInner1
    reeval_list = record_invalidations_for_type_deletion(oldtype)
    @test TestVisit1 in reeval_list
    for m in methods(TestVisit1)
        @test m in reeval_list
    end
    m = only(methods(func_test_visit1, (TestVisit1,)))
    @test m in reeval_list
end

abstract type TestVisitAbs2 end
struct TestVisitInner2 <: TestVisitAbs2; x::Int; end
struct TestVisit2; x::TestVisitInner2; end
func_test_visit_abs2(::TestVisitAbs2) = nothing
func_test_visit2(::TestVisit2) = nothing
let oldtype = TestVisitInner2
    reeval_list = record_invalidations_for_type_deletion(oldtype)
    @test TestVisit2 in reeval_list
    @test TestVisitAbs2 ∉ reeval_list
    for m in methods(TestVisit2)
        @test m in reeval_list
    end
    let m = only(methods(func_test_visit_abs2, (TestVisitAbs2,)))
        @test m ∉ reeval_list
    end
    let m = only(methods(func_test_visit2, (TestVisit2,)))
        @test m in reeval_list
    end
end
let oldtype = TestVisitAbs2
    reeval_list = record_invalidations_for_type_deletion(oldtype)
    @test TestVisit2 in reeval_list
    for m in methods(TestVisit2)
        @test m in reeval_list
    end
    @test TestVisitInner2 in reeval_list
    for m in methods(TestVisitInner2)
        @test m in reeval_list
    end
    let m = only(methods(func_test_visit_abs2, (TestVisitAbs2,)))
        @test m in reeval_list
    end
    let m = only(methods(func_test_visit2, (TestVisit2,)))
        @test m in reeval_list
    end
end

abstract type TestVisitAbs3 end
struct TestVisitInner3{T} <: TestVisitAbs3; x::T; end
struct TestVisit3{T<:TestVisitInner3}; x::T; end
func_test_visit_abs3(::TestVisitAbs3) = nothing
func_test_visit3(::TestVisit3) = nothing
let oldtype = TestVisitAbs3
    reeval_list = record_invalidations_for_type_deletion(oldtype)
    @test TestVisit3 in reeval_list
    for m in methods(TestVisit3)
        @test m in reeval_list
    end
    @test TestVisitInner3 in reeval_list
    for m in methods(TestVisitInner3)
        @test m in reeval_list
    end
    let m = only(methods(func_test_visit_abs3, (TestVisitAbs3,)))
        @test m in reeval_list
    end
    let m = only(methods(func_test_visit3, (TestVisit3,)))
        @test m in reeval_list
    end
end

abstract type TestVisitAbs4 end
struct TestVisitInner4{T} <: TestVisitAbs4; x::T; end
struct TestVisit4; xs::Vector{<:TestVisitInner4}; end
func_test_visit_abs4(::TestVisitAbs4) = nothing
func_test_visit4(::TestVisit4) = nothing
let oldtype = TestVisitAbs4
    reeval_list = record_invalidations_for_type_deletion(oldtype)
    @test TestVisit4 in reeval_list
    for m in methods(TestVisit4)
        @test m in reeval_list
    end
    @test TestVisitInner4 in reeval_list
    for m in methods(TestVisitInner4)
        @test m in reeval_list
    end
    let m = only(methods(func_test_visit_abs4, (TestVisitAbs4,)))
        @test m in reeval_list
    end
    let m = only(methods(func_test_visit4, (TestVisit4,)))
        @test m in reeval_list
    end
end

end # test_visit
