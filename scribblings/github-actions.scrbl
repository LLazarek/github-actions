#lang scribble/manual

@(require scribble/core)

@;;;;;;;;;;;;;;;@
@; Boilerplate ;@
@;;;;;;;;;;;;;;;@

@(require (for-label racket
                     github-actions
	  	     (only-in gregor moment?))
          scribble/example)

@(define github-actions-eval (make-base-eval))
@examples[#:eval github-actions-eval #:hidden (require racket github-actions simple-option/either)]

@title{github-actions}
@author{Lukas Lazarek}

This library provides a simple interface to @hyperlink["https://docs.github.com/en/rest/actions"]{github's actions api}.

@section{Interface}
@defmodule[github-actions]

@defparam[current-github-token token string? #:value #f]{
The parameter storing a @hyperlink["https://docs.github.com/en/rest/guides/getting-started-with-the-rest-api#using-personal-access-tokens"]{personal access token}.
This parameter needs to be set before using any of the api functions below.
}

@defproc[(launch-run! [repo-owner string?] [repo-name string?] [workflow-id string?] [ref string?]) (either/c actions-run?)]{
Request to launch a workflow run, and poll github to recover information about the run that gets launched, packaged up in a @racket[actions-run].
}

@defstruct*[actions-run ([id string?]
			 [url string?]
			 [html-url string?]
			 [commit string?]
			 [status string?]
			 [conclusion string?]
			 [creation-time moment?]
			 [log-url string?]
			 [cancel-url string?])
			 #:prefab]{
A struct packaging up the info about a workflow run provided by the Actions api.
}

@defproc[(cancel-run! [a-run actions-run?]) boolean?]{
Request to cancel a workflow run.
Returns whether the request was successfully received.
}

@defproc[(get-run-log! [a-run actions-run?] [#:section section-name (or/c string? #f) #f]) (either/c string?)]{
Request the log contents for a workflow run.
Optionally, just one section of the log can be retrieved with @racket[section-name] (otherwise it is the contents of every section concatenated).
Returns the contents as a string, if successful.
}

@defproc[(get-all-runs! [repo-owner string?] [repo-name string?]) (either/c (listof actions-run?))]{
Request a list of all workflow runs for a repo.

@emph{Limitation}: as of now, this does not handle pagination, so it only obtains the first page.
}

@defproc[(get-run-by-url! [url string?]) (either/c actions-run?)]{
Request information for a run using its url (as corresponds to the @racket[actions-run-url] field of an @racket[actions-run] instance).
}

@; @defproc[(get-runs-by-url! [repo-owner string?] [repo-name string?] [urls (listof string?)]) (either/c (hash/c string? (either/c actions-run?)))]{
@; Request information for multiple runs using their urls, like @racket[get-run-by-url!].
@; This function could more efficiently use api calls than using @racket[get-run-by-url!] once per url.
@; }

