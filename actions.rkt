#lang at-exp racket

(provide get-all-runs!
         get-runs-by-url!
         get-run-by-url!
         cancel-run!
         launch-run!
         get-run-log!
         (struct-out ci-run))

(require "github-api.rkt"
         simple-option/either
         gregor
         file/unzip)

(struct ci-run (id
                url
                html-url
                commit
                status
                conclusion
                creation-time
                log-url
                cancel-url)
  #:prefab)

;; lltodo: this doesn't deal with pagination
(define/contract (get-all-runs! repo-owner repo-name)
  (string? string? . -> . (either/c (listof ci-run?)))

  (either-let*
   ([run-info (github-request! (~a "repos/" repo-owner "/" repo-name "/actions/runs"))]
    [runs (hash-ref/either run-info
                           'workflow_runs
                           @~a{Failed to get runs: @run-info})])
   (map json->ci-run runs)))

(define/contract (get-runs-by-url! repo-owner repo-name urls)
  (string? string? (listof string?) . -> . (either/c (hash/c string? (either/c ci-run?))))

  ;; Alternative version that (probably) more efficiently uses api calls, but
  ;; needs to deal with pagination
  #;(either-let*
     ([all-runs (get-all-runs! repo-owner repo-name)]
      [runs-by-url (for/hash ([run (in-list all-runs)])
                     (values (ci-run-url run) run))])
     (for/hash ([url (in-list urls)])
       (values url
               (hash-ref/option runs-by-url url @~a{No run found with url @url}))))
  (for/hash ([url (in-list urls)])
    (values url (get-run-by-url! url))))

(define/contract (get-run-by-url! url)
  (string? . -> . (either/c ci-run?))

  (either-let*
   ([run-json (github-request! url)
              #:extra-failure-message (~a url " : ")])
   (json->ci-run run-json)))

(define (failed-to action code headers in)
  (failure
   @~a{
       Failed to @action, response code @code
       Message: @(try-read-body-string code headers in)
       }))

(define (json->ci-run run-info-json)
  (match run-info-json
    [(hash-table ['id id]
                 ['url url]
                 ['html_url html-url]
                 ['head_sha commit]
                 ['status status]
                 ['conclusion conclusion]
                 ['created_at creation-time]
                 ['logs_url log-url]
                 ['cancel_url cancel-url]
                 _ ...)
     (ci-run id
             url
             html-url
             commit
             status
             conclusion
             (iso8601->moment creation-time)
             log-url
             cancel-url)]
    [else (failure "Unexpected run info shape in api response")]))

(define/contract (cancel-run! a-run)
  (ci-run? . -> . boolean?)

  (github-request! (ci-run-cancel-url a-run)
                   #:method POST
                   #:read-response (λ (code headers in) (equal? code 202))))

(define run-retrieval-polling-period-seconds 5)
(define run-retrieval-polling-timeout-seconds (* 1 60))

(define/contract (launch-run! repo-owner repo-name workflow-id ref)
  (string?
   string?
   string?
   string?
   . -> .
   (either/c ci-run?))

  (define (ci-run-newer? run1 run2)
    (moment>? (ci-run-creation-time run1)
              (ci-run-creation-time run2)))
  (define (newest-job-in jobs)
    (match (sort jobs ci-run-newer?)
      [(cons newest _) newest]
      ['() #f]))
  (define (wait/poll-for-new-job! original-jobs)
    (either-let*
     ([original-latest-job
       (let loop ([retry-count 0])
         (match (newest-job-in original-jobs)
           [(? ci-run? a-job) a-job]
           [else
            #:when (< (* retry-count run-retrieval-polling-period-seconds)
                      run-retrieval-polling-timeout-seconds)
            (sleep run-retrieval-polling-period-seconds)
            (loop (add1 retry-count))]
           [else (failure @~a{
                              Couldn't find launched job after polling for @;
                              @|run-retrieval-polling-timeout-seconds|s
                              })]))]
      [the-run
       (let loop ([retry-count 0])
         (match (get-all-runs! repo-owner repo-name)
           [(and (not (? failure?))
                 (app newest-job-in latest-job))
            #:when (ci-run-newer? latest-job original-latest-job)
            latest-job]
           [else
            #:when (< (* retry-count run-retrieval-polling-period-seconds)
                      run-retrieval-polling-timeout-seconds)
            (sleep run-retrieval-polling-period-seconds)
            (loop (add1 retry-count))]
           [else (failure @~a{
                              Couldn't find launched job after polling for @;
                              @|run-retrieval-polling-timeout-seconds|s
                              })]))])
     the-run))

  (either-let*
   ([jobs-before-launch (get-all-runs! repo-owner repo-name)]
    [_ (github-request! (~a "repos/" repo-owner "/" repo-name
                            "/actions/workflows/" workflow-id "/dispatches")
                        #:method POST
                        #:data (string->bytes/utf-8 @~a{{"ref": "@ref"}})
                        #:read-response (match-lambda**
                                         [{204 _ _} 'ok]
                                         [{other headers in}
                                          (failed-to "launch run"
                                                     other
                                                     headers
                                                     in)]))]
    [the-run (wait/poll-for-new-job! jobs-before-launch)])
   the-run))

(define wget (find-executable-path "wget"))

(define/contract (get-run-log! a-run #:section [section-name #f])
  ({ci-run?}
   {#:section (or/c string? #f)}
   . ->* .
   (either/c string?))

  (define (url->log-contents log-download-url)
    (with-handlers ([exn:fail? (λ (e) (failure @~a{Error raised while getting log: @(exn-message e)}))])
      (match-define (list stdout stdin _ stderr ctl)
        (process* wget
                  "-4" ;; wget sometimes hangs on IPv6 addresses, so force IPv4
                  "-O"
                  "-"
                  log-download-url))
      (close-output-port stdin)

      (define log-sections (box empty))
      (unzip
       stdout
       (match-lambda**
        [{(regexp #rx"^.*/([0-9]+)_(.+).txt$" (list _
                                                    section-number-bytes
                                                    section-name-bytes))
          #f
          contents-port}
         #:when (or (not section-name)
                    (string-ci=? (bytes->string/utf-8 section-name-bytes) section-name))
         ;; Sections aren't necessarily unpacked in order, so hang on to the section number
         ;; to order them later
         (define section-number (string->number (bytes->string/utf-8 section-number-bytes)))
         (set-box! log-sections
                   (cons (list section-number (port->string contents-port))
                         (unbox log-sections)))]
        [{_ _ _} (void)]))
      (ctl 'kill)
      (close-input-port stdout)
      (close-input-port stderr)

      (match (unbox log-sections)
        ['() (failure "Failed to get log using download url")]
        [sections
         (string-join (map second (sort sections < #:key first))
                      "\n")])))

  (either-let*
   ([log-download-url (github-request!
                       (ci-run-log-url a-run)
                       #:read-response (match-lambda**
                                        [{302 (regexp #rx"(?mi:^location: (.+?)$)" (list _ url)) _}
                                         url]
                                        [{302 headers in}
                                         (failed-to @~a{
                                                        parse log download url in headers:
                                                        @headers
                                                        }
                                                    302
                                                    headers
                                                    in)]
                                        [{other headers in}
                                         (failed-to "get log download url"
                                                    other
                                                    headers
                                                    in)]))]
    [contents (url->log-contents log-download-url)])
   contents))

