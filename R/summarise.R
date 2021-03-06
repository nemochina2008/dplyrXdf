#' Summarise multiple values to a single value
#'
#' @param .data A tbl for an Xdf data source; or a raw Xdf data source.
#' @param ... Name-value pairs of summary functions like \code{\link{min}()}, \code{\link{mean}()}, \code{\link{max}()} etc.
#' @param .outFile Output format for the returned data. If not supplied, create an xdf tbl; if \code{NULL}, return a data frame; if a character string naming a file, save an Xdf file at that location.
#' @param .rxArgs A list of RevoScaleR arguments. See \code{\link{rxArgs}} for details.
#'
#' @details
#' There are 5 possible methods for doing the summarisation. To choose which method is used, specify a \code{.method} argument in the call to \code{summarise}, with a number from 1 to 5.
#' \enumerate{
#'  \item use \code{\link[RevoScaleR]{rxCube}}, cbind data frames together: only \code{n()}, \code{mean()}, \code{sum()} supported, grouped data only (fast)
#'  \item use \code{\link[RevoScaleR]{rxSummary}}, cbind data frames together: stats in rxSummary supported (fast)
#'  \item as 2), but build classification levels by pasting the grouping variable(s) together (moderately fast)
#'  \item split into multiple Xdfs by group, run \code{dplyr::summarise} on each, rbind xdfs together: arbitrary stats supported (slow)
#'  \item split into multiple Xdfs by group, run \code{rxSummary} on each, rbind xdfs together: stats in rxSummary supported (slowest, most scalable)
#' }
#' The default method is 1 if the data is grouped and the requested summary statistics are supported by \code{rxCube}; otherwise 2 if the requested statistics are supported by \code{rxSummary}; otherwise 4. Method 3 is supplied for the case where the product of factor levels for the grouping variables exceeds 2^32 - 1, a known limitation of \code{rxCube} and \code{rxSummary}.
#'
#' Supplying custom functions to summarise is supported, but they must be \emph{named} functions (and will automatically cause \code{.method=4} to be selected). Anonymous functions will cause an error.
#'
#' Due to limitations in RevoScaleR support for HDFS, you should take note of the following:
#' \itemize{
#'   \item The result of the summarise will be streamed to the client (either the edge node or a remote client) before being written back to HDFS.
#'   \item If summarising over character grouping variables, it may be faster to specify \code{.method=4} or \code{5}. This is because the usual summarise functions, \code{rxSummary} and \code{rxCube}, require factor or numeric groups, and converting character to factor can be slow for HDFS data.
#' }
#'
#' @return
#' An object representing the summary. This depends on the \code{.outFile} argument: if missing, it will be an xdf tbl object; if \code{NULL}, a data frame; and if a filename, an Xdf data source referencing a file saved to that location.
#'
#' @seealso
#' \code{\link[dplyr]{summarise}} in package dplyr, \code{\link[RevoScaleR]{rxCube}}, \code{\link[RevoScaleR]{rxSummary}}
#'
#' @examples
#' mtx <- as_xdf(mtcars, overwrite=TRUE)
#'
#' tbl <- summarise(mtx, m=mean(mpg))
#' as.data.frame(tbl)
#'
#' tbl2 <- group_by(mtx, cyl) %>% summarise(m=mean(mpg))
#' as.data.frame(tbl2)
#'
#' # filter and summarise simultaneously with .rxArgs
#' tbl3 <- summarise(mtx, m=mean(mpg), .rxArgs=list(rowSelection=cyl > 4))
#' as.data.frame(tbl3)
#'
#' # compute a weighted mean
#' tbl4 <- summarise(mtx, m=mean(mpg), .rxArgs=list(pweights="wt"))
#' as.data.frame(tbl4)
#'
#' # save to a persistent Xdf file
#' summarise(mtx, m=mean(mpg), .outFile="mtcars_summary.xdf")
#' @aliases summarise summarize
#' @rdname summarise
#' @export
summarise.RxFileData <- function(.data, ..., .outFile=tbl_xdf(.data), .rxArgs, .method=NULL)
{
    dots <- quos(..., .named=TRUE)

    exprs <- lapply(dots, get_expr)
    stats <- sapply(exprs, function(term) as.character(term[[1]]))
    needs_mutate <- vapply(exprs, function(e)
    {
        (length(e) < 2 || !is.name(e[[2]])) && !identical(e, quote(n()))
    }, logical(1))
    if(any(needs_mutate))
        stop("summarise with xdf tbls only works with named variables, not expressions")

    .rxArgs <- enquo(.rxArgs)
    .rxArgs <- if(!quo_is_missing(.rxArgs) && is_lang(.rxArgs))
        lang_args(.rxArgs)
    else NULL

    grps <- group_vars(.data)

    # options:
    # 1- one or multiple calls to rxCube, cbind data frames together: only n, mean, sum supported, grouped data only (fast)
    # 2- one call to rxSummary, cbind data frames together: stats in rxSummary supported (fast)
    # 3- as 2, but build classification levels by pasting grouping vars together (work around cube size limitation in rxCube/rxSummary)
    # 4- split into multiple xdfs, dplyr::summarise on each, rbind xdfs together: arbitrary stats supported (slow)
    # 5- split into multiple xdfs, rxSummary on each, rbind xdfs together: stats in rxSummary supported (slowest, most scalable)
    .method <- selectSmryMethod(stats, .method, grps)

    smryFunc <- switch(.method,
        smryRxCube, smryRxSummary, smryRxSummary2, smryRxSplitDplyr, smryRxSplit)
    smry <- smryFunc(.data, grps, stats, exprs, .rxArgs)

    output <- makeSmryOutput(smry, .outFile, .data)

    # strip off one level of grouping
    simpleRegroup(output, grps[-length(grps)])
}


selectSmryMethod <- function(stats, method=NULL, groups=NULL)
{
    cubeStats <- all(stats %in% c("mean", "sum", "n"))
    simpleStats <- all(stats %in% c("mean", "sum", "sd", "var", "n", "min", "max"))
    grouped <- length(groups) > 0
    defaultMethod <- is.null(method)
    if(!defaultMethod && !(method %in% 1:5))
        stop("unknown method selection for summarise (must be a number from 1 to 5)")
    if(defaultMethod)
    {
        if(cubeStats && grouped)
            method <- 1
        else if(simpleStats)
            method <- 2
        else method <- 4
    }
    else  # various sanity checks
    {
        if(method == 1 && !grouped)
        {
            warning("grouping variables required for .method = 1", call.=FALSE)
            method <- Recall(stats=stats, method=NULL, groups=groups)
        }
        else if(method == 3 && !grouped)
        {
            warning("grouping variables required for .method = 3", call.=FALSE)
            method <- Recall(stats=stats, method=NULL, groups=groups)
        }
        else if(method == 1 && !cubeStats)
        {
            warning("requested summary statistics not supported by rxCube", call.=FALSE)
            method <- Recall(stats=stats, method=NULL, groups=groups)
        }
        else if(method %in% c(2, 5) && !simpleStats)
        {
            warning("requested summary statistics not supported by rxSummary", call.=FALSE)
            method <- Recall(stats=stats, method=NULL, groups=groups)
        }
    }
    method
}


makeSmryOutput <- function(smry, .outFile, .data)
{
    if(in_hdfs(.data))
        makeSmryOutputHdfs(smry, .outFile, .data)
    else makeSmryOutputNative(smry, .outFile, .data)
}


makeSmryOutputHdfs <- function(smry, .outFile, .data)
{
    # summarise will create a data frame on client, whether edge node or remote
    if(is.data.frame(smry))
    {
        # easy case: return data frame
        if(is.null(.outFile))
            return(smry)

        returnTbl <- inherits(.outFile, "tbl_xdf")
        if(isRemoteHdfsClient())
        {
            # if remote, create xdf on client then copy it
            if(inherits(.outFile, "RxXdfData"))
                .outFile <- .outFile@file

            localXdf <- tbl_xdf(file=file.path(get_dplyrxdf_dir("native"), basename(.outFile)),
                fileSystem=RxNativeFileSystem(),
                createCompositeSet=is_composite_xdf(.data))
            on.exit(deleteIfTbl(localXdf))
            local_exec(rxDataStep(smry, localXdf, rowsPerRead=.dxOptions$rowsPerRead))

            output <- copy_to(rxGetFileSystem(.data), localXdf, dirname(.outFile))
        }
        else
        {
            # create xdf directly in HDFS
            if(is.character(.outFile))
                .outFile <- RxXdfData(.outFile, fileSystem=rxGetFileSystem(.data), createCompositeSet=TRUE)

            output <- local_exec(rxDataStep(smry, unTbl(.outFile), rowsPerRead=.dxOptions$rowsPerRead, overwrite=TRUE))
        }

        if(returnTbl)
            return(as(output, "tbl_xdf"))
        else return(output)
    }
    else # xdf output from summary worker -- should never happen
    {
        stop("cannot have xdf outputs from summary workers on HDFS", call.=FALSE)
    }
}


makeSmryOutputNative <- function(smry, .outFile, .data)
{
    if(is.data.frame(smry))
    {
        if(inherits(.outFile, "RxXdfData"))
            rxDataStep(smry, .outFile, rowsPerRead=.dxOptions$rowsPerRead, overwrite=TRUE)
        else if(is.character(.outFile))
        {
            .outFile <- RxXdfData(.outFile, createCompositeSet=is_composite_xdf(.data), fileSystem=RxNativeFileSystem())
            rxDataStep(smry, .outFile, rowsPerRead=.dxOptions$rowsPerRead, overwrite=TRUE)
        }
        else smry
    }
    else # xdf output from summary worker -- should never happen
    {
        warning("unexpected xdf output from summary worker")
        if(inherits(.outFile, "tbl_xdf"))
        {
            as(smry, "tbl_xdf")
        }
        else if(is.character(.outFile))
        {
            file.rename(smry@file, .outFile)
            RxXdfData(.outFile, createCompositeSet=is_composite_xdf(smry))
        }
        else as.data.frame(smry)
    }
}
