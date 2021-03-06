#===============================================================================
Optimizers for (WH)ALE
===============================================================================#
# TODO: arbitrary fixed rates, specified in config file
# NOTE: changed nmwhale, now returns D as well (for backtracking reasons)

# This is actually the only one we really need.
function nmwhale(S::SpeciesTree, ccd::Array{CCD}, slices::Slices, η::Float64,
        q::Array{Float64}; oib::Bool=true, max_iter::Int64=5000,
        restart_every::Int64=0)
    nmwhale(S, ccd, slices, η, q, Dict(x => 1 for x in 1:length(S.tree.nodes)),
        oib=oib, max_iter=max_iter, restart_every=restart_every)
end

function nmwhale(S::SpeciesTree, ccd::Array{CCD}, slices::Slices, η::Float64;
        oib::Bool=true, max_iter::Int64=5000, restart_every::Int64=0)
    nmwhale(S, ccd, slices, η, [-1. for x in 1:length(S.wgd_index)],
        Dict(x => 1 for x in 1:length(S.tree.nodes)), oib=oib,
        max_iter=max_iter, restart_every=restart_every)
end

function nmwhale(S::SpeciesTree, ccd::Array{CCD}, slices::Slices, η::Float64,
        rate_index::Dict{Int64,Int64}; oib::Bool=true, max_iter::Int64=5000,
        restart_every::Int64=0)
    nmwhale(S, ccd, slices, η, [-1. for x in 1:length(S.wgd_index)],
        rate_index, oib=oib, max_iter=max_iter, restart_every=restart_every)
end

"""
    nmwhale(S, ccd, slices, η, q, rate_index; ...)
Nelder-Mead (Downhill simplex method) optimizer for Whale. In parallel.
"""
function nmwhale(S::SpeciesTree, ccd::Array{CCD}, slices::Slices, η::Float64,
        q::Array{Float64}, rate_index::Dict{Int64,Int64}; oib::Bool=true,
        max_iter::Int64=5000, restart_every::Int64=0, init::Array{Float64}=Float64[])
    @info "Starting Nelder-Mead optimization"
    nw = length(workers())
    @info " .. Distributing over $nw workers"
    D = distribute(ccd)

    n_cat = length(Set(values(rate_index)))
    @info " .. There are $n_cat rate categories"
    fixed_q = length([x for x in q if x >= 0.])
    free_q = length(q) - fixed_q
    @assert fixed_q + free_q == length(S.wgd_index)
    @info " .. There are $free_q retention rates to optimize"

    function joint_p(x)
        q_ = update_q(q, x, i=2*n_cat+1)
        λ = x[1:n_cat]
        μ = x[n_cat+1:2*n_cat]
        log_iteration(λ, μ, q_)
        joint = evaluate_lhood!(D, S, slices, λ, μ, q_, η, rate_index)
        @printf "⤷ log[P(Γ)] = %.3f\n"  joint; flush(stdout)
        return - joint
    end
    # currently the starting point is lambda = mu = 0, not sure if a good idea
    # but if their have been losses/duplications it will certainly move away
    # from these
    if restart_every == 0
        restart_every = max_iter
    end

    length(init) > 0 ? result = init : result = zeros(n_cat*2 + free_q) .+ rand()
    ml = -Inf; converged = false; out = nothing; total = 0
    while !(converged) && total < max_iter
        out = optimize(
            joint_p, result,
            NelderMead(initial_simplex = Optim.AffineSimplexer()),
            Optim.Options(g_tol = 1e-5, iterations=restart_every)
        )
        result = out.minimizer
        ml = -Optim.minimum(out)
        converged = Optim.converged(out)
        total += restart_every
    end

    set_recmat!(D)
    q_ = update_q(q, result, i=2*n_cat+1)
    @printf "Maximum: log(L) = %.4f\n" ml
    @printf "ML estimates (η = %.2f): " η
    log_iteration(result[1:n_cat], result[n_cat+1:2*n_cat], q_)
    println()
    return out, D
end

"""
     map_nmwhale(ccd, chain, prior; [...])
Nelder-Mead (Downhill simplex method) optimizer for MAP estimation, we assume a
chain and prior object (no proposals).
"""
function map_nmwhale(ccd, chain, prior; max_iter::Real=5000, init::Array{Float64}=Float64[])
    @info "Starting Nelder-Mead optimization for MAP estimation"
    nw = length(workers())
    @info " .. Distributing over $nw workers"
    D = distribute(ccd)

    n_cat = length(Set(values(chain.ri)))
    typeof(prior) == IidRates ? n_cat -= 1 : nothing # HACK
    @info " .. There are $n_cat rate categories"
    #fixed_q = length([x for x in q if x >= 0.])
    #free_q = length(q) - fixed_q
    #@assert fixed_q + free_q == length(chain.S.wgd_index)
    #@info " .. There are $free_q retention rates to optimize"
    # FIXME, currently only with all q rates optimized
    free_q = length(keys(chain.S.wgd_index))

    # initial parameter vector
    length(init) > 0 ? result = init : result = zeros(n_cat*2 + free_q) .+ rand()
    function posterior(x)
        λ = x[1:n_cat]
        μ = x[n_cat+1:2*n_cat]
        if typeof(prior) == IidRates
            λ = [0.2 ; λ] # HACK
            μ = [0.2 ; μ]
        end
        q = x[2*n_cat+1:end]
        log_iteration_ssv(λ, μ, q)
        π = Whale.evaluate_prior(chain.S, λ, μ, q, chain.state, prior)
        l = Whale.evaluate_lhood!(D, λ, μ, q, chain, prior)
        #@printf "⤷ log[P(θ|x)] = %.3f\n"  π + l; flush(stdout)
        @printf "%.3f %.3f %.3f\n" π l (π + l); flush(stdout)
        return - (π + l)
    end

    out = optimize(
        posterior, result,
        NelderMead(initial_simplex = Optim.AffineSimplexer()),
        Optim.Options(g_tol = 1e-5, iterations=max_iter)
    )
    result = out.minimizer
    ml = -Optim.minimum(out)
    @printf "Posterior mode: log(P(θ|x)) = %.4f\n" ml
    @printf "MAP estimates (η = %.2f): " chain.state["η"][1]
    log_iteration(result[1:n_cat], result[n_cat+1:2*n_cat], result[2*n_cat+1:end])
    println()
    return out
end

function log_iteration(λ::Array{Float64}, μ::Array{Float64}, q::Array{Float64})
    print("λ = (", join([@sprintf "%6.3f" x for x in λ], ", "), ") ; ")
    print("μ = (", join([@sprintf "%6.3f" x for x in μ], ", "), ") ; ")
    print("q = (", join([@sprintf "%6.3f" x for x in q], ", "), ") ; ")
end

function log_iteration(λ::Array{Float64}, μ::Array{Float64})
    print("λ = (", join([@sprintf "%6.3f" x for x in λ], ", "), ") ; ")
    print("μ = (", join([@sprintf "%6.3f" x for x in μ], ", "), ") ; ")
end

function log_iteration_ssv(λ::Array{Float64}, μ::Array{Float64}, q::Array{Float64})
    print(join([@sprintf "%6.3f" x for x in λ], " ") * " ")
    print(join([@sprintf "%6.3f" x for x in μ], " ") * " ")
    print(join([@sprintf "%6.3f" x for x in q], " ") * " ")
end


# OLD STUFF??
# Nelder-Mead optimizers -------------------------------------------------------
"""
    nm_aledl(S::SpeciesTree, ccd::Array{CCD}, slices::Slices, η::Float64)

Nelder-Mead (Downhill simplex method) optimizer for ALE with hte basic DL model
and a geometric prior on the number of lineages at the root.
"""
function nm_aledl(S::SpeciesTree, ccd::Array{CCD}, slices::Slices, η::Float64;
                  one_in_both::Bool=true, max_iter::Int64=1000)
    return nm_whale(S, ccd, slices, η, zeros(length(S.wgd_index)),
                    one_in_both=one_in_both, max_iter=max_iter)
end


"""
    nm_whale(S::SpeciesTree, ccd::Array{CCD}, slices::Slices, η::Float64)

Nelder-Mead (Downhill simplex method) optimizer for ALE with WGD (WHALE) and
a geometric prior on the number of lineages at the root.
"""
function nm_whale(S::SpeciesTree, ccd::Array{CCD}, slices::Slices, η::Float64;
                  one_in_both::Bool=true, max_iter::Int64=5000)
    return nm_whale(S, ccd, slices, η, zeros(length(S.wgd_index)) .- 1. ,
                    one_in_both=one_in_both, max_iter=max_iter)
end


"""
    nm_whale(S, ccd, slices, η, q::Array{Float64})

Nelder-Mead (Downhill simplex method) optimizer for ALE with WGD (WHALE) and
a geometric prior on the number of lineages at the root. Version with fixed q.
WGDs with q set to a value < 0 will be optimized for q.

This is the most general version without branch-wise rates
"""
function nm_whale(
    S::SpeciesTree, ccd::Array{CCD}, slices::Slices, η::Float64,
    q::Array{Float64}; one_in_both::Bool=true, max_iter::Int64=5000
)
    println(" ⧐ Starting Nelder-Mead optimization")
    fixed_q = length([x for x in q if x >= 0.])
    free_q = length(q) - fixed_q
    @assert fixed_q + free_q == length(S.wgd_index)
    function joint_p(x)
        q_ = update_q(q, x)
        #q = [x[3:end] ; fixed_q]
        @assert length(q_) == length(S.wgd_index)
        @printf "λ = %6.3f ; μ = %6.3f ; q = ( " x[1] x[2]
        print(join([@sprintf "%6.3f" x for x in q_], ", "), " ) ; ")
        joint = sum([whale_likelihood(S, c, slices, x[1], x[2], q_, η,
                     one_in_both=one_in_both)[2] for c in ccd])
        @printf "⤷ log[P(Γ)] = %.3f\n"  joint
        return - joint
    end
    # currently the starting point is lambda = mu = 0, not sure if a good idea
    # but if their have been losses/duplications it will certainly move away
    # from theseq::Array{Float64},
    out = optimize(
        joint_p, zeros(2 + free_q) .+ rand(),
        NelderMead(initial_simplex = Optim.AffineSimplexer()),
        Optim.Options(g_tol = 1e-4, iterations=max_iter)
    )

    result = out.minimizer
    q_ = update_q(q, result)
    out.minimizer = [out.minimizer[1:2] ; q_]
    @printf "Maximum: log(L) = %.4f\n" -Optim.minimum(out)
    @printf "ML estimates (η = %.2f): " η
    @printf "λ = %.6f ; μ = %.6f ; q = ( " result[1] result[2]
    print(join([@sprintf "%6.3f" x for x in q_], ", "), " )\n")
    return out
end


"""
    update_q(q::Array{Float64}, x::Array{Float64})

Update the retention rates, keeping those that should be fixed fixed while
optimizing others.
"""
function update_q_(q, x; minq::Float64=1e-6, maxq::Float64=0.999999, i::Int64=3)
    q_ = Float64[]
    for qq in q  # optimized
        if qq < 0
            if x[i] < minq
                push!(q_, 0.); i+= 1
            elseif x[i] > maxq
                push!(q_, 1.); i+= 1
            else
                push!(q_, x[i]); i+= 1
            end
        else  # fixed
            push!(q_, qq)
        end
    end
    return q_
end


"""
    update_q(q::Array{Float64}, x::Array{Float64})

Update the retention rates, keeping those that should be fixed fixed while
optimizing others.
"""
function update_q(q, x; i::Int64=3)
    q_ = Float64[]
    for qq in q  # optimized
        if qq < 0.
            push!(q_, x[i]) ; i += 1
        else
            push!(q_, qq)
        end
    end
    return q_
end


"""
    nm_whale_bw(...)

Nelder-Mead (Downhill simplex method) optimizer for ALE with WGD (WHALE) and
a geometric prior on the number of lineages at the root.
"""
function nm_whale_bw(
        S::SpeciesTree, ccd::Array{CCD}, slices::Slices, η::Float64,
        rate_index::Dict{Int64,Int64}; one_in_both::Bool=true,
        max_iter::Int64=5000
    )
    return nm_whale_bw(S, ccd, slices, η, zeros(length(S.wgd_index)) .- 1. ,
                    rate_index, one_in_both=one_in_both)
end


"""
Nelder-Mead (Downhill simplex method) optimizer for ALE with WGD, prior and
arbitrary branch-wise rates. With restart(s).
"""
function nm_whale_bw(
    S::SpeciesTree, ccd::Array{CCD}, slices::Slices, η::Float64,
    q::Array{Float64}, rate_index::Dict{Int64,Int64}; one_in_both::Bool=true,
    max_iter::Int64=5000, restart_every::Int64=0
)
    @info " ⧐ Starting Nelder-Mead optimization"
    n_cat = length(Set(values(rate_index)))
    @info " .. There are $n_cat rate categories"
    fixed_q = length([x for x in q if x >= 0.])
    free_q = length(q) - fixed_q
    @assert fixed_q + free_q == length(S.wgd_index)

    function joint_p(x)
        q_ = update_q(q, x, i=2*n_cat+1)
        λ = x[1:n_cat]
        μ = x[n_cat+1:2*n_cat]
        log_iteration(λ, μ, q_)
        joint = sum([whale_likelihood_bw(S, c, slices, λ, μ, q_, η, rate_index,
                     one_in_both=one_in_both)[2] for c in ccd])
        @printf "⤷ log[P(Γ)] = %.3f\n"  joint
        return - joint
    end
    # currently the starting point is lambda = mu = 0, not sure if a good idea
    # but if their have been losses/duplications it will certainly move away
    # from these
    if restart_every == 0
        restart_every = max_iter
    end

    result = zeros(n_cat*2 + free_q) .+ rand()
    ml = -Inf; converged = false; out = nothing; total = 0
    while !(converged) && total < max_iter
        out = optimize(
            joint_p, result,
            NelderMead(initial_simplex = Optim.AffineSimplexer()),
            Optim.Options(g_tol = 1e-4, iterations=restart_every)
        )
        result = out.minimizer
        ml = -Optim.minimum(out)
        converged = Optim.converged(out)
        total += restart_every
    end
    q_ = update_q(q, result, i=2*n_cat+1)
    @printf "Maximum: log(L) = %.4f\n" ml
    @printf "ML estimates (η = %.2f): " η
    log_iteration(
        result[1:n_cat], result[n_cat+1:2*n_cat], q_)
    println()
    return out
end


# Parallel computation ---------------------------------------------------------
"""
Nelder-Mead (Downhill simplex method) optimizer for ALE with WGD, prior and
arbitrary branch-wise rates.
"""
function nm_whale_bw_parallel(
    S::SpeciesTree, ccd::Array{CCD}, slices::Slices, η::Float64,
    q::Array{Float64}, rate_index::Dict{Int64,Int64}; one_in_both::Bool=true,
    max_iter::Int64=5000
)
    println(" ⧐ Starting Nelder-Mead optimization")
    n_cat = length(Set(values(rate_index)))
    println(" .. There are ", n_cat, " rate categories")
    fixed_q = length([x for x in q if x >= 0.])
    free_q = length(q) - fixed_q
    @assert fixed_q + free_q == length(S.wgd_index)

    function joint_p(x)
        q_ = update_q(q, x, i=2*n_cat+1)
        λ = x[1:n_cat]
        μ = x[n_cat+1:2*n_cat]
        log_iteration(λ, μ, q_)
        joint = joint_likelihood_parallel(
            S, ccd, slices, λ, μ, q_, η, rate_index, oib=one_in_both
        )
        @printf "⤷ log[P(Γ)] = %.3f\n"  joint
        return - joint
    end
    # currently the starting point is lambda = mu = 0, not sure if a good idea
    # but if their have been losses/duplications it will certainly move away
    # from these
    out = optimize(
        joint_p, zeros(n_cat*2 + free_q) .+ rand(),
        NelderMead(initial_simplex = Optim.AffineSimplexer()),
        Optim.Options(g_tol = 1e-4, iterations=max_iter)
    )

    result = out.minimizer
    q_ = update_q(q, result, i=2*n_cat+1)
    @printf "Maximum: log(L) = %.4f\n" -Optim.minimum(out)
    @printf "ML estimates (η = %.2f): " η
    log_iteration(
        result[1:n_cat], result[n_cat+1:2*n_cat], q_)
    println()
    return out
end


"""
Not tested... The idea is to do parallel joint optimization per batch, not per
family as that might speed up lots of stuff.
"""
function joint_likelihood_parallel(
    S::SpeciesTree, ccd::Array{CCD}, slices::Slices, λ::Array{Float64},
    μ::Array{Float64}, q::Array{Float64}, η::Float64, ri::Dict{Int64,Int64};
    oib::Bool=true
)
    joint_p = @distributed (+) for i = 1:length(ccd)
        whale_likelihood_bw(S, ccd[i], slices, λ, μ, q, η, ri,
            one_in_both=oib)[2]
    end
    return joint_p
end


"""
Not tested... The idea is to do parallel joint optimization per batch, not per
family as that might speed up lots of stuff.
"""
function joint_likelihood_parallel(
    S::SpeciesTree, batches::Array{Array{CCD,1},1}, slices::Slices, λ::Float64,
    μ::Float64, q::Array{Float64}, η::Float64; one_in_both::Bool=true
)
    joint_p = @distributed (+) for i = 1:length(batches)
        sum([whale_likelihood(S, c, slices, λ, μ, q, η,
             one_in_both=one_in_both)[2] for c in batches[i]])
    end
    return joint_p
end


function nm_whale_parallel(
    S::SpeciesTree, ccd::Array{CCD}, slices::Slices, η::Float64,
    q::Array{Float64}, n::Int64; one_in_both::Bool=true
)
    N = length(ccd) ; batch_size = ceil(Int64, N/n)
    batches = [ccd[i:min(N,i+batch_size-1)] for i in 1:batch_size:N]
    println(" .. # batches = ", length(batches), "; size(batch) = ", batch_size)
    function joint_p(x)
        @printf "λ = %6.3f ; μ = %6.3f ; q = " x[1] x[2]
        print(q, " ")
        joint = joint_likelihood_parallel(
                    S, batches, slices, x[1], x[2], q, η,
                    one_in_both=one_in_both
                )
        @printf "⤷ log[P(Γ)] = %.3f\n"  joint
        return - joint
    end
    # currently the starting point is lambda = mu = 0, not sure if a good idea
    # but if their have been losses/duplications it will certainly move away
    # from these
    out = optimize(
        joint_p, zeros(2) .+ rand(),
        NelderMead(initial_simplex = Optim.AffineSimplexer()),
        Optim.Options(g_tol = 1e-6, iterations=500)
    )

    result = out.minimizer
    @printf "Maximum: log(L) = %.4f\n" -Optim.minimum(out)
    @printf "ML estimates (η = %.2f): " η
    @printf "λ = %.6f ; μ = %.6f ; q = " result[1] result[2]
    print(q, "\n")
    return out
end


# Simulated annealing ----------------------------------------------------------
"""
Nelder-Mead (Downhill simplex method) optimizer for ALE with WGD, prior and
arbitrary branch-wise rates.
"""
function samin_whale_bw(
    S::SpeciesTree, ccd::Array{CCD}, slices::Slices, η::Float64,
    q::Array{Float64}, rate_index::Dict{Int64,Int64}; one_in_both::Bool=true,
    rt::Float64=0.9
)
    println(" ⧐ Starting SAMIN optimization, k = ", rt)
    n_cat = length(Set(values(rate_index)))
    println(" .. There are ", n_cat, " rate categories")
    fixed_q = length([x for x in q if x >= 0.])
    free_q = length(q) - fixed_q
    @assert fixed_q + free_q == length(S.wgd_index)

    function joint_p(x)
        q_ = update_q(q, x, i=2*n_cat+1)
        λ = x[1:n_cat]
        μ = x[n_cat+1:2*n_cat]
        log_iteration(λ, μ, q_)
        joint = sum([whale_likelihood_bw(S, c, slices, λ, μ, q_, η, rate_index,
                     one_in_both=one_in_both)[2] for c in ccd])
        @printf "⤷ log[P(Γ)] = %.3f\n"  joint
        return - joint
    end
    # currently the starting point is lambda = mu = 0, not sure if a good idea
    # but if their have been losses/duplications it will certainly move away
    # from these
    out = Optim.optimize(
        joint_p, zeros(n_cat*2 + free_q), ones(n_cat*2 + free_q),
        zeros(n_cat*2 + free_q) .+ rand(), Optim.SAMIN(rt=rt, coverage_ok=true),
        Optim.Options(iterations=10^6)
    )

    result = out.minimizer
    q_ = update_q(q, result, i=2*n_cat+1)
    @printf "Maximum: log(L) = %.4f\n" -Optim.minimum(out)
    @printf "ML estimates (η = %.2f): " η
    log_iteration(
        result[1:n_cat], result[n_cat+1:2*n_cat], q_)
    println()
    return out
end

# Other ------------------------------------------------------------------------
"""
LBFGS for WHALE, with gradient approximated
"""
function gd_whale(
    S::SpeciesTree, ccd::Array{CCD}, slices::Slices, η::Float64,
    q::Array{Float64}, rate_index::Dict{Int64,Int64}; one_in_both::Bool=true,
    max_iter::Int64=5000
)
    println(" ⧐ Starting LBFGS optimization")
    n_cat = length(Set(values(rate_index)))
    println(" .. There are ", n_cat, " rate categories")
    fixed_q = length([x for x in q if x >= 0.])
    free_q = length(q) - fixed_q
    @assert fixed_q + free_q == length(S.wgd_index)

    function joint_p(x)
        q_ = update_q(q, x, i=2*n_cat+1)
        λ = x[1:n_cat]
        μ = x[n_cat+1:2*n_cat]
        log_iteration(λ, μ, q_)
        joint = sum([whale_likelihood_bw(S, c, slices, λ, μ, q_, η, rate_index,
                     one_in_both=one_in_both)[2] for c in ccd])
        @printf "⤷ log[P(Γ)] = %.3f\n"  joint
        return - joint
    end
    # currently the starting point is lambda = mu = 0, not sure if a good idea
    # but if their have been losses/duplications it will certainly move away
    # from these
    lower = zeros(n_cat*2 + free_q)
    upper = ones(n_cat*2 + free_q)
    upper[1:n_cat*2] .+= Inf
    out = optimize(
        joint_p, lower, upper, zeros(n_cat*2 + free_q) .+ rand(),
        Fminbox(LBFGS()),
    )

    result = out.minimizer
    q_ = update_q(q, result, i=2*n_cat+1)
    @printf "Maximum: log(L) = %.4f\n" -Optim.minimum(out)
    @printf "ML estimates (η = %.2f): " η
    log_iteration(
        result[1:n_cat], result[n_cat+1:2*n_cat], q_)
    println()
    return out
end


"""
PSO for WHALE
"""
function ps_whale(
    S::SpeciesTree, ccd::Array{CCD}, slices::Slices, η::Float64,
    q::Array{Float64}, rate_index::Dict{Int64,Int64}; one_in_both::Bool=true,
    max_iter::Int64=5000, n_particles::Int64=10
)
    println(" ⧐ Starting Particle Swarm optimization")
    n_cat = length(Set(values(rate_index)))
    println(" .. There are ", n_cat, " rate categories")
    fixed_q = length([x for x in q if x >= 0.])
    free_q = length(q) - fixed_q
    @assert fixed_q + free_q == length(S.wgd_index)

    function joint_p(x)
        q_ = update_q(q, x, i=2*n_cat+1)
        λ = x[1:n_cat]
        μ = x[n_cat+1:2*n_cat]
        log_iteration(λ, μ, q_)
        joint = sum([whale_likelihood_bw(S, c, slices, λ, μ, q_, η, rate_index,
                     one_in_both=one_in_both)[2] for c in ccd])
        @printf "⤷ log[P(Γ)] = %.3f\n"  joint
        return - joint
    end
    # currently the starting point is lambda = mu = 0, not sure if a good idea
    # but if their have been losses/duplications it will certainly move away
    # from these
    lower = zeros(n_cat*2 + free_q)
    upper = ones(n_cat*2 + free_q)
    out = optimize(
        joint_p, zeros(n_cat*2 + free_q) .+ rand(),
        ParticleSwarm(lower=lower, upper=upper, n_particles=n_particles),
        Optim.Options(g_tol = 1e-4, iterations=max_iter)
    )

    result = out.minimizer
    q_ = update_q(q, result, i=2*n_cat+1)
    @printf "Maximum: log(L) = %.4f\n" -Optim.minimum(out)
    @printf "ML estimates (η = %.2f): " η
    log_iteration(
        result[1:n_cat], result[n_cat+1:2*n_cat], q_)
    println()
    return out
end
