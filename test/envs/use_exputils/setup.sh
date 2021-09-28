#!/bin/bash

# Ensure that packages that get updated indirectly by external
# manifest updates work as well as can be hoped.
# See https://github.com/timholy/Revise.jl/issues/647

# Install and compile two versions of ExponentialUtilities
dn=$(dirname "$BASH_SOURCE")
julia $dn/install.jl "1.10.0"
julia $dn/install.jl "1.9.0"
