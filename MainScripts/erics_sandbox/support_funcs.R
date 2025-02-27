betaParams <- function(x) {
  # read data if filename is given
  if(is.character(x)) {
    x <- read.delim(x, row.names = 1)
  }
  
  # by-sample (columns) coverage
  coverage <- colSums(x)
  
  # fit beta shape parameters (transpose matrix for recycling of coverage vector)
  tx <- t(x)
  result <- array(c(tx + 1, coverage - tx + 1), dim = c(dim(tx), 2))
  dimnames(result) <- list(
    colnames(x),
    rownames(x),
    c('shape1', 'shape2')
  )
  result
}


ranRelPct <- function(beta.params) {
  # draw random sample from beta distribution with shape parameters 'p'
  pct <- apply(beta.params, c(1, 2), function(p) rbeta(1, p[1], p[2]))
  
  # normalize random percents to unity and return matrix
  # (transposed back to original dimensions)
  pct <- t(pct / rowSums(pct))
  rownames(pct) <- dimnames(beta.params)[[2]]
  colnames(pct) <- dimnames(beta.params)[[1]]
  pct
}

ranPCA <- function(beta.params) {
  prob <- t(ranRelPct(beta.params))
  log(prob / (1 - prob)) |> 
    prcomp() |> 
    summary()
}

numImpPCs <- function(pca) {
  # number of important PCs = as many as account for expected variance 
  imp.gt.exp <- pca$importance["Proportion of Variance", ] >= (1 / ncol(pca$importance))
  max(1, which.min(imp.gt.exp) - 1) 
}

jagsPClm <- function(pc.resp, pc.preds, chains, adapt, burnin, total.samples, thin) {
  library(runjags)
  
  data.list <- list(
    num.ind = nrow(pc.resp),
    num.resp = ncol(pc.resp),
    num.preds = ncol(pc.preds),
    pc.resp = pc.resp,
    pc.preds = pc.preds
  )
  
  jags.model <- "model {
    for(r in 1:num.resp) {
      # Prior for intercept
      intercept[r] ~ dnorm(0, 5e-4)

      for(p in 1:num.preds) {
        # Draw of switch for coefficient occurrence
        w[r, p] ~ dbern(0.5)
        
        # Prior for ASV coefficients
        b[r, p] ~ dnorm(0, 1e-6)
        
        # Modified (switched) ASV coefficient
        b.prime[r, p] <- b[r, p] * w[r, p]
      }

      # Prior for variance
      v[r] ~ dunif(0, 1000)
      tau[r] <- 1 / v[r]
    }

    for(i in 1:num.ind) {
      for(r in 1:num.resp) {
        mu[i, r] <- intercept[r] + inprod(b.prime[r, ], pc.preds[i, ])
        pc.resp[i, r] ~ dnorm(mu[i, r], tau[r])
      }
    }
  }"
  
  run.jags(
    model = jags.model,
    monitor = c("deviance", "intercept", "b.prime", "w", "v"),
    data = data.list,
    inits = function() list(
      .RNG.name = "lecuyer::RngStream",
      .RNG.seed = sample(1:9999, 1)
    ),
    modules = c("glm", "lecuyer"),
    summarise = FALSE,
    method = "parallel",
    n.chains = chains,
    adapt = adapt,
    burnin = burnin,
    sample = ceiling(total.samples / chains),
    thin = thin
  )
}


repBayesianPCAlm <- function(
    run.label, resp.label, resp.beta, pred.label, pred.beta, 
    nrep, mcmc, output.log = TRUE
) {
  # make sure rows are in same order for both sets of data
  resp.beta <- resp.beta[dimnames(pred.beta)[[1]], , ]
  
  # do nrep iterations, save results to list, and write to RDS file
  start.time <- Sys.time()
  reps <- lapply(1:nrep, function(i) {
    message('\n-------------')
    message(format(Sys.time()), ' : Begin replicate ', i)
    message('-------------\n')
    
    # Extract PCs -------------------------------------------------------------
    pca <- setNames(
      list(ranPCA(resp.beta), ranPCA(pred.beta)),
      c(resp.label, pred.label)
    )
    pca[[resp.label]]$num.pcs <- numImpPCs(pca[[resp.label]])
    pca[[pred.label]]$num.pcs <- numImpPCs(pca[[pred.label]])
    
    # Run Bayesian model ------------------------------------------------------
    post <- jagsPClm(
      pc.resp = pca[[resp.label]]$x[, 1:pca[[resp.label]]$num.pcs],
      pc.preds = pca[[pred.label]]$x[, 1:pca[[pred.label]]$num.pcs],
      chains = mcmc$chains, 
      adapt = mcmc$adapt, 
      burnin = mcmc$burnin, 
      total.samples = mcmc$total.samples, 
      thin = mcmc$thin
    )
    
    message('\n-------------')
    message(
      format(Sys.time()), ' : ',
      'Replicate ', i, ' time elapsed: ', 
      format(round(swfscMisc::autoUnits(post$timetaken), 2))
    )
    message('-------------\n')
    
    # Extract posterior and name dimensions -----------------------------------
    p <- swfscMisc::runjags2list(post)
    dimnames(p$intercept)[[1]] <-
      dimnames(p$b.prime)[[1]] <-
      dimnames(p$w)[[1]] <-
      dimnames(p$v)[[1]] <- paste0(resp.label, '.PC', 1:pca[[resp.label]]$num.pcs)
    dimnames(p$b.prime)[[2]] <-
      dimnames(p$w)[[2]] <- paste0(pred.label, '.PC', 1:pca[[pred.label]]$num.pcs)
    
    list(pca = pca, post.smry = summary(post, silent.jags = TRUE), post.list = p)
  })
  end.time = Sys.time()
  
  res <- list(
    labels = c(run = run.label, resp = resp.label, pred = pred.label),
    params = c(list(nrep = nrep), mcmc),
    reps = reps,
    run.time = list(
      start = start.time,
      end = end.time,
      elapsed = difftime(end.time, start.time)
    )
  )
  saveRDS(res, paste0(run.label, '_', format(Sys.time(), '%Y%m%d_%H%M%S.rds')))
  
  message('\n-------------')
  message(format(Sys.time()), ' : End replicates')
  message('Number of replicates: ', nrep)
  message('MCMC parameters:')
  message('  Chains: ', mcmc$chains)
  message('  Adapt: ', mcmc$adapt)
  message('  Burnin: ', mcmc$burnin)
  message('  Total Samples: ', mcmc$total.samples)
  message('  Thinning: ', mcmc$thin)
  message(
    'Total elapsed time: ', format(round(swfscMisc::autoUnits(res$run.time$elapsed), 2)),
    ' (', format(round(swfscMisc::autoUnits(res$run.time$elapsed / nrep), 2)), ' per replicate)'
  )
  message('-------------\n')
  
  invisible(res)
}


extractPC <- function(pca.list, pc, locus) {
  loadings <- sapply(pca.list, function(x) x$pca[[locus]]$rotation[, pc]) 
  for(i in 1:nrow(loadings)) {
    switch.sign <- sign(loadings[i, ]) != sign(loadings[i, 1])
    loadings[i, switch.sign] <- loadings[i, switch.sign] * -1
  }
  
  scores <- sapply(pca.list, function(x) x$pca[[locus]]$x[, pc])
  for(i in 1:nrow(scores)) {
    switch.sign <- sign(scores[i, ]) != sign(scores[i, 1])
    scores[i, switch.sign] <- scores[i, switch.sign] * -1
  }
  
  list(loadings = loadings, scores = scores)
}

#' Returns a vector of logicals identifying values that are 
#'   outliers. iqr = inter-quartile range, z = z-score
isOutlier <- function(x, type = c('iqr', 'z'), thresh = 3) {
  switch(
    match.arg(type),
    iqr = {
      quarts <- quantile(x, probs = c(0.25, 0.75))
      iqr <- diff(quarts)
      thresh <- c(quarts[1] - 1.5 * iqr, quarts[2] + 1.5 * iqr)
      x <= thresh[1] | x >= thresh[2]
    },
    z = {
      z.score <- (x - mean(x)) / sd(x)
      abs(z.score) >= thresh
    },
    NULL
  )
}

outlierLoadings <- function(pca) {
  apply(pca$rotation[, 1:pca$num.pcs], 2, function(x) {
    outliers <- x[isOutlier(x)]
    list(
      pos = sort(outliers[outliers > 0], decreasing = TRUE),
      neg = sort(outliers[outliers < 0]))
  })
}


contrastSummary <- function(results, d, pc, min.iter = length(results)) {
  res <- lapply(results, function(x) {
    outlierLoadings(x$pca[[d]])[[pc]]
  })
  
  pos <- lapply(res, function(x) names(x$pos)) |> 
    unlist() |> 
    table() |> 
    sort(d = T)
  
  neg <- lapply(res, function(x) names(x$neg)) |> 
    unlist() |> 
    table() |> 
    sort(d = T)
  
  list(
    pos = names(pos[pos >= min.iter]),
    neg = names(neg[neg >= min.iter])
  )
}


switchSummary <- function(results, min.p = 0.75) {
  resp <- results$labels['resp']
  pred <- results$labels['pred']
  
  min.pcs <- results$reps |> 
    sapply(function(x) {
      sapply(x$pca, function(pca.x) pca.x$num.pcs)
    }) |> 
    apply(1, min)
  
  w.post <- do.call(
    abind::abind,
    c(lapply(results$reps, function(x) {
      apply(x$post.list$w[1:min.pcs[resp], 1:min.pcs[pred], ], c(1, 2), mean)
    }), list(along = 3))
  )
  dimnames(w.post)[[3]] <- 1:dim(w.post)[3]
  names(dimnames(w.post)) <- c(resp, pred, 'rep')
  
  w.post <- w.post |> 
    as.data.frame.table() |> 
    setNames(c('resp', 'pred', 'rep', 'w')) |> 
    mutate(rep = as.numeric(rep)) 
  
  smry <- w.post |> 
    group_by(resp, pred) |> 
    summarize(median = median(w), .groups = 'drop') |> 
    filter(median > min.p)
  
  p <- w.post |> 
    left_join(smry, by = c('resp', 'pred')) |> 
    mutate(to.highlight = !is.na(median)) |> 
    ggplot() +
    geom_histogram(aes(w, fill = to.highlight)) +
    scale_fill_manual(values = c('black', 'red')) +
    facet_grid(pred ~ resp) +
    theme(legend.position = 'none')
  print(p)
  
  smry
}