# Types for whale.
# © Arthur Zwaenepoel - 2019
"""
    SpeciesTree(tree, node2sp::Dict)
Species tree struct, holds the species tree related information (location of
WGD nodes etc.)
"""
struct SpeciesTree
    tree::Tree
    species::Dict{Int64,String}
    wgd_index::Dict{Int64,Int64}  # an index relating node to WGD id
    clades::Dict{Int64,Set{Int64}}

    function SpeciesTree(tree::Tree, node2sp::Dict{Int64,String})
        wgd_index = Dict{Int64,Int64}()
        clades = Dict{Int64,Set{Int64}}()
        function walk(node)
            if isleaf(tree, node)
                clades[node] = Set([node])
            else
                clades[node] = Set([])
                for c in childnodes(tree, node)
                    walk(c)
                    union!(clades[node], clades[c])
                end
            end
        end
        walk(1)
        new(tree, node2sp, wgd_index, clades)
    end
end

"""
    RecTree(tree, labels, σ, γ, leaves)
A reconciled tree struct.
"""
mutable struct RecTree
    tree::Tree
    labels::Dict{Int64,String}
    σ::Dict{Int64,Int64}  # species mapping
    γ::Dict{Int64,Int64}  # clade ID map for convenience
    leaves::Dict{Int64,String}

    # new RecTree, all specified
    function RecTree(tree::Tree, labels::Dict{Int64,String}, σ::Dict{Int64,Int64},
            γ::Dict{Int64,Int64}, leaves::Dict{Int64,String})
        new(tree, labels, σ, γ, leaves)
    end

    # initialize empty RecTree
    function RecTree()
        new(Tree(), Dict{Int64,String}(), Dict{Int64,Int64}(),
            Dict{Int64,Int64}(), Dict{Int64,String}())
    end
end

"""
    Slices(slices, slice_lengths, branches)
Species tree slices structure.
"""
struct Slices
    slices::Dict{Int64,Int64}
    slice_lengths::Dict{Int64,Array{Float64}}
    branches::Array{Int64}  # a postorder of species tree branches

    function Slices(slices, slice_lengths, branches)
        new(slices, slice_lengths, branches)
    end
end

# I don't think the set_ids are used? - I skipped them
"""
    CCD(...)
CCD composite type, holds an approximation of the posterior distribution over
trees. This version is adapted for the parallel MCMC algorithm.
"""
mutable struct CCD
    Γ::Int64                                        # ubiquitous clade
    total::Int64                                    # total # of samples
    m1::Dict{Int64,Int64}                           # counts for every clade
    m2::Dict{Int64,Array{Tuple{Int64,Int64,Int64}}} # counts for every triple
    m3::Dict{Int64,Int64}                           # leaf to species node map
    ccp::Dict{Tuple,Float64}                        # conditional clade p's
    leaves::Dict{Int64,String}                      # leaf names
    blens::Dict{Int64,Float64}                      # branch lengths for γ's'
    clades::Array{Int64,1}                          # clades ordered by size
    species::Dict{Int64,Set{Int64}}                 # clade to species nodes
    tmpmat::Dict{Int64,Array{Float64,2}}            # tmp reconciliation matrix
    recmat::Dict{Int64,Array{Float64,2}}            # the reconciliation matrix

    # the idea of the `tmpmat` and `recmat` fields is that the latter contains
    # the reconciliation matrix computed using the parameters of the last
    # completed iteration of the MCMC sample, whereas the former can hold the
    # copied and partially recomputed matrix under some new parameter values.
    # When all partial recomputations are performed we evaluate the likelihood,
    # and at that moment we must be able to, upon acceptance, store the newly
    # computed matrices (such that they can be used for partial recomputation
    # in the next iteration) **but**, upon rejection, we must be able to revert
    # to the matrices before partial recomputation. Hence the idea of working
    # on a deepcopy in `tmpmat` and setting `recmat` to `tmpmat` upon
    # acceptance. The nice thing about encoding this in the CCD type is that it
    # is straightforward (I think) to do this efficiently in a parallel setting.

    function CCD(total, m1, m2, m3, l, blens, clades, species, Γ, ccp)
        m  = Dict{Int64,Array{Float64,2}}()
        m_ = Dict{Int64,Array{Float64,2}}()
        new(Γ, total, m1, m2, m3, ccp, l, blens, clades, species, m, m_)
    end
end

# show method
function Base.show(io::IO, ccd::CCD)
    println("n = $(ccd.total)| N = $(length(ccd.clades))| Γ = $(ccd.Γ)| L = $(length(ccd.leaves))")
end
