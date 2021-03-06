#' Perform optimized Loess regression for each chromosome
#' 
#' Called after the \code{\link{calculateDistance}} step and before
#' \code{\link{prePeak}}.
#'
#' @param mmapprData The \code{\linkS4class{MmapprData}} object to be analyzed.
#'
#' @return A \code{\linkS4class{MmapprData}} object with the \code{$loess} element
#'   of the \code{distance} slot list filled.
#'   
#' @examples 
#' if (requireNamespace('MMAPPR2data', quietly = TRUE)) {
#'     ## Ignore these lines:
#'     MMAPPR2:::.insertFakeVEPintoPath()
#'     genDir <- gmapR::GmapGenomeDirectory('DEFAULT', create=TRUE)
#' 
#'     # Specify parameters:
#'     mmapprParam <- MmapprParam(refGenome = gmapR::GmapGenome("GRCz11", genDir),
#'                                wtFiles = MMAPPR2data::zy13wtBam(),
#'                                mutFiles = MMAPPR2data::zy13mutBam(),
#'                                species = "danio_rerio")
#' }
#' \dontrun{
#' md <- new('MmapprData', param = mmapprParam)
#' postCalcDistMD <- calculateDistance(md)
#' 
#' postLoessMD <- loessFit(postCalcDistMD)
#' }
#' @export
loessFit <- function(mmapprData) {
    loessOptResolution <- mmapprData@param@loessOptResolution
    loessOptCutFactor <- mmapprData@param@loessOptCutFactor
    
    # each item (chr) of distance list has mutCounts, wtCounts,
    # distanceDf going in
    mmapprData@distance <- 
        .runFunctionInParallel(mmapprData@distance,
                               functionToRun=.loessFitForChr,
                               loessOptResolution=loessOptResolution,
                               loessOptCutFactor=loessOptCutFactor)
    #.loessFitForChr returns list with mutCounts, wtCounts, loess, aicc
    
    return(mmapprData)
}


.getLoess <- function(s, pos, euc_dist, ...){
    x <- try(loess(euc_dist ~ pos, span=s, degree=1, 
                   family="symmetric", ...), silent=TRUE)
    return(x)
}

# gets greater of the two differences to either side of a span in a
# vector of spans
.localResolution <- function(spans, span) {
    stopifnot(is.numeric(spans))
    stopifnot(all(spans >= 0 & spans <= 1))
    
    spans <- unique(sort(spans))
    index <- which(spans %in% span)
    stopifnot(length(index) == 1)
    
    result <- max(c(diff(spans)[index-1], diff(spans)[index]), na.rm=TRUE)
    stopifnot(is.numeric(result))
    return(result)
}

#returns a list of aicc and span values as well as the time it took
#define needed functions
.aiccOpt <- function(distanceDf, spans, resolution, cutFactor) {
    aiccValues <- vapply(spans, .aicc, FUN.VALUE=numeric(1),
                         euc_dist=distanceDf$distance, pos=distanceDf$pos)
    if (length(spans) != length(aiccValues))
        stop("AICc values and spans don't match")
    aiccDf <- data.frame(spans, aiccValues)
    
    #finds two lowest local minima for finer attempt
    minVals <- .minTwo(.localMin(aiccDf$aiccValues))
    # gets first column of dataframe after selecting for rows that
    # match the two lowest localMins
    minSpans <- aiccDf[aiccDf$aiccValues %in% minVals, 1]
    
    # goes through each minimum and goes deeper if resolution isn't fine enough
    for (minSpan in minSpans) {
        # get resolution at that point, which is greater of differences
        # to either side
        localResolution <- round(.localResolution(spans, minSpan),
                                 digits=.numDecimals(resolution))
        stopifnot(is.numeric(localResolution))
        if (abs(localResolution) > resolution){
            addVector <- ((localResolution * cutFactor) * seq(1, 9))
            newSpans <- c(minSpan - addVector, minSpan + addVector)
            newSpans <- newSpans[newSpans > 0 & newSpans <= 1]
            newSpans <- round(newSpans, digits = .numDecimals(resolution))
            newSpans <- unique(newSpans)
            #recursive call
            aiccDf <- rbind(aiccDf, .aiccOpt(distanceDf, spans=newSpans, 
                                             resolution=resolution,
                                             cutFactor=cutFactor))
        }
    }
    return(aiccDf)
}

#returns minimum two elements (useful for .aiccOpt)
.minTwo <- function(x){
    len <- length(x)
    if(len < 2){
        return(x)
    }
    sort(x,partial=c(1, 2))[c(1, 2)]
}

#returns all local minima (problem if repeated local maxima on end)
.localMin <- function(x){
    indices <- which(diff(c(FALSE,diff(x)>0,TRUE))>0)
    return(x[indices])
}

.numDecimals <- function(x) {
    stopifnot(is(x, "numeric"))
    if (!grepl("[.]", x)) return(0)
    x <- sub("0+$","",x)
    x <- sub("^.+[.]","",x)
    nchar(x)
}

.aicc <- function (s, euc_dist, pos) {
    # extract values from loess object
    x <- .getLoess(s, pos, euc_dist)
    if(is(x, "try-error")) return(NA)
    span <- x$pars$span
    n <- x$n
    traceL <- x$trace.hat
    sigma2 <- sum( x$residuals^2 ) / (n-1)
    delta1 <- x$one.delta
    delta2 <- x$two.delta
    enp <- x$enp
    #return aicc value
    return(log(sigma2) + 1 + 2* (2*(traceL+1)) / (n-traceL-2))
    #what I understand:
    #return(n*log(sigma2) + 2*traceL + 2*traceL*(traceL + 1) / (n-traceL-1))
}


# the function that gets run for each chromosome
# takes element of mmapprData@distance (with mutCounts, wtCounts, distanceDf)
# outputs complete element of mmapprData@distance
# with columns (mutcounts, wtCounts, loess, aicc)
.loessFitForChr <- function(resultList, loessOptResolution, loessOptCutFactor){
    startTime <- proc.time()
    tryCatch({
        if(is(resultList, 'character')) stop('--Loess fit failed')
        
        #returns dataframe with spans and aicc values for each loess
        startSpans <- c(seq(.01, .16, .01), seq(.21, .91, .10))
        resultList$aicc <- .aiccOpt(distanceDf = resultList$distanceDf, 
                                              spans = startSpans,
                                              resolution = loessOptResolution,
                                              cutFactor = loessOptCutFactor)
        
        #now get loess for best aicc
        minAicc <- min(resultList$aicc$aiccValues, na.rm=TRUE)
        bestSpan <- round(
            resultList$aicc[resultList$aicc$aiccValues == minAicc, 'spans'],
            digits = .numDecimals(loessOptResolution)
        )
        bestSpan <- mean(bestSpan, na.rm = TRUE)
        resultList$loess <- .getLoess(bestSpan, resultList$distanceDf$pos,
                                      resultList$distanceDf$distance,
                                      surface = "direct"
        )
        
        precision <- .numDecimals(loessOptResolution)
        
        #no longer needed
        resultList$distanceDf <- NULL
        resultList$seqname <- NULL
        
        resultList$loessTime <- proc.time() - startTime
        return(resultList)
    },
    error = function(e) {
        if (is(resultList, "character"))
            return(paste0(resultList, e$message))
        else return(e$message)
    }
    )
}

