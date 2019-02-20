# Whale: whole genome duplication inference by amalgamated likelihood estimation

- This library implements the duplication, loss and whole genome duplication (DL + WGD) model for performing joint gene tree - reconciliation inference using amalgamated likelihood estimation (ALE).

- This method, called Whale, can be used to assess WGD hypotheses using gene family phylogenetic trees. It can also be used to estimate branch-specific duplication and loss rates for a species tree under various models of rate evolution.

- To install `Whale`, you will need a julia installation (v1.x). Currently you should clone this repository, open a julia session, type `]` to enter the package manager and then do `dev /path/to/Whale`. Then you should be able to type `using Whale` in a julia session, after which you can use the library. Note that this is still a development version.

- To do analyses with Whale, you will need (1) a dated species tree, (2) a set of gene families with for each gene family a sample from the posterior distribution of gene trees (bootstrap replicates can also be used in principle), summarized as a *conditional clade distribution* in an `ale` file (see below) and (3) a configuration file. All analyses are invoked by using

    `julia -p <n_cores> whale.jl <species tree> <ale directory|file|filelist> <config file>`

- The main program is `whale.jl` in the `bin` folder of this repository (it is not a binary file but a julia script, but following traditions I have put it in a bin folder).

- `julia` can have a rather slow startup time, if you plan to use `Whale` a lot, you may want to open a julia session, load the Whale package and do your analyses in the session. However for the typical rather long analyses performed with Whale, you will probably just submit your job to some cluster.

- Below we explain how to use Whale in a maximum-likelihood and Bayesian framework.

## Testing WGD hypotheses by maximum likelihood

Models with and without WGD can be compared by means of a likelihood ratio test or information criterion (such as AIC or BIC). The method allows to estimate branch-specific rates and use arbitrary rate classes for branches of the species tree. To use Whale with the ML approach you will need a config file like `whalemle.conf` in the `example` directory of this repository. This looks something like this:

```
[wgd]
SEED = GBIL,ATHA 3.9 -1.
ANGI = ATRI,ATHA 3.08 -1.
PPAT = PPAT 0.6 -1.

[rates]
ATHA,CPAP = 1 true
PPAT,MPOL = 2 true
GBIL,PABI = 3 false

[ml]
η = 0.66
```

Where the species tree (`example/morris-9taxa.nw`) looks like this

```
((MPOL:4.752,PPAT:4.752):0.292,(SMOE:4.457,(((OSAT:1.555,(ATHA:0.5548,CPAP:0.5548):1.0002):0.738,ATRI:2.293):1.225,(GBIL:3.178,PABI:3.178):0.34):0.939):0.587);
```

To specify a WGD hypothesis in the config file, for example the seed plant WGD, you have to put a line like the following in your configuration in the `[wgd]` section:

```
SEED = GBIL,ATHA 3.9 -1.
```

Where `SEED` is the name of the WGD, `GBIL,ATHA` reflects the common ancestor node for the largest clade that shares this WGD (*i.e.* the node that is the common ancestor of `ATHA` and `GBIL` in the species tree). `3.9` is the estimated age of this WGD. `-1` indicates that the retention rate for this WGD should be estimated. Specifying a value between 0 and 1 (boundaries included) will fix this retention rate in the analysis (and not estimate it).

To specify branch wise rates one can use the `[rates]` section. This looks like the following

```
[rates]
ATHA,CPAP = 1 true
PPAT,MPOL = 2 true
GBIL,PABI = 3 false
```

Here we have specified a rate class (with ID 1) for the clade defined by the common ancestor of `ATHA` and `CPAP`. Similarly for the mosses (with ID 2). By using the `false` setting, the rate is not defined for the full clade below the speicfied node but only for the branch leasing to that node. Si, in this case we assigned a rate class (3) to the branch leading to the gymnosperms (the branch leading to the `GBIL,PABI` common ancestor node).

Other options for the ML method are specified in the `[ml]` section, here you can parametrize the geometric prior distribution on the number of lineages at the root (η). Other parameters that can be set here are `maxiter` (the maximum number of iterations) and `ctol` (the convergence criterion).

## Testing WGD hypotheses and inferring branch-wise duplication and loss rates using MCMC

Whale implements a Bayesian approach using MCMC to do posterior inference for the DL + WGD model with branch-wise rates. To do such an analysis, one needs a configuration file like `example/whalebay.conf`, this looks like:

```
[wgd]
SEED = GBIL,ATHA 3.900 -1.
ANGI = ATRI,ATHA 3.080 -1.
MONO = OSAT      0.910 -1.
GMMA = ATHA,VVIT 1.200 -1.
ALPH = ATHA      0.501 -1.
CPAP = CPAP      0.275 -1.
BETA = ATHA      0.550 -1.
PPAT = PPAT      0.655 -1.

[mcmc]
# priors
rates = gbm         # one of iid|gbm
p_q = 1. 1.         # beta prior on q
p_λ = 0.15 0.5      # LN prior on λ at the root (gbm) or tree wide mean (iid)
p_μ = 0.15 0.5      # LN prior on μ at the root (gbm) or tree wide mean (iid)
p_ν = 0.10          # rate heterogeneity strength parameter
p_η = 4.0  2.0      # prior on η; single param assumes fixed, two params assumes beta prior

# kernel (if arwalk, no other params should be set)
kernel = arwalk

# chain
outfile = whalebay-gbm.csv  # output file for posterior sampled
ngen = 11000                # number of generations to run the chain
freq = 1                    # chain sample frequency
```

For the `[wgd]` section, please refer to the previous section. The `[mcmc]` section is quite self-explanatory (note the comments indicating the priors etc.). The `rates = gbm` setting will result in the autocorrelation (geometric Brownian motion) prior being used, whereas `iid` will result in the independent and identically distributed rates prior being used. Note that the ν parameter has a different meaning in both models. Currently as `kernel` setting only `arwalk` (adaptive random walk) is supported.

## Extra

There are some scripts and pieces of julia code in the `scripts` dir that might be of interest if you would like to make trace plots (`trace.py`), or plot a species tree with branches colored by duplication or loss rates and WGDs marked along the phylogeny. The `viz.jl` code in the `src` dir contains other functions to plot reconciled trees. This will however require you to use Whale as a julia package in a julia session (I would recommend downloading the Juno editor and playing around with Julia there, it's a lot like R or Python!).

For example, to backtrack reconciled trees after an MCMC analysis you could use the following code in a julia session:

```
using Whale

S = read_sp_tree("example/morris-9taxa.nw")
post = CSV.read("<path to your csv file with results>/whalebay.csv")[1000:end,:]  # discard 1000 generations as burn-in
conf = read_whaleconf("example/whalebay.conf")
q, ids = mark_wgds!(S, conf["wgd"])
slices = get_slices_conf(S, conf["slices"])
ccd = get_ccd("example/100.nw.ale", S)
rtrees = backtrackmcmcpost(post, ccd_, S, slices, 100)  # do the backtracking (sample 100 trees)
```
In a `julia` session you can always use `?` to fetch documentation of particular functions.