function freqresp(sys::DelayLtiSystem, ω::AbstractVector{T}) where {T <: Real}
    ny = noutputs(sys)
    nu = ninputs(sys)

    P_fr = ControlSystems.freqresp(sys.P.P, ω);

    G_fr = zeros(eltype(P_fr), length(ω), ny, nu)

    for ω_idx=1:length(ω)
        P11_fr = P_fr[ω_idx, 1:ny, 1:nu]
        P12_fr = P_fr[ω_idx, 1:ny, nu+1:end]
        P21_fr = P_fr[ω_idx, ny+1:end, 1:nu]
        P22_fr = P_fr[ω_idx, ny+1:end, nu+1:end]

        delay_matrix_inv_fr = Diagonal(exp.(im*sys.Tau*ω[ω_idx])) # Frequency response of the diagonal matrix with delays
        # Inverse of the delay matrix, so there should not be any minus signs in the exponents

        G_fr[ω_idx,:,:] .= P11_fr + P12_fr/(delay_matrix_inv_fr - P22_fr)*P21_fr # The matrix is invertible (?!)
    end

    return G_fr
end

struct FunctionWrapper <: Function
    f::Function
end
(fv::FunctionWrapper)(dx, x, h!, p, t) = fv.f(dx, x, h!, p, t)

struct UWrapper <: Function
    f::Function
end
(fv::UWrapper)(out, t) = fv.f(out, t)


"""
    `t, x, y = lsim(sys::DelayLtiSystem, t::AbstractArray{<:Real}; u=(out, t) -> (out .= 0), x0=fill(0.0, nstates(sys)), alg=MethodOfSteps(Tsit5()), kwargs...)`

    Simulate system `sys`, over time `t`, using input signal `u`, with initial state `x0`, using method `alg` .

    Arguments:

    `t`: Has to be an `AbstractVector` with equidistant time samples (`t[i] - t[i-1]` constant)
    `u`: Function to determine control signal `ut` at a time `t`, on any of the following forms:
        Can be a constant `Number` or `Vector`, interpreted as `ut .= u` , or
        Function `ut .= u(t)`, or
        In-place function `u(ut, t)`. (Slightly more effienct)

    Returns: `x` and `y` at times `t`.
"""
function lsim(sys::DelayLtiSystem{T}, u, t::AbstractArray{<:T}; x0=fill(zero(T), nstates(sys)), alg=MethodOfSteps(Tsit5())) where T
    # Make u! in-place function of u
    u! = if isa(u, Number) || isa(u,AbstractVector) # Allow for u to be a constant number or vector
        println("Number vector")
        (uout, t) -> uout .= u
    elseif DiffEqBase.isinplace(u, 2)               # If u is an inplace (more than 1 argument function)
        println("Inplace")
        u
    else                                            # If u is a regular u(t) function
        println("Outplace")
        (out, t) -> (out .= u(t))
    end
    _lsim(sys, UWrapper(u!), t, x0, alg)
end

function dde_param(dx, x, h!, p, t)
    A, B1, B2, C2, D21, Tau, u!, uout, hout, tmp = p[1],p[2],p[3],p[4],p[5],p[6],p[7],p[8],p[9],p[10]

    u!(uout, t)     # uout = u(t)

    #dx .= A*x + B1*ut
    mul!(dx, A, x)
    mul!(tmp, B1, uout)
    dx .+= tmp

    for k=1:length(Tau)     # Add each of the delayed signals
        u!(uout, t-Tau[k])      # uout = u(t-tau[k])
        h!(hout, p, t-Tau[k])
        dk_delayed = dot(view(C2,k,:), hout) + dot(view(D21,k,:), uout)
        dx .+= view(B2,:, k) .* dk_delayed
    end
    return
end

function _lsim(sys::DelayLtiSystem{T}, u!, t::AbstractArray{<:T}, x0::Vector{T}, alg) where T
    P = sys.P

    if ~iszero(P.D22)
        error("non-zero D22-matrix block is not supported") # Due to limitations in differential equations
    end

    dt = t[2] - t[1]
    if ~all(diff(t) .≈ dt) # QUESTION Does this work or are there precision problems?
        error("The t-vector should be uniformly spaced, t[2] - t[1] = $dt.") # Perhaps dedicated function for checking this?
    end

    # Get all matrices to save on allocations
    A, B1, B2, C1, C2, D11, D12, D21, D22 = P.A, P.B1, P.B2, P.C1, P.C2, P.D11, P.D12, P.D21, P.D22
    Tau = sys.Tau

    hout = fill(zero(T), nstates(sys))  # in place storage for h
    uout = fill(zero(T), ninputs(sys)) # in place storage for u
    tmp = similar(x0)

    h!(out, p, t) = (out .= 0)      # History function

    p = (A, B1, B2, C2, D21, Tau, u!, uout, hout, tmp)
    prob = DDEProblem{true}(dde_param, x0, h!, (t[1], t[end]), p, constant_lags=sys.Tau)

    sol = DelayDiffEq.solve(prob, alg, saveat=t)

    x = sol.u::Array{Array{T,1},1} # the states are labeled u in DelayDiffEq
    println(size(x))

    y = Array{T,2}(undef, noutputs(sys), length(t))
    d = Array{T,2}(undef, size(C2,1), length(t))
    # Build y signal (without d term)
    for k = 1:length(t)
        u!(uout, t[k])
        y[:,k] = C1*x[k] + D11*uout
        #d[:,k] = C2*x[k] + D21*uout
    end
    xitp = Interpolations.interpolate((t,), x, Interpolations.Gridded(Interpolations.Linear()))

    dtmp = Array{T,1}(undef, size(C2,1))
    # Function to evaluate d(t)_i at an arbitrary time
    # X is constinuous, so interpoate, u is not
    function dfunc!(tmp::Array{T1}, t, i) where T1
        tmp .= if t < 0
            T1(0)
        else
            xitp(t)
        end
        u!(uout, t)
        return dot(view(C2,i,:),tmp) + dot(view(D21,i,:),uout)
    end

    # Account for the effect of the delayed d-signal on y
    for k=1:length(Tau)
        for j=1:length(t)
            di = dfunc!(tmp, t[j] - Tau[k], k)
            y[:, j] .+= view(D12,:, k) .* di
        end
    end

    return t, x, y
end