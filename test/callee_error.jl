module CalleeError

inner(A, i) = A[i]
function outer(A)
    s = zero(eltype(A))
    for i = 1:length(A)+1
        s += inner(A, i)
    end
    return s
end

s = outer([1,2,3])

foo(x::Float32) = 1

end
