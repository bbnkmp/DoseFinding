## functions related to fitting dose-response models using ML or generalized approach

fit.control <- function(control){
  ## get control parameters for nonlinear fitting
  ## default parameters
  res <- list(nlminbcontrol = list(),
              optimizetol = .Machine$double.eps^0.5,
              gridSize = list(dim1 = 30, dim2 = 144))
  if(!is.null(control)){
    ## check arguments first
    if(!is.null(control$nlminbcontrol)){
      if(!is.list(control$nlminbcontrol))
        stop("nlminbcontrol element of fitControl must be a list")
    }
    if(!is.null(control$gridSize)){
      if(!is.list(control$gridSize))
        stop("gridSize element of fitControl must be a list")
      nams <- names(control$gridSize)
      ind <- any(is.na(match(nams,c("dim1", "dim2"))))
      if(ind){
        stop("gridSize list needs to have names dim1 and dim2")
      } else {
        if(!is.numeric(control$gridSize$dim1) | !is.numeric(control$gridSize$dim1))
          stop("gridSize$dim1 and gridSize$dim2 need to be numeric")
      }
    }
    nams <- names(control)
    res[nams] <- control
    if(!all(nams %in% c("nlminbcontrol","optimizetol","gridSize")))
      warning("control needs to have entries called \"nlminbcontrol\",\"optimizetol\",\"gridSize\"")
    res[nams] <- control
  }
  res
}

getGrid <- function(Ngrd, bnds, dim){
  if(dim == 1){
    grdnods <- (2*(1:Ngrd)-1)/(2*Ngrd)
    mat <- matrix(grdnods*(bnds[2]-bnds[1])+bnds[1], ncol = 1)
  } else { # use generalized lattice point set (glp) set (maximum size 75025)
    glp <- c(3, 5, 8, 13, 21, 34, 55, 89, 144, 233, 377, 
             610, 987, 1597, 2584, 4181, 6765, 10946, 
             17711, 28657, 46368, 75025)
    if(Ngrd > 75025)
      Ngrd <- 75025
    if(Ngrd < 5)
      Ngrd <- 5
    ind <- min((1:22)[glp >= Ngrd])
    N <- glp[ind]
    k <- 1:N
    mat <- cbind((k-0.5)/N, ((glp[ind-1]*k-0.5)/N)%%1)
    mat[,1] <- mat[,1]*(bnds[1,2]-bnds[1,1])+bnds[1,1]
    mat[,2] <- mat[,2]*(bnds[2,2]-bnds[2,1])+bnds[2,1]
  }
  mat
}


fitMod.raw <- function(dose, resp, data, model, S, type,
                       addCovars = ~1, placAdj = FALSE, bnds, df, start = NULL,
                       na.action = na.fail, control, doseNam, respNam,
                       off, scal, nodes, covarsUsed){
  ## fit model but do not check for arguments (for use in MCPMod function)!
  ## differences to fitMod:
  ## - dose, resp need to be vectors containing the data
  ## - additional args: doseNam, respNam, off, scal
  builtIn <- c("linlog", "linear", "quadratic", "linInt", "emax",
               "exponential", "logistic", "betaMod", "sigEmax")
  modelNum <- match(model, builtIn)

  weights <- NULL;clinS <- NULL
  ## package data for model-fitting
  if(type == "general"){ # general approach
    dataFit <- data.frame(dose = dose, resp = resp)
    ## pre-calculate some necessary information
    clinS <- chol(solve(S))
  } else { # normal data
    if(covarsUsed){ 
      dataFit <- data
      ind1 <- which(names(dataFit) == doseNam)
      ind2 <- which(names(dataFit) == respNam)
      names(dataFit)[c(ind1, ind2)] <- c("dose", "resp")
      ord <- order(dataFit$dose)
      dataFit <- dataFit[ord,] ## sorting by increasing dose is needed for optGrid (specifically getZmat)
    } else { ## for efficiency fit on means in case of no covariates
      dataFit <- data.frame(dose = sort(unique(dose)), 
                            resp = as.numeric(tapply(resp, dose, mean)))
      ## calculate within group variance to recover full RSS later
      n <- as.vector(table(dose))
      vars <- tapply(resp, dose, var)
      vars[n == 1] <- 0
      S2 <- sum((n - 1) * vars)
      weights <- n
    }
  } 
  ## call actual fitting algorithms
  if(is.element(modelNum, 1:4)){ # linear model
    fit <- fitModel.lin(dataFit, model, addCovars, off, type,
                        weights, placAdj, clinS)
  } else { # non-linear model
    fit <- fitModel.bndnls(dataFit, model, addCovars, type, bnds, control,
                           start, scal, weights, placAdj, clinS)
  }
  ## now need to post-process
  resid <- fit$resid
  if(type == "normal" & !covarsUsed) # fitted on means, need to recover full RSS
    resid <- fit$resid + S2
  ## extract levels for factor covariates
  if(covarsUsed){
    usedVars <- all.vars(addCovars) # variables used for fitting
    ind <- sapply(data, function(x) is.factor(x)) # determine factors in data
    ind <- is.element(names(data), usedVars) & ind # has the factor been used in fitting?
    xlev <- lapply(data[ind], levels) # extract levels
  } else {
    xlev <- NULL
  }
  df <- ifelse(is.null(fit$df), df, fit$df)
  res <- list(coefs = fit$coefs, resid, df=df,
              addCovars = addCovars)
  names(res)[2] <- ifelse(type == "normal", "RSS", "gRSS")
  attr(res, "model") <- model
  attr(res, "type") <- type
  attr(res, "placAdj") <- placAdj
  attr(res, "addCovars") <- addCovars
  attr(res, "xlev") <- xlev
  attr(res, "doseRespNam") <- c(doseNam, respNam)
  attr(res, "off") <- off
  attr(res, "scal") <- scal
  attr(res, "nodes") <- nodes
  class(res) <- "DRMod"
  res
}
    
fitModel.lin <- function(dataFit, model, addCovars, off, type,
                         weights, placAdj, clinS){
  dose <- dataFit$dose
  resp <- dataFit$resp
  ## build model matrices and fit model using QR decompositions
  X <- switch(model,
              linear = cbind(1, dose),
              linlog = cbind(1, log(dose + off)),
              quadratic = cbind(1, dose, dose^2),
              linInt = model.matrix(~as.factor(dose)-1, data=dataFit))
                
  if(model == "quadratic"){
    nam <- c("e0", "b1", "b2")
  } else {
    if(model == "linInt"){
      nam <- paste("d", sort(unique(dose)), sep="")
    } else {
      nam <- c("e0", "delta")
    }
  }
  if(placAdj){ # no intercept
    if(model != "linInt"){ # only need to remove intercept for non-linInt mods
      X <- X[,-1, drop = FALSE]
      nam <- nam[-1]
    }
  }
  covarsUsed <- addCovars != ~1
  if(type == "normal" & covarsUsed){ # normal with covariates
    form <- paste("resp ~", addCovars[2], sep="")
    m <- model.matrix(as.formula(form), data = dataFit)
    X <- cbind(X, m[,-1])
    nam <- c(nam, colnames(m)[-1])
    par <- as.numeric(qr.coef(qr(X),resp))
    df <- nrow(X)-ncol(X)
  } else { # general or normal without covariates
    if(type == "normal"){
      clinS <- diag(sqrt(weights))
      df <- sum(weights) - length(nam)
    } else {
      df <- NULL
    }
    par <- as.numeric(qr.coef(qr(clinS%*%X),clinS%*%resp))
  }
  pred <- as.numeric(X%*%par)
  names(par) <- nam
  if(covarsUsed){
    out <- list(coefs=par, sum((resp-pred)^2), df = df)    
  } else {
    out <- list(coefs=par, as.numeric(crossprod(clinS%*%(resp-pred))), df = df)
  }
  names(out)[2] <- "resid"
  out
}


fitModel.bndnls <- function(dataFit, model, addCovars, type, bnds, control, 
                            start, scal, weights, placAdj, clinS){

  ctrl <- fit.control(control)
  if(model == "emax"|model == "exponential"){
    dim <- 1
    if(!is.matrix(bnds))
      bnds <- matrix(bnds, nrow = 1)
  } else {
    dim <- 2
  }
  dose <- dataFit$dose
  resp <- dataFit$resp
  ## preliminary calculations (need resXY, clinS and qrX)
  covarsUsed <- addCovars != ~1
  covarNams <- NULL
  if(type == "general"){ # general approach
    if(placAdj){ # no intercept
      resXY <- as.numeric(clinS%*%resp)
    } else {
      X2 <- clinS%*%matrix(1, nrow = length(dose))
      resp2 <- clinS%*%resp
      qrX <- qr(X2)
      resXY <- as.numeric(qr.resid(qrX, resp2))
    }
  } else { # normal data
    form <- paste("resp ~", addCovars[2], sep="")
    m <- model.matrix(as.formula(form), dataFit)
    if(covarsUsed){ # covariates present
      covarNams <- colnames(m)[2:ncol(m)]
      qrX <- qr(m)
      resXY <- as.numeric(qr.resid(qrX, resp))
    } else { # no covariates: fit on means
      clinS <- diag(sqrt(weights))
      qrX <- qr(clinS%*%m)
      resXY <- as.numeric(qr.resid(qrX, sqrt(weights)*resp))
    }
  }

  ## if no starting values provided use grid-search
  if(is.null(start)){
    opt <- optGrid(model, dim, bnds, ctrl$gridSize, dose, type,
                   qrX, resXY, clinS, placAdj, scal)
    strt <- opt$coefs;resid <- opt$resid
    if(dim == 1){ ## refine bounds
      N <- ctrl$gridSize$dim1
      dif <- (bnds[2]-bnds[1])/N # distance between grid points
      bnds[1] <- max(c(strt-1.1*dif), bnds[1])
      bnds[2] <- min(c(strt+1.1*dif), bnds[2])
    }
  } else {
    strt <- start;resid <- Inf
  }
  ## start local optimizer at starting value
  opt2 <- optLoc(model, dim, bnds, dose, qrX, resXY, strt, scal,
                 placAdj, type, ctrl$optimizetol, ctrl$nlminbcontrol,
                 clinS)
  ## recover names
  nam1 <- switch(model, emax = c("eMax", "ed50"),
                 sigEmax = c("eMax", "ed50", "h"),
                 logistic = c("eMax", "ed50", "delta"),
                 exponential = c("e1", "delta"),
                 betaMod = c("eMax", "delta1", "delta2"))
  ## recover all parameters from nonlin parameter and return results
  f0 <- getStandDR(model, dose, opt2$coefs, scal)
  if(type == "general"){ # return "generalized" sum of squares
    if(placAdj){ # no intercept
      par0 <- sum((clinS %*% f0) * (clinS%*%resp))/sum((clinS %*% f0)^2)
      pred <- f0*par0
      par <- c(par0, opt2$coefs)
      names(par) <- nam1      
    } else { # with intercept
      F <- cbind(1, f0)
      par0 <- qr.coef(qr(clinS %*% F), clinS %*% resp)
      pred <- F%*%par0
      par <- c(par0, opt2$coefs)
      names(par) <- c("e0", nam1)
    }
    return(list(coefs=par, resid = opt2$resid))
  } else { ## type == normal
    X <- cbind(1,f0,m[,-1])
    if(covarsUsed){
      par0 <- as.numeric(qr.coef(qr(X),resp))
      pred <- as.numeric(X%*%par0)
      par <- c(par0[1:2], opt2$coefs, par0[3:length(par0)])
      df <- nrow(X) - length(par)
    } else { # no covariates; was fitted on means
      par0 <- qr.coef(qr(clinS %*% X), clinS %*% resp)
      pred <- X%*%par0
      par <- c(par0, opt2$coefs)
      df <- sum(weights) - length(par)
    }
    names(par) <- c("e0", nam1, covarNams)
    return(list(coefs=par, resid = opt2$resid, df = df))
  }
}

optGrid <- function(model, dim, bnds, gridSize, dose, type,
                    qrX, resXY, wMat, placAdj, scal){
  ## grid optimizer for non-linear case
  N <- ifelse(dim==1, gridSize$dim1, gridSize$dim2)
  if(N < 1)
    stop("need N >= 1")
  nodes <- getGrid(N, bnds, dim)
  ## calculate residuals
  if(type == "normal" & is.null(wMat)){ # normal with covariates
    Zmat <- getZmat(dose, nodes, model, dim, scal)
    resZmat <- qr.resid(qrX, Zmat)
  } else { # normal without covariates or general
    Zmat <- getZmat.weighted(dose, nodes, model, dim, scal)
    Zmat <- wMat%*%Zmat
    if(placAdj & type == "general") # general without intercept
      resZmat <- Zmat
    else
      resZmat <- qr.resid(qrX, Zmat)
  }

  colsms1 <- colSums(resZmat * resXY)
  colsms2 <- colSums(resZmat * resZmat)
  RSSvec <- sum(resXY*resXY) - (colsms1*colsms1)/colsms2
  indMin <- which.min(RSSvec)
  coefs <- nodes[indMin,]
  list(coefs=coefs, resid = RSSvec[indMin])  
}

getZmat <- function(x, nodes, model, dim, scal=NULL){
  getPred <- function(vec, x, model, scal)
    getStandDR(model, x, vec, scal)
  xU <- sort(unique(x))
  n <- as.numeric(table(x))
  args <- nodes
  res0 <- apply(args, 1, getPred, x=xU, model=model, scal=scal)
  Zmat <- apply(res0, 2, function(x,n) rep(x,n), n=n)
  Zmat
}

getZmat.weighted <- function(x, nodes, model, dim, scal){
  # does not exploit repeated observations
  getPred <- function(vec, x, model, scal)
    getStandDR(model, x, vec, scal)
  args <- nodes
  Zmat <- apply(args, 1, getPred, x=x, model=model, scal=scal)
  Zmat
}

getStandDR <- function(model, x, nl, scal){
  ## calculate standardized response for nonlinear models
  switch(model,
         emax = emax(x, 0, 1, nl),
         sigEmax = sigEmax(x, 0, 1, nl[1], nl[2]),
         exponential = exponential(x, 0, 1, nl),
         logistic = logistic(x, 0, 1, nl[1], nl[2]),
         betaMod = betaMod(x, 0, 1, nl[1], nl[2], scal))
}

optLoc <- function(model, dim, bnds, dose, qrX, resXY, start, scal,
                   placAdj, type, tol, nlminbcontrol, clinS){
  ## function to calculate ls residuals (to be optimized)
  optFunc <- function(nl, x, qrX, resXY, model, scal, clinS){
    Z <- getStandDR(model, x, nl, scal)
    if(!is.null(clinS)){
      Z <- clinS%*%Z
    }
    if(placAdj & type == "general"){
      resXZ <- Z
    } else {
      resXZ <- try(qr.resid(qrX, Z)) # might be NaN if function is called on strange parameters
      if(inherits(resXZ, "try-error"))
        return(NA)
    }
    sumrsXYrsXZ <- sum(resXY*resXZ)
    sum(resXY*resXY) - sumrsXYrsXZ*sumrsXYrsXZ/sum(resXZ*resXZ)
  }

  if(dim == 1){ # one-dimensional models
    optobj <- optimize(optFunc, c(bnds[1], bnds[2]), x=dose, qrX=qrX, resXY=resXY,
                       model = model, tol=tol, clinS=clinS, scal = scal)
    coefs <- optobj$minimum
    RSS <- optobj$objective
  } else {
    optobj <- try(nlminb(start, optFunc, x=dose, qrX=qrX, resXY=resXY,
                         model = model, scal = scal,
                         lower = bnds[,1], upper = bnds[,2],
                         control = nlminbcontrol, clinS=clinS))
    if(inherits(optobj, "try-error")){
      coefs <- RSS <- NA
    } else {
      coefs <- optobj$par
      RSS <- optobj$objective
    }
  }
  list(coefs=coefs, resid=RSS)
}

sepCoef <- function(object){
  model <- attr(object, "model")
  if(attr(object, "type") == "general")
    return(list(DRpars=object$coefs, covarPars = numeric(0)))
  if(attr(object, "type") == "normal" & object$addCovars == ~1)
    return(list(DRpars=object$coefs, covarPars = numeric(0)))
  ## determine the number of parameters (not counting e0 and eMax)
  if(model %in% c("linear","linlog"))
    dim <- 2
  if(model %in% c("quadratic", "exponential", "emax"))
    dim <- 3
  if(model %in% c("sigEmax", "logistic", "betaMod"))
    dim <- 4
  if(model == "linInt")
    dim <- length(attr(object, "nodes"))
  cf <- object$coefs
  p <- length(cf)
  ## extract coefficients
  DRpars <- cf[1:dim] # coefs of DR model
  covarPars <- cf[(dim+1):p]
  return(list(DRpars=DRpars, covarPars=covarPars))
}

gradCalc <- function(model, cf, dose, off, scal, nodes){
  ## wrapper function to calculate gradient
  switch(model,
         linear = {
           linearGrad(dose)
         }, linlog = {
           linlogGrad(dose, off=off)
         }, quadratic = {
           quadraticGrad(dose)
         }, emax = {
           emaxGrad(dose, eMax = cf[2], ed50 = cf[3])
         }, logistic = {
           logisticGrad(dose, eMax = cf[2], ed50 = cf[3], delta = cf[4])
         }, sigEmax = {
           sigEmaxGrad(dose, eMax = cf[2], ed50 = cf[3], h = cf[4])
         }, betaMod = {
           betaModGrad(dose, eMax = cf[2], delta1 = cf[3], delta2 = cf[4], scal = scal)
         }, exponential = {
           exponentialGrad(dose, e1 = cf[2], delta = cf[3])
         }, linInt = {
           linIntGrad(dose, resp=cf, nodes=nodes)
         })
}


plotFunc <- function(x, CI = FALSE, level = 0.95,
                     plotData = c("means", "meansCI", "raw", "none"),
                     plotGrid = TRUE, colMn = 1, colFit = 1, ...){
  ## Extract relevant information from object
  if(inherits(x, "DRMod"))
    obj <- x
  if(inherits(x, "MCPMod"))
    obj <- x$mods[[1]]
  addCovars <- attr(obj, "addCovars")
  covarsUsed <- addCovars != ~1
  xlev <- attr(obj, "xlev")
  doseNam <- attr(obj, "doseRespNam")[1]
  respNam <- attr(obj, "doseRespNam")[2]
  data <- attr(obj, "data")
  type <- attr(obj, "type")
  placAdj <- attr(obj, "placAdj")
  plotData <- match.arg(plotData)
  if(type == "general" & plotData == "raw")
    stop("plotData =\"raw\" only allowed if fitted DRmod object is of type = \"normal\"")

  ## save anova info in pList list
  pList <- as.list(data)
  if(type == "normal"){
    if(plotData %in% c("means", "meansCI")){
      ## produce estimates for ANOVA type model
      data$doseFac <- as.factor(data[[doseNam]])
      form <- as.formula(paste(respNam, "~ doseFac +", addCovars[2]))
      fit <- lm(form, data=data)
      ## build design matrix for prediction
      dose <- sort(unique(data[[doseNam]]))
      preddat <- data.frame(doseFac=factor(dose))
      m <- model.matrix(~doseFac, data=preddat)
      if(covarsUsed){
        ## get sas type ls-means
        nams <- all.vars(addCovars)
        out <- list()
        z <- 1
        for(covar in nams){
          varb <- data[,covar]
          if(is.numeric(varb)){
            out[[z]] <- mean(varb)
          } else if(is.factor(varb)){
            k <- nlevels(varb)
            out[[z]] <- rep(1/k, k-1)
          }
          z <- z+1
        }
        out <- do.call("c", out)
        m0 <- matrix(rep(out, length(dose)), byrow=TRUE, nrow = length(dose))
        m <- cbind(m, m0)
      }
      pList$dos <- sort(unique(data[[doseNam]]))
      pList$mns <- as.numeric(m%*%coef(fit))
      if(plotData == "meansCI"){
        sdv <- sqrt(diag(m%*%vcov(fit)%*%t(m)))
        quant <- qt(1 - (1 - level)/2, df=fit$df)
        pList$lbndm <- pList$mns-quant*sdv
        pList$ubndm <- pList$mns+quant*sdv
      }
    }
  }
  if(type == "general"){
    ## extract ANOVA estimates
    if(plotData %in% c("means", "meansCI")){
      pList$dos <- data[[doseNam]]
      pList$mns <- data[[respNam]]
      sdv <- sqrt(diag(data$S))
      if(plotData == "meansCI"){
        quant <- qnorm(1 - (1 - level)/2)
        pList$lbndm <- pList$mns-quant*sdv
        pList$ubndm <- pList$mns+quant*sdv
      }
    }
  }
  
  doseSeq <- seq(0, max(data[[doseNam]]), length=201)
  ## create data frame for plotting dr-functions
  predtype <- ifelse(placAdj, "effect-curve", "ls-means")
  if(inherits(x, "MCPMod")){
    nmods <- length(x$mods)
    lst <- vector(mode = "list", nmods)
    for(i in 1:nmods){
      pred <- predict(x$mods[[i]], predType = predtype, doseSeq = doseSeq, se.fit = CI)
      lbnd <- ubnd <- rep(NA, length(doseSeq))
      if(CI){
        quant <- qt(1 - (1 - level)/2, df=x$mods[[i]]$df)
        lbnd <- pred$fit-quant*pred$se.fit
        ubnd <- pred$fit+quant*pred$se.fit
        pred <- pred$fit
      }
      lst[[i]] <- data.frame(rep(doseSeq, 3), c(pred, lbnd, ubnd),
                             rep(c("pred", "LB", "UB"), each=length(doseSeq)),
                             attr(x$mods[[i]], "model"))
    }
    plotdf <- do.call("rbind", lst)
  }
  if(inherits(x, "DRMod")){
    pred <- predict(x, predType = predtype, doseSeq = doseSeq, se.fit = CI)
    lbnd <- ubnd <- rep(NA, length(doseSeq))
    if(CI){
      quant <- qt(1 - (1 - level)/2, df=x$df)
      lbnd <- pred$fit-quant*pred$se.fit
      ubnd <- pred$fit+quant*pred$se.fit
      pred <- pred$fit
    }
    plotdf <- data.frame(rep(doseSeq, 3), c(pred, lbnd, ubnd),
                         rep(c("pred", "LB", "UB"), each=length(doseSeq)),
                         attr(x, "model"))
  }
  names(plotdf) <- c(doseNam, respNam, "group", "model")
  
  ## calculate plotting range
  rng <- switch(plotData,
                raw = range(data[[respNam]]),
                none = range(plotdf[[respNam]], na.rm=TRUE),
                range(plotdf[[respNam]], pList$mns, pList$lbndm, pList$ubndm,
                      na.rm=TRUE))
  dff <- diff(rng)
  ylim <- c(rng[1] - 0.05 * dff, rng[2] + 0.05 * dff)
  
  ## produce plot
  form <- as.formula(paste(respNam, "~", doseNam, "|model", sep=""))
  print(
    lattice::xyplot(form, groups = plotdf$group, data = plotdf, pList=pList, ...,
           ylim = ylim, panel = function(x, y, ..., pList){
             if(plotGrid)
               lattice::panel.grid(h = -1, v = -1, col = "lightgrey", lty = 2)
             if(plotData != "none"){
               if(type == "normal" & plotData == "raw"){
                 lattice::lpoints(data[[doseNam]], data[[respNam]], col = "grey45", pch=19)
               } else {
                 lattice::lpoints(pList$dos, pList$mns, pch=19, col = colMn)
                 if(plotData == "meansCI"){
                   quant <- qnorm(1 - (1 - level)/2)
                   for(i in 1:length(pList$dos)){
                     lattice::llines(rep(pList$dos[i], 2),
                            c(pList$lbndm[i], pList$ubndm[i]),
                            lty=2, col = colMn, ...)
                   }
                 }
               }
             }
             lattice::panel.xyplot(x, y, col=colFit, type="l", ...)
           }))
}


gAIC <- function (object, ..., k = 2) 
  UseMethod("gAIC")




