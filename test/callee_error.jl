module CalleeError

inner(A, i) = A[i]
function outer(A)
    s = zero(eltype(A))
    for i = 1:length(A)+1
        s += inner(A, i)
    end
    return s
end

s = outer([1,2,3])            # compiled mode
s2 = eval(:(outer([1,2,3])))  # interpreted mode

foo(x::Float32) = 1   # this line is tested for being on line number 14

end
