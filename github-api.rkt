#lang at-exp racket

(provide request!
         try-read-json
         try-read-body-string
         github-request!
         current-github-token
         load-github-token!
         GET POST)

(require net/url
         json)


(define-values {GET POST} (values 'get 'post))

(define (request! url
                  headers
                  [read-output (λ (code header in) (port->string in))]
                  #:method [method GET]
                  #:data [post-data #f])

  (define (read-output/parse-status in)
    (define header (purify-port in))
    (define code (match header
                   [(regexp @pregexp{HTTP/[^ ]* +(\d+)} (list _ code))
                    (string->number code)]
                   [else -1]))
    (read-output code header in))
  (call/input-url (string->url url)
                  (λ (url)
                    (define req-f
                      (match method
                        [(== GET)  get-impure-port]
                        [(== POST) (λ (url headers)
                                     (post-impure-port url (or post-data #"") headers))]))
                    (req-f url headers))
                  read-output/parse-status))

(define api-url? #rx"^https://.+[^/]$")
(define/contract current-github-api-base-url
  (parameter/c api-url?)
  (make-parameter "https://api.github.com"))
(define current-github-token
  (make-parameter #f))
(define (load-github-token! path)
  (current-github-token (with-output-to-string (thunk (system @~a{ gpg --batch -dq @path})))))

(define (try-read-json code headers in)
  (define in-str (port->string in))
  (with-handlers ([exn:fail:read? (λ _ in-str)])
    (call-with-input-string in-str read-json)))

(define (try-read-body-string code headers in)
  (match headers
    [(regexp #rx"(?mi:^content-length: (.+?)$)"
             (list _ (app string->number (? integer? len))))
     #:when (> len 0)
     (port->string in)]
    [else "<no message body>"]))

(define/contract (github-request! request-url
                                  #:output-type [output-type "application/vnd.github.v3+json"]
                                  #:auth-token [token (current-github-token)]
                                  #:base-url [base-url (current-github-api-base-url)]
                                  #:extra-headers [extra-headers '()]
                                  #:method [method GET]
                                  #:data [post-data #f]
                                  #:read-response [read-response try-read-json]
                                  #:user-agent [user-agent "software-construction-admin"])
  ({string?}
   {#:output-type string?
    #:auth-token string?
    #:base-url api-url?
    #:extra-headers (listof (and/c string? #rx".+: .+"))
    #:method (or/c GET POST)
    #:data bytes?
    #:read-response (integer? string? input-port? . -> . any)
    #:user-agent string?}
   . ->* .
   any)

  (request!
   (if (string-prefix? request-url "http")
       request-url
       @~a{@|base-url|@(if (string-prefix? request-url "/") "" "/")@request-url})
   (list* "Github-API-Version: 3"
          @~a{Accept: @output-type}
          @~a{Authorization: token @token}
          @~a{User-Agent: @user-agent}
          extra-headers)
   read-response
   #:method method
   #:data post-data))
