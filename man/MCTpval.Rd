\name{MCTpval}
\alias{MCTpval}
\title{
  Calculate multiplicity adjusted p-values for multiple contrast test
}
\description{
  Calculate multiplicity adjusted p-values for a maximum contrast test
  corresponding to a set of contrasts and given a set of observed test
  statistics. This function is exported as it may be a useful building
  block and used in more complex testing situations that are not covered
  by \code{\link{MCTtest}}. Most users probably don't need to use
  this function.
}
\usage{
MCTpval(contMat, corMat, df, tStat,
        alternative = c("one.sided", "two.sided"),
        control = mvtnorm.control())
}
\arguments{
  \item{contMat}{
    Contrast matrix to use. The individual contrasts should be saved in
    the columns of the matrix
}
\item{corMat}{
  correlation matrix of the contrasts
}
\item{df}{
  Degrees of freedom to assume in case \samp{S} (a general covariance
  matrix) is specified. When \samp{n} and \samp{sigma} are specified
  the ones from the corresponding ANOVA model are calculated.
}
\item{tStat}{
  Vector of contrast test statistics
}
\item{alternative}{
  Character determining the alternative for the multiple contrast
  trend test. 
}
\item{control}{
  A list specifying additional control parameters for the \samp{qmvt}
  and \samp{pmvt} calls in the code, see also \samp{mvtnorm.control}
  for details.
}
}
\value{
  Numeric containing the calculated p-values.
}
\references{
  Pinheiro, J. C., Bornkamp, B., and Bretz, F. (2006). Design and analysis of dose finding studies
combining multiple comparisons and modeling procedures, \emph{Journal of Biopharmaceutical
Statistics}, \bold{16}, 639--656

}
\author{
  Bjoern Bornkamp
}
\seealso{
  \code{\link{MCTtest}}, \code{\link{optContr}}
}
\examples{
## need to add example
}


