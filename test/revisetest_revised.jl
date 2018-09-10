__precompile__(false)

module ReviseTest

square(x) = x^2

cube(x) = x^3

fourth(x) = x^4  # this is an addition to the file

module Internal

mult2(x) = 2*x
mult3(x) = 3*x

"""
This has a docstring
"""
unchanged(x) = x

unchanged2(@nospecialize(x)) = x

end  # Internal

end
