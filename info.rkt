#lang info
(define collection "github-actions")
(define deps '("base"
               "gregor"
               "git://github.com/llazarek/simple-option.git"))
(define build-deps '("scribble-lib"
                     "racket-doc"
                     "at-exp-lib"))
(define pkg-desc "Github actions api library")
(define pkg-authors '(lukas))
(define scribblings '(("scribblings/github-actions.scrbl" ())))


