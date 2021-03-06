.calc_IL_vector <- function(slope, aspect, sunzenith, sunazimuth, IL.epsilon) {
    IL <- cos(slope) * cos(sunzenith) + sin(slope) * sin(sunzenith) * 
        cos(sunazimuth - aspect)
    IL[IL == 0] <- IL.epsilon
    return(IL)
}

.calc_IL <- function(slope, aspect, sunzenith, sunazimuth, IL.epsilon) {
    overlay(slope, aspect,
            fun=function(slope_vals, aspect_vals) {
                .calc_IL_vector(slope_vals, aspect_vals, sunzenith, sunazimuth, 
                               IL.epsilon)
            })
}

#' Topographic correction for satellite imagery
#'
#' Perform topographic correction using a number of different methods. This 
#' code is modified from the code in the \code{landsat} package by Sarah 
#' Goslee.  This version of the code has been altered from the \code{landsat} 
#' version to allow the option of using a sample of pixels for calculation of k 
#' in the Minnaert correction (useful when dealing with large images).
#' 
#' See the help page for \code{topocorr} in the \code{landsat} package for 
#' details on the parameters.
#'
#' @export
#' @import raster
#' @param x image as a \code{RasterLayer}
#' @param slope the slope in radians as a \code{RasterLayer}
#' @param aspect the aspect in radians as a \code{RasterLayer}
#' @param sunelev sun elevation in degrees
#' @param sunazimuth sun azimuth in degrees
#' @param method the method to use for the topographic correction:
#' cosine, improvedcosine, minnaert, minslope, ccorrection, gamma, SCS, or 
#' illumination
#' @param na.value the value used to code no data values
#' @param IL.epsilon a small amount to add to calculated illumination values 
#' that are equal to zero to avoid division by zero resulting in Inf values
#' @param sampleindices (optional) row-major indices of sample pixels to use in 
#' regression models used for some topographic correction methods (like 
#' Minnaert). Useful when handling very large images. See
#' \code{\link{gridsample}} for one method of calculating these indices.
#' @param DN_min minimum allowable pixel value after correction (values less 
#' than \code{DN_min} are set to NA)
#' @param DN_max maximum allowable pixel value after correction (values less 
#' than \code{DN_max} are set to NA)
#' @return RasterBrick with two layers: 'slope' and 'aspect'
#' @author Sarah Goslee and Alex Zvoleff
#' @references
#' Sarah Goslee. Analyzing Remote Sensing Data in {R}: The {landsat} Package.  
#' Journal of Statistical Software, 2011, 43:4, pg 1--25.  
#' http://www.jstatsoft.org/v43/i04/
#' @examples
#' #TODO: add examples
topocorr_samp <- function(x, slope, aspect, sunelev, sunazimuth, method="cosine", 
                          na.value=NA, IL.epsilon=0.000001,
                          sampleindices=NULL, DN_min=NULL, DN_max=NULL) {
    # some inputs are in degrees, but we need radians
    stopifnot((sunelev >= 0) & (sunelev <= 90))
    stopifnot((sunazimuth >= 0) & (sunazimuth <= 360))
    sunzenith <- (pi/180) * (90 - sunelev)
    sunazimuth <- (pi/180) * sunazimuth

    x[x == na.value] <- NA

    IL <- .calc_IL(slope, aspect, sunzenith, sunazimuth, IL.epsilon)
    rm(aspect, sunazimuth)

    if (!is.null(sampleindices) && !(method %in% c('minnaert', 'minslope', 
                                                   'ccorrection'))) {
        warning(paste0('sampleindices are not used when method is "', method,
                       '". Ignoring sampleindices.'))
    }

    METHODS <- c("cosine", "improvedcosine", "minnaert", "minslope", 
                 "ccorrection", "gamma", "SCS", "illumination")
    method <- pmatch(method, METHODS)
    if (is.na(method)) 
        stop("invalid method")
    if (method == -1) 
        stop("ambiguous method")


    if(method == 1){
        ## Cosine method
        xout <- x * (cos(sunzenith)/IL)
    } else if(method == 2) {
        ## Improved cosine method
        ILmean <- cellStats(IL, stat='mean', na.rm=TRUE)
        xout <- x + (x * (ILmean - IL)/ILmean)
    } else if(method == 3) {
        ## Minnaert
        ## K is between 0 and 1
        ## only use points with greater than 5% slope
        targetslope <- atan(.05)

        if(all(x[slope >= targetslope] < 0, na.rm=TRUE)) {
            K <- 1
        } else {
            if (!is.null(sampleindices)) {
                K <- data.frame(y=x[slope >= targetslope][sampleindices],
                                x=IL[slope >= targetslope][sampleindices]/cos(sunzenith))
            } else {
                K <- data.frame(y=x[slope >= targetslope],
                                x=IL[slope >= targetslope]/cos(sunzenith))
            }
            # IL can be <=0 under certain conditions
            # but that makes it impossible to take log10 so remove those 
            # elements
            K <- K[!apply(K, 1, function(x)any(is.na(x))),]
            K <- K[K$x > 0, ]
            K <- K[K$y > 0, ]

            K <- lm(log10(K$y) ~ log10(K$x))
            K <- coefficients(K)[[2]] # need slope
            if(K > 1) K <- 1
            if(K < 0) K <- 0
        }

        xout <- x * (cos(sunzenith)/IL) ^ K
    } else if(method == 4) {
        ## Minnaert with slope
        ## K is between 0 and 1
        ## only use points with greater than 5% slope
        targetslope <- atan(.05)

        if(all(x[slope >= targetslope] < 0, na.rm=TRUE)) {
            K <- 1
        } else {
            if (!is.null(sampleindices)) {
                K <- data.frame(y=x[slope >= targetslope][sampleindices],
                                x=IL[slope >= targetslope][sampleindices] / cos(sunzenith))
            } else {
                K <- data.frame(y=x[slope >= targetslope], 
                                x=IL[slope >= targetslope]/cos(sunzenith))
            }
            # IL can be <=0 under certain conditions
            # but that makes it impossible to take log10 so remove those elements
            K <- K[!apply(K, 1, function(x) any(is.na(x))),]
            K <- K[K$x > 0, ]
            K <- K[K$y > 0, ]

            K <- lm(log10(K$y) ~ log10(K$x))
            K <- coefficients(K)[[2]] # need slope
            if(K > 1) K <- 1
            if(K < 0) K <- 0
        }
        xout <- x * cos(slope) * (cos(sunzenith) / (IL * cos(slope))) ^ K
    } else if(method == 5) {
        ## C correction
        if (!is.null(sampleindices)) {
            band.lm <- lm(x[sampleindices] ~ IL[sampleindices])
        } else {
            band.lm <- lm(getValues(x) ~ getValues(IL))
        }
        C <- coefficients(band.lm)[[1]]/coefficients(band.lm)[[2]]

        xout <- x * (cos(sunzenith) + C) / (IL + C)
    } else if(method == 6) {
        ## Gamma
        ## assumes zenith viewing angle
        viewterrain <- pi/2 - slope
        xout <- x * (cos(sunzenith) + cos(pi / 2)) / (IL + cos(viewterrain))
    } else if(method == 7) {
        ## SCS method from GZ2009
        xout <- x * (cos(sunzenith) * cos(slope))/IL
    } else if(method == 8) {
        ## illumination only
        xout <- IL
    }

    ## if slope is zero, reflectance does not change
    if(method != 8) 
        xout[slope == 0 & !is.na(slope)] <- x[slope == 0 & !is.na(slope)]

    if ((!is.null(DN_min)) || (!is.null(DN_max))) {
        xout <- calc(xout, fun=function(vals) {
                        if (!is.null(DN_min)) vals[vals < DN_min] <- NA
                        if (!is.null(DN_max)) vals[vals > DN_max] <- NA
                        return(vals)
                     })
    }
    return(xout)
}

