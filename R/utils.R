#' Make GET requests over several pages of an API
#'
#' @param ch_url URL to request from, preferably from the \code{path_*} functions
#' @param num_pages Number of pages to request
#' @param page The page at which the request should being. This should rarely be used
#' @param ... Arguments passed to \code{\link[httr]{GET}}
#'
#' @return the parsed JSON object as a list but inside the items
#' slots it contains all data lists obtained from the pages specified
#' in \code{num_pages}
get_resp_paginated <- function(ch_url, num_pages = 1, page = 0, ...) {

  # For the parsed items data_list
  data_list <- NULL
  # For the accumulated number of data_lists
  data_lists <- NULL

  while (num_pages > 0) {

    # IMPORTANT!!
    # All number of page queries should be specified as arguments in this
    # function rather than in the CH_URL
    ch_url <- httr::modify_url(ch_url,
                               query = list("_pageSize" = 50, "_page" = page))

    parsed_response <- get_resp(ch_url)

    data_list <- parsed_response$result$items
    data_lists <- c(data_list, data_lists)

    if (is.null(parsed_response$result$`next`)) {
      # finished pagination, can quit
      break
    }

    # set up for next iteration
    page <- page + 1
    num_pages <- num_pages - 1
  }

  # Return the last parsed_response but with
  # all accumulated datasets in the items slot
  parsed_response$result$items <- data_lists

  parsed_response
}


#' Make GET requests with repeated trials
#'
#' @param ch_url A url, preferably from the \code{path_*} functions
#' @param attempts_left Number of attempts of trying to request from the website
#' @param ... Arguments passed to \code{\link[httr]{GET}}
get_resp <- function(ch_url, attempts_left = 5, ...) {

  # Handle so that the API knows who's downloading the data
  ua <- httr::user_agent("https://github.com/ropenspain/opendataes")
  timeout <- httr::config(connecttimeout = 60)

  stopifnot(attempts_left > 0)

  resp <- httr::GET(ch_url, ua, httr::timeout(120), ...)
  # To avoid making too many quick requests
  Sys.sleep(1)

  # On a successful GET, return the response's content
  if (httr::status_code(resp) == 200) {
    # Ensure that returned response is application/json
    if (httr::http_type(resp) != "application/json") {
      stop("The datos.gob.es API returned an unusual format and not a JSON", call. = FALSE)
    }

    httr::content(resp)
  } else if (attempts_left == 1) { # When attempts run out, stop with an error
    httr::stop_for_status(resp) # Return appropiate error message
  } else { # Otherwise, sleep a second and try again
    Sys.sleep(1)
    get_resp(ch_url, attempts_left - 1)
  }

}

# This is a function factory that produces the same function
# but changes only one function. This function extracts
# the url format and assigns either that dataset's url
# or that dataset's name depending on the function passed to
# .fun. See the two functions below this function.
determine_valid_urls <- function(.fun) {
  function(data_list, allowed_formats = permitted_formats) {

    # URL formats
    url_formats <- extract_url_format(data_list)
    # This is the only thing that changes
    names(url_formats) <- .fun(data_list)

    available_formats <- allowed_formats %in% url_formats

    if (any(available_formats)) {
      # We turn to factor in order to sort according to the allowed formats.
      # This way when we subset we keep the order of preference of files.
      sorted_formats <- sort(factor(url_formats, levels = allowed_formats))

      names_urls <- names(sorted_formats)
      formats <- as.character(sorted_formats)

      index_formats <- formats %in% allowed_formats
      url_formats <- formats[index_formats]

      # We return the file format together with
      # the chosen unit for this particular function so that
      # we automatically subset the url without calling
      # extract_access_url again.
      names(url_formats) <- names_urls[index_formats]
    } else {
      url_formats <- character(0)
    }

    url_formats
  }
}

determine_dataset_name <- determine_valid_urls(extract_dataset_name)
determine_dataset_url <- determine_valid_urls(extract_access_url)

# If guess_encoding returns something, this function
# will return the guessed encoding. If for any reason
# guess_encoding cannot determine the encoding, it returns the
# fall back encoding
determine_dataset_encoding <- function(data_url, encoding) {
  # We have found some cases where the data is not hosted at the data_url provided by datos.gob.es
  # and for this reason we have to control what happen if guess_encoding cannot read from this url
  # If this occurs, it returns the fall back encoding
  # An example of this case is l01280796-multas-de-circulacion-detalle1
  guessed_encoding <- suppress_all(try(readr::guess_encoding(data_url), silent = TRUE))

  # If nrow == 0 it means that there are no encodings
  # with a threshold of confidence higher than 0.2
  if (inherits(guessed_encoding, "try-error")) {
    return(encoding)
  }
  else if (nrow(guessed_encoding) == 0) {
    return(encoding)
    # If the first encoding is NA, there was no encoding detected
  } else if (is.na(guessed_encoding$encoding[1])) {
    return(encoding)
  } else {
    return(guessed_encoding$encoding[1])
  }
}

suppress_all <- function(x) suppressMessages(suppressWarnings(x))


# This function checks the proportion of datasets that can be read from a specified publisher
check_datasets_read <- function(publisher) {

  message("Function started")
  res <- get_resp_paginated(ch_url = paste0("http://datos.gob.es/apidata/catalog/dataset/publisher/",publisher),
                            num_pages = 1000)
  message("Response obtained")
  # The results is a data_list
  datasets_can_read <- sapply(res$result$items, function(x) "csv" %in% determine_dataset_url(x))
  filtered_data <- res$result$items[datasets_can_read]

  # Here we obtain a vector with the URLs
  urls <- sapply(filtered_data, extract_endpath)

  # Apply openes_load over all urls.
  determine_number <- function(x) {
    check_read <- function(data) !all(names(data) %in% c('name', 'format', "URL"))

    has_url_col <- vapply(x[[2]], check_read, logical(1))
    number_of_reads  <- sum(has_url_col)

    number_of_reads
  }

  message("Reading data")
  all_data <- sapply(urls, function(x) {
    res <- determine_number(openes_load(x))
    cat(paste0(x, ": ", res, "\n"))
    res
  })

  # Count non zeros
  message("Total files read determined")
  count_non_zeros <- sapply(all_data, function(x) x != 0)
  return(sum(count_non_zeros) / length(count_non_zeros))
}
.onAttach <- function(libname, pkgname) {
   packageStartupMessage("\nPlease cite as: \n")
   packageStartupMessage("Cimentada, J. and Jorge Lopez (2019). Interact with the datos.gob.es API to download public data from all of Spain R package version 0.0.1")
}
