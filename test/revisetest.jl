__precompile__(false)

module ReviseTest

square(x) = x^2

cube(x) = x^4  # should be x^3, but this simulates a mistake

module Internal

mult2(x) = 2*x
mult3(x) = 4*x  # oops
mult4(x) = -x

"""
This has a docstring
"""
unchanged(x) = x

unchanged2(@nospecialize(x)) = x

end  # Internal

end  # ReviseTest
